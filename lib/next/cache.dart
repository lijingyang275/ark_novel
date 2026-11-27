import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show File, gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder, GZipEncoder;
import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_client.dart' show runInBackground;
import '../models/cat_chapter.dart';
import '../models/content.dart';
import 'data.dart';
import 'image_cache.dart';
import 'library.dart';
import 'read_state.dart';
import 'session.dart' show friendlyError;
import 'unlock.dart';

Uint8List _gzipEncodeString(String text) =>
    kIsWeb ? Uint8List.fromList(GZipEncoder().encode(utf8.encode(text))) : Uint8List.fromList(gzip.encode(utf8.encode(text)));

String _gzipDecodeString(Uint8List bytes) => kIsWeb ? utf8.decode(GZipDecoder().decodeBytes(bytes)) : utf8.decode(gzip.decode(bytes));

/// 离线章节缓存。正文放在 LazyBox（只在读的时候才从磁盘取，不常驻内存），
/// 章数、大小、书的信息放在一个很小的普通 Box 里，列表和计数不用碰正文。
///
/// - `chapters`（LazyBox）：`aid:cid` → `{z: gzip 压过的正文, i: [插图地址]}`（旧数据是 `{t: 正文, i: ...}`，后台慢慢转）
/// - `chapter_index`（Box）：`aid:cid` → 正文字数；`meta:aid` → 书名、总章数、封面、第一章；`oimg|aid` → 离线下载的插图地址
class ChapterCache {
  ChapterCache._();

  static LazyBox? _text;
  static Box? _index;
  static int _openGen = 0;
  static Completer<LazyBox>? _textReady;
  static Completer<LazyBox>? _pagesReady;

  /// aid → 已缓存章数、字数（书架每本书都要查，不能每次扫一遍索引）
  static final _counts = <String, int>{};
  static final _charsOf = <String, int>{};
  static int _totalChars = 0;
  static int? _cachedFileBytes;

  /// 刚写入的最近 3 章极小内存热缓存，避免阅读器预取写盘后立刻读盘解压。
  static const _hotChapterCap = 3;
  static const _computeGzipThreshold = 16384;
  static const _compressBatchSize = 10;
  static final _hotChapters = <String, Content>{};

  static Box get _idx => (_index != null && _index!.isOpen) ? _index! : Hive.box('chapter_index');

