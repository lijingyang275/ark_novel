import 'dart:convert' show utf8;
import 'dart:io' show File, gzip;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/cat_chapter.dart';
import '../models/content.dart';
import 'data.dart';
import 'image_cache.dart';
import 'library.dart';
import 'read_state.dart';
import 'unlock.dart';

/// 离线章节缓存。正文放在 LazyBox（只在读的时候才从磁盘取，不常驻内存），
/// 章数、大小、书的信息放在一个很小的普通 Box 里，列表和计数不用碰正文。
///
/// - `chapters`（LazyBox）：`aid:cid` → `{z: gzip 压过的正文, i: [插图地址]}`（旧数据是 `{t: 正文, i: ...}`，后台慢慢转）
/// - `chapter_index`（Box）：`aid:cid` → 正文字数；`meta:aid` → 书名、总章数、封面、第一章；`oimg|aid` → 离线下载的插图地址
class ChapterCache {
  ChapterCache._();

  static late LazyBox _text;
  static late Box _index;

  /// aid → 已缓存章数、字数（书架每本书都要查，不能每次扫一遍索引）
  static final _counts = <String, int>{};
  static final _charsOf = <String, int>{};

  /// 删除次数：整本删一次 [_bookGen] 加一，删某几章时这几章各自的 [_chapterGen] 加一。
  /// 联网取正文前先记下 [ticket]，取回来写缓存时对不上就说明这期间被删过，不再写回去
  /// （否则「删掉缓存」之后，正在下载 / 预取的章节过几秒又出现了）。只在内存里，重启后从头算。
  static final _bookGen = <String, int>{};
  static final _chapterGen = <String, int>{};

  /// 写缓存的凭证：联网之前取，传给 [put] 的 `ticket`。
  static (int, int) ticket(String aid, String cid) => (_bookGen[aid] ?? 0, _chapterGen['$aid:$cid'] ?? 0);

  static void _tally(String aid, int n, int chars) {
    _counts[aid] = (_counts[aid] ?? 0) + n;
    _charsOf[aid] = (_charsOf[aid] ?? 0) + chars;
  }

  /// 章节的键是 `aid:cid`；网页备份的时间戳 `pt|网址` 里也有冒号，要排除
  static bool _isChapter(Object? k) => k is String && k.contains(':') && !k.startsWith('meta:') && !k.startsWith('pt|');

  static Future<void> open() async {
    _text = await Hive.openLazyBox('chapters');
    _index = await Hive.openBox('chapter_index');
    PageStore._box = await Hive.openLazyBox('pages');
    PageStore._stamp = _index;
    PageStore._lastWrite = _index.keys.whereType<String>().where((k) => k.startsWith('pt|')).fold<int>(0, (last, k) {
      final time = (_index.get(k) as int?) ?? 0;
      return time > last ? time : last;
    });
    await _migrate();
    for (final k in _index.keys.where(_isChapter)) {
      _tally((k as String).split(':').first, 1, (_index.get(k) as int?) ?? 0);
    }
  }

  /// 旧版本把 meta 和正文放在同一个 Box 里、没有索引：一次性搬过来。
  static Future<void> _migrate() async {
    if (_index.get('migrated') == true) return;
    for (final key in _text.keys.whereType<String>().toList()) {
      final v = await _text.get(key);
      if (v is! Map) continue;
      if (key.startsWith('meta:')) {
        await _index.put(key, v);
        await _text.delete(key);
      } else if (!_index.containsKey(key)) {
        await _index.put(key, (v['t'] as String).length);
      }
    }
    await _index.put('migrated', true);
  }

  /// 缓存的一章；没有、或者存坏了（解压不了）返回 null，当作没缓存重新取。
  static Future<Content?> get(String aid, String cid) async {
    final v = await _text.get('$aid:$cid');
    if (v is! Map) return null;
    try {
      return Content(text: _textOf(v), images: (v['i'] as List).cast<String>());
    } on FormatException {
      return null;
    }
  }

