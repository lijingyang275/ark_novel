import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_client.dart';
import '../models/cat_volume.dart';
import '../models/content.dart';
import 'cache.dart';
import 'cover_trim.dart';
import 'app_prefs.dart';
import 'bangumi.dart';
import 'data.dart';
import 'unlock.dart';
import 'image_cache.dart';
import 'library.dart';
import 'progress.dart';
import 'read_state.dart';
import 'stats.dart';
import 'sync.dart';

/// 目录里的一卷：卷名、章节 cid（按顺序）、插图章节的 cid（没有为 null）。
class Vol {
  const Vol(this.title, this.cids, this.illus);

  factory Vol.from(CatVolume v) => Vol(v.title, [for (final c in v.chapters) c.cid], v.chapters.where((c) => isIllustration(c.title)).firstOrNull?.cid);

  final String title;
  final List<String> cids;
  final String? illus;

  /// 判断读完用的章节：不算插图章（只有图，很多人会跳过）
  Iterable<String> get textCids => cids.where((c) => c != illus);
}

bool isIllustration(String title) => title.contains('插图') || title.contains('插圖') || title.contains('插画') || title.contains('插畫');

/// 分卷数据，全部存在本机（不用每次都请求网页）：
/// - `vols:aid` 卷列表（目录加载时记下，书架、报告页同步就能用）
/// - `vcover2:aid` 卷名 → 封面地址（插图章节里第一张竖着的图，见 [chooseCover]；'' 表示这卷没有插图）
///   （`vcover:` 是旧版直接取第一张图的记录，作废不用）
/// - `vdone:aid` 卷名 → 读完的时间（毫秒）
/// - `vrate:aid` 卷名 → 星级
class Volumes {
  Volumes._();

  static Box get _box => Hive.box('session');

  /// 卷封面、读完状态变了：书架、书籍墙、报告页据此刷新
  static final changes = ValueNotifier<int>(0);

  static List<Vol> of(String aid) => [
    for (final m in ((_box.get('vols:$aid') as List?) ?? const []).cast<Map>()) Vol(m['t'] as String, (m['c'] as List).cast<String>(), m['i'] as String?),
  ];

  /// 目录加载后记下卷列表，并顺带核对一遍哪些卷读完了。
  /// 若某卷原本没有插图章（或之前取封面时记成了空串 `''` / Bangumi 兜底），后来更新补上了插图章，
  /// 自动清掉非手动挑选的旧封面记录与插图章缓存，让封面队列重新去取真正的卷插图。
  static Future<void> saveCatalogue(String aid, List<CatVolume> cat) async {
    final old = of(aid);
    final oldIllus = {for (final v in old) v.title: v.illus};
    final next = [
      for (final v in cat)
        {'t': v.title, 'c': [for (final c in v.chapters) c.cid], 'i': v.chapters.where((c) => isIllustration(c.title)).firstOrNull?.cid},
    ];
    if (!listEquals(
      next.map((e) => '${e['t']}|${(e['c'] as List).join(',')}|${e['i']}').toList(),
      old.map((v) => '${v.title}|${v.cids.join(',')}|${v.illus}').toList(),
    )) {
      await _box.put('vols:$aid', next);
    }
    final covers = _covers(aid);
    if (covers.isNotEmpty) {
      final picked = _picked(aid);
      final updated = {...covers};
      final staleCids = <String>[];
      for (final e in next) {
        final title = e['t'] as String;
        final illus = e['i'] as String?;
        final saved = covers[title];
        if (illus == null || saved == null) continue;
        final manual = picked.contains(title) || saved.contains('#crop=');
        if (manual) continue;
        // 插图章变了（比如后来才补上）：清掉旧记录重新抓取。记成 '' 而插图章没变的，由 [VolumeCoverQueue.get] 每次运行重试一次
        if (old.isNotEmpty && oldIllus[title] != illus) {
          updated.remove(title);
          staleCids.add(illus);
        }
      }
      if (updated.length != covers.length) {
        await _box.put('vcover2:$aid', updated);
        if (staleCids.isNotEmpty && Hive.isBoxOpen('chapter_index')) {
          await ChapterCache.removeChapters(aid, staleCids, compact: false);
        }
        changes.value++;
      }
    }
    await refreshDone(aid);
  }

