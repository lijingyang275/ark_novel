import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../models/common/charset_type.dart';
import '../../models/custom_exception.dart';
import 'wenku8_charset.dart';
import 'wenku8_exceptions.dart';

/// 访问 wenku8 的 HTTP 客户端。
///
/// 只负责"发请求 + 处理编码/重定向/Cloudflare + 管理 cookie"，不依赖 GetX 或本地存储：
/// 节点地址和编码通过构造参数里的函数按需读取，方便测试和以后替换状态管理。
class Wenku8Client {
  Wenku8Client({
    required this.baseUrl,
    required this.charset,
    required Map<String, String> headers,
    Dio? dio,
    CookieJar? cookieJar,
    this.challengeFallback,
    this.shouldRetryAfterFallback,
    Duration rateLimitPause = const Duration(seconds: 10),
    this.challengeCooldown = const Duration(seconds: 5),
    this.transientRetryDelay = const Duration(milliseconds: 350),
  }) : _cookieJar = cookieJar ?? CookieJar() {
    this.dio = (dio ?? Dio())
      ..options = BaseOptions(
        headers: headers,
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (status) => status != null,
        connectTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 25),
      )
      ..interceptors.add(_CloudflareInterceptor(onChallengeTriggered: _onCfDetected))
      ..interceptors.add(_ThrottleInterceptor(rateLimitPause, challengeGate: _challengeGateFor, cooldownError: _cooldownErrorFor));
    // 浏览器自己管理 cookie，CookieManager 在网页环境会断言失败（网页预览的 cookie 由转发程序保存）
    if (!kIsWeb) this.dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// 当前节点地址，例如 `https://www.wenku8.net`
  final String Function() baseUrl;

  /// 当前使用的页面编码
  final CharsetType Function() charset;

  final CookieJar _cookieJar;
  final Duration challengeCooldown;
  final Duration transientRetryDelay;

  late final Dio dio;

  /// GET 页面被 Cloudflare 验证或 403 拦下时改用它取页面（原生 App 里是不显示的网页），返回解码好的 HTML
  final Future<String> Function(String url, {String? referer})? challengeFallback;

  /// 无头网页过盾返回 HTML 后，若仍像是未带完整登录态的页面（例如 `login.php`），用刚写回的新 `cf_clearance` 让 Dio 重试一次。
  final bool Function(String html)? shouldRetryAfterFallback;

  // 按域名维护单飞 CF 协调与失败冷却窗口，防止多条并发请求齐刷刷撞 403 并排队进无头 WebView
  final _hostChallenges = <String, Completer<void>>{};
  final _hostClearedAt = <String, DateTime>{};
  final _hostFailedAt = <String, (DateTime, DioException)>{};

  // 相同 (url, referer) 的在途幂等 GET 请求合并去重
  final _inflight = <(String, String?), _InflightGet>{};

  int _fallbackCount = 0;

  /// 已触发无头网页 CF 兜底的累计次数（用于调用方判断某次请求是否经由兜底完成）。
  int get fallbackCount => _fallbackCount;

  /// 手动验证完成后清除对应域名（或全部域名）的 CF 失败冷却窗口，让紧接着的重试立即生效。
  void clearChallengeCooldown([String? host]) {
    if (host == null || host.isEmpty) {
      _hostFailedAt.clear();
    } else {
      _hostFailedAt.remove(host.toLowerCase());
    }
  }

  Completer<void>? _onCfDetected(String host, RequestOptions options) {
    if (options.extra['cfFallback'] != true || challengeFallback == null) return null;
    if (_hostChallenges.containsKey(host)) return null;
    final gate = Completer<void>();
    _hostChallenges[host] = gate;
    options.extra['cfGateOwner'] = gate;
    options.extra['cfGateHost'] = host;
    return gate;
  }

  Future<void>? _challengeGateFor(String host) => _hostChallenges[host]?.future;