  static bool _lazyCompaction(int entries, int deletedEntries) =>
      deletedEntries >= 100 || (entries > 0 && deletedEntries > 40 && deletedEntries / entries > 0.15);

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
    _totalChars += chars;
    if (_totalChars < 0) _totalChars = 0;
  }

  static void _rememberHotChapter(String key, Content content) {
    _hotChapters.remove(key);
    _hotChapters[key] = content;
    while (_hotChapters.length > _hotChapterCap) {
      _hotChapters.remove(_hotChapters.keys.first);
    }
  }

  /// 释放内存中的最近章节热缓存。
  static void evictMemory() => _hotChapters.clear();

  static void _rebuildCountsFromIndex() {
    _counts.clear();
    _charsOf.clear();
    _totalChars = 0;
    var lastWrite = 0;
    final idx = _idx;
    for (final k in idx.keys) {
      if (k is! String) continue;
      if (k.startsWith('pt|')) {
        final time = (idx.get(k) as int?) ?? 0;
        if (time > lastWrite) lastWrite = time;
      } else {
        final sep = k.indexOf(':');
        if (sep > 0 && !k.startsWith('meta:')) {
          _tally(k.substring(0, sep), 1, (idx.get(k) as int?) ?? 0);
        }
      }
    }
    PageStore._lastWrite = lastWrite;
    PageStore.invalidateLooseCount();
  }

  /// 冷启动只同步打开很小的 `chapter_index`；两个大 LazyBox（`chapters`/`pages`）异步在后台打开，
  /// 由 [ensureTextReady] / [ensurePagesReady] 守卫，所有异步读写透明等待就绪。
  static Future<void> open() async {
    final prevText = _textReady;
    final prevPages = _pagesReady;
    final gen = ++_openGen;
    _text = null;
    _textReady = null;
    _pagesReady = null;
    PageStore._box = null;
    _cachedFileBytes = null;
    _hotChapters.clear();

    // 若前一次 open 的后台 LazyBox 打开尚未结束（如备份恢复重开或单测快速切换目录），
    // 等其感知旧代号并关闭旧句柄后再开新目录，避免 Hive 全局映射残留已删目录的旧 Box。
    if (prevText != null && !prevText.isCompleted) {
      await prevText.future.then<void>((_) {}, onError: (_) {});
    }
    if (prevPages != null && !prevPages.isCompleted) {
      await prevPages.future.then<void>((_) {}, onError: (_) {});
    }

    final index = await Hive.openBox('chapter_index');
    _index = index;
    PageStore._stamp = index;
    _rebuildCountsFromIndex();

    // 后台触发两个大 LazyBox 打开；忽略无人等待时的关闭竞态错误，显式 await ensure*Ready 仍会正常感知错误。
    unawaited(_startOpenText(gen).then<void>((_) {}, onError: (_) {}));
    unawaited(_startOpenPages(gen).then<void>((_) {}, onError: (_) {}));
  }

  static Future<LazyBox> _startOpenText(int gen) {
    final completer = Completer<LazyBox>();
    _textReady = completer;
    () async {
      try {
        final box = await Hive.openLazyBox('chapters', compactionStrategy: _lazyCompaction);
        if (gen != _openGen || _index == null || !_index!.isOpen || !box.isOpen) {
          try {
            if (box.isOpen) await box.close();
          } catch (_) {}
          if (!completer.isCompleted) completer.complete(box);
          return;
        }
        _text = box;
        if (_index!.get('migrated') != true) {
          await _migrate(box);
          if (gen == _openGen && _index!.isOpen) _rebuildCountsFromIndex();
        }
        if (gen == _openGen && box.isOpen) {
          unawaited(_refreshFileBytes(box, gen));
        }
        if (!completer.isCompleted) completer.complete(box);
      } catch (e, st) {
        if (identical(_textReady, completer)) _textReady = null;
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    }();
    return completer.future;
  }

  static Future<LazyBox> _startOpenPages(int gen) {
    final completer = Completer<LazyBox>();
    _pagesReady = completer;
    () async {
      try {
        final box = await Hive.openLazyBox('pages', compactionStrategy: _lazyCompaction);
        if (gen != _openGen || _index == null || !_index!.isOpen || !box.isOpen) {
          try {
            if (box.isOpen) await box.close();
          } catch (_) {}
          if (!completer.isCompleted) completer.complete(box);
          return;
        }
        PageStore._box = box;
        if (!completer.isCompleted) completer.complete(box);
      } catch (e, st) {
        if (identical(_pagesReady, completer)) _pagesReady = null;
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    }();
    return completer.future;
  }

  /// 确保 `chapters` LazyBox 已完成打开与一次性迁移。
  static Future<LazyBox> ensureTextReady() {
    final existing = _text;
    if (existing != null && existing.isOpen) return Future.value(existing);
    final ready = _textReady;
    if (ready != null) return ready.future;
    return _startOpenText(_openGen);
  }

  /// 确保 `pages` LazyBox 已完成打开。
  static Future<LazyBox> ensurePagesReady() {
    final existing = PageStore._box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    final ready = _pagesReady;
    if (ready != null) return ready.future;
    return _startOpenPages(_openGen);
  }

  /// 旧版本把 meta 和正文放在同一个 Box 里、没有索引：一次性搬过来。
  static Future<void> _migrate(LazyBox textBox) async {
    final idx = _idx;
    if (idx.get('migrated') == true) return;
    for (final key in textBox.keys.whereType<String>().toList()) {
      final v = await textBox.get(key);
      if (v is! Map) continue;
      if (key.startsWith('meta:')) {
        await idx.put(key, v);
        await textBox.delete(key);
      } else if (!idx.containsKey(key) && v['t'] is String) {
        await idx.put(key, (v['t'] as String).length);
      }
    }
    await idx.put('migrated', true);
  }

  /// 缓存的一章；没有、或者存坏了（解压不了）返回 null，当作没缓存重新取。
  static Future<Content?> get(String aid, String cid) async {
    final key = '$aid:$cid';
    final hot = _hotChapters.remove(key);
    if (hot != null) {
      _hotChapters[key] = hot;
      return hot;
    }
    final textBox = await ensureTextReady();
    final v = await textBox.get(key);
    if (v is! Map) return null;
    try {
      final text = await _textOfAsync(v);
      return Content(text: text, images: (v['i'] as List).cast<String>());
    } on FormatException {
      return null;
    }
  }

  static Future<String> _textOfAsync(Map v) async {
    if (v['z'] is List) {
      final raw = v['z'] as List<int>;
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      if (!kIsWeb && bytes.length >= _computeGzipThreshold) {
        return compute(_gzipDecodeString, bytes);
      }
      return _gzipDecodeString(bytes);
    }
    return v['t'] as String;
  }

  // 中文正文 gzip 后一般不到原来的一半；网页预览没有 gzip，照旧存原文
  static Map<String, Object> _pack(String text, List<String> images) =>
      kIsWeb ? {'t': text, 'i': images} : {'z': Uint8List.fromList(gzip.encode(utf8.encode(text))), 'i': images};

  static Future<Map<String, Object>> _packAsync(String text, List<String> images) async {
    if (kIsWeb) return {'t': text, 'i': images};
    if (text.length >= _computeGzipThreshold) {
      return {'z': await compute(_gzipEncodeString, text), 'i': images};
    }
    return {'z': Uint8List.fromList(gzip.encode(utf8.encode(text))), 'i': images};
  }

  /// 写入一章。给了 [ticket] 且这期间这章（或整本）被删过时不写，返回 false。
  static Future<bool> put(String aid, String cid, Content c, {(int, int)? ticket}) async {
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) return false;
    final textBox = await ensureTextReady();
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) return false;
    final packed = await _packAsync(c.text, c.images);
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) return false;
    final key = '$aid:$cid';
    await textBox.put(key, packed);
    if (ticket != null && ticket != ChapterCache.ticket(aid, cid)) {
      await textBox.delete(key);
      return false;
    }
    final old = _idx.get(key) as int?;
    _tally(aid, old == null ? 1 : 0, c.text.length - (old ?? 0));
    _rememberHotChapter(key, c);
    await _idx.put(key, c.text.length);
    unawaited(_refreshFileBytes(textBox));
    return true;
  }

  /// 批量写入同一本书的多章内容（供整本文本拆章一次性落盘，显著减少 Hive 逐条刷盘开销）。
  /// [entries] 为 `cid -> (length, images, gzipped, text)`；支持直接传入后台 Isolate 预压缩好的 gzip [Uint8List]。
  static Future<int> putBatch(
    String aid,
    Map<String, ({int length, List<String> images, Uint8List? gzipped, String? text})> entries, {
    int? bookTicket,
    Map<String, (int, int)>? tickets,
  }) async {
    if (entries.isEmpty) return 0;
    if (bookTicket != null && (_bookGen[aid] ?? 0) != bookTicket) return 0;
    final textBox = await ensureTextReady();
    if (bookTicket != null && (_bookGen[aid] ?? 0) != bookTicket) return 0;

    final textPuts = <String, Object>{};
    final indexPuts = <String, int>{};
    final accepted = <String, ({int length, List<String> images, String? text})>{};
    for (final MapEntry(key: cid, value: item) in entries.entries) {
      final t = tickets?[cid];
      if (t != null && t != ticket(aid, cid)) continue;
      final key = '$aid:$cid';
      final Map<String, Object> packed;
      if (!kIsWeb && item.gzipped != null) {
        packed = {'z': item.gzipped!, 'i': item.images};
      } else {
        packed = _pack(item.text ?? '', item.images);
      }
      textPuts[key] = packed;
      indexPuts[key] = item.length;
      accepted[key] = (length: item.length, images: item.images, text: item.text);
    }
    if (textPuts.isEmpty) return 0;

    await textBox.putAll(textPuts);
    final staleKeys = <String>[];
    for (final key in textPuts.keys) {
      final cid = key.substring(aid.length + 1);
      final t = tickets?[cid];
      final bookStale = bookTicket != null && (_bookGen[aid] ?? 0) != bookTicket;
      if (bookStale || (t != null && t != ticket(aid, cid))) {
        staleKeys.add(key);
      }
    }
    if (staleKeys.isNotEmpty) {
      await textBox.deleteAll(staleKeys);
      for (final k in staleKeys) {
        indexPuts.remove(k);
        accepted.remove(k);
      }
    }
    if (indexPuts.isEmpty) {
      unawaited(_refreshFileBytes(textBox));
      return 0;
    }

    final idx = _idx;
    for (final MapEntry(key: key, value: len) in indexPuts.entries) {
      final old = idx.get(key) as int?;
      _tally(aid, old == null ? 1 : 0, len - (old ?? 0));
      final info = accepted[key];
      if (info?.text != null) {
        _rememberHotChapter(key, Content(text: info!.text!, images: info.images));
      } else {
        _hotChapters.remove(key);
      }
    }
    await idx.putAll(indexPuts);
    unawaited(_refreshFileBytes(textBox));
    return indexPuts.length;
  }

  /// 旧版本存的原文在后台分批压一遍（只做一次），批次间让出帧时间；做完整理一下文件，空出来的地方才真正还给系统。
  static Future<void> compressOld() async {
    if (kIsWeb || _idx.get('zipped') == true) return;
    final textBox = await ensureTextReady();
    final idx = _idx;
    final keys = textBox.keys.toList();
    for (var i = 0; i < keys.length; i += _compressBatchSize) {
      final end = (i + _compressBatchSize).clamp(0, keys.length);
      final batchPuts = <Object, Object>{};
      for (var j = i; j < end; j++) {
        final key = keys[j];
        final v = await textBox.get(key);
        // 读的这会儿可能刚被删掉：索引里没有了就别写回去，否则留下删不掉的正文
        if (v is Map && v['t'] is String && idx.containsKey(key)) {
          final packed = await _packAsync(v['t'] as String, (v['i'] as List).cast<String>());
          if (idx.containsKey(key)) batchPuts[key] = packed;
        }
      }
      if (batchPuts.isNotEmpty) await textBox.putAll(batchPuts);
      if (end < keys.length) await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await textBox.compact();
    await idx.put('zipped', true);
    unawaited(_refreshFileBytes(textBox));
  }

  /// 离线下载时记下这本书的插图，图片缓存清理时不删
  static Future<void> addOfflineImages(String aid, Iterable<String> urls) async {
    final idx = _idx;
    final old = ((idx.get('oimg|$aid') as List?) ?? const []).cast<String>();
    final all = {...old, ...urls};
    if (all.length != old.length) await idx.put('oimg|$aid', all.toList());
  }

  static Iterable<String> offlineImages() => _idx.keys.whereType<String>().where((k) => k.startsWith('oimg|')).expand((k) => (_idx.get(k) as List).cast<String>());

  static bool has(String aid, String cid) => _idx.containsKey('$aid:$cid');

  /// 缓存的这章有多少字，没缓存为 null。
  static int? length(String aid, String cid) => _idx.get('$aid:$cid') as int?;

  static Iterable<String> _keys(String aid) => _idx.keys.whereType<String>().where((k) => k.startsWith('$aid:'));

  static int count(String aid) => _counts[aid] ?? 0;

  static Future<void> setMeta(String aid, String title, int total, String img, String firstCid) => _idx.put('meta:$aid', {'title': title, 'total': total, 'img': img, 'first': firstCid});

  /// 这本书下载过离线缓存（缓存页里列着的）
  static bool offline(String aid) => _idx.containsKey('meta:$aid');

  /// O(1) 读取单本书的离线缓存元数据：`(书名, 总章数, 封面地址, 第一章 cid)`，不存在返回 null。
  static (String, int, String, String)? metaOf(String aid) {
    if (!Hive.isBoxOpen('chapter_index')) return null;
    final m = _idx.get('meta:$aid');
    if (m is! Map) return null;
    return (
      m['title'] as String,
      m['total'] as int,
      (m['img'] as String?) ?? '',
      (m['first'] as String?) ?? '',
    );
  }

  /// 有缓存的书：aid → (书名, 总章数, 封面地址, 第一章 cid)
  static Map<String, (String, int, String, String)> books() {
    final idx = _idx;
    return {
      for (final k in idx.keys.whereType<String>().where((k) => k.startsWith('meta:')))
        k.substring(5): (
          (idx.get(k) as Map)['title'] as String,
          (idx.get(k) as Map)['total'] as int,
          ((idx.get(k) as Map)['img'] as String?) ?? '',
          ((idx.get(k) as Map)['first'] as String?) ?? '',
        ),
    };
  }

  static Future<void> remove(String aid, {bool compact = true}) async {
    _bookGen[aid] = (_bookGen[aid] ?? 0) + 1;
    final textBox = await ensureTextReady();
    final idx = _idx;
    final keys = [..._keys(aid), 'meta:$aid', 'oimg|$aid'];
    _counts.remove(aid);
    final removedChars = _charsOf.remove(aid) ?? 0;
    _totalChars -= removedChars;
    if (_totalChars < 0) _totalChars = 0;
    _hotChapters.removeWhere((k, _) => k.startsWith('$aid:'));
    await idx.deleteAll(keys);
    await textBox.deleteAll(keys);
    if (Hive.isBoxOpen('session')) await Hive.box('session').delete('unlock:txt:$aid');
    if (compact) await textBox.compact();
    unawaited(_refreshFileBytes(textBox));
  }

  static Future<void> removeChapters(String aid, Iterable<String> cids, {bool compact = true}) async {
    for (final c in cids) {
      _chapterGen['$aid:$c'] = (_chapterGen['$aid:$c'] ?? 0) + 1;
      _hotChapters.remove('$aid:$c');
    }
    final textBox = await ensureTextReady();
    final idx = _idx;
    final keys = [for (final c in cids) '$aid:$c'].where(idx.containsKey).toList();
    _tally(aid, -keys.length, -_chars(keys));
    await idx.deleteAll(keys);
    await textBox.deleteAll(keys);
    if (compact) await textBox.compact();
    unawaited(_refreshFileBytes(textBox));
  }

  /// 有缓存章节的书（含读过自动缓存的）
  static Iterable<String> cachedBooks() => _counts.keys.where((a) => count(a) > 0);

  /// 清掉所有书里读过的章节（含离线缓存的书），返回清掉的章数
  static Future<int> clearRead() async {
    final textBox = await ensureTextReady();
    var n = 0;
    for (final aid in cachedBooks().toList()) {
      final read = ReadState.readView(aid);
      final cids = [for (final k in _keys(aid)) k.substring(aid.length + 1)].where(read.contains).toList();
      if (cids.isEmpty) continue;
      n += cids.length;
      await removeChapters(aid, cids, compact: false);
    }
    await textBox.compact();
    unawaited(_refreshFileBytes(textBox));
    return n;
  }

  /// 清掉读过时自动缓存的章节（整本"离线缓存"的书不动），返回清掉的章数。
  static Future<int> clearAuto() async {
    final textBox = await ensureTextReady();
    final aids = _counts.keys.where((a) => !offline(a)).toList();
    var n = 0;
    for (final aid in aids) {
      n += count(aid);
      await remove(aid, compact: false);
    }
    await textBox.compact();
    unawaited(_refreshFileBytes(textBox));
    return n;
  }

  static int _chars(Iterable keys) {
    final idx = _idx;
    return keys.fold<int>(0, (a, k) => a + ((idx.get(k) as int?) ?? 0));
  }

  static Future<void> _refreshFileBytes([LazyBox? box, int? gen]) async {
    if (kIsWeb) return;
    final target = box ?? _text;
    final expectedGen = gen ?? _openGen;
    final path = target?.path;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        final len = await file.length();
        if (expectedGen == _openGen) _cachedFileBytes = len;
      }
    } catch (_) {}
  }

  /// 异步刷新正文文件实际字节数缓存并返回最新值（不阻塞 UI 线程）。
  static Future<int> refreshTotalBytes() async {
    final box = await ensureTextReady();
    await _refreshFileBytes(box, _openGen);
    return totalBytes();
  }

  /// 正文文件实际占用（纯内存 O(1) 返回，后台异步刷新文件长度，零主线程 syscall）；尚未刷新或网页端按每字 3 字节估。
  static int totalBytes() {
    if (!kIsWeb) {
      final cached = _cachedFileBytes;
      if (cached != null) return cached;
    }
    return _totalChars * 3;
  }

  /// 一本书的正文大约占多少：按它的字数占总字数的比例分摊 [totalBytes]
  static int bytesOf(String aid) {
    final all = _totalChars;
    return all == 0 ? 0 : (totalBytes() * (_charsOf[aid] ?? 0) / all).round();
  }

  static String totalLabel() => sizeText(totalBytes());

  static String sizeLabel(String aid) => sizeText(bytesOf(aid));
}

