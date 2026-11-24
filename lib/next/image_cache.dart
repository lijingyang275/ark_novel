import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/image_url_helper.dart';
import '../models/custom_exception.dart';
import 'app_prefs.dart';
import 'cache.dart';
import 'files.dart';
import 'library.dart';
import 'local_books.dart' show LocalBooks, isLocalImageUrl;
import 'session.dart';
import 'volumes.dart';

/// 图片缓存：内存里最多留 [_memBytes] 字节（LRU），磁盘上长期保留，断网后封面和插图还能显示。
/// 网页预览不用它（直接走转发程序）。
class ImageStore {
  ImageStore(this._ref) {
    srVersion.addListener(_onGlobalSrVersion);
  }

  final Ref _ref;
  // 按字节算：封面几十 KB、插图几百 KB；移动端留 48 MB 避免叠加解码缓存与超分缓冲吃紧，桌面留 64 MB
  static final int _memBytes = (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? (48 << 20) : (64 << 20);
  // 书架封面缩略图独立 16 MB 内存 LRU（单张 ~10-25 KB，足够常驻上千张封面，避免与阅读器大图互踢）
  static const _thumbMemBytes = 16 << 20;
  static const _thumbMaxWidth = 360;
  static const _thumbMaxHeight = 640;

  final _mem = <String, Uint8List>{}; // Dart 的 Map 字面量保持插入顺序，当 LRU 用
  var _memUsed = 0;
  final _thumbMem = <String, Uint8List>{};
  var _thumbMemUsed = 0;
  final _inflight = <String, Future<Uint8List>>{};
  final _inflightRefs = <String, int>{}; // 同一规范 URL 并发订阅计数，全部取消且未 pinned 才中止下载
  final _cancelTokens = <String, CancelToken>{};
  final _cancelled = <String>{};
  final _thumbInflight = <String, Future<Uint8List>>{};
  final _thumbInflightRefs = <String, int>{};
  final _thumbCancelled = <String>{};
  final _thumbCalledLoad = <String>{};
  final _unbakedThumbs = <String>{};
  final _recentNetworkHits = <String>{}; // 记录最近由网络新下载完成的规范 URL，仅网络图做短淡入，磁盘秒命中直接显示
  final _hostChallenges = <String, Future<Uint8List?>>{}; // 同一个图床域名并发被拦时只拉起一次无头网页过盾
  final _hostClearedAt = <String, DateTime>{};
  final _hostFailedAt = <String, DateTime>{};
  static const _challengeCooldown = Duration(seconds: 60);

  // 网络下载排队：同时最多 [maxNet] 张。可见图排 [_highWaiting]（LIFO，优先唤醒最新进入视口），预取/后置露边排 [_lowWaiting]（FIFO）。
  // 滑出屏幕的会被 [cancel] 从队里拿掉，已无订阅者时取消在途 CancelToken 立即归还槽位；退出阅读器可调 [cancelPrefetch] 取消预取。
  static const maxNet = 6;
  int _running = 0;
  final _highWaiting = <String, Completer<void>>{}; // Map 保持插入顺序，尾部为最新进入视口的等待者（LIFO）
  final _lowWaiting = <String, Completer<void>>{};
  final _pinned = <String>{}; // 预取的（[prefetch]），页面一闪而过时不因单控件 dispose 取消；可用 [cancelPrefetch] 批量取消
  Directory? _dir;
  Directory? _thumbDirCache;

  Future<Directory> _cacheDir() async => _dir ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'imgcache')).create(recursive: true);

  Future<Directory> _thumbDir() async => _thumbDirCache ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'imgthumb')).create(recursive: true);

  /// 两个不同种子的 32 位 FNV-1a 拼成文件名（网页版不支持 64 位字面量）；只为避开 URL 里的特殊字符和过长的名字。
  static String _name(String url) {
    final bytes = utf8.encode(url);
    String hash(int seed) {
      var h = seed;
      for (final b in bytes) {
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
      }
      return h.toRadixString(16).padLeft(8, '0');
    }

    return hash(0x811c9dc5) + hash(0x9747b28c);
  }

  static String _norm(String url) => splitCrop(url).url.replaceFirst('http://', 'https://');

  /// 缩略图缓存键：规范 URL + 归一化裁剪框（`#crop=`/`#trim=` 统一）+ 当前是否展示 `#sr`。
  String thumbKey(String rawUrl, {bool? sr}) {
    final (:url, :crop) = splitCrop(rawUrl);
    final norm = url.replaceFirst('http://', 'https://');
    final useSr = sr ?? _srShown(rawUrl, norm);
    final buf = StringBuffer(norm);
    if (crop != null) {
      buf
        ..write('#crop=')
        ..write(crop.left.toStringAsFixed(4))
        ..write(',')
        ..write(crop.top.toStringAsFixed(4))
        ..write(',')
        ..write(crop.width.toStringAsFixed(4))
        ..write(',')
        ..write(crop.height.toStringAsFixed(4));
    }
    if (useSr) buf.write('#sr');
    return buf.toString();
  }

  static String _thumbFileName(String normUrl, String key) => '${_name(normUrl)}_${_name(key)}';

  Uint8List? _hit(String key) {
    final hit = _mem.remove(key);
    return hit == null ? null : _mem[key] = hit;
  }

  Uint8List? _hitThumb(String key) {
    final hit = _thumbMem.remove(key);
    return hit == null ? null : _thumbMem[key] = hit;
  }

  /// 最近一次加载是否经过了网络下载（用于区分本地磁盘秒命中与网络下载，仅后者做淡入动画）。
  bool wasLoadedFromNetwork(String rawUrl) => _recentNetworkHits.contains(_norm(rawUrl));

  /// 缩略图是否已烘焙裁剪框（无裁剪框或成功裁切压缩的缩略图均为 true；仅解码回退原图时为 false）。
  bool isThumbBaked(String rawUrl) => splitCrop(rawUrl).crop == null || !_unbakedThumbs.contains(thumbKey(rawUrl));

  /// 同步查询书架缩略图内存缓存（独立 16 MB LRU）。
  Uint8List? peekThumb(String rawUrl) => rawUrl.isEmpty ? null : _hitThumb(thumbKey(rawUrl));

  /// 异步加载书架缩略图（内存 → `imgthumb/` 磁盘 → 原图烘焙裁剪并压缩落盘；headless 或不支持压缩插件时优雅回退）。
  Future<Uint8List> loadThumb(String rawUrl, {bool lowPriority = false}) {
    final key = thumbKey(rawUrl);
    _thumbCancelled.remove(key);
    final hit = _hitThumb(key);
    if (hit != null) return Future.value(hit);
    final running = _thumbInflight[key];
    if (running != null) {
      _thumbInflightRefs[key] = (_thumbInflightRefs[key] ?? 0) + 1;
      if (!lowPriority) _bump(_norm(rawUrl));
      return running;
    }
    _thumbInflightRefs[key] = 1;
    late final Future<Uint8List> f;
    f = _fetchThumb(rawUrl, key, lowPriority: lowPriority).whenComplete(() {
      if (identical(_thumbInflight[key], f)) {
        _thumbInflight.remove(key);
        _thumbInflightRefs.remove(key);
        _thumbCalledLoad.remove(key);
      }
    });
    return _thumbInflight[key] = f;
  }

  /// 取消一次缩略图订阅；仅当该缩略图无其他订阅者时释放底层网络请求。
  void cancelThumb(String rawUrl) {
    final key = thumbKey(rawUrl);
    if (!_thumbInflight.containsKey(key)) return;
    final left = (_thumbInflightRefs[key] ?? 1) - 1;
    if (left > 0) {
      _thumbInflightRefs[key] = left;
      return;
    }
    _thumbInflightRefs.remove(key);
    _thumbInflight.remove(key);
    _thumbCancelled.add(key);
    if (_thumbCalledLoad.remove(key)) {
      cancel(rawUrl);
    }
  }

  Future<Uint8List> _fetchThumb(String rawUrl, String key, {required bool lowPriority}) async {
    final (:url, :crop) = splitCrop(rawUrl);
    final normUrl = url.replaceFirst('http://', 'https://');
    final dir = await _thumbDir();
    final file = File(p.join(dir.path, _thumbFileName(normUrl, key)));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (isValidImageBytes(bytes)) {
        _recentNetworkHits.remove(normUrl);
        _unbakedThumbs.remove(key);
        _putThumb(key, bytes);
        _touch(file).ignore();
        if (srSupported && (_autoSr(normUrl) || wantsSr(rawUrl)) && _srDone == null) {
          warmSrIndex().ignore();
        }
        return bytes;
      }
    }
    if (_thumbCancelled.remove(key)) throw const ImageCancelled();
    _thumbCalledLoad.add(key);
    final orig = await _load(normUrl, lowPriority: lowPriority);
    final source = srSupported ? await _srOr(rawUrl, orig) : orig;
    final effectiveKey = thumbKey(rawUrl);
    if (effectiveKey != key) {
      final hit = _hitThumb(effectiveKey);
      if (hit != null) return hit;
      final ef = File(p.join(dir.path, _thumbFileName(normUrl, effectiveKey)));
      if (await ef.exists()) {
        final eb = await ef.readAsBytes();
        if (isValidImageBytes(eb)) {
          _unbakedThumbs.remove(effectiveKey);
          _putThumb(effectiveKey, eb);
          _touch(ef).ignore();
          return eb;
        }
      }
    }
    final result = await _buildThumbnail(source, crop);
    if (result.baked || crop == null) {
      _unbakedThumbs.remove(effectiveKey);
      await dir.create(recursive: true);
      final outFile = File(p.join(dir.path, _thumbFileName(normUrl, effectiveKey)));
      await writeFileAtomic(outFile, result.bytes);
      _putThumb(effectiveKey, result.bytes);
    } else {
      _unbakedThumbs.add(effectiveKey);
    }
    return result.bytes;
  }

  /// 内存里有就直接给（同步），没有返回 null。放大过清晰度的图给放大后的（还没读进内存时返回 null，免得先闪一下原图）。
  Uint8List? peek(String rawUrl) {
    final url = _norm(rawUrl);
    return _srShown(rawUrl, url) ? _hit('$url#sr') : _hit(url);
  }

  /// 图片字节；要放大清晰度的（见 [srSupported]）给放大后的，还没放大好就先给原图、排队去放大
  Future<Uint8List> load(String rawUrl) => loadWithPriority(rawUrl);

  /// 按优先级加载原图字节（保持 [load] 签名不变以兼容现有测试桩）。
  Future<Uint8List> loadWithPriority(String rawUrl, {bool lowPriority = false}) async {
    final bytes = await _load(rawUrl, lowPriority: lowPriority);
    return srSupported ? _srOr(rawUrl, bytes) : bytes;
  }

  /// 原图字节（不管清晰度）
  Future<Uint8List> _load(String rawUrl, {bool lowPriority = false, bool fromPrefetch = false}) {
    final url = _norm(rawUrl);
    _cancelled.remove(url);
    final hit = _hit(url);
    if (hit != null) return Future.value(hit);
    final running = _inflight[url];
    if (running != null) {
      if (!fromPrefetch) _inflightRefs[url] = (_inflightRefs[url] ?? 0) + 1;
      if (!lowPriority) _bump(url);
      return running;
    }
    if (!fromPrefetch) _inflightRefs[url] = 1;
    late final Future<Uint8List> f;
    // 本地导入书籍图片（localimg:// 或本地路径）：直接读本地并放入内存 LRU，不走网络也不进磁盘 imgcache
    if (isLocalImageUrl(url)) {
      f = _fetchLocal(url).whenComplete(() {
        if (identical(_inflight[url], f)) {
          _inflight.remove(url);
          _inflightRefs.remove(url);
        }
      });
      return _inflight[url] = f;
    }
    final token = CancelToken();
    _cancelTokens[url] = token;
    // 只删自己：被取消后又重新请求时，这里已经换成新的那次了
    f = _fetch(url, lowPriority: lowPriority, cancelToken: token).whenComplete(() {
      if (identical(_inflight[url], f)) {
        _inflight.remove(url);
        _inflightRefs.remove(url);
        _cancelTokens.remove(url);
      }
    });
    return _inflight[url] = f;
  }

  Future<Uint8List> _fetchLocal(String url) async {
    final bytes = await LocalBooks.readImageBytes(url);
    if (bytes == null || bytes.isEmpty) throw StateError('local image not found: $url');
    _put(url, bytes);
    return bytes;
  }

  /// 已经存在本机的图（内存或磁盘），没有返回 null，不联网
  Future<Uint8List?> cached(String rawUrl) async {
    final url = _norm(rawUrl);
    if (isLocalImageUrl(url)) return peek(url) ?? await LocalBooks.readImageBytes(url);
    final f = File(p.join((await _cacheDir()).path, _name(url)));
    return peek(url) ?? (await f.exists() ? await f.readAsBytes() : null);
  }

  /// 预取一整章的插图：排入低优先级队列，不抢占可见封面/图片；正要看的那张会提升到高优队尾（见 [_bump]）。
  /// 退出阅读器时可调 [cancelPrefetch] 取消尚未开始的预取。
  void prefetch(Iterable<String> urls) {
    for (final raw in urls) {
      final url = _norm(raw);
      if (raw.isEmpty || _mem.containsKey(url)) continue;
      if (!_pinned.add(url)) continue;
      _load(url, lowPriority: true, fromPrefetch: true).whenComplete(() => _pinned.remove(url)).ignore(); // 只下载，放大清晰度等真要显示时再说
    }
  }

  /// 取消尚未开始的预取（传 [urls] 仅取消指定批，不传则取消全部低优预取）；仍有可见控件订阅的图不受影响。
  void cancelPrefetch([Iterable<String>? urls]) {
    final targets = urls == null ? _pinned.toList() : [for (final u in urls) if (u.isNotEmpty) _norm(u)];
    for (final url in targets) {
      _pinned.remove(url);
      if ((_inflightRefs[url] ?? 0) > 0 || _highWaiting.containsKey(url)) continue; // 已有可见控件在等这张图，不取消
      _abortInflight(url);
    }
  }

  /// 还在排队的图有人要看了：挪到高优队尾（LIFO 最高优），下一个空出来的名额最先给它。
  void _bump(String url) {
    final c = _highWaiting.remove(url) ?? _lowWaiting.remove(url);
    if (c == null) return;
    _highWaiting[url] = c;
  }

  /// 本地缓存文件的路径（没缓存就先下载）：给通知栏封面这种只认文件的地方用
  Future<String> path(String rawUrl) async {
    final url = _norm(rawUrl);
    if (isLocalImageUrl(url)) {
      final localPath = await LocalBooks.resolveImagePath(url);
      if (localPath == null) throw StateError('local image not found: $url');
      return localPath;
    }
    await load(url);
    // 内存里有、磁盘上的文件却可能已经被清理掉了：补写一份，别给出不存在的路径
    final file = File(p.join((await _cacheDir()).path, _name(url)));
    if (!await file.exists()) await writeFileAtomic(file, await _load(url));
    return file.path;
  }

  Future<void> _slot(String url, {bool lowPriority = false}) {
    if (_running < maxNet) {
      _running++;
      return Future.value();
    }
    final queue = lowPriority ? _lowWaiting : _highWaiting;
    return (queue[url] = Completer<void>()).future;
  }

  void _release() {
    if (_highWaiting.isNotEmpty) {
      // 高优队列 LIFO：优先唤醒最新进入视口的封面
      _highWaiting.remove(_highWaiting.keys.last)!.complete();
    } else if (_lowWaiting.isNotEmpty) {
      // 低优队列 FIFO：按顺序推进后台预取与后置露边
      _lowWaiting.remove(_lowWaiting.keys.first)!.complete();
    } else {
      _running--;
    }
  }

  void _abortInflight(String url) {
    final c = _highWaiting.remove(url) ?? _lowWaiting.remove(url);
    final token = _cancelTokens.remove(url);
    _inflightRefs.remove(url);
    if (c != null) {
      _inflight.remove(url); // 马上又滑回来时重新排队，别拿到这个被取消的结果
      c.completeError(const ImageCancelled());
      return;
    }
    if (_inflight.remove(url) != null) {
      _cancelled.add(url);
      if (token != null && !token.isCancelled) token.cancel('ImageStore.cancel');
    }
  }

  /// 不再需要这张图（滑出屏幕、页面关了）：减少订阅计数；当所有订阅者都取消且未被预取 pin 住时，
  /// 移出等待队列并取消在途 Dio 请求以尽快归还并发槽位。
  void cancel(String rawUrl) {
    final url = _norm(rawUrl);
    if (!_inflight.containsKey(url)) return;
    final left = (_inflightRefs[url] ?? 1) - 1;
    if (left > 0) {
      _inflightRefs[url] = left;
      return;
    }
    _inflightRefs.remove(url);
    if (_pinned.contains(url)) return;
    _abortInflight(url);
  }

  static bool _isChallengeError(Object e) {
    if (e is Cloudflare403Exception || e is CloudflareChallengeException) return true;
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 403 || status == 503) {
        final headers = e.response?.headers;
        final server = headers?.value('server')?.toLowerCase() ?? '';
        if (status == 403 && server.contains('nginx') && headers?.value('cf-ray') == null) return false;
        return true;
      }
    }
    return false;
  }

  Future<List<int>> _download(String requestUrl, {CancelToken? cancelToken}) async {
    // 封面图床的 https 在国内不开代理时常连不上，http 正常；缓存文件名仍按 https 地址算，旧缓存照用
    final res = await _ref.read(imageDioProvider).get<List<int>>(
      requestUrl.replaceFirst('https://img.wenku8.com/', 'http://img.wenku8.com/'),
      cancelToken: cancelToken,
    );
    final data = res.data;
    if (data == null || data.isEmpty) throw StateError('empty image response');
    if (data.length > 5 && data[0] == 0x3C) {
      final head = latin1.decode(data.take(1024).toList(), allowInvalid: true).toLowerCase();
      final cf = res.headers.value('cf-mitigated') == 'challenge' ||
          head.contains('cloudflare') ||
          head.contains('just a moment') ||
          head.contains('cf-turnstile') ||
          head.contains('challenge-platform');
      if (cf) throw CloudflareChallengeException(requestOptions: res.requestOptions);
      throw StateError('invalid image response');
    }
    if (!isValidImageBytes(data)) throw StateError('invalid image response');
    return data;
  }

  Future<List<int>> _downloadViaChallenge(String targetUrl, ImageChallengeFallback challenge, DateTime requestStarted, {CancelToken? cancelToken}) async {
    final host = Uri.tryParse(targetUrl)?.host.toLowerCase() ?? '';
    final clearedAt = _hostClearedAt[host];
    // 在本次请求发出之后才刚过完盾：cookie jar 已刷新，先直接重试一次，不必再开网页
    if (clearedAt != null && !clearedAt.isBefore(requestStarted)) {
      try {
        return await _download(targetUrl, cancelToken: cancelToken);
      } catch (e) {
        if (!_isChallengeError(e)) rethrow;
      }
    }
    final running = _hostChallenges[host];
    if (running != null) {
      await running;
      return _download(targetUrl, cancelToken: cancelToken);
    }
    final failedAt = _hostFailedAt[host];
    if (failedAt != null && DateTime.now().difference(failedAt) < _challengeCooldown) {
      throw CloudflareChallengeException(requestOptions: RequestOptions(path: targetUrl));
    }
    final f = challenge(targetUrl);
    _hostChallenges[host] = f;
    try {
      final bytes = await f;
      if (bytes != null && bytes.isNotEmpty) {
        if (!isValidImageBytes(bytes)) throw StateError('invalid image response');
        _hostFailedAt.remove(host);
        _hostClearedAt[host] = DateTime.now();
        return bytes;
      }
      final retry = await _download(targetUrl, cancelToken: cancelToken);
      _hostFailedAt.remove(host);
      _hostClearedAt[host] = DateTime.now();
      return retry;
    } catch (_) {
      _hostFailedAt[host] = DateTime.now();
      rethrow;
    } finally {
      if (identical(_hostChallenges[host], f)) _hostChallenges.remove(host);
    }
  }

  Future<Uint8List> _fetch(String url, {bool lowPriority = false, required CancelToken cancelToken}) async {
    final file = File(p.join((await _cacheDir()).path, _name(url)));
    Uint8List bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
      _recentNetworkHits.remove(url);
      _touch(file).ignore();
    } else {
      if (cancelToken.isCancelled || (_cancelled.remove(url) && !_pinned.contains(url))) {
        throw const ImageCancelled();
      }
      List<int>? data;
      Object? primaryErr;
      Object? altErr;
      final started = DateTime.now();
      DateTime? altStarted;
      final alt = ImageUrlHelper.fallback(url);
      final hasAlt = alt.isNotEmpty && alt != url;
      // 仅普通 HTTP 下载占并发槽位；长耗时 challenge 过盾与本地图片压缩移出 _slot，避免饿死其他图床。
      await _slot(url, lowPriority: lowPriority);
      try {
        if (cancelToken.isCancelled) throw const ImageCancelled();
        try {
          data = await _download(url, cancelToken: cancelToken);
        } catch (e) {
          if (cancelToken.isCancelled || (e is DioException && e.type == DioExceptionType.cancel)) {
            throw const ImageCancelled();
          }
          primaryErr = e;
          if (hasAlt) {
            altStarted = DateTime.now();
            try {
              data = await _download(alt, cancelToken: cancelToken);
            } catch (e2) {
              if (cancelToken.isCancelled || (e2 is DioException && e2.type == DioExceptionType.cancel)) {
                throw const ImageCancelled();
              }
              altErr = e2;
            }
          }
        }
      } finally {
        _release();
      }
      if (data == null) {
        final challenge = _ref.read(imageChallengeProvider);
        if (challenge == null) throw (altErr ?? primaryErr)!;
        if (_isChallengeError(primaryErr!)) {
          try {
            data = await _downloadViaChallenge(url, challenge, started, cancelToken: cancelToken);
          } catch (_) {
            if (cancelToken.isCancelled) throw const ImageCancelled();
            if (altErr == null || !_isChallengeError(altErr)) rethrow;
            data = await _downloadViaChallenge(alt, challenge, altStarted!, cancelToken: cancelToken);
          }
        } else if (altErr != null && _isChallengeError(altErr)) {
          data = await _downloadViaChallenge(alt, challenge, altStarted!, cancelToken: cancelToken);
        } else {
          throw altErr ?? primaryErr;
        }
      }
      final rawBytes = data is Uint8List ? data : Uint8List.fromList(data);
      if (!isValidImageBytes(rawBytes)) throw StateError('invalid image response');
      bytes = await shrinkImage(rawBytes);
      await file.parent.create(recursive: true); // 下载期间可能清空了缓存目录
      await writeFileAtomic(file, bytes);
      _recentNetworkHits.remove(url);
      _recentNetworkHits.add(url);
      if (_recentNetworkHits.length > 256) _recentNetworkHits.remove(_recentNetworkHits.first);
    }
    _put(url, bytes);
    return bytes;
  }

  void _put(String key, Uint8List bytes) {
    _memUsed += bytes.length - (_mem.remove(key)?.length ?? 0);
    _mem[key] = bytes;
    while (_memUsed > _memBytes && _mem.length > 1) {
      _memUsed -= _mem.remove(_mem.keys.first)!.length;
    }
  }

  void _putThumb(String key, Uint8List bytes) {
    _thumbMemUsed += bytes.length - (_thumbMem.remove(key)?.length ?? 0);
    _thumbMem[key] = bytes;
    while (_thumbMemUsed > _thumbMemBytes && _thumbMem.length > 1) {
      _thumbMemUsed -= _thumbMem.remove(_thumbMem.keys.first)!.length;
    }
  }

  // ---- 提升清晰度（Real-ESRGAN 放大 4 倍，只有安卓，见 Upscaler.kt）----
  // 自动模式放大书架上的书的封面里长边不到 600 像素的（文库的小封面、Bangumi 的老封面），手动模式只放大地址带 `#sr` 的（框封面时选的）。
  // 放大好的存在 imgsr 目录，文件名和原图一样；不归图片缓存的清理管，清空图片缓存时一起删。

  static bool get srSupported => !kIsWeb && Platform.isAndroid;

  static bool get _srAuto => Hive.isBoxOpen('session') && AppPrefs.read(P.coverSr, 1) == 0;

  /// 当前是否开启自动超分（供图片控件决定是否订阅超分版本号）。
  static bool get srAutoEnabled => _srAuto;

  static const _upscale = MethodChannel('ark/upscale');

  /// 有图放大好了、模式换了：兼容旧版全量订阅；新代码请使用 [srNotifierFor] / [srVersionForProvider] 做按 URL 局部刷新。
  final srVersion = ValueNotifier<int>(0);
  final _srUrlNotifiers = <String, _UrlSrNotifier>{};
  bool _inSingleSrNotify = false;
  Directory? _srDirCache;
  Set<String>? _srDone; // 放大好的（原图文件名），第一次用到时从目录读
  Future<Set<String>>? _srIndexFuture;
  final _srQueue = <String>[];
  final _srSkip = <String>{}; // 不用放大（太大）或放大失败的，这次运行不再试
  bool _srRunning = false;
  final _srAllowed = <String>{}; // 自动模式能放大的：书架上的书的封面（取封面时记下）

  /// 按图片地址获取局部超分版本号通知器（仅该图超分完成或全局模式切换时递增）。
  ValueNotifier<int> srNotifierFor(String rawUrl) {
    final url = _norm(rawUrl);
    return _srUrlNotifiers.putIfAbsent(url, _UrlSrNotifier.new);
  }

  void _releaseSrNotifierIfUnused(String rawUrl) {
    final url = _norm(rawUrl);
    final n = _srUrlNotifiers[url];
    if (n != null && !n.active) {
      _srUrlNotifiers.remove(url);
      n.dispose();
    }
  }

  void _onGlobalSrVersion() {
    if (_inSingleSrNotify) return;
    for (final n in _srUrlNotifiers.values.toList()) {
      n.value++;
    }
  }

  void _notifySingleSr(String url) {
    _srUrlNotifiers[url]?.value++;
    _inSingleSrNotify = true;
    try {
      srVersion.value++;
    } finally {
      _inSingleSrNotify = false;
    }
  }

  /// 切换超分模式时调用：通知所有已挂载图片重新评估清晰度。
  void notifySrModeChanged() => srVersion.value++;

  void dispose() {
    srVersion.removeListener(_onGlobalSrVersion);
    srVersion.dispose();
    for (final n in _srUrlNotifiers.values) {
      n.dispose();
    }
    _srUrlNotifiers.clear();
  }

  /// 书架上的书的封面，自动模式可以放大（发现、排行、搜索里别的书的封面不放大）。
  void allowAutoSr(String rawUrl) => _srAllowed.add(_norm(rawUrl));

  bool _autoSr(String url) => _srAuto && _srAllowed.contains(url);

  Future<Directory> _srDir() async => _srDirCache ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'imgsr')).create(recursive: true);

  /// 在主界面空闲时异步预热超分目录索引，避免首次展示超分图时在热路径扫描整个 `imgsr`。
  Future<void> warmSrIndex() async {
    if (!srSupported) return;
    await _srIndex();
  }

  Future<Set<String>> _srIndex() {
    if (_srDone case final done?) return Future.value(done);
    return _srIndexFuture ??= () async {
      final names = {await for (final f in (await _srDir()).list()) if (f is File) p.basename(f.path)};
      _srDone ??= names;
      if (names.isNotEmpty) {
        for (final entry in _srUrlNotifiers.entries.toList()) {
          if (names.contains(_name(entry.key))) entry.value.value++;
        }
        _inSingleSrNotify = true;
        try {
          srVersion.value++; // 读到之前显示的是原图，换一下
        } finally {
          _inSingleSrNotify = false;
        }
      }
      return _srDone!;
    }().whenComplete(() => _srIndexFuture = null);
  }

  bool _srShown(String raw, String url) => srSupported && (_autoSr(url) || wantsSr(raw)) && (_srDone?.contains(_name(url)) ?? false);

  Future<Uint8List> _srOr(String raw, Uint8List orig) async {
    final manual = wantsSr(raw);
    final url = _norm(raw);
    if (!_autoSr(url) && !manual) return orig;
    final name = _name(url);
    final done = await _srIndex();
    if (done.contains(name)) {
      final hit = _hit('$url#sr');
      if (hit != null) return hit;
      final f = File(p.join((await _srDir()).path, name));
      if (await f.exists()) {
        final b = await f.readAsBytes();
        _put('$url#sr', b);
        return b;
      }
      done.remove(name);
    }
    if (_srSkip.contains(url) || _srQueue.contains(url)) return orig;
    if (!manual && (await imageSize(orig)).longestSide >= 600) {
      _srSkip.add(url);
      return orig;
    }
    _srQueue.add(url);
    _pumpSr().ignore();
    return orig;
  }

  /// 一次放大一张（手机上一张一两秒，几张一起跑会卡）
  Future<void> _pumpSr() async {
    if (_srRunning) return;
    _srRunning = true;
    try {
      while (_srQueue.isNotEmpty) {
        final url = _srQueue.removeAt(0);
        try {
          final out = await _upscale.invokeMethod<Uint8List>('upscale', {'bytes': await _load(url)});
          if (out == null) throw StateError('empty');
          await writeFileAtomic(File(p.join((await _srDir()).path, _name(url))), out);
          (await _srIndex()).add(_name(url));
          _put('$url#sr', out);
          _notifySingleSr(url);
        } catch (e) {
          debugPrint('upscale $url: $e');
          _srSkip.add(url);
        }
      }
    } finally {
      _srRunning = false;
    }
  }

  /// 把磁盘上已有的这些图按顺序读进内存（不联网），内存用到一半就停，免得把别的图挤掉。
  /// [thumbnail] 为 true 时预热书架缩略图（独立 16 MB LRU），否则预热原图/已超分图。
  Future<void> warm(Iterable<String> urls, {bool thumbnail = false}) async {
    if (thumbnail) {
      final dir = await _thumbDir();
      for (final raw in urls) {
        if (_thumbMemUsed > _thumbMemBytes ~/ 2) return;
        if (raw.isEmpty) continue;
        final normUrl = _norm(raw);
        final key = thumbKey(raw);
        if (_thumbMem.containsKey(key) || _thumbInflight.containsKey(key)) continue;
        final f = File(p.join(dir.path, _thumbFileName(normUrl, key)));
        if (!await f.exists()) continue;
        final bytes = await f.readAsBytes();
        if (!isValidImageBytes(bytes) || _thumbMem.containsKey(key)) continue;
        _putThumb(key, bytes);
      }
      return;
    }
    final dir = await _cacheDir();
    Directory? srDir;
    for (final raw in urls) {
      if (_memUsed > _memBytes ~/ 2) return;
      if (raw.isEmpty) continue;
      final url = _norm(raw);
      if (isLocalImageUrl(url)) {
        if (_mem.containsKey(url) || _inflight.containsKey(url)) continue;
        final bytes = await LocalBooks.readImageBytes(url);
        if (bytes == null || _mem.containsKey(url)) continue;
        _put(url, bytes);
        continue;
      }
      final sr = _srShown(raw, url);
      final memKey = sr ? '$url#sr' : url;
      if (_mem.containsKey(memKey) || _inflight.containsKey(url)) continue;
      final f = sr ? File(p.join((srDir ??= await _srDir()).path, _name(url))) : File(p.join(dir.path, _name(url)));
      if (!await f.exists()) continue;
      final bytes = await f.readAsBytes();
      if (_mem.containsKey(memKey)) continue;
      _put(memKey, bytes);
    }
  }

  /// 删掉这些图的缓存（内存、原图磁盘、超分磁盘与缩略图磁盘）
  Future<void> remove(Iterable<String> urls) async {
    final dir = await _cacheDir();
    final thumbDir = await _thumbDir();
    final srDir = srSupported ? await _srDir() : null;
    final normSet = <String>{};
    final baseNames = <String>{};
    for (final raw in urls) {
      if (raw.isEmpty) continue;
      final url = _norm(raw);
      final name = _name(url);
      normSet.add(url);
      baseNames.add(name);
      _memUsed -= _mem.remove(url)?.length ?? 0;
      _memUsed -= _mem.remove('$url#sr')?.length ?? 0;
      _recentNetworkHits.remove(url);
      _srDone?.remove(name);
      if (isLocalImageUrl(url)) continue;
      final f = File(p.join(dir.path, name));
      if (await f.exists()) await f.delete();
      if (srDir != null) {
        final sf = File(p.join(srDir.path, name));
        if (await sf.exists()) await sf.delete();
      }
    }
    if (normSet.isEmpty) return;
    for (final k in _thumbMem.keys.where((k) => normSet.contains(_norm(k))).toList()) {
      _thumbMemUsed -= _thumbMem.remove(k)?.length ?? 0;
    }
    _unbakedThumbs.removeWhere((k) => normSet.contains(_norm(k)));
    if (await thumbDir.exists()) {
      await for (final f in thumbDir.list()) {
        if (f is! File || _isTemp(f)) continue;
        final base = p.basename(f.path).split('_').first;
        if (baseNames.contains(base)) await f.delete();
      }
    }
  }

  /// 以前缓存的图在后台按现在的标准压一遍（每次调高压缩程度后做一次），一张一张来，压完一张存一张，保留原来的修改时间（清理时按它排先后）。
  Future<void> shrinkOld() async {
    final box = Hive.box('session');
    if (box.get('imgShrunk2') == true) return;
    final dir = await _cacheDir();
    // 先列好再压：边列边写，临时文件会混进列表
    for (final f in await dir.list().toList()) {
      if (f is! File || _isTemp(f)) continue;
      final before = await f.readAsBytes();
      final after = await shrinkImage(before);
      if (!identical(after, before)) {
        final mtime = (await f.stat()).modified;
        await writeFileAtomic(f, after);
        await f.setLastModified(mtime);
      }
    }
    await box.put('imgShrunk2', true);
  }

  Future<void> clearDisk() async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    final td = await _thumbDir();
    if (await td.exists()) await td.delete(recursive: true);
    if (srSupported) {
      final sd = await _srDir();
      if (await sd.exists()) await sd.delete(recursive: true);
      _srDirCache = null;
      _srDone = null;
      _srIndexFuture = null;
    }
    _dir = null;
    _thumbDirCache = null;
    _mem.clear();
    _memUsed = 0;
    _thumbMem.clear();
    _thumbMemUsed = 0;
    _unbakedThumbs.clear();
    _recentNetworkHits.clear();
  }

  /// 磁盘缓存超过 [maxBytes] 时按修改时间（最近一次用到的时间，见 [_touch]）从旧到新删，删到上限的 80%。
  /// 不删：书架上显示的封面（网站小封面和第一卷的卷封面）、手动挑过的卷封面、离线缓存的插图，以及这些保留封面的缩略图。
  Future<void> trim({int maxBytes = 500 << 20, int? maxThumbBytes}) async {
    final keep = {
      for (final url in [...LibraryStore.covers(), ...Volumes.keptCovers(LibraryStore.aids()), ...ChapterCache.offlineImages()]) _name(_norm(url)),
    };
    await trimDir(await _cacheDir(), maxBytes, keep: keep);
    await trimDir(
      await _thumbDir(),
      maxThumbBytes ?? math.min(64 << 20, maxBytes),
      shouldKeep: (name) => keep.contains(name.split('_').first),
    );
  }

  /// 从磁盘读到时把修改时间改成现在，清理时常看的排在后面；一天内用过的不重复改
  Future<void> _touch(File f) async {
    final now = DateTime.now();
    if (now.difference(await f.lastModified()) > const Duration(days: 1)) await f.setLastModified(now);
  }

  /// 以前按长边 1600、质量 75 压过的图清掉一次（压过的回不去了），用到时按现在的标准重新下载；离线缓存的插图留着，没网时还要看
  Future<void> dropLowQualityOnce() async {
    final box = Hive.box('session');
    if (box.get('imgHq') == true) return;
    if (box.get('imgShrunk2') == true) {
      final keep = {for (final url in ChapterCache.offlineImages()) _name(_norm(url))};
      final dir = await _cacheDir();
      await for (final f in dir.list()) {
        if (f is File && !keep.contains(p.basename(f.path))) await f.delete();
      }
      final td = await _thumbDir();
      if (await td.exists()) {
        await for (final f in td.list()) {
          if (f is File) await f.delete();
        }
      }
      _mem.clear();
      _memUsed = 0;
      _thumbMem.clear();
      _thumbMemUsed = 0;
      _unbakedThumbs.clear();
    }
    await box.put('imgHq', true);
  }

  Future<int> diskBytes() async {
    var n = 0;
    for (final dir in [await _cacheDir(), await _thumbDir(), if (srSupported) await _srDir()]) {
      if (!await dir.exists()) continue;
      await for (final f in dir.list()) {
        if (f is File && !_isTemp(f)) n += await f.length();
      }
    }
    return n;
  }

  /// 生成书架级缩略图（最大宽 [_thumbMaxWidth]，移动端 WebP / 桌面 JPEG，质量 82），带裁剪框时直接烘焙裁剪区域。
  /// 在 `flutter test` 等 headless 或不支持原生压缩插件的平台上优雅回退。
  Future<({Uint8List bytes, bool baked})> _buildThumbnail(Uint8List source, Rect? crop) async {
    if (_isGif(source) || _isAnimatedWebp(source)) {
      return (bytes: source, baked: crop == null);
    }
    final ui.Size origSize;
    try {
      origSize = await imageSize(source);
    } catch (_) {
      return (bytes: source, baked: false);
    }
    if (origSize.width <= 0 || origSize.height <= 0) {
      return (bytes: source, baked: false);
    }
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final format = mobile ? CompressFormat.webp : CompressFormat.jpeg;
    if (crop == null) {
      if (origSize.width <= _thumbMaxWidth && origSize.height <= _thumbMaxHeight && source.length <= (32 << 10)) {
        return (bytes: source, baked: true);
      }
      final scale = math.min(1.0, math.min(_thumbMaxWidth / origSize.width, _thumbMaxHeight / origSize.height));
      final dstW = math.max(1, (origSize.width * scale).round());
      final dstH = math.max(1, (origSize.height * scale).round());
      try {
        final out = await FlutterImageCompress.compressWithList(
          source,
          minWidth: dstW,
          minHeight: dstH,
          quality: 82,
          format: format,
        );
        if (out.isNotEmpty && isValidImageBytes(out)) {
          return (bytes: (out.length <= source.length || scale < 1.0) ? out : source, baked: true);
        }
      } catch (_) {}
      if (scale >= 1.0) return (bytes: source, baked: true);
      final resized = await _cropAndScalePng(source, null, origSize, dstW, dstH);
      if (resized != null && resized.length < source.length) {
        return (bytes: resized, baked: true);
      }
      return (bytes: source, baked: true);
    }
    final cropW = (origSize.width * crop.width).clamp(1.0, origSize.width);
    final cropH = (origSize.height * crop.height).clamp(1.0, origSize.height);
    final scale = math.min(1.0, math.min(_thumbMaxWidth / cropW, _thumbMaxHeight / cropH));
    final dstW = math.max(1, (cropW * scale).round());
    final dstH = math.max(1, (cropH * scale).round());
    final croppedPng = await _cropAndScalePng(source, crop, origSize, dstW, dstH);
    if (croppedPng == null) return (bytes: source, baked: false);
    try {
      final out = await FlutterImageCompress.compressWithList(
        croppedPng,
        minWidth: dstW,
        minHeight: dstH,
        quality: 82,
        format: format,
      );
      if (out.isNotEmpty && isValidImageBytes(out)) {
        return (bytes: out, baked: true);
      }
    } catch (_) {}
    return (bytes: croppedPng, baked: true);
  }

  Future<Uint8List?> _cropAndScalePng(Uint8List source, Rect? crop, ui.Size origSize, int dstW, int dstH) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    ui.Image? srcImg;
    ui.Picture? picture;
    ui.Image? outImg;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(source);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final scale = crop == null
          ? math.min(1.0, math.min(dstW / origSize.width, dstH / origSize.height))
          : math.min(1.0, math.min(dstW / math.max(1.0, origSize.width * crop.width), dstH / math.max(1.0, origSize.height * crop.height)));
      final decW = math.max(1, (origSize.width * scale).ceil());
      final decH = math.max(1, (origSize.height * scale).ceil());
      codec = await desc.instantiateCodec(targetWidth: decW, targetHeight: decH);
      srcImg = (await codec.getNextFrame()).image;
      final sw = srcImg.width.toDouble();
      final sh = srcImg.height.toDouble();
      final Rect srcRect;
      if (crop == null) {
        srcRect = Rect.fromLTWH(0, 0, sw, sh);
      } else {
        final left = (crop.left * sw).clamp(0.0, math.max(0.0, sw - 1.0)).toDouble();
        final top = (crop.top * sh).clamp(0.0, math.max(0.0, sh - 1.0)).toDouble();
        final width = (crop.width * sw).clamp(1.0, math.max(1.0, sw - left)).toDouble();
        final height = (crop.height * sh).clamp(1.0, math.max(1.0, sh - top)).toDouble();
        srcRect = Rect.fromLTWH(left, top, width, height);
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        srcImg,
        srcRect,
        Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      picture = recorder.endRecording();
      outImg = await picture.toImage(dstW, dstH);
      final byteData = await outImg.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      outImg?.dispose();
      picture?.dispose();
      srcImg?.dispose();
      codec?.dispose();
      desc?.dispose();
      buffer?.dispose();
    }
  }
}