  static String _textOf(Map v) => v['z'] is List ? utf8.decode(gzip.decode(v['z'] as List<int>)) : v['t'] as String;

  // 中文正文 gzip 后一般不到原来的一半；网页预览没有 gzip，照旧存原文
  static Map<String, Object> _pack(String text, List<String> images) => kIsWeb ? {'t': text, 'i': images} : {'z': Uint8List.fromList(gzip.encode(utf8.encode(text))), 'i': images};

  /// 写入一章。给了 [ticket] 且这期间这章（或整本）被删过时不写，返回 false。
  static Future<bool> put(String aid, String cid, Content c, {(int, int)? ticket}) async {
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) return false;
    await _text.put('$aid:$cid', _pack(c.text, c.images));
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) {
      await _text.delete('$aid:$cid');
      return false;
    }
    final old = _index.get('$aid:$cid') as int?;
    _tally(aid, old == null ? 1 : 0, c.text.length - (old ?? 0));
    await _index.put('$aid:$cid', c.text.length);
    return true;
  }

  /// 旧版本存的原文在后台压一遍（只做一次），一章一章来；做完整理一下文件，空出来的地方才真正还给系统。
  static Future<void> compressOld() async {
    if (kIsWeb || _index.get('zipped') == true) return;
    for (final key in _text.keys.toList()) {
      final v = await _text.get(key);
      // 读的这会儿可能刚被删掉：索引里没有了就别写回去，否则留下删不掉的正文
      if (v is Map && v['t'] is String && _index.containsKey(key)) await _text.put(key, _pack(v['t'] as String, (v['i'] as List).cast<String>()));
    }
    await _text.compact();
    await _index.put('zipped', true);
  }

  /// 离线下载时记下这本书的插图，图片缓存清理时不删
  static Future<void> addOfflineImages(String aid, Iterable<String> urls) async {
    final old = ((_index.get('oimg|$aid') as List?) ?? const []).cast<String>();
    final all = {...old, ...urls};
    if (all.length != old.length) await _index.put('oimg|$aid', all.toList());
  }

  static Iterable<String> offlineImages() => _index.keys.whereType<String>().where((k) => k.startsWith('oimg|')).expand((k) => (_index.get(k) as List).cast<String>());

  static bool has(String aid, String cid) => _index.containsKey('$aid:$cid');

  /// 缓存的这章有多少字，没缓存为 null。
  static int? length(String aid, String cid) => _index.get('$aid:$cid') as int?;

  static Iterable<String> _keys(String aid) => _index.keys.whereType<String>().where((k) => k.startsWith('$aid:'));

  static int count(String aid) => _counts[aid] ?? 0;

  static Future<void> setMeta(String aid, String title, int total, String img, String firstCid) => _index.put('meta:$aid', {'title': title, 'total': total, 'img': img, 'first': firstCid});

  /// 这本书下载过离线缓存（缓存页里列着的）
  static bool offline(String aid) => _index.containsKey('meta:$aid');

  /// 有缓存的书：aid → (书名, 总章数, 封面地址, 第一章 cid)
  static Map<String, (String, int, String, String)> books() => {
    for (final k in _index.keys.whereType<String>().where((k) => k.startsWith('meta:')))
      k.substring(5): (
        (_index.get(k) as Map)['title'] as String,
        (_index.get(k) as Map)['total'] as int,
        ((_index.get(k) as Map)['img'] as String?) ?? '',
        ((_index.get(k) as Map)['first'] as String?) ?? '',
      ),
  };

  static Future<void> remove(String aid, {bool compact = true}) async {
    _bookGen[aid] = (_bookGen[aid] ?? 0) + 1;
    final keys = [..._keys(aid), 'meta:$aid', 'oimg|$aid'];
    _counts.remove(aid);
    _charsOf.remove(aid);
    await _index.deleteAll(keys);
    await _text.deleteAll(keys);
    if (compact) await _text.compact();
  }

  static Future<void> removeChapters(String aid, Iterable<String> cids, {bool compact = true}) async {
    for (final c in cids) {
      _chapterGen['$aid:$c'] = (_chapterGen['$aid:$c'] ?? 0) + 1;
    }
    final keys = [for (final c in cids) '$aid:$c'].where(_index.containsKey).toList();
    _tally(aid, -keys.length, -_chars(keys));
    await _index.deleteAll(keys);
    await _text.deleteAll(keys);
    if (compact) await _text.compact();
  }

  /// 有缓存章节的书（含读过自动缓存的）
  static Iterable<String> cachedBooks() => _counts.keys.where((a) => count(a) > 0);

  /// 清掉所有书里读过的章节（含离线缓存的书），返回清掉的章数
  static Future<int> clearRead() async {
    var n = 0;
    for (final aid in cachedBooks().toList()) {
      final read = ReadState.read(aid);
      final cids = [for (final k in _keys(aid)) k.substring(aid.length + 1)].where(read.contains).toList();
      if (cids.isEmpty) continue;
      n += cids.length;
      await removeChapters(aid, cids, compact: false);
    }
    await _text.compact();
    return n;
  }

  /// 清掉读过时自动缓存的章节（整本"离线缓存"的书不动），返回清掉的章数。
  static Future<int> clearAuto() async {
    final aids = _counts.keys.where((a) => !offline(a)).toList();
    var n = 0;
    for (final aid in aids) {
      n += count(aid);
      await remove(aid, compact: false);
    }
    await _text.compact();
    return n;
  }

  static int _allChars() => _charsOf.values.fold(0, (a, b) => a + b);

  static int _chars(Iterable keys) => keys.fold<int>(0, (a, k) => a + ((_index.get(k) as int?) ?? 0));

  /// 正文文件实际占用（含还没整理掉的旧数据）；网页预览拿不到，按每字 3 字节估
  static int totalBytes() {
    final path = kIsWeb ? null : _text.path;
    if (path == null) return _allChars() * 3;
    try {
      return File(path).lengthSync();
    } catch (_) {
      return _allChars() * 3;
    }
  }

  /// 一本书的正文大约占多少：按它的字数占总字数的比例分摊 [totalBytes]
  static int bytesOf(String aid) {
    final all = _allChars();
    return all == 0 ? 0 : (totalBytes() * (_charsOf[aid] ?? 0) / all).round();
  }

  static String totalLabel() => sizeText(totalBytes());

  static String sizeLabel(String aid) => sizeText(bytesOf(aid));
}