  /// [cid] 在第几卷，找不到为 -1。
  static int indexOf(String aid, String cid) => of(aid).indexWhere((v) => v.cids.contains(cid));

  // ---- 封面 ----

  static Map<String, String> _covers(String aid) => ((_box.get('vcover2:$aid') as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String));

  /// 这卷的封面：null 还没取过，'' 这卷没有插图。
  static String? cover(String aid, String title) => _covers(aid)[title];

  /// 手动挑过封面的卷（标题）
  static Set<String> _picked(String aid) => ((_box.get('vpick:$aid') as List?) ?? const []).cast<String>().toSet();

  /// [url] 可以带裁剪框（见 [withCrop]），自选封面就是这样存的；[picked] 是手动挑的，图片缓存清理时一直留着
  static Future<void> setCover(String aid, String title, String url, {bool picked = false}) async {
    await _box.put('vcover2:$aid', {..._covers(aid), title: url});
    if (picked) {
      await _box.put('vpick:$aid', (_picked(aid)..add(title)).toList());
      await _box.put('vpickTs:$aid', {...((_box.get('vpickTs:$aid') as Map?) ?? const {}), title: DateTime.now().millisecondsSinceEpoch});
    }
    changes.value++;
  }

  /// 一次记好几卷的封面（只发一次变化通知）
  static Future<void> setCovers(String aid, Map<String, String> covers) async {
    if (covers.isEmpty) return;
    await _box.put('vcover2:$aid', {..._covers(aid), ...covers});
    changes.value++;
  }

  /// 忘掉这本书所有卷的封面记录（没加入书架的书退出详情页时）
  static Future<void> forgetCovers(String aid) async {
    await _box.delete('vcover2:$aid');
    await _box.delete('vpick:$aid');
    changes.value++;
  }

  /// 去掉自选的封面，下次显示时重新自动挑（同时清掉该卷插图章的本地缓存，以便重新联网抓取最新插图）
  static Future<void> resetCover(String aid, String title) async {
    await _box.put('vcover2:$aid', {..._covers(aid)}..remove(title));
    await _box.put('vpick:$aid', (_picked(aid)..remove(title)).toList());
    await Sync.tombstone(['vcover:$aid:$title']);
    final illus = of(aid).where((v) => v.title == title).firstOrNull?.illus;
    if (illus != null && Hive.isBoxOpen('chapter_index')) {
      await ChapterCache.removeChapters(aid, [illus], compact: false);
    }
    changes.value++;
  }

  /// 图片缓存清理时要留着的卷封面：书架上这些书显示的那张（第一卷），加上所有手动挑过的
  static Iterable<String> keptCovers(Iterable<String> shelf) => {
    for (final aid in shelf)
      if (of(aid).firstOrNull case final v?) ?cover(aid, v.title),
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vpick:')))
      for (final title in _picked(k.substring(6))) ?cover(k.substring(6), title),
    // 有这个标记之前手动裁过的：带裁剪框的一定是手动挑的
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vcover2:')))
      ...(_box.get(k) as Map).values.cast<String>().where((e) => e.contains('#crop=')),
  }.where((e) => e.isNotEmpty);

  // ---- 读完 ----

  static Map<String, int> done(String aid) => ((_box.get('vdone:$aid') as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as int));

  /// 按已读章节核对每卷：正文章节全读了就记下读完时间，不再全读（标回未读）就去掉。
  /// 第一次核对这本书时（以前读完的卷没有日期），用最后一次阅读的时间代替。
  static Future<void> refreshDone(String aid) async {
    final vols = of(aid);
    if (vols.isEmpty) return;
    final first = !_box.containsKey('vdone:$aid');
    final last = ReadingProgress.lastRead(aid);
    final now = first && last > 0 ? last : DateTime.now().millisecondsSinceEpoch;
    final read = ReadState.read(aid);
    final old = done(aid);
    final next = <String, int>{
      for (final v in vols)
        if (v.textCids.isNotEmpty && v.textCids.every(read.contains)) v.title: old[v.title] ?? now,
    };
    if (first || !mapEquals(old, next)) {
      await _box.put('vdone:$aid', next);
      changes.value++;
    }
  }