final chapterCacheChangesProvider = StreamProvider.autoDispose<BoxEvent>(
  (ref) => Hive.box('chapter_index').watch().where((e) => e.key is! String || !(e.key as String).startsWith('pt|')),
);

String sizeText(int bytes) => bytes > 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';

/// 网页原文的离线备份（详情、目录、书架、用户页）：联网并解析成功后才更新，断网时拿来顶替。
/// 最多保留 [_cap] 页，超出删写入最早的（写入时间记在 chapter_index 里，Hive 自己的顺序是按键排的，不能拿来判断新旧）；
/// 账号私有的页面（书架）键里带用户 ID，退出登录时清掉。本地书架里的书的详情和目录不参与淘汰，一直留着。
class PageStore {
  PageStore._();

  static LazyBox? _box;
  static Box? _stamp;
  static const _cap = 400;
  static int _lastWrite = 0;
  static int? _looseCount;
  static int _looseGen = 0;

  static Box get _stampBox => (_stamp != null && _stamp!.isOpen) ? _stamp! : Hive.box('chapter_index');

  /// 书架增删改变了 `_pinned` 集合时调用，令非固定页计数失效。
  static void invalidateLooseCount() {
    _looseGen++;
    _looseCount = null;
  }

  static int _time(String key) => (_stampBox.get('pt|$key') as int?) ?? 0;