String sizeText(int bytes) => bytes > 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';

/// 网页原文的离线备份（详情、目录、书架、用户页）：联网并解析成功后才更新，断网时拿来顶替。
/// 最多保留 [_cap] 页，超出删写入最早的（写入时间记在 chapter_index 里，Hive 自己的顺序是按键排的，不能拿来判断新旧）；
/// 账号私有的页面（书架）键里带用户 ID，退出登录时清掉。本地书架里的书的详情和目录不参与淘汰，一直留着。
class PageStore {
  PageStore._();

  static late LazyBox _box;
  static late Box _stamp;
  static const _cap = 400;
  static int _lastWrite = 0;

  static int _time(String key) => (_stamp.get('pt|$key') as int?) ?? 0;

  static Future<String?> get(String key) async => await _box.get(key) as String?;

  static bool has(String key) => _box.containsKey(key);

  static final _bookPage = RegExp(r'(?:articleinfo\.php\?id=|reader\.php\?aid=)(\d+)$');

  static bool _pinned(String key) {
    final m = _bookPage.firstMatch(key);
    return m != null && LibraryStore.contains(m[1]!);
  }

  static Future<void> put(String key, String html) async {
    await _box.put(key, html);
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastWrite = now > _lastWrite ? now : _lastWrite + 1; // 同一毫秒内也有严格顺序，不让淘汰结果取决于 Hive 的键排序
    await _stamp.put('pt|$key', _lastWrite);
    final loose = _box.keys.whereType<String>().where((k) => !_pinned(k)).toList();
    while (loose.length > _cap) {
      final oldest = loose.reduce((a, b) => _time(a) <= _time(b) ? a : b);
      loose.remove(oldest);
      await _box.delete(oldest);
      await _stamp.delete('pt|$oldest');
    }
  }