  DioException? _cooldownErrorFor(String host, RequestOptions options) {
    final failed = _hostFailedAt[host];
    if (failed == null) return null;
    if (DateTime.now().difference(failed.$1) >= challengeCooldown) {
      _hostFailedAt.remove(host);
      return null;
    }
    options.extra['cfCooldownHit'] = true;
    return failed.$2 is Cloudflare403Exception
        ? Cloudflare403Exception(requestOptions: options)
        : CloudflareChallengeException(requestOptions: options);
  }

  void _releaseGate(String host, Completer<void>? gate) {
    if (gate == null) return;
    if (identical(_hostChallenges[host], gate)) _hostChallenges.remove(host);
    if (!gate.isCompleted) gate.complete();
  }

  static final _cookieEscapeRe = RegExp(r'[ ",;\\]');

  /// 把 `a=1;b=2` 形式的 cookie 字符串解析成 [Cookie] 列表，转义 `dart:io` 不接受的字符。
  static List<Cookie> parseCookieString(String cookie) {
    final cookies = <Cookie>[];
    for (final e in cookie.split(';').map((e) => e.trim()).where((e) => e.contains('='))) {
      final kv = e.split('=');
      try {
        // dart:io 的 Cookie 不允许值里有空格、引号、逗号、分号、反斜杠（例如阅读记录 cookie 里的逗号），转义后再放进去
        cookies.add(Cookie(kv[0].trim(), kv.sublist(1).join('=').replaceAllMapped(_cookieEscapeRe, (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}')));
      } on FormatException {
        // 名字里有 dart:io 不认的字符：只跳过这一个，别让整批都放不进去
      }
    }
    return cookies;
  }

  /// 把登录后拿到的 cookie 字符串（`a=1;b=2`）写入 cookie jar，对 [hosts] 里的每个节点都生效。
  Future<void> restoreCookie(String cookie, Iterable<String> hosts) async {
    final cookies = parseCookieString(cookie);
    for (final host in hosts) {
      await _cookieJar.saveFromResponse(Uri.parse(host), cookies);
    }
  }

  Future<void> clearCookie() => _cookieJar.deleteAll();

  /// 导出 cookie jar 里会发给 [host] 的 cookie（名字 → 值），用来把服务端续期过的 cookie 存回本地。
  Future<Map<String, String>> exportCookies(String host) async => {for (final c in await _cookieJar.loadForRequest(Uri.parse(host))) c.name: c.value};

  /// GET 一个页面并按当前编码解码成字符串。
  ///
  /// [charsetParam] 为 false 且当前是 GBK（网站默认编码）时不追加 `charset` 参数：上游项目发现带这个参数的书架、榜单、
  /// 详情、目录、正文请求会被 Cloudflare 的规则拦成 403；繁体（Big5）必须带参数，否则返回的还是 GBK 页面。
  /// [referer] 给目录、正文请求带上来源页，和浏览器行为一致。
  /// [cancelToken] 支持在排队或传输阶段取消请求，释放节流槽位。
  /// [retryTransient] 为 true 时对幂等 GET 的瞬态连接错误/502/504 最多重试 1 次（绝不重试 403/CF/4xx），并发相同 `(url, referer)` 自动去重合并。
  /// [allowChallengeFallback] 为 false（如阅读器后台章节预加载）时遇到 403/CF 直接快速失败，绝不静默拉起无头 WebView。
  Future<String> getPage(
    String url, {
    bool charsetParam = true,
    String? referer,
    CancelToken? cancelToken,
    bool retryTransient = true,
    bool allowChallengeFallback = true,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw cancelToken!.cancelError ?? DioException.requestCancelled(requestOptions: RequestOptions(path: url), reason: 'cancelled');
    }
    final currentCharset = charset();
    final target = charsetParam || currentCharset != CharsetType.gbk ? Wenku8Charset.withCharsetParam(url, currentCharset) : url;
    if (!retryTransient) {
      return _fetchPage(target, currentCharset, referer, cancelToken, retryTransient: false, allowChallengeFallback: allowChallengeFallback);
    }

    final key = (target, referer);
    var entry = _inflight[key];
    if (entry != null && entry.internalCancel.isCancelled) {
      _inflight.remove(key);
      entry = null;
    }
    if (entry == null && !allowChallengeFallback) {
      return _fetchPage(target, currentCharset, referer, cancelToken, retryTransient: true, allowChallengeFallback: false);
    }
    if (entry == null) {
      final internalCancel = CancelToken();
      entry = _InflightGet(internalCancel);
      _inflight[key] = entry;
      entry.future = _fetchPage(target, currentCharset, referer, internalCancel, retryTransient: true).whenComplete(() {
        if (identical(_inflight[key], entry)) _inflight.remove(key);
      });
    }
    entry.waiters++;
    if (cancelToken == null) {
      try {
        return await entry.future;
      } finally {
        entry.waiters--;
      }
    }

    final done = Completer<String>();
    var released = false;
    void releaseWaiter({required bool cancelled}) {
      if (released) return;
      released = true;
      entry!.waiters--;
      if (cancelled && entry.waiters <= 0 && !entry.internalCancel.isCancelled) {
        if (identical(_inflight[key], entry)) _inflight.remove(key);
        entry.internalCancel.cancel(cancelToken.cancelError?.error ?? 'cancelled');
      }
    }

    unawaited(entry.future.then(
      (value) {
        releaseWaiter(cancelled: false);
        if (!done.isCompleted) done.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        releaseWaiter(cancelled: false);
        if (!done.isCompleted) done.completeError(error, stack);
      },
    ));
    unawaited(cancelToken.whenCancel.then((err) {
      releaseWaiter(cancelled: true);
      if (!done.isCompleted) done.completeError(err);
    }));
    return done.future;
  }

  Future<String> _fetchPage(
    String target,
    CharsetType currentCharset,
    String? referer,
    CancelToken? cancelToken, {
    required bool retryTransient,
    bool allowChallengeFallback = true,
  }) async {
    final targetHost = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    final requestStarted = DateTime.now();
    final gateBox = <Completer<void>?>[null];
    final gateHostBox = <String?>[null];
    final Uint8List bytes;
    try {
      bytes = await _getRetrying(
        target,
        referer,
        cancelToken,
        retryTransient: retryTransient,
        allowChallengeFallback: allowChallengeFallback,
        gateBox: gateBox,
        gateHostBox: gateHostBox,
      );
    } on DioException catch (e) {
      final ownedGate = gateBox[0];
      // 若经过 301/302 跳转（例如 wenku8.cc -> wenku8.net），实际触发 CF 的是跳转后的域名，门控与冷却必须按该域名一致维护
      final cfHost = (gateHostBox[0] ?? e.requestOptions.uri.host.toLowerCase()).isNotEmpty
          ? (gateHostBox[0] ?? e.requestOptions.uri.host.toLowerCase())
          : targetHost;
      // 书架这类页面不出验证，直接 403 拒绝不像浏览器的请求，也交给网页再试
      if (e is! CloudflareChallengeException && e is! Cloudflare403Exception) {
        _releaseGate(cfHost, ownedGate);
        rethrow;
      }
      final fallback = allowChallengeFallback ? challengeFallback : null;
      if (fallback == null || e.requestOptions.extra['cfCooldownHit'] == true) {
        _releaseGate(cfHost, ownedGate);
        rethrow;
      }
      final fallbackTarget = e.requestOptions.uri.toString().isNotEmpty ? e.requestOptions.uri.toString() : target;
      return _handleChallenge(cfHost, fallbackTarget, currentCharset, referer, requestStarted, e, fallback, cancelToken, ownedGate);
    } catch (_) {
      _releaseGate(gateHostBox[0] ?? targetHost, gateBox[0]);
      rethrow;
    }
    return Wenku8Charset.decode(bytes, currentCharset);
  }

  Future<String> _handleChallenge(
    String host,
    String target,
    CharsetType currentCharset,
    String? referer,
    DateTime requestStarted,
    DioException cfError,
    Future<String> Function(String url, {String? referer}) fallback,
    CancelToken? cancelToken,
    Completer<void>? ownedGate,
  ) async {
    // 若在本次请求在途期间其他请求已经过完盾，直接用新 cookie 重试一次 Dio，不必再拉起无头浏览器
    final clearedAt = _hostClearedAt[host];
    if (ownedGate == null && clearedAt != null && !clearedAt.isBefore(requestStarted)) {
      final bytes = await _getRetrying(target, referer, cancelToken, retryTransient: false);
      return Wenku8Charset.decode(bytes, currentCharset);
    }

    // 已有另一条请求作为该域名的单飞领队：等待它结束后直接走 Dio 重试或快速失败
    final running = _hostChallenges[host];
    if (running != null && !identical(running, ownedGate)) {
      _releaseGate(host, ownedGate);
      final cancelled = await _waitFutureOrCancel(running.future, cancelToken);
      if (cancelled != null) throw cancelled;
      final failed = _hostFailedAt[host];
      if (failed != null && DateTime.now().difference(failed.$1) < challengeCooldown) {
        throw failed.$2;
      }
      final bytes = await _getRetrying(target, referer, cancelToken, retryTransient: false);
      return Wenku8Charset.decode(bytes, currentCharset);
    }

    // 冷却窗口内不再重复拉起无头 WebView
    final failed = _hostFailedAt[host];
    if (failed != null && DateTime.now().difference(failed.$1) < challengeCooldown) {
      _releaseGate(host, ownedGate);
      throw failed.$2;
    }

    final gate = ownedGate ?? (_hostChallenges[host] = Completer<void>());
    String html;
    try {
      _fallbackCount++;
      html = await fallback(target, referer: referer);
      _hostClearedAt[host] = DateTime.now();
      _hostFailedAt.remove(host);
    } on DioException catch (err) {
      if (err is CloudflareChallengeException || err is Cloudflare403Exception) {
        _hostFailedAt[host] = (DateTime.now(), err);
      }
      rethrow;
    } finally {
      _releaseGate(host, gate);
    }
    if (shouldRetryAfterFallback?.call(html) == true) {
      try {
        final bytes = await _getRetrying(target, referer, cancelToken, retryTransient: false);
        return Wenku8Charset.decode(bytes, currentCharset);
      } catch (_) {
        // 重试失败则回退到 fallback 拿到的页面，避免掩盖原始状态
      }
    }
    return html;
  }

  /// 读页面没有副作用，被限流（429）就排队再试：限流拦截器会先等暂停结束。试 3 次还不行才算失败。
  /// 幂等 GET 遇到瞬态连接中断 / 502 / 504 最多短退避重试 1 次（绝不重试 403/CF/4xx）。
  Future<Uint8List> _getRetrying(
    String target,
    String? referer,
    CancelToken? cancelToken, {
    required bool retryTransient,
    bool allowChallengeFallback = true,
    List<Completer<void>?>? gateBox,
    List<String?>? gateHostBox,
  }) async {
    var rateLimitTries = 0;
    var transientTries = 0;
    while (true) {
      if (cancelToken?.isCancelled == true) {
        throw cancelToken!.cancelError ?? DioException.requestCancelled(requestOptions: RequestOptions(path: target), reason: 'cancelled');
      }
      final extra = <String, dynamic>{'cfFallback': allowChallengeFallback && challengeFallback != null};
      try {
        final response = await dio.get(
          target,
          cancelToken: cancelToken,
          options: Options(headers: referer == null ? null : {'Referer': referer}, extra: extra),
        );
        return await _followRedirect(response, cancelToken: cancelToken, extra: extra);
      } on Wenku8HttpException catch (e) {
        if (e.status == 429 && ++rateLimitTries < 3 && cancelToken?.isCancelled != true) {
          continue;
        }
        if (retryTransient && (e.status == 502 || e.status == 504) && ++transientTries <= 1 && cancelToken?.isCancelled != true) {
          await _delayOrCancel(transientRetryDelay, cancelToken);
          continue;
        }
        rethrow;
      } on DioException catch (e) {
        final owner = e.requestOptions.extra['cfGateOwner'];
        if (owner is Completer<void> && gateBox != null) gateBox[0] = owner;
        final gateHost = e.requestOptions.extra['cfGateHost'];
        if (gateHost is String && gateHostBox != null) gateHostBox[0] = gateHost;
        if (e is CloudflareChallengeException || e is Cloudflare403Exception) rethrow;
        if (retryTransient && _isTransientDioError(e) && ++transientTries <= 1 && cancelToken?.isCancelled != true) {
          await _delayOrCancel(transientRetryDelay, cancelToken);
          continue;
        }
        rethrow;
      }
    }
  }

  static bool _isTransientDioError(DioException e) {
    if (e is CloudflareChallengeException || e is Cloudflare403Exception) return false;
    if (e.type == DioExceptionType.cancel || e.type == DioExceptionType.badResponse || e.type == DioExceptionType.badCertificate) return false;
    if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout) return false;
    final detail = '${e.error ?? ''} ${e.message ?? ''}'.toLowerCase();
    if (detail.contains('immediatelyretryable=true')) return true;
    if (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.unknown) {
      return detail.contains('connection reset') ||
          detail.contains('connection closed') ||
          detail.contains('broken pipe') ||
          detail.contains('err_network_changed') ||
          detail.contains('err_connection_reset') ||
          detail.contains('err_connection_closed') ||
          detail.contains('econnreset') ||
          detail.contains('nsurlerrornetworkconnectionlost') ||
          detail.contains('-1005');
    }
    return false;
  }

  /// 以 `application/x-www-form-urlencoded` 提交表单，返回解码后的页面。
  ///
  /// [data] 可以是 Map（由 dio 编码），也可以是已经编码好的字符串。
  Future<String> postForm(String url, Object? data, {CancelToken? cancelToken}) async {
    final currentCharset = charset();
    final response = await dio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    // 成功提交常用 302/303 跳到结果页；只用 GET 确认，不重发 POST。跳到登录页不能冒充成功。
    final bytes = await _followRedirect(response, submitting: true, cancelToken: cancelToken);
    return Wenku8Charset.decode(bytes, currentCharset);
  }

  /// 4xx/5xx 不是页面，抛出让调用方走"网络问题"分支（403 已由 Cloudflare 拦截器处理）。
  void _checkStatus(Response response) {
    final status = response.statusCode ?? 0;
    if (status >= 400) throw Wenku8HttpException(status);
  }

  static bool _isMainSiteHost(String host) {
    final h = host.toLowerCase();
    return h == 'wenku8.net' || h.endsWith('.wenku8.net') || h == 'wenku8.cc' || h.endsWith('.wenku8.cc');
  }

  /// wenku8 会用 3xx 跳转（例如跳到登录页）。dio 关闭了自动跳转，这里手动跟随，
  /// 好让解析层拿到最终页面并判断出"未登录"等情况。
  /// - location 可能是相对路径（`userdetail.php`、`/login.php`）或绝对地址，基于当前请求地址解析
  /// - 主站明文 `http://` 跳转自动升级为 `https://`，避免丢掉 `Secure` cookie 或触发明文拦截
  /// - 最多跟随 [maxRedirects] 次，防止重定向死循环
  Future<Uint8List> _followRedirect(Response response, {int maxRedirects = 5, bool submitting = false, CancelToken? cancelToken, Map<String, dynamic>? extra}) async {
    var current = response;
    for (var i = 0; i < maxRedirects; i++) {
      final status = current.statusCode;
      if (status == null || status < 300 || status >= 400) break;
      final location = current.headers.value('location')?.trim();
      if (location == null || location.isEmpty) break;
      var target = current.requestOptions.uri.resolve(location);
      if (target.scheme == 'http' && _isMainSiteHost(target.host)) {
        target = target.replace(scheme: 'https');
      }
      if (submitting && target.path.toLowerCase().endsWith('/login.php')) throw const Wenku8UnexpectedPageException('登录已失效，请重新登录后再提交');
      // 307/308 要保留 POST 方法和请求体，不能改成 GET，也不自动重发可能已有副作用的请求。
      if (submitting && (status == 307 || status == 308)) throw const Wenku8UnexpectedPageException('提交请求被重定向，结果未确认，请刷新后检查');
      current = await dio.getUri(target, cancelToken: cancelToken, options: extra == null ? null : Options(extra: Map<String, dynamic>.of(extra)));
    }
    if (submitting && (current.statusCode ?? 0) >= 300 && (current.statusCode ?? 0) < 400) {
      throw const Wenku8UnexpectedPageException('提交结果未确认，请刷新后检查');
    }
    _checkStatus(current);
    return current.data as Uint8List;
  }
}

class _InflightGet {
  _InflightGet(this.internalCancel);

  final CancelToken internalCancel;
  late Future<String> future;
  int waiters = 0;
}

Future<DioException?> _waitFutureOrCancel(Future<void> future, CancelToken? cancelToken) {
  if (cancelToken == null) return future.then((_) => null);
  if (cancelToken.isCancelled) return Future.value(cancelToken.cancelError);
  final done = Completer<DioException?>();
  unawaited(future.then(
    (_) {
      if (!done.isCompleted) done.complete(null);
    },
    onError: (_) {
      if (!done.isCompleted) done.complete(null);
    },
  ));
  unawaited(cancelToken.whenCancel.then((err) {
    if (!done.isCompleted) done.complete(err);
  }));
  return done.future;
}

Future<void> _delayOrCancel(Duration delay, CancelToken? cancelToken) async {
  if (delay <= Duration.zero) return;
  if (cancelToken == null) {
    await Future<void>.delayed(delay);
    return;
  }
  if (cancelToken.isCancelled) throw cancelToken.cancelError!;
  final cancelled = await _waitFutureOrCancel(Future<void>.delayed(delay), cancelToken);
  if (cancelled != null) throw cancelled;
}

class _CloudflareInterceptor extends Interceptor {
  _CloudflareInterceptor({this.onChallengeTriggered});

  final Completer<void>? Function(String host, RequestOptions options)? onChallengeTriggered;

  static bool _looksLikeChallengeBody(dynamic data) {
    if (data is! List<int> || data.isEmpty) return false;
    final head = latin1.decode(data.take(2048).toList(), allowInvalid: true).toLowerCase();
    return head.contains('just a moment') ||
        head.contains('checking your browser') ||
        head.contains('cf-turnstile') ||
        head.contains('challenge-platform') ||
        head.contains('cf_chl_') ||
        head.contains('id="challenge-form"') ||
        head.contains('id="challenge-running"');
  }

  void _rejectCf(Response<dynamic> response, ResponseInterceptorHandler handler, DioException err) {
    final host = response.requestOptions.uri.host.toLowerCase();
    onChallengeTriggered?.call(host, response.requestOptions);
    // callFollowingErrorInterceptor: true 确保后续 _ThrottleInterceptor.onError 必定释放 _busy
    handler.reject(err, true);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    // 验证页本身可能是 403 或 503，先认出来，免得当成被封或普通源站错误
    final cfMitigated = response.headers['cf-mitigated'];
    if (cfMitigated != null && cfMitigated.any((v) => v.toLowerCase().contains('challenge'))) {
      _rejectCf(response, handler, CloudflareChallengeException(requestOptions: response.requestOptions));
      return;
    }
    final status = response.statusCode;
    final server = response.headers.value('server')?.toLowerCase() ?? '';
    final hasCfRay = response.headers.value('cf-ray') != null;
    if (status == 503) {
      final isCf503 = _looksLikeChallengeBody(response.data) || (server.contains('cloudflare') && hasCfRay);
      if (isCf503) {
        _rejectCf(response, handler, CloudflareChallengeException(requestOptions: response.requestOptions));
        return;
      }
    }
    if (status == 403) {
      // nginx 自身的 403 交给外层按 HTTP 403 处理，别拉起无头浏览器白等
      if (server.contains('nginx') && !hasCfRay) {
        handler.next(response);
        return;
      }
      final err = _looksLikeChallengeBody(response.data)
          ? CloudflareChallengeException(requestOptions: response.requestOptions)
          : Cloudflare403Exception(requestOptions: response.requestOptions);
      _rejectCf(response, handler, err);
      return;
    }
    handler.next(response);
  }
}

const _backgroundKey = #wenku8Background;

/// [body] 里发的请求算后台任务（检查更新、取详情、取封面）：排在用户正在等的请求后面，发得也更慢。
T runInBackground<T>(T Function() body) => runZoned(body, zoneValues: {_backgroundKey: true});

/// 所有页面请求排一条队，一次只发一个，保证不触发网站的速率限制。前台可以插队。
/// 任何请求收到 429，优先遵循 Retry-After 并做指数退避 + 抖动。
/// 排队期间支持监听 [CancelToken] 立即出队，且与主站单飞 CF 协调联动避免无效撞墙。
class _ThrottleInterceptor extends Interceptor {
  _ThrottleInterceptor(this._pause, {this.challengeGate, this.cooldownError});

  static const _foregroundGap = Duration(milliseconds: 300);
  static const _backgroundGap = Duration(seconds: 1);

  final Duration _pause;
  final Future<void>? Function(String host)? challengeGate;
  final DioException? Function(String host, RequestOptions options)? cooldownError;

  final _foreground = Queue<Completer<bool>>();
  final _background = Queue<Completer<bool>>();
  final _rand = Random();
  bool _busy = false;
  Completer<void>? _wake;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _consecutive429 = 0;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final host = options.uri.host.toLowerCase();
    final useCfGate = options.extra['cfFallback'] == true;
    while (true) {
      if (options.cancelToken?.isCancelled == true) {
        handler.reject(options.cancelToken!.cancelError!);
        return;
      }
      if (useCfGate) {
        final gate = challengeGate?.call(host);
        if (gate != null) {
          final cancelled = await _waitFutureOrCancel(gate, options.cancelToken);
          if (cancelled != null) {
            handler.reject(cancelled);
            return;
          }
          continue;
        }
        final err = cooldownError?.call(host, options);
        if (err != null) {
          handler.reject(err);
          return;
        }
      }

      final acquired = await _acquireTurn(options);
      if (!acquired) {
        handler.reject(options.cancelToken!.cancelError!);
        return;
      }

      // 排队期间可能刚触发了该域名的单飞 CF 挑战或冷却：先释放节流槽位，避免白撞 403 或卡住其他域名
      if (useCfGate) {
        final gate = challengeGate?.call(host);
        final err = gate == null ? cooldownError?.call(host, options) : null;
        if (gate != null || err != null) {
          _busy = false;
          unawaited(Future.microtask(_dispatch));
          if (err != null) {
            handler.reject(err);
            return;
          }
          continue;
        }
      }
      break;
    }

    options.extra['throttled'] = true;
    unawaited(options.cancelToken?.whenCancel.whenComplete(() => _release(options)));
    handler.next(options);
  }

  Future<bool> _acquireTurn(RequestOptions options) async {
    final turn = Completer<bool>();
    final isBg = Zone.current[_backgroundKey] == true;
    final queue = isBg ? _background : _foreground;
    queue.add(turn);
    if (!isBg && _wake != null && !_wake!.isCompleted) _wake!.complete();
    final cancelToken = options.cancelToken;
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) {
        if (!turn.isCompleted) {
          queue.remove(turn);
          turn.complete(false);
        }
      }));
    }
    unawaited(_dispatch());
    return turn.future;
  }

  /// 等到能发了放行一个；它的响应回来（[_release]）才放下一个。
  Future<void> _dispatch() async {
    if (_busy) return;
    _busy = true;
    while (true) {
      while (_foreground.isNotEmpty && _foreground.first.isCompleted) {
        _foreground.removeFirst();
      }
      while (_background.isNotEmpty && _background.first.isCompleted) {
        _background.removeFirst();
      }
      if (_foreground.isEmpty && _background.isEmpty) {
        _busy = false;
        return;
      }
      // 等的时候可能来了前台请求或新的 429，每次醒来重新算
      final next = _last.add(_foreground.isNotEmpty ? _foregroundGap : _backgroundGap);
      final wait = (next.isAfter(_pausedUntil) ? next : _pausedUntil).difference(DateTime.now());
      if (wait <= Duration.zero) break;
      final wake = _wake = Completer<void>();
      await Future.any([Future<void>.delayed(wait), wake.future]);
      _wake = null;
    }
    while (_foreground.isNotEmpty && _foreground.first.isCompleted) {
      _foreground.removeFirst();
    }
    while (_background.isNotEmpty && _background.first.isCompleted) {
      _background.removeFirst();
    }
    if (_foreground.isEmpty && _background.isEmpty) {
      _busy = false;
      return;
    }
    _last = DateTime.now();
    (_foreground.isNotEmpty ? _foreground : _background).removeFirst().complete(true);
  }

  void _release(RequestOptions options) {
    if (options.extra.remove('throttled') != true) return;
    _busy = false;
    // 用 microtask 派发下一条：确保 CookieManager.onResponse 保存完 Set-Cookie 或外层 CF 逻辑先接管
    Future.microtask(_dispatch);
  }

  Duration _compute429Pause(Response<dynamic> response) {
    _consecutive429++;
    final retryAfter = _parseRetryAfter(response.headers.value('retry-after'));
    Duration base;
    if (retryAfter != null) {
      base = retryAfter;
    } else {
      final mult = 1 << (_consecutive429 - 1).clamp(0, 3);
      final ms = (_pause.inMilliseconds * mult).clamp(0, 60000);
      base = Duration(milliseconds: ms);
    }
    if (base <= Duration.zero) return Duration.zero;
    final jitterMs = (base.inMilliseconds * (_rand.nextDouble() * 0.2)).round();
    return base + Duration(milliseconds: jitterMs);
  }

  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final secs = int.tryParse(s);
    if (secs != null) return Duration(seconds: secs.clamp(1, 120));
    final dt = _parseHttpDate(s);
    if (dt == null) return null;
    final diff = dt.difference(DateTime.now().toUtc());
    if (diff <= Duration.zero) return const Duration(seconds: 1);
    return diff > const Duration(seconds: 120) ? const Duration(seconds: 120) : diff;
  }

  static final _httpDateRe = RegExp(r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$');

  static DateTime? _parseHttpDate(String s) {
    // RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
    final m = _httpDateRe.firstMatch(s);
    if (m == null) return null;
    const months = {'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12};
    final month = months[m[2]!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(int.parse(m[3]!), month, int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final status = response.statusCode ?? 0;
    if (status == 429) {
      final until = DateTime.now().add(_compute429Pause(response));
      if (until.isAfter(_pausedUntil)) _pausedUntil = until;
    } else if (status > 0 && status < 400) {
      _consecutive429 = 0;
    }
    _release(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _release(err.requestOptions);
    handler.next(err);
  }
}