  /// 所有读完的卷：(aid, 卷序号, 卷, 读完时间)，新的在前。书籍墙用。
  static List<(String, int, Vol, int)> allDone() {
    final out = <(String, int, Vol, int)>[];
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vdone:'))) {
      final aid = k.substring(6);
      final vols = of(aid);
      for (final e in done(aid).entries) {
        final i = vols.indexWhere((v) => v.title == e.key);
        if (i >= 0) out.add((aid, i, vols[i], e.value));
      }
    }
    return out..sort((a, b) => b.$4.compareTo(a.$4));
  }

  // ---- 评分 ----

  static int rating(String aid, String title) => ((_box.get('vrate:$aid') as Map?)?[title] as int?) ?? 0;

  static Future<void> setRating(String aid, String title, int stars) async {
    await _box.put('vrate:$aid', {...((_box.get('vrate:$aid') as Map?) ?? const {}), title: stars});
    changes.value++;
  }

  // ---- 统计 ----

  /// 这卷读了多少秒、哪些天读过（按章记录的时间，这个功能上线之后才有）。
  static ({int seconds, List<String> days}) time(String aid, Vol v) {
    final ch = ReadingStats.chapterSeconds(aid);
    var seconds = 0;
    final days = <String>{};
    for (final c in v.cids) {
      for (final e in (ch[c] ?? const <String, int>{}).entries) {
        seconds += e.value;
        days.add(e.key);
      }
    }
    return (seconds: seconds, days: days.toList()..sort());
  }

  /// 这卷读过的字数：读过、而且缓存过（读过的章节都会自动缓存）的章节字数之和。
  static int readChars(String aid, Vol v) {
    final read = ReadState.read(aid);
    return v.cids.where(read.contains).fold(0, (a, c) => a + (ChapterCache.length(aid, c) ?? 0));
  }
}

/// 取卷封面：一次只取一卷，新请求的先取（刚滑到眼前的），从网上取的之间隔一会儿，免得被限流。
/// 插图章节缓存过就直接用缓存，不联网；从网上取到的正文也顺手存进缓存。网络出问题就先停下，下次再说。
class VolumeCoverQueue {
  VolumeCoverQueue(this._ref);

  final Ref _ref;
  final _queue = <(String, String)>[];
  final _bg = <(String, String)>[]; // 后台慢慢取的，排在眼前要看的后面
  Future<void>? _pumping;
  static const _maxFailures = 3;
  static const _failureGap = Duration(milliseconds: 1500);
  final _bgmTried = <(String, String)>{}; // 这次运行里已经按 Bangumi 补过（或者对不上）的卷
  final _bgmFilling = <String>{};
  final _bgmFailed = <String>{}; // 连不上 Bangumi、图下不下来的书，这次运行不再试
  final _emptyTried = <(String, String)>{}; // 之前记成 '' 但现在有插图章的卷，本次运行重抓一次
  final _tempCovers = <(String, String), String>{}; // 文库图床/章节拉取失败时临时用 Bangumi 兜底（不落库，恢复后换回原站）
  final _tempRequested = <(String, String)>{}; // 需要临时兜底的卷（(aid, '') 表示整本书缺目录时的兜底）
  final _tempTried = <(String, String)>{};
  final _tempFilling = <String>{};
  final _officialTried = <(String, String)>{}; // 本轮已经尝试过原站取封面的卷，避免 build 反复入队
  final _failedUrls = <String>{}; // 本轮实际下载失败的封面地址（如旧缓存没命中或站点小封面被拦），刷新或重启后清空重试
  bool _netBlocked = false; // 连着几本失败时先熔断，本轮直接走 Bangumi 兜底；刷新或下次启动再试原站

