import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'session.dart';
import 'volumes.dart';

/// 图片缓存：内存里最多留 [_memBytes] 字节（LRU），磁盘上长期保留，断网后封面和插图还能显示。
/// 网页预览不用它（直接走转发程序）。
class ImageStore {
  ImageStore(this._ref);

  final Ref _ref;
  // 按字节算：封面几十 KB、插图几百 KB，按张数算不是存不下封面就是插图占太多内存
  static const _memBytes = 64 << 20;
  final _mem = <String, Uint8List>{}; // Dart 的 Map 字面量保持插入顺序，当 LRU 用
  var _memUsed = 0;
  final _inflight = <String, Future<Uint8List>>{};
  final _cancelled = <String>{};
  final _hostChallenges = <String, Future<Uint8List?>>{}; // 同一个图床域名并发被拦时只拉起一次无头网页过盾
  final _hostClearedAt = <String, DateTime>{};

  // 网络下载排队：同时最多 [_maxNet] 张，按请求顺序（列表从上到下）。不排队时几十张一起抢带宽，挂代理时谁都快不了，最后一起冒出来。
  // 滑出屏幕的会被 [cancel] 从队里拿掉，所以排着的基本都是眼前这一屏的。
  static const _maxNet = 4;
  int _running = 0;
  final _waiting = <String, Completer<void>>{}; // Map 保持插入顺序
  final _pinned = <String>{}; // 预取的（[prefetch]），页面一闪而过也不取消
  Directory? _dir;