const _maxSide = 2400;

/// 图片存盘前压一下：长边超过 [_maxSide] 的缩到 [_maxSide]，再转 WebP（只有安卓、iOS 支持，macOS 转 JPEG），质量 90，看起来和原图没区别。
/// 不用无损 WebP：网站的图大多是 JPEG，转成无损反而比原图大。
/// 小图（150 KB 以下，比如书的小封面）、动图（GIF、动态 WebP）、不超过 [_maxSide] 的 WebP 不动；压完没小两成以上（源图本来就压得狠）就留原图。
/// 不支持的平台（Windows、Linux）原样返回。
Future<Uint8List> shrinkImage(Uint8List b) async {
  if (b.length < 150 << 10 || _isGif(b) || _isAnimatedWebp(b)) return b;
  try {
    final size = await imageSize(b);
    final long = size.longestSide;
    if (_isWebp(b) && long <= _maxSide) return b;
    final s = long > _maxSide ? _maxSide / long : 1.0;
    final out = await FlutterImageCompress.compressWithList(
      b,
      minWidth: (size.width * s).round(),
      minHeight: (size.height * s).round(),
      quality: 90,
      format: Platform.isAndroid || Platform.isIOS ? CompressFormat.webp : CompressFormat.jpeg,
    );
    return out.length < b.length * 0.8 ? out : b;
  } catch (_) {
    return b;
  }
}