  static Future<void> removeScope(String scope) async {
    final keys = _box.keys.where((k) => k is String && k.startsWith('$scope|')).toList();
    await _box.deleteAll(keys);
    await _stamp.deleteAll([for (final k in keys) 'pt|$k']);
  }
}

class DownloadState {
  const DownloadState({this.done = 0, this.total = 0, this.running = false, this.error});

  final int done;
  final int total;
  final bool running;
  final String? error;
}

/// 缓存下载：一本书一个任务，章节一章一章下载（放慢一点，避免被网站限流），可暂停。
/// 正文和插图都下载，断网后插图也能显示。
class DownloadController extends Notifier<Map<String, DownloadState>> {
  final _cancelled = <String>{};
  // 每本书第几次下载：删除缓存（[forget]）或重新开始后，旧的那次不再更新状态，不会把清掉的进度又加回来
  final _runs = <String, int>{};

  @override
  Map<String, DownloadState> build() => {};

  void cancel(String aid) => _cancelled.add(aid);

  /// 删除缓存后把这本书的下载状态一起清掉（不重建整个 Notifier，免得打断别的书的下载）。
  void forget(String aid) {
    _cancelled.add(aid);
    _runs[aid] = (_runs[aid] ?? 0) + 1;
    state = {...state}..remove(aid);
  }

  /// 下载 [chapters] 里还没缓存的章节；[total] 是全书章数，用来显示整本书的进度。
  Future<void> start(String aid, String title, List<CatChapter> chapters, {int? total, String img = '', String firstCid = ''}) async {
    if (state[aid]?.running ?? false) return;
    final api = ref.read(apiProvider);
    final images = ref.read(imageStoreProvider);
    final all = total ?? chapters.length;
    _cancelled.remove(aid);
    final run = _runs[aid] = (_runs[aid] ?? 0) + 1;
    bool stale() => _runs[aid] != run;
    void emit({bool running = true, String? error}) {
      if (!ref.mounted || stale()) return;
      state = {...state, aid: DownloadState(done: ChapterCache.count(aid), total: all, running: running, error: error)};
    }

    emit();
    await ChapterCache.setMeta(aid, title, all, img, firstCid.isEmpty && chapters.isNotEmpty ? chapters.first.cid : firstCid);
    try {
      for (final c in chapters) {
        if (_cancelled.contains(aid) || stale()) break;
        if (ChapterCache.has(aid, c.cid)) continue;
        final ticket = ChapterCache.ticket(aid, c.cid);
        final Content content;
        try {
          content = await api.chapter(aid, c.cid);
        } on ChapterLockedException {
          continue; // 受限书 TXT 里没有的章（插图），跳过
        }
        // 请求期间可能已经暂停或删除了缓存：此时不能再写回去
        if (_cancelled.contains(aid)) break;
        // 写不进去：整本被删了就停；只是这一章被删了（比如「清掉已读章节」）就跳过它接着下
        if (!await ChapterCache.put(aid, c.cid, content, ticket: ticket)) {
          if (ChapterCache.ticket(aid, c.cid).$1 != ticket.$1) break;
          continue;
        }
        for (final url in content.images) {
          try {
            await images.load(url);
          } catch (_) {}
        }
        // 下插图这段时间缓存可能被删了：不再记插图（删除时已经把这条记录清掉了）
        if (ChapterCache.ticket(aid, c.cid).$1 != ticket.$1) break;
        await ChapterCache.addOfflineImages(aid, content.images);
        emit();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      emit(running: false);
    } catch (e) {
      emit(running: false, error: e.toString());
    }
  }
}

final downloadProvider = NotifierProvider<DownloadController, Map<String, DownloadState>>(DownloadController.new);