  Future<Directory> _cacheDir() async => _dir ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'imgcache')).create(recursive: true);

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

  Uint8List? _hit(String key) {
    final hit = _mem.remove(key);
    return hit == null ? null : _mem[key] = hit;
  }

  /// 内存里有就直接给（同步），没有返回 null。放大过清晰度的图给放大后的（还没读进内存时返回 null，免得先闪一下原图）。
  Uint8List? peek(String rawUrl) {
    final url = _norm(rawUrl);
    return _srShown(rawUrl, url) ? _hit('$url#sr') : _hit(url);
  }

  /// 图片字节；要放大清晰度的（见 [srSupported]）给放大后的，还没放大好就先给原图、排队去放大
  Future<Uint8List> load(String rawUrl) async {
    final bytes = await _load(rawUrl);
    return srSupported ? _srOr(rawUrl, bytes) : bytes;
  }

  /// 原图字节（不管清晰度）
  Future<Uint8List> _load(String rawUrl) {
    final url = _norm(rawUrl);
    _cancelled.remove(url);
    final hit = _hit(url);
    if (hit != null) return Future.value(hit);
    final running = _inflight[url];
    if (running != null) {
      _bump(url);
      return running;
    }
    late final Future<Uint8List> f;
    // 只删自己：被取消后又重新请求时，这里已经换成新的那次了
    f = _fetch(url).whenComplete(() { if (identical(_inflight[url], f)) _inflight.remove(url); });
    return _inflight[url] = f;
  }

  /// 已经存在本机的图（内存或磁盘），没有返回 null，不联网
  Future<Uint8List?> cached(String rawUrl) async {
    final url = _norm(rawUrl);
    final f = File(p.join((await _cacheDir()).path, _name(url)));
    return peek(url) ?? (await f.exists() ? await f.readAsBytes() : null);
  }

  /// 预取一整章的插图：按顺序排进下载队列，一次排好，不用翻到哪页才去取哪张。
  /// 翻页快、页面一闪而过时也不取消（见 [cancel]）；正要看的那张会插到队首（见 [_bump]）。
  void prefetch(Iterable<String> urls) {
    for (final raw in urls) {
      final url = _norm(raw);
      if (raw.isEmpty || _mem.containsKey(url)) continue;
      _pinned.add(url);
      _load(url).whenComplete(() => _pinned.remove(url)).ignore(); // 只下载，放大清晰度等真要显示时再说
    }
  }

  /// 还在排队的图有人要看了：挪到队首，下一个空出来的名额先给它。
  void _bump(String url) {
    final c = _waiting.remove(url);
    if (c == null) return;
    final rest = {..._waiting};
    _waiting
      ..clear()
      ..[url] = c
      ..addAll(rest);
  }

  /// 本地缓存文件的路径（没缓存就先下载）：给通知栏封面这种只认文件的地方用
  Future<String> path(String rawUrl) async {
    final url = _norm(rawUrl);
    await load(url);
    // 内存里有、磁盘上的文件却可能已经被清理掉了：补写一份，别给出不存在的路径
    final file = File(p.join((await _cacheDir()).path, _name(url)));
    if (!await file.exists()) await writeFileAtomic(file, await _load(url));
    return file.path;
  }

  Future<void> _slot(String url) {
    if (_running < _maxNet) {
      _running++;
      return Future.value();
    }
    return (_waiting[url] = Completer<void>()).future;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _running--;
    } else {
      _waiting.remove(_waiting.keys.first)!.complete(); // 名额直接交给排在最前面的
    }
  }

  /// 不再需要这张图（滑出屏幕、页面关了）：还在排队的就不下了。已经在下的照常下完存起来。
  void cancel(String rawUrl) {
    final url = _norm(rawUrl);
    if (_pinned.contains(url)) return;
    final c = _waiting.remove(url);
    if (c == null) {
      if (_inflight.containsKey(url)) _cancelled.add(url);
      return;
    }
    _inflight.remove(url); // 马上又滑回来时重新排队，别拿到这个被取消的结果
    c.completeError(const ImageCancelled());
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

  Future<List<int>> _download(String requestUrl) async {
    // 封面图床的 https 在国内不开代理时常连不上，http 正常；缓存文件名仍按 https 地址算，旧缓存照用
    final res = await _ref.read(imageDioProvider).get<List<int>>(requestUrl.replaceFirst('https://img.wenku8.com/', 'http://img.wenku8.com/'));
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
    return data;
  }

  Future<List<int>> _downloadViaChallenge(String targetUrl, ImageChallengeFallback challenge, DateTime requestStarted) async {
    final host = Uri.tryParse(targetUrl)?.host.toLowerCase() ?? '';
    final clearedAt = _hostClearedAt[host];
    // 在本次请求发出之后才刚过完盾：cookie jar 已刷新，先直接重试一次，不必再开网页
    if (clearedAt != null && !clearedAt.isBefore(requestStarted)) {
      try {
        return await _download(targetUrl);
      } catch (e) {
        if (!_isChallengeError(e)) rethrow;
      }
    }
    final running = _hostChallenges[host];
    if (running != null) {
      await running;
      return _download(targetUrl);
    }
    final f = challenge(targetUrl);
    _hostChallenges[host] = f;
    try {
      final bytes = await f;
      _hostClearedAt[host] = DateTime.now();
      if (bytes != null && bytes.isNotEmpty) return bytes;
      return await _download(targetUrl);
    } finally {
      if (identical(_hostChallenges[host], f)) _hostChallenges.remove(host);
    }
  }

  Future<Uint8List> _fetch(String url) async {
    final file = File(p.join((await _cacheDir()).path, _name(url)));
    Uint8List bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
      _touch(file).ignore();
    } else {
      if (_cancelled.remove(url) && !_pinned.contains(url)) {
        _inflight.remove(url);
        throw const ImageCancelled();
      }
      await _slot(url);
      try {
        final started = DateTime.now();
        List<int> data;
        try {
          data = await _download(url);
        } catch (primaryErr) {
          final alt = ImageUrlHelper.fallback(url);
          if (alt.isNotEmpty && alt != url) {
            final altStarted = DateTime.now();
            try {
              data = await _download(alt);
            } catch (altErr) {
              final challenge = _ref.read(imageChallengeProvider);
              if (challenge == null) rethrow;
              if (_isChallengeError(primaryErr)) {
                try {
                  data = await _downloadViaChallenge(url, challenge, started);
                } catch (_) {
                  if (!_isChallengeError(altErr)) rethrow;
                  data = await _downloadViaChallenge(alt, challenge, altStarted);
                }
              } else if (_isChallengeError(altErr)) {
                data = await _downloadViaChallenge(alt, challenge, altStarted);
              } else {
                rethrow;
              }
            }
          } else {
            final challenge = _ref.read(imageChallengeProvider);
            if (challenge == null || !_isChallengeError(primaryErr)) rethrow;
            data = await _downloadViaChallenge(url, challenge, started);
          }
        }
        bytes = await shrinkImage(Uint8List.fromList(data));
      } finally {
        _release();
      }
      await file.parent.create(recursive: true); // 下载期间可能清空了缓存目录
      await writeFileAtomic(file, bytes);
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

  // ---- 提升清晰度（Real-ESRGAN 放大 4 倍，只有安卓，见 Upscaler.kt）----
  // 自动模式放大书架上的书的封面里长边不到 600 像素的（文库的小封面、Bangumi 的老封面），手动模式只放大地址带 `#sr` 的（框封面时选的）。
  // 放大好的存在 imgsr 目录，文件名和原图一样；不归图片缓存的清理管，清空图片缓存时一起删。

  static bool get srSupported => !kIsWeb && Platform.isAndroid;

  static bool get _srAuto => AppPrefs.read(P.coverSr, 1) == 0;

  static const _upscale = MethodChannel('ark/upscale');

  /// 有图放大好了、模式换了：显示中的图重新取一次
  final srVersion = ValueNotifier<int>(0);
  Directory? _srDirCache;
  Set<String>? _srDone; // 放大好的（原图文件名），第一次用到时从目录读
  final _srQueue = <String>[];
  final _srSkip = <String>{}; // 不用放大（太大）或放大失败的，这次运行不再试
  bool _srRunning = false;
  final _srAllowed = <String>{}; // 自动模式能放大的：书架上的书的封面（取封面时记下）

  /// 书架上的书的封面，自动模式可以放大（发现、排行、搜索里别的书的封面不放大）。
  void allowAutoSr(String rawUrl) => _srAllowed.add(_norm(rawUrl));

  bool _autoSr(String url) => _srAuto && _srAllowed.contains(url);

  Future<Directory> _srDir() async => _srDirCache ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'imgsr')).create(recursive: true);

  Future<Set<String>> _srIndex() async {
    if (_srDone case final done?) return done;
    final names = {await for (final f in (await _srDir()).list()) if (f is File) p.basename(f.path)};
    if (_srDone != null) return _srDone!;
    _srDone = names;
    if (names.isNotEmpty) srVersion.value++; // 读到之前显示的是原图，换一下
    return names;
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
          srVersion.value++;
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
  Future<void> warm(Iterable<String> urls) async {
    final dir = await _cacheDir();
    for (final raw in urls) {
      if (_memUsed > _memBytes ~/ 2) return;
      final url = _norm(raw);
      if (raw.isEmpty || _mem.containsKey(url) || _inflight.containsKey(url)) continue;
      final f = File(p.join(dir.path, _name(url)));
      if (!await f.exists()) continue;
      final bytes = await f.readAsBytes();
      if (_mem.containsKey(url)) continue;
      _memUsed += bytes.length;
      _mem[url] = bytes;
    }
  }

  /// 删掉这些图的缓存（内存和磁盘）
  Future<void> remove(Iterable<String> urls) async {
    final dir = await _cacheDir();
    final srDir = srSupported ? await _srDir() : null;
    for (final raw in urls) {
      final url = _norm(raw);
      final name = _name(url);
      _memUsed -= _mem.remove(url)?.length ?? 0;
      _memUsed -= _mem.remove('$url#sr')?.length ?? 0;
      _srDone?.remove(name);
      final f = File(p.join(dir.path, name));
      if (await f.exists()) await f.delete();
      if (srDir != null) {
        final sf = File(p.join(srDir.path, name));
        if (await sf.exists()) await sf.delete();
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
    if (srSupported) {
      final sd = await _srDir();
      if (await sd.exists()) await sd.delete(recursive: true);
      _srDirCache = null;
      _srDone = null;
    }
    _dir = null;
    _mem.clear();
    _memUsed = 0;
  }

  /// 磁盘缓存超过 [maxBytes] 时按修改时间（最近一次用到的时间，见 [_touch]）从旧到新删，删到上限的 80%。
  /// 不删：书架上显示的封面（网站小封面和第一卷的卷封面）、手动挑过的卷封面、离线缓存的插图。其余卷封面删了也不怕，用到时重新下载，挑封面的记录和裁剪框另外存着。
  Future<void> trim({int maxBytes = 500 << 20}) async => trimDir(
    await _cacheDir(),
    maxBytes,
    keep: {for (final url in [...LibraryStore.covers(), ...Volumes.keptCovers(LibraryStore.aids()), ...ChapterCache.offlineImages()]) _name(_norm(url))},
  );

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
      _mem.clear();
      _memUsed = 0;
    }
    await box.put('imgHq', true);
  }

  Future<int> diskBytes() async {
    var n = 0;
    for (final dir in [await _cacheDir(), if (srSupported) await _srDir()]) {
      await for (final f in dir.list()) {
        if (f is File && !_isTemp(f)) n += await f.length();
      }
    }
    return n;
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

bool _isGif(Uint8List b) => b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46;

bool _isWebp(Uint8List b) => b.length > 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;

/// WebP 的 VP8X 扩展头里，标志字节（第 20 字节）的 0x02 位表示有动画
bool _isAnimatedWebp(Uint8List b) => _isWebp(b) && b.length > 20 && b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x58 && b[20] & 0x02 != 0;

/// 目录总大小超过 [maxBytes] 时，按修改时间从旧到新删文件，直到不超过 [maxBytes] 的 80%。
/// 文件名在 [keep] 里的不删（但计入总大小）。
Future<void> trimDir(Directory dir, int maxBytes, {Set<String> keep = const {}}) async {
  final files = <(File, FileStat)>[];
  var total = 0;
  await for (final f in dir.list()) {
    if (f is! File || _isTemp(f)) continue; // 正在写的临时文件，一会儿就改名了
    final st = await f.stat();
    total += st.size;
    if (!keep.contains(p.basename(f.path))) files.add((f, st));
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

class ImageCancelled implements Exception {
  const ImageCancelled();
}

final imageStoreProvider = Provider<ImageStore>((ref) => ImageStore(ref));