  /// 读取离线网页备份：兼容新版本 gzip 压缩的 [Uint8List] 与老版本未压缩的明文 [String]。
  static Future<String?> get(String key) async {
    final box = await ChapterCache.ensurePagesReady();
    final raw = await box.get(key);
    if (raw == null) return null;
    if (raw is String) return raw;
    if (raw is List<int>) {
      try {
        final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
        if (!kIsWeb && bytes.length >= ChapterCache._computeGzipThreshold) {
          return await compute(_gzipDecodeString, bytes);
        }
        return _gzipDecodeString(bytes);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static bool has(String key) {
    final box = _box;
    if (box != null && box.isOpen) return box.containsKey(key);
    if (Hive.isBoxOpen('pages')) return Hive.lazyBox('pages').containsKey(key);
    if (_stamp != null && _stamp!.isOpen) return _stamp!.containsKey('pt|$key');
    return Hive.isBoxOpen('chapter_index') && Hive.box('chapter_index').containsKey('pt|$key');
  }

  static final _bookPage = RegExp(r'(?:articleinfo\.php\?id=|reader\.php\?aid=)(\d+)$');

  static bool _pinned(String key) {
    final m = _bookPage.firstMatch(key);
    return m != null && LibraryStore.contains(m[1]!);
  }

  static Future<void> put(String key, String html) async {
    final box = await ChapterCache.ensurePagesReady();
    final stamp = _stampBox;
    final existed = box.containsKey(key);
    final genBeforePut = _looseGen;
    final compressed = (!kIsWeb && html.length >= ChapterCache._computeGzipThreshold)
        ? await compute(_gzipEncodeString, html)
        : _gzipEncodeString(html);
    await box.put(key, compressed);
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastWrite = now > _lastWrite ? now : _lastWrite + 1; // 同一毫秒内也有严格顺序，不让淘汰结果取决于 Hive 的键排序
    await stamp.put('pt|$key', _lastWrite);
    if (box.length <= _cap) {
      invalidateLooseCount();
      return;
    }
    if (!existed && genBeforePut == _looseGen && _looseCount != null && !_pinned(key)) {
      _looseCount = _looseCount! + 1;
    }
    if (_looseCount != null && _looseCount! <= _cap) return;
    final genBeforeEvict = _looseGen;
    final loose = box.keys.whereType<String>().where((k) => !_pinned(k)).toList();
    final toDelete = <String>[];
    final stampDelete = <String>[];
    while (loose.length > _cap) {
      final oldest = loose.reduce((a, b) => _time(a) <= _time(b) ? a : b);
      loose.remove(oldest);
      toDelete.add(oldest);
      stampDelete.add('pt|$oldest');
    }
    if (toDelete.isNotEmpty) {
      await box.deleteAll(toDelete);
      await stamp.deleteAll(stampDelete);
    }
    if (genBeforeEvict == _looseGen) {
      _looseCount = loose.length;
    }
  }

  static Future<void> removeScope(String scope) async {
    final box = await ChapterCache.ensurePagesReady();
    final stamp = _stampBox;
    final keys = box.keys.where((k) => k is String && k.startsWith('$scope|')).toList();
    await box.deleteAll(keys);
    await stamp.deleteAll([for (final k in keys) 'pt|$k']);
    invalidateLooseCount();
  }

  /// 清空全部网页离线备份并整理磁盘文件。
  static Future<void> clear() async {
    final box = await ChapterCache.ensurePagesReady();
    final stamp = _stampBox;
    final stamps = stamp.keys.where((k) => k is String && k.startsWith('pt|')).toList();
    await box.clear();
    await stamp.deleteAll(stamps);
    await box.compact();
    _looseGen++;
    _looseCount = 0;
  }
}

class DownloadState {
  const DownloadState({this.done = 0, this.total = 0, this.running = false, this.error});

  final int done;
  final int total;
  final bool running;
  final String? error;
}

class _DownloadTask {
  _DownloadTask({required this.aid, required this.chapters, required this.total, required this.run});

  final String aid;
  final List<CatChapter> chapters;
  final int total;
  final int run;
  final cancelToken = CancelToken();
  final activeImages = <String>{};
  final done = Completer<void>();
}

/// 缓存下载：多书排队单任务串行执行，章节一章一章在后台低优先级队列下载（避免抢占前台与触发限流），可暂停。
/// 正文和插图都下载（插图按小并发批量拉取），断网后插图也能显示。
class DownloadController extends Notifier<Map<String, DownloadState>> {
  final _cancelled = <String>{};
  // 每本书第几次下载：删除缓存（[forget]）或重新开始后，旧的那次不再更新状态，不会把清掉的进度又加回来
  final _runs = <String, int>{};
  final _queue = <String, _DownloadTask>{};
  final _activeTasks = <String, _DownloadTask>{};
  bool _pumping = false;
  static const _imageBatchSize = 3;
  static const _offlineImageFlushInterval = 10;

  @override
  Map<String, DownloadState> build() => {};

  void _abortActiveTask(String aid) {
    final active = _activeTasks[aid];
    if (active == null) return;
    if (!active.cancelToken.isCancelled) active.cancelToken.cancel('DownloadController.cancel');
    if (active.activeImages.isNotEmpty) {
      final images = ref.read(imageStoreProvider);
      for (final url in active.activeImages.toList()) {
        try {
          images.cancel(url);
        } on Object {
          // 兼容单测中的简化 ImageStore 测试桩
        }
      }
      active.activeImages.clear();
    }
  }

  void cancel(String aid) {
    _cancelled.add(aid);
    _abortActiveTask(aid);
    final pending = _queue.remove(aid);
    if (pending != null) {
      if (!pending.cancelToken.isCancelled) pending.cancelToken.cancel('DownloadController.cancel');
      if (ref.mounted && _runs[aid] == pending.run) {
        state = {...state, aid: DownloadState(done: ChapterCache.count(aid), total: pending.total, running: false)};
      }
      if (!pending.done.isCompleted) pending.done.complete();
    }
  }

  /// 删除缓存后把这本书的下载状态一起清掉（不重建整个 Notifier，免得打断别的书的下载）。
  void forget(String aid) {
    _cancelled.add(aid);
    _runs[aid] = (_runs[aid] ?? 0) + 1;
    _abortActiveTask(aid);
    final pending = _queue.remove(aid);
    if (pending != null) {
      if (!pending.cancelToken.isCancelled) pending.cancelToken.cancel('DownloadController.forget');
      if (!pending.done.isCompleted) pending.done.complete();
    }
    state = {...state}..remove(aid);
  }

  /// 下载 [chapters] 里还没缓存的章节；[total] 是全书章数，用来显示整本书的进度。
  /// 多书同时触发时排入串行队列逐本下载。
  Future<void> start(String aid, String title, List<CatChapter> chapters, {int? total, String img = '', String firstCid = ''}) async {
    if (state[aid]?.running ?? false) return;
    final all = total ?? chapters.length;
    _cancelled.remove(aid);
    final run = _runs[aid] = (_runs[aid] ?? 0) + 1;
    if (ref.mounted) {
      state = {...state, aid: DownloadState(done: ChapterCache.count(aid), total: all, running: true)};
    }
    await ChapterCache.setMeta(aid, title, all, img, firstCid.isEmpty && chapters.isNotEmpty ? chapters.first.cid : firstCid);
    if (!ref.mounted || _runs[aid] != run || _cancelled.contains(aid)) {
      if (ref.mounted && _runs[aid] == run) {
        state = {...state, aid: DownloadState(done: ChapterCache.count(aid), total: all, running: false)};
      }
      return;
    }
    final task = _DownloadTask(aid: aid, chapters: List.of(chapters), total: all, run: run);
    _queue[aid] = task;
    unawaited(_pump());
    return task.done.future;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && ref.mounted) {
        final key = _queue.keys.first;
        final task = _queue.remove(key)!;
        await _runTask(task);
      }
    } finally {
      _pumping = false;
      if (_queue.isNotEmpty && ref.mounted) unawaited(_pump());
    }
  }

  Future<void> _runTask(_DownloadTask task) async {
    final aid = task.aid;
    final all = task.total;
    final run = task.run;
    final api = ref.read(apiProvider);
    final images = ref.read(imageStoreProvider);
    bool stale() => _runs[aid] != run;
    void emit({bool running = true, String? error}) {
      if (!ref.mounted || stale()) return;
      state = {...state, aid: DownloadState(done: ChapterCache.count(aid), total: all, running: running, error: error)};
    }

    _activeTasks[aid] = task;
    final pendingImages = <String>[];
    var chaptersSinceFlush = 0;
    final bookTicketAtStart = ChapterCache.ticket(aid, '').$1;
    Future<void> flushImages() async {
      if (pendingImages.isEmpty) return;
      final batch = List<String>.of(pendingImages);
      pendingImages.clear();
      chaptersSinceFlush = 0;
      if (ChapterCache.ticket(aid, '').$1 != bookTicketAtStart) return;
      await ChapterCache.addOfflineImages(aid, batch);
    }

    try {
      await runInBackground(() async {
        for (final c in task.chapters) {
          if (_cancelled.contains(aid) || task.cancelToken.isCancelled || stale() || !ref.mounted) break;
          if (ChapterCache.has(aid, c.cid)) continue;
          final ticket = ChapterCache.ticket(aid, c.cid);
          final Content content;
          try {
            content = await () async {
              try {
                return await api.fetchChapter(aid, c.cid, cancelToken: task.cancelToken);
              } on NoSuchMethodError {
                return await api.chapter(aid, c.cid);
              }
            }();
          } on ChapterLockedException {
            continue; // 受限书 TXT 里没有的章（插图），跳过
          } on DioException catch (e) {
            if (e.type == DioExceptionType.cancel || task.cancelToken.isCancelled || _cancelled.contains(aid)) break;
            rethrow;
          }
          // 请求期间可能已经暂停或删除了缓存：此时不能再写回去
          if (_cancelled.contains(aid) || task.cancelToken.isCancelled || stale() || !ref.mounted) break;
          // 写不进去：整本被删了就停；只是这一章被删了（比如「清掉已读章节」）就跳过它接着下
          if (!await ChapterCache.put(aid, c.cid, content, ticket: ticket)) {
            if (ChapterCache.ticket(aid, c.cid).$1 != ticket.$1) break;
            continue;
          }
          for (var i = 0; i < content.images.length; i += _imageBatchSize) {
            if (_cancelled.contains(aid) || task.cancelToken.isCancelled || stale() || !ref.mounted) break;
            final end = (i + _imageBatchSize).clamp(0, content.images.length);
            final batch = content.images.sublist(i, end);
            task.activeImages.addAll(batch);
            try {
              await Future.wait([
                for (final url in batch) images.load(url).then<void>((_) {}, onError: (_) {}),
              ]);
            } finally {
              task.activeImages.removeAll(batch);
            }
          }
          // 下插图这段时间缓存可能被删了：不再记插图（删除时已经把这条记录清掉了）
          if (ChapterCache.ticket(aid, c.cid).$1 != ticket.$1) break;
          if (content.images.isNotEmpty) pendingImages.addAll(content.images);
          chaptersSinceFlush++;
          if (chaptersSinceFlush >= _offlineImageFlushInterval) {
            await flushImages();
          }
          emit();
        }
      });
      await flushImages();
      emit(running: false);
    } catch (e) {
      await flushImages();
      if (_cancelled.contains(aid) || task.cancelToken.isCancelled) {
        emit(running: false);
      } else {
        emit(running: false, error: friendlyError(e));
      }
    } finally {
      if (identical(_activeTasks[aid], task)) _activeTasks.remove(aid);
      task.activeImages.clear();
      if (!task.done.isCompleted) task.done.complete();
    }
  }
}

final downloadProvider = NotifierProvider<DownloadController, Map<String, DownloadState>>(DownloadController.new);
