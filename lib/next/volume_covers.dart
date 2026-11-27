import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_client.dart';
import '../models/content.dart';
import 'app_prefs.dart';
import 'bangumi.dart';
import 'cache.dart';
import 'cover_trim.dart';
import 'data.dart';
import 'image_cache.dart';
import 'library.dart';
import 'unlock.dart';
import 'volumes.dart';

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
  static const _maxBgmConcurrent = 2;
  static const _sessionCap = 512;
  final _bgmTried = <(String, String)>{}; // 这次运行里已经按 Bangumi 补过（或者对不上）的卷
  final _bgmFilling = <String>{};
  final _bgmQueue = <String>[];
  var _bgmRunning = 0;
  final _bgmFailed = <String>{}; // 连不上 Bangumi、图下不下来的书，这次运行不再试
  final _emptyTried = <(String, String)>{}; // 之前记成 '' 但现在有插图章的卷，本次运行重抓一次
  final _tempCovers = <(String, String), String>{}; // 文库图床/章节拉取失败时临时用 Bangumi 兜底（不落库，恢复后换回原站）
  final _tempRequested = <(String, String)>{}; // 需要临时兜底的卷（(aid, '') 表示整本书缺目录时的兜底）
  final _tempTried = <(String, String)>{};
  final _tempFilling = <String>{};
  final _tempQueue = <String>[];
  var _tempRunning = 0;
  final _officialTried = <(String, String)>{}; // 本轮已经尝试过原站取封面的卷，避免 build 反复入队
  final _failedUrls = <String>{}; // 本轮实际下载失败的封面地址（如旧缓存没命中或站点小封面被拦），刷新或重启后清空重试
  bool _netBlocked = false; // 连着几本失败时先熔断，本轮直接走 Bangumi 兜底；刷新或下次启动再试原站
  int _bgPauseCount = 0;

  static bool _addBounded<T>(Set<T> set, T value) {
    final added = set.add(value);
    while (set.length > _sessionCap) {
      set.remove(set.first);
    }
    return added;
  }

  static void _putBounded<K, V>(Map<K, V> map, K key, V value) {
    map.remove(key);
    map[key] = value;
    while (map.length > _sessionCap) {
      map.remove(map.keys.first);
    }
  }

  /// 清理长会话积累的辅助去重集合（保留活跃临时兜底封面），防止内存无限增长。
  void evictSessionCaches() {
    _bgmTried.clear();
    _bgmFailed.clear();
    _emptyTried.clear();
    _tempRequested.clear();
    _tempTried.clear();
    _officialTried.clear();
    _failedUrls.clear();
  }

  bool get isBackgroundPaused => _bgPauseCount > 0;

  void pauseBackground() {
    _bgPauseCount++;
  }

  void resumeBackground() {
    if (_bgPauseCount > 0 && --_bgPauseCount == 0) {
      if (_bg.isNotEmpty || _queue.isNotEmpty) Future.microtask(_pump);
      if (_bgmQueue.isNotEmpty) Future.microtask(_pumpBangumi);
      if (_tempQueue.isNotEmpty) Future.microtask(_pumpTemp);
    }
  }

  /// 后台把这些书在书架上显示的封面（第一卷的）取下来（打开 App、同步完书架后调用）。其他卷不常看，打开卷册页时再取。
  /// 若之前有书因文库失败临时用了 Bangumi 兜底，重新调用时会再尝试恢复原站封面（恢复前继续显示临时封面不闪烁）。
  Future<void> prefetchAll(Iterable<String> aids) {
    final hadFailed = _failedUrls.isNotEmpty;
    _netBlocked = false;
    _officialTried.clear();
    _tempTried.clear();
    _tempQueue.clear();
    _bgmFailed.clear();
    _failedUrls.clear();
    for (final aid in aids) {
      final v = Volumes.of(aid).firstOrNull;
      if (v != null && Volumes.cover(aid, v.title) == null) {
        _addBounded(_officialTried, (aid, v.title));
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
    final added = _addBounded(_failedUrls, clean);
    if (!added && _tempCovers.containsKey((aid, title))) return;
    _requestTemp(aid, title);
  }

  /// 没加入书架的书退出详情页时：不再取它的封面，删掉挑封面时下载的图（插图章节的前几张）和封面记录，下次打开再取。
  Future<void> forget(String aid) async {
    _queue.removeWhere((e) => e.$1 == aid);
    _bg.removeWhere((e) => e.$1 == aid);
    _tempQueue.remove(aid);
    _bgmQueue.remove(aid);
    _bgmFailed.remove(aid);
    _bgmTried.removeWhere((k) => k.$1 == aid);
    _emptyTried.removeWhere((k) => k.$1 == aid);
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
      if (v.illus != null && !_netBlocked && _addBounded(_emptyTried, (aid, v.title)) && !_queue.contains((aid, v.title))) {
        _queue.add((aid, v.title));
        Future.microtask(_pump);
      }
      if (!_bgmTried.contains((aid, v.title))) _enqueueBangumi(aid);
      return null;
    }
    final temp = _tempCovers[(aid, v.title)];
    if (_netBlocked) {
      if (temp == null) _requestTemp(aid, v.title);
    } else if (_addBounded(_officialTried, (aid, v.title)) && !_queue.contains((aid, v.title))) {
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
    // 单本出错就跳过并尝试临时用 Bangumi 兜底；连着几本都出错多半是网络问题或被限流，先停并把队列里剩余的排入受控 Bangumi 兜底队列
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
      if (_queue.isEmpty && _bgPauseCount > 0) break;
      final (aid, title) = _queue.isNotEmpty ? _queue.removeLast() : _bg.removeAt(0);
      final v = Volumes.of(aid).where((v) => v.title == title).firstOrNull;
      final existing = Volumes.cover(aid, title);
      if (v == null || (existing != null && (existing.isNotEmpty || v.illus == null))) continue;
      if (v.illus == null) {
        await Volumes.setCover(aid, title, '');
        _enqueueBangumi(aid);
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
          _enqueueBangumi(aid);
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
      if (url.isEmpty) _enqueueBangumi(aid);
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
    _addBounded(_tempRequested, (aid, title));
    if (_tempTried.contains((aid, title)) || _bgmFailed.contains(aid)) return;
    if (_tempFilling.contains(aid) || _tempQueue.contains(aid)) return;
    _tempQueue.add(aid);
    Future.microtask(_pumpTemp);
  }

  void _pumpTemp() {
    if (_bgPauseCount > 0) return;
    while (_tempRunning < _maxBgmConcurrent && _tempQueue.isNotEmpty) {
      final aid = _tempQueue.removeAt(0);
      if (_bgmFailed.contains(aid) || _tempFilling.contains(aid)) continue;
      _tempRunning++;
      _fillTempFromBangumi(aid).whenComplete(() {
        _tempRunning--;
        if (_tempQueue.isNotEmpty) Future.microtask(_pumpTemp);
      });
    }
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
            if (a == aid && _addBounded(_tempTried, (a, t))) t,
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
            _putBounded(_tempCovers, (aid, title), url);
            changed = true;
          }
        }
      }
    } catch (_) {
      _addBounded(_bgmFailed, aid);
    } finally {
      _tempFilling.remove(aid);
      if (changed) Volumes.notifyAid(aid);
    }
  }

  void _enqueueBangumi(String aid) {
    if (_bgmFailed.contains(aid) || _bgmFilling.contains(aid) || _bgmQueue.contains(aid)) return;
    _bgmQueue.add(aid);
    Future.microtask(_pumpBangumi);
  }

  void _pumpBangumi() {
    if (_bgPauseCount > 0) return;
    while (_bgmRunning < _maxBgmConcurrent && _bgmQueue.isNotEmpty) {
      final aid = _bgmQueue.removeAt(0);
      if (_bgmFailed.contains(aid) || _bgmFilling.contains(aid)) continue;
      _bgmRunning++;
      _fillFromBangumi(aid).whenComplete(() {
        _bgmRunning--;
        if (_bgmQueue.isNotEmpty) Future.microtask(_pumpBangumi);
      });
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
        final empty = {for (final v in vols) if (Volumes.cover(aid, v.title) == '' && _addBounded(_bgmTried, (aid, v.title))) v.title};
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
      _addBounded(_bgmFailed, aid);
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
      for (final MapEntry(key: title, value: saved) in Volumes.covers(aid).entries) {
        final manual = saved.contains('#crop=');
        if (saved.isEmpty || (manual && !manualOn)) continue;
        final (:url, :crop) = splitCrop(saved);
        final bytes = await store.cached(url);
        if (bytes == null) continue;
        try {
          final from = crop ?? const ui.Rect.fromLTWH(0, 0, 1, 1);
          final px = await CoverPixels.decode(bytes, maxSide: manual ? 1600 : 800);
          final r = await px.trimAsync(from, maxTrim: manual ? 0.15 : 0.1);
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
      final px = await CoverPixels.decode(bytes, maxSide: 800);
      final r = await px.trimAsync(full, maxTrim: 0.1);
      return r == full ? url : withCrop(url, r, auto: true);
    } catch (_) {
      return url;
    }
  }

  /// 图片本来就要显示，下载后存在本机。
  Future<ui.Size> _size(String url) async => imageSize(await _ref.read(imageStoreProvider).load(url));
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
