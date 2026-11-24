import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

CronetEngine? _sharedCronetEngine;
bool _cronetUnavailable = false;

/// 用系统自带的网络栈发请求：安卓是 Cronet（和 Chrome 同一套 TLS），苹果是 NSURLSession（和 Safari / WebView 同一套）。
/// Dart 自己的 TLS 指纹和浏览器不一样，Cloudflare 会据此拦截；WebView 通过验证后拿到的 cf_clearance，用同样指纹的请求才不容易被再次质询。
///
/// - 安卓共享进程级单例 [CronetEngine]（复用连接池/线程池并开启 HTTP/2 与 Brotli），无 Google 服务或 Cronet 不可用时退回 [fallback]
/// - 苹果端关掉系统的 cookie 处理：cookie 由 Dio 的 cookie jar 自己管，免得两边各发一份，同时设置请求空闲超时
HttpClientAdapter? nativeAdapter(HttpClientAdapter Function() fallback) {
  if (Platform.isAndroid) return _SplitCookies(_SharedCronetAdapter(fallback));
  if (Platform.isIOS || Platform.isMacOS) {
    return _SplitCookies(NativeAdapter(
      createCupertinoConfiguration: () => URLSessionConfiguration.ephemeralSessionConfiguration()
        ..httpShouldSetCookies = false
        ..httpCookieAcceptPolicy = NSHTTPCookieAcceptPolicy.NSHTTPCookieAcceptPolicyNever
        ..timeoutIntervalForRequest = const Duration(seconds: 25),
    ));
  }
  return null;
}

/// 懒加载并复用进程级单例 [CronetEngine]；关闭单个 Dio 时只关闭对应的 [CronetClient] 包装，不关闭共享引擎。
class _SharedCronetAdapter implements HttpClientAdapter {
  _SharedCronetAdapter(this._fallback);

  final HttpClientAdapter Function() _fallback;
  HttpClientAdapter? _selected;
  bool _closed = false;

  HttpClientAdapter _select() {
    final existing = _selected;
    if (existing != null) return existing;
    if (_cronetUnavailable) return _selected = _fallback();
    try {
      final engine = _sharedCronetEngine ??= CronetEngine.build(enableHttp2: true, enableBrotli: true);
      return _selected = CronetAdapter(engine, closeEngine: false);
    } catch (error) {
      final msg = error.toString();
      if (msg.contains('All available Cronet providers are disabled') || msg.contains('Unable to find any Cronet provider')) {
        _cronetUnavailable = true;
        return _selected = _fallback();
      }
      rethrow;
    }
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      _select().fetch(options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _selected?.close(force: force);
  }
}

/// 系统网络栈经 http 包转过来时，多条 Set-Cookie 被合成一条逗号拼接的。cookie jar 按一条解析会失败
/// （带 `expires=Thu, 01 Jan …` 的整个请求被当成出错）或存错，登录后的书架这类页面就取不到。这里拆回多条。
class _SplitCookies implements HttpClientAdapter {
  _SplitCookies(this._inner);

  final HttpClientAdapter _inner;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final res = await _inner.fetch(options, requestStream, cancelFuture);
    final v = res.headers['set-cookie'];
    if (v != null) res.headers['set-cookie'] = splitSetCookie(v);
    return res;
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

// 和 http 包 headersSplitValues 拆 set-cookie 的规则一样：逗号后面紧跟 `名字=` 才算下一条，expires 里的逗号不拆
final _setCookieSplitter = RegExp(r"[ \t]*,[ \t]*(?=[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)");

List<String> splitSetCookie(List<String> values) => [for (final v in values) ...v.split(_setCookieSplitter)];