bool _isTemp(File f) => f.path.endsWith('.tmp');

/// 校验图片魔数（JPEG / PNG / GIF / WebP），防止非 HTML 报错体或截断垃圾数据落盘污染缓存。
bool isValidImageBytes(List<int> b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true; // JPEG
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) return true; // PNG
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61) return true; // GIF87a/89a
  if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return true; // WebP
  return false;
}

bool _isGif(Uint8List b) => b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46;

bool _isWebp(Uint8List b) => b.length > 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;

/// WebP 的 VP8X 扩展头里，标志字节（第 20 字节）的 0x02 位表示有动画
bool _isAnimatedWebp(Uint8List b) => _isWebp(b) && b.length > 20 && b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x58 && b[20] & 0x02 != 0;

/// 目录总大小超过 [maxBytes] 时，按修改时间从旧到新删文件，直到不超过 [maxBytes] 的 80%。
/// 文件名在 [keep] 里或满足 [shouldKeep] 的不删（但计入总大小）。
Future<void> trimDir(Directory dir, int maxBytes, {Set<String> keep = const {}, bool Function(String name)? shouldKeep}) async {
  if (!await dir.exists()) return;
  final files = <(File, FileStat)>[];
  var total = 0;
  await for (final f in dir.list()) {
    if (f is! File || _isTemp(f)) continue; // 正在写的临时文件，一会儿就改名了
    final st = await f.stat();
    total += st.size;
    final name = p.basename(f.path);
    if (!keep.contains(name) && !(shouldKeep?.call(name) ?? false)) files.add((f, st));
  }
  if (total <= maxBytes) return;
  files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
  for (final (f, st) in files) {
    if (total <= maxBytes * 0.8) break;
    await f.delete();
    total -= st.size;
  }
}