  /// 后台把这些书在书架上显示的封面（第一卷的）取下来（打开 App、同步完书架后调用）。其他卷不常看，打开卷册页时再取。
  /// 若之前有书因文库失败临时用了 Bangumi 兜底，重新调用时会再尝试恢复原站封面（恢复前继续显示临时封面不闪烁）。
  Future<void> prefetchAll(Iterable<String> aids) {
    final hadFailed = _failedUrls.isNotEmpty;
    _netBlocked = false;
    _officialTried.clear();
    _tempTried.clear();
    _bgmFailed.clear();
    _failedUrls.clear();
    for (final aid in aids) {
      final v = Volumes.of(aid).firstOrNull;
      if (v != null && Volumes.cover(aid, v.title) == null) {
        _officialTried.add((aid, v.title));
        if (!_bg.contains((aid, v.title)) && !_queue.contains((aid, v.title))) _bg.add((aid, v.title));
      }
    }
    if (hadFailed) Volumes.changes.value++;
    return Future.microtask(_pump);
  }

  /// 图片控件加载某张书架封面失败时通知：临时改用 Bangumi 兜底，直到下次刷新或重启再试原站。
  void reportCoverFailed(String aid, String url, {String? volumeTitle}) {
    final clean = splitCrop(url).url;
    if (clean.isEmpty || clean.contains('bgm.tv') || !LibraryStore.contains(aid)) return;
    final title = volumeTitle ?? Volumes.of(aid).firstOrNull?.title ?? '';
    final added = _failedUrls.add(clean);
    if (!added && _tempCovers.containsKey((aid, title))) return;
    _requestTemp(aid, title);
  }

  /// 没加入书架的书退出详情页时：不再取它的封面，删掉挑封面时下载的图（插图章节的前几张）和封面记录，下次打开再取。
  Future<void> forget(String aid) async {
    _queue.removeWhere((e) => e.$1 == aid);
    _bg.removeWhere((e) => e.$1 == aid);
    _tempCovers.removeWhere((k, _) => k.$1 == aid);
    _tempRequested.removeWhere((k) => k.$1 == aid);
    _tempTried.removeWhere((k) => k.$1 == aid);
    _officialTried.removeWhere((k) => k.$1 == aid);
    final store = _ref.read(imageStoreProvider);
    for (final v in Volumes.of(aid)) {
      if (v.illus == null || Volumes.cover(aid, v.title) == null) continue;
      final content = await ChapterCache.get(aid, v.illus!);
      if (content != null) await store.remove(content.images.take(_checked));
    }
    await Volumes.forgetCovers(aid);
  }

  /// 一卷的封面；这卷没有插图（比如短篇集）或者还没取到时用书的高清封面（第一卷的）。
  String volCover(String aid, Vol v, String fallback) => get(aid, v) ?? bookCover(aid, fallback);

  /// 这卷的封面，还没取过就排队去取（返回 null，若文库失败则返回临时 Bangumi 兜底）；没有插图、不在书架上的书也返回 null（只用网站的封面）。
  String? get(String aid, Vol v) {
    if (!LibraryStore.contains(aid)) return null;
    final url = Volumes.cover(aid, v.title);
    if (url != null) {
      if (url.isNotEmpty) {
        if (_failedUrls.contains(splitCrop(url).url)) {
          final temp = _tempCovers[(aid, v.title)];
          if (temp == null) _requestTemp(aid, v.title);
          if (temp != null) _ref.read(imageStoreProvider).allowAutoSr(temp);
          return temp;
        }
        _tempCovers.remove((aid, v.title));
        _ref.read(imageStoreProvider).allowAutoSr(url);
        return url;
      }
      if (v.illus != null && !_netBlocked && _emptyTried.add((aid, v.title)) && !_queue.contains((aid, v.title))) {
        _queue.add((aid, v.title));
        Future.microtask(_pump);
      }
      if (!_bgmTried.contains((aid, v.title))) Future.microtask(() => _fillFromBangumi(aid));
      return null;
    }
    final temp = _tempCovers[(aid, v.title)];
    if (_netBlocked) {
      if (temp == null) _requestTemp(aid, v.title);
    } else if (_officialTried.add((aid, v.title)) && !_queue.contains((aid, v.title))) {
      _bg.remove((aid, v.title));
      _queue.add((aid, v.title));
      Future.microtask(_pump);
    }
    if (temp != null) {
      _ref.read(imageStoreProvider).allowAutoSr(temp);
      return temp;
    }
    return null;
  }

