import 'dart:async';
import 'dart:collection';
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
  Wenku8Client({required this.baseUrl, required this.charset, required Map<String, String> headers, Dio? dio, CookieJar? cookieJar, this.challengeFallback, Duration rateLimitPause = const Duration(seconds: 10)})
    : _cookieJar = cookieJar ?? CookieJar() {
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
      ..interceptors.add(_ThrottleInterceptor(rateLimitPause))
      ..interceptors.add(_CloudflareInterceptor());
    // 浏览器自己管理 cookie，CookieManager 在网页环境会断言失败（网页预览的 cookie 由转发程序保存）
    if (!kIsWeb) this.dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// 当前节点地址，例如 `https://www.wenku8.net`
  final String Function() baseUrl;

  /// 当前使用的页面编码
  final CharsetType Function() charset;

  final CookieJar _cookieJar;

  late final Dio dio;

  /// GET 页面被 Cloudflare 验证或 403 拦下时改用它取页面（原生 App 里是不显示的网页），返回解码好的 HTML
  final Future<String> Function(String url, {String? referer})? challengeFallback;

  /// 把登录后拿到的 cookie 字符串（`a=1;b=2`）写入 cookie jar，对 [hosts] 里的每个节点都生效。
  Future<void> restoreCookie(String cookie, Iterable<String> hosts) async {
    final cookies = <Cookie>[];
    for (final e in cookie.split(';').map((e) => e.trim()).where((e) => e.contains('='))) {
      final kv = e.split('=');
      try {
        // dart:io 的 Cookie 不允许值里有空格、引号、逗号、分号、反斜杠（例如阅读记录 cookie 里的逗号），转义后再放进去
        cookies.add(Cookie(kv[0].trim(), kv.sublist(1).join('=').replaceAllMapped(RegExp(r'[ ",;\\]'), (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}')));
      } on FormatException {
        // 名字里有 dart:io 不认的字符：只跳过这一个，别让整批都放不进去
      }
    }
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
  Future<String> getPage(String url, {bool charsetParam = true, String? referer}) async {
    final currentCharset = charset();
    final target = charsetParam || currentCharset != CharsetType.gbk ? Wenku8Charset.withCharsetParam(url, currentCharset) : url;
    final Uint8List bytes;
    try {
      bytes = await _getRetrying(target, referer);
    } on DioException catch (e) {
      // 书架这类页面不出验证，直接 403 拒绝不像浏览器的请求，也交给网页再试
      if (e is! CloudflareChallengeException && e is! Cloudflare403Exception) rethrow;
      final fallback = challengeFallback;
      if (fallback == null) rethrow;
      return fallback(target, referer: referer);
    }
    return Wenku8Charset.decode(bytes, currentCharset);
  }

  /// 读页面没有副作用，被限流（429）就排队再试：限流拦截器会先等暂停结束。试 3 次还不行才算失败。
  Future<Uint8List> _getRetrying(String target, String? referer) async {
    for (var tries = 1; ; tries++) {
      try {
        final response = await dio.get(target, options: referer == null ? null : Options(headers: {'Referer': referer}));
        return await _followRedirect(response);
      } on Wenku8HttpException catch (e) {
        if (e.status != 429 || tries >= 3) rethrow;
      }
    }
  }

  /// 以 `application/x-www-form-urlencoded` 提交表单，返回解码后的页面。
  ///
  /// [data] 可以是 Map（由 dio 编码），也可以是已经编码好的字符串。
  Future<String> postForm(String url, Object? data) async {
    final currentCharset = charset();
    final response = await dio.post(
      url,
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    // 成功提交常用 302/303 跳到结果页；只用 GET 确认，不重发 POST。跳到登录页不能冒充成功。
    final bytes = await _followRedirect(response, submitting: true);
    return Wenku8Charset.decode(bytes, currentCharset);
  }

  /// 4xx/5xx 不是页面，抛出让调用方走"网络问题"分支（403 已由 Cloudflare 拦截器处理）。
  void _checkStatus(Response response) {
    final status = response.statusCode ?? 0;
    if (status >= 400) throw Wenku8HttpException(status);
  }

  /// wenku8 会用 3xx 跳转（例如跳到登录页）。dio 关闭了自动跳转，这里手动跟随，
  /// 好让解析层拿到最终页面并判断出"未登录"等情况。
  /// - location 可能是相对路径（`userdetail.php`、`/login.php`）或绝对地址，基于当前请求地址解析
  /// - 最多跟随 [maxRedirects] 次，防止重定向死循环
  Future<Uint8List> _followRedirect(Response response, {int maxRedirects = 5, bool submitting = false}) async {
    var current = response;
    for (var i = 0; i < maxRedirects; i++) {
      final status = current.statusCode;
      if (status == null || status < 300 || status >= 400) break;
      final location = current.headers.value('location');
      if (location == null || location.isEmpty) break;
      final target = current.requestOptions.uri.resolve(location);
      if (submitting && target.path.toLowerCase().endsWith('/login.php')) throw const Wenku8UnexpectedPageException('登录已失效，请重新登录后再提交');
      // 307/308 要保留 POST 方法和请求体，不能改成 GET，也不自动重发可能已有副作用的请求。
      if (submitting && (status == 307 || status == 308)) throw const Wenku8UnexpectedPageException('提交请求被重定向，结果未确认，请刷新后检查');
      current = await dio.getUri(target);
    }
    if (submitting && (current.statusCode ?? 0) >= 300 && (current.statusCode ?? 0) < 400) {
      throw const Wenku8UnexpectedPageException('提交结果未确认，请刷新后检查');
    }
    _checkStatus(current);
    return current.data as Uint8List;
  }
}

class _CloudflareInterceptor extends Interceptor {
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    // 验证页本身也是 403，先认出来，免得当成被封
    final cfMitigated = response.headers['cf-mitigated'];
    if (cfMitigated != null && cfMitigated.contains('challenge')) {
      handler.reject(CloudflareChallengeException(requestOptions: response.requestOptions));
      return;
    }
    if (response.statusCode == 403) {
      handler.reject(Cloudflare403Exception(requestOptions: response.requestOptions));
      return;
    }
    handler.next(response);
  }
}

const _backgroundKey = #wenku8Background;

/// [body] 里发的请求算后台任务（检查更新、取详情、取封面）：排在用户正在等的请求后面，发得也更慢。
T runInBackground<T>(T Function() body) => runZoned(body, zoneValues: {_backgroundKey: true});

/// 所有页面请求排一条队，一次只发一个，保证不触发网站的速率限制。前台可以插队。
/// 任何请求收到 429，所有请求一起暂停 [_pause]。
class _ThrottleInterceptor extends Interceptor {
  _ThrottleInterceptor(this._pause);

  static const _foregroundGap = Duration(milliseconds: 300);
  static const _backgroundGap = Duration(seconds: 1);

  final Duration _pause;
  final _foreground = Queue<Completer<void>>();
  final _background = Queue<Completer<void>>();
  bool _busy = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final turn = Completer<void>();
    (Zone.current[_backgroundKey] == true ? _background : _foreground).add(turn);
    unawaited(_dispatch());
    await turn.future;
    options.extra['throttled'] = true;
    handler.next(options);
  }

  /// 等到能发了放行一个；它的响应回来（[_release]）才放下一个。
  Future<void> _dispatch() async {
    if (_busy) return;
    _busy = true;
    while (true) {
      if (_foreground.isEmpty && _background.isEmpty) {
        _busy = false;
        return;
      }
      // 等的时候可能来了前台请求或新的 429，每次醒来重新算
      final next = _last.add(_foreground.isNotEmpty ? _foregroundGap : _backgroundGap);
      final wait = (next.isAfter(_pausedUntil) ? next : _pausedUntil).difference(DateTime.now());
      if (wait <= Duration.zero) break;
      await Future<void>.delayed(wait);
    }
    _last = DateTime.now();
    (_foreground.isNotEmpty ? _foreground : _background).removeFirst().complete();
  }

  void _release(RequestOptions options) {
    if (options.extra.remove('throttled') != true) return;
    _busy = false;
    unawaited(_dispatch());
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 429) _pausedUntil = DateTime.now().add(_pause);
    _release(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _release(err.requestOptions);
    handler.next(err);
  }
}