/// 自选封面的裁剪框记在地址后面：`图片地址#crop=左,上,宽,高`（都是 0~1 的比例）。下载、缓存都按去掉它的地址算。
/// 自动挑的封面去掉白边时记成 `#trim=`，显示上一样，只是不算手动挑的（图片缓存清理时可以删）。
({String url, Rect? crop}) splitCrop(String s) {
  s = s.replaceFirst('#sr', '');
  var i = s.indexOf('#crop=');
  if (i < 0) i = s.indexOf('#trim=');
  if (i < 0) return (url: s, crop: null);
  final n = s.substring(i + 6).split(',').map(double.tryParse).toList();
  if (n.length != 4 || n.contains(null)) return (url: s.substring(0, i), crop: null);
  return (url: s.substring(0, i), crop: Rect.fromLTWH(n[0]!, n[1]!, n[2]!, n[3]!));
}

/// 框封面时选了「提升清晰度」：地址后面加 `#sr`（在裁剪框前面：`图片地址#sr#crop=…`），见 [ImageStore.load]
bool wantsSr(String s) => s.contains('#sr');

String withSr(String s, bool on) {
  final clean = s.replaceFirst('#sr', '');
  if (!on) return clean;
  final i = clean.indexOf('#');
  return i < 0 ? '$clean#sr' : '${clean.substring(0, i)}#sr${clean.substring(i)}';
}