  /// 书的封面：第一卷的卷封面（高清）；没有卷信息、还没取到、没插图时用 [fallback]（网站的小封面），文库被拦时临时用 Bangumi 兜底。
  String bookCover(String aid, String fallback) {
    final vols = Volumes.of(aid);
    final url = vols.isEmpty ? null : get(aid, vols.first);
    if (url != null) return url;
    if (vols.isEmpty && LibraryStore.contains(aid)) {
      final temp = _tempCovers[(aid, '')];
      if (temp != null) {
        _ref.read(imageStoreProvider).allowAutoSr(temp);
        return temp;
      }
      if (_netBlocked) _requestTemp(aid, '');
    }
    if (LibraryStore.contains(aid)) _ref.read(imageStoreProvider).allowAutoSr(fallback);
    return fallback;
  }

  Future<void> _pump() => _pumping ??= _runPump().whenComplete(() => _pumping = null);

  Future<void> _runPump() async {
    var failures = 0;
    // 单本出错就跳过并尝试临时用 Bangumi 兜底；连着几本都出错多半是网络问题或被限流，先停并把队列里剩余的交给 Bangumi 兜底
    Future<void> skip(String aid, String title) async {
      _requestTemp(aid, title);
      if (++failures >= _maxFailures) {
        _netBlocked = true;
        final rest = [..._queue, ..._bg];
        _queue.clear();
        _bg.clear();
        for (final (qAid, qTitle) in rest) {
          _requestTemp(qAid, qTitle);
        }
        Volumes.changes.value++;
      } else {
        await Future<void>.delayed(_failureGap);
      }
    }

    while (_queue.isNotEmpty || _bg.isNotEmpty) {
      final (aid, title) = _queue.isNotEmpty ? _queue.removeLast() : _bg.removeAt(0);
      final v = Volumes.of(aid).where((v) => v.title == title).firstOrNull;
      final existing = Volumes.cover(aid, title);
      if (v == null || (existing != null && (existing.isNotEmpty || v.illus == null))) continue;
      if (v.illus == null) {
        await Volumes.setCover(aid, title, '');
        _fillFromBangumi(aid).ignore();
        continue;
      }
      var content = await ChapterCache.get(aid, v.illus!);
      if (content != null && content.images.isEmpty) content = null;
      if (content == null) {
        final ticket = ChapterCache.ticket(aid, v.illus!);
        try {
          content = await runInBackground<Future<Content>>(() => _ref.read(apiProvider).chapter(aid, v.illus!));
        } on ChapterLockedException {
          // 受限书：哪一卷的插图都取不到，不用一卷一卷去试；没取过的都记成没插图，再一次按卷号从 Bangumi 补上
          await Volumes.setCovers(aid, {for (final x in Volumes.of(aid)) if (Volumes.cover(aid, x.title) == null) x.title: ''});
          _queue.removeWhere((e) => e.$1 == aid);
          _bg.removeWhere((e) => e.$1 == aid);
          _fillFromBangumi(aid).ignore();
          continue;
        } catch (_) {
          await skip(aid, title);
          continue;
        }
        if (content.images.isNotEmpty) await ChapterCache.put(aid, v.illus!, content, ticket: ticket);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      final String url;
      try {
        url = await _trimmed(await chooseCover(content.images, _size));
      } catch (_) {
        await skip(aid, title);
        continue;
      }
      failures = 0;
      _tempCovers.remove((aid, title));
      _tempCovers.remove((aid, ''));
      await Volumes.setCover(aid, title, url);
      if (url.isEmpty) _fillFromBangumi(aid).ignore();
      await _dropSkipped(aid, v, content.images);
    }
  }

  /// 挑封面时下载了又没选上的图（插图章节开头的横版跨页，一张几百 KB）删掉，只留封面；以后打开插图章节再下。
  /// 下载过离线缓存的书不删，离线时还要看。
  Future<void> _dropSkipped(String aid, Vol v, List<String> images) async {
    if (ChapterCache.offline(aid)) return;
    final cover = splitCrop(Volumes.cover(aid, v.title) ?? '').url;
    await _ref.read(imageStoreProvider).remove(images.take(_checked).where((u) => u != cover));
  }

  /// 以前挑封面时留下的这种图删一遍（只做一次）
  Future<void> dropSkippedOnce(Iterable<String> aids) async {
    final box = Hive.box('session');
    if (box.get('coverSkipDropped') == true) return;
    for (final aid in aids) {
      for (final v in Volumes.of(aid)) {
        if (v.illus == null || Volumes.cover(aid, v.title) == null) continue;
        final content = await ChapterCache.get(aid, v.illus!);
        if (content != null) await _dropSkipped(aid, v, content.images);
      }
    }
    await box.put('coverSkipDropped', true);
  }

  void _requestTemp(String aid, String title) {
    if (!LibraryStore.contains(aid)) return;
    _tempRequested.add((aid, title));
    if (_tempTried.contains((aid, title)) || _bgmFailed.contains(aid)) return;
    Future.microtask(() => _fillTempFromBangumi(aid));
  }

  /// 有插图但文库暂时被拦/取图失败时，用 Bangumi 封面临时兜底：只放内存里，不写入 `vcover2`，网络恢复后会自动换回原站高清封面。
  Future<void> _fillTempFromBangumi(String aid) async {
    if (_bgmFailed.contains(aid) || !_tempFilling.add(aid)) return;
    if (BangumiCovers.bookTitle(aid) == null) {
      _tempFilling.remove(aid);
      return;
    }
    var changed = false;
    try {
      final s = await _ref.read(bangumiProvider).series(aid);
      while (true) {
        final vols = Volumes.of(aid);
        final targets = {
          for (final (a, t) in _tempRequested)
            if (a == aid && _tempTried.add((a, t))) t,
        };
        if (targets.isEmpty || s == null) break;
        final titles = [for (final v in vols) v.title];
        final matched = titles.isEmpty ? const <String, String>{} : {...matchExtraCovers(titles, s), ...matchVolumeCovers(titles, s.vols)};
        for (final title in targets) {
          final saved = title.isEmpty ? null : Volumes.cover(aid, title);
          if (saved != null && !_failedUrls.contains(splitCrop(saved).url)) continue;
          final img = title.isEmpty ? s.vols.firstOrNull?.img : matched[title];
          if (img == null || img.isEmpty) continue;
          final url = await _trimmed(img);
          final latest = title.isEmpty ? null : Volumes.cover(aid, title);
          if (latest != null && !_failedUrls.contains(splitCrop(latest).url)) continue;
          if (_tempCovers[(aid, title)] != url) {
            _tempCovers[(aid, title)] = url;
            changed = true;
          }
        }
      }
    } catch (_) {
      _bgmFailed.add(aid);
    } finally {
      _tempFilling.remove(aid);
      if (changed) Volumes.changes.value++;
    }
  }

  /// 没插图的卷（受限书、没有插图章节的卷）去 Bangumi 找封面补上：正卷按卷号，8.5 卷、外传按 [matchExtraCovers]，对不上的不补，有封面的不动。
  /// 哪一卷变成没插图了就来补一次；Bangumi 的结果存在本机，不会每次联网。
  Future<void> _fillFromBangumi(String aid) async {
    if (_bgmFailed.contains(aid) || !_bgmFilling.add(aid)) return;
    if (BangumiCovers.bookTitle(aid) == null) {
      _bgmFilling.remove(aid);
      return;
    }
    try {
      final s = await _ref.read(bangumiProvider).series(aid);
      // 补的时候又有卷变成没插图的（比如受限书一次记了一整本），接着补
      while (true) {
        final vols = Volumes.of(aid);
        final empty = {for (final v in vols) if (Volumes.cover(aid, v.title) == '' && _bgmTried.add((aid, v.title))) v.title};
        if (empty.isEmpty || s == null) break;
        // 拿所有卷去对（Bangumi 认不出卷号时要按全部正卷的顺序对），只用没插图的那些；正卷之外的（8.5 卷、外传）再按外传对
        final titles = [for (final v in vols) v.title];
        for (final MapEntry(key: title, value: img) in {...matchExtraCovers(titles, s), ...matchVolumeCovers(titles, s.vols)}.entries) {
          if (!empty.contains(title)) continue;
          final url = await _trimmed(img);
          if (Volumes.cover(aid, title) == '') await Volumes.setCover(aid, title, url); // 下载期间手动换过的不动
        }
      }
    } catch (_) {
      _bgmFailed.add(aid);
    } finally {
      _bgmFilling.remove(aid);
    }
  }

  /// 有去白边以前挑好的卷封面补做一次（只做一次）：只收白边，不动框的位置；只用本机已有的图，不联网。
  /// 手动框的仍记成手动框的（`#crop=`），关了「自动去白边」就不动它们。
  Future<void> retrimOnce(Iterable<String> aids) async {
    final box = Hive.box('session');
    if (box.get('coverRetrimmed') == true) return;
    final store = _ref.read(imageStoreProvider);
    final manualOn = AppPrefs.read(P.coverTrim, false);
    for (final aid in aids) {
      for (final MapEntry(key: title, value: saved) in Volumes._covers(aid).entries) {
        final manual = saved.contains('#crop=');
        if (saved.isEmpty || (manual && !manualOn)) continue;
        final (:url, :crop) = splitCrop(saved);
        final bytes = await store.cached(url);
        if (bytes == null) continue;
        try {
          final from = crop ?? const ui.Rect.fromLTWH(0, 0, 1, 1);
          final r = (await CoverPixels.decode(bytes)).trim(from, maxTrim: manual ? 0.15 : 0.1);
          if (r != from) await Volumes.setCover(aid, title, withCrop(url, r, auto: !manual));
        } catch (_) {} // 解码不了就保持原样
      }
    }
    await box.put('coverRetrimmed', true);
  }

  /// 自动挑的封面四周有白边（扫描图常有）就记一个裁剪框去掉（`#trim=`，见 [splitCrop]）。只收很窄的一圈，
  /// 白底的封面不会被削掉多少；解码不了就用整张。
  Future<String> _trimmed(String url) async {
    if (url.isEmpty) return url;
    final bytes = await _ref.read(imageStoreProvider).load(url);
    try {
      const full = ui.Rect.fromLTWH(0, 0, 1, 1);
      final r = (await CoverPixels.decode(bytes)).trim(full, maxTrim: 0.1);
      return r == full ? url : withCrop(url, r, auto: true);
    } catch (_) {
      return url;
    }
  }

  /// 图片本来就要显示，下载后存在本机。
  Future<ui.Size> _size(String url) async => imageSize(await _ref.read(imageStoreProvider).load(url));
}

/// 只读图片头部拿宽高，不完整解码。
Future<ui.Size> imageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final size = ui.Size(desc.width.toDouble(), desc.height.toDouble());
  desc.dispose();
  buffer.dispose();
  return size;
}

/// 挑封面时最多看插图章节的前几张
const _checked = 4;

/// 从插图章节的图里挑封面：第一张竖着的（宽不超过高）。第一张常常是连书脊、封底一起的横版展开图，就往后找；
/// 前几张都是横的就还用第一张。没有图返回 ''。
Future<String> chooseCover(List<String> images, Future<ui.Size> Function(String url) sizeOf) async {
  for (final url in images.take(_checked)) {
    final s = await sizeOf(url);
    if (s.width <= s.height) return url;
  }
  return images.firstOrNull ?? '';
}

final volumeCoverQueueProvider = Provider<VolumeCoverQueue>(VolumeCoverQueue.new);

/// 卷数据变了就重建（书架封面、书籍墙）
final volumeChangesProvider = Provider<int>((ref) {
  void listener() => ref.invalidateSelf();
  Volumes.changes.addListener(listener);
  ref.onDispose(() => Volumes.changes.removeListener(listener));
  return Volumes.changes.value;
});