String withCrop(String url, Rect r, {bool auto = false}) => '$url#${auto ? 'trim' : 'crop'}=${[r.left, r.top, r.width, r.height].map((e) => e.toStringAsFixed(4)).join(',')}';

class _UrlSrNotifier extends ValueNotifier<int> {
  _UrlSrNotifier() : super(0);

  bool get active => hasListeners;
}

class ImageCancelled implements Exception {
  const ImageCancelled();
}

final imageStoreProvider = Provider<ImageStore>((ref) {
  final store = ImageStore(ref);
  ref.onDispose(store.dispose);
  return store;
});

/// 只读图片头部拿宽高，不完整解码。
Future<ui.Size> imageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? desc;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buffer);
    return ui.Size(desc.width.toDouble(), desc.height.toDouble());
  } finally {
    desc?.dispose();
    buffer?.dispose();
  }
}

/// 按图片地址细粒度订阅超分版本号：单张图超分完成只刷新对应图片，不再触发全屏级失效重建。
final srVersionForProvider = Provider.autoDispose.family<int, String>((ref, rawUrl) {
  final store = ref.watch(imageStoreProvider);
  final notifier = store.srNotifierFor(rawUrl);
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() {
    notifier.removeListener(listener);
    store._releaseSrNotifierIfUnused(rawUrl);
  });
  return notifier.value;
});
