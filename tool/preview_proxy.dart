// 网页预览用的转发程序：让浏览器里的预览版 App 能访问 wenku8。
//
// 浏览器不允许网页直接读取别的网站（跨域限制），也不允许网页设置 User-Agent、读写别站 cookie，
// 所以网页预览版把所有请求发到这里，由它转发给 wenku8，并在服务器上保存登录 cookie。
//
// 运行：dart run tool/preview_proxy.dart
// 环境变量：
//   PREVIEW_BIND    监听地址，默认 0.0.0.0（建议填 Tailscale 地址，只让自己的设备访问）
//   PREVIEW_PORT    监听端口，默认 8091（网页版默认会连同一台机器的 8091）
//   WENKU8_TARGET   转发目标，默认 https://www.wenku8.cc
//   PREVIEW_STATE   cookie 保存位置，默认 ~/.ark_preview_session.json
//   https_proxy     需要的话，转发时走的上游代理
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0';

/// 图片转发只允许这些域名，避免被当成任意网址的开放代理
const _imageHosts = ['wenku8.com', 'wenku8.net', 'wenku8.cc', '777743.xyz'];

final _env = Platform.environment;
final Uri _target = Uri.parse(_env['WENKU8_TARGET'] ?? 'https://www.wenku8.cc');
final File _stateFile = File(_env['PREVIEW_STATE'] ?? '${_env['HOME']}/.ark_preview_session.json');
final Map<String, String> _cookies = {};

final HttpClient _http = HttpClient()
  ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri, environment: _env))
  ..connectionTimeout = const Duration(seconds: 20);

Future<void> main() async {
  if (_stateFile.existsSync()) {
    _cookies.addAll(Map<String, String>.from(jsonDecode(_stateFile.readAsStringSync()) as Map));
  }
  final bind = _env['PREVIEW_BIND'] ?? '0.0.0.0';
  final port = int.parse(_env['PREVIEW_PORT'] ?? '8091');
  final server = await HttpServer.bind(bind, port);
  stdout.writeln('preview proxy: http://$bind:$port -> $_target (cookies: ${_cookies.keys.join(', ')})');
  await for (final request in server) {
    unawaited(
      _handle(request).catchError((Object e) {
        stderr.writeln('error ${request.method} ${request.uri}: $e');
        try {
          request.response
            ..statusCode = HttpStatus.badGateway
            ..write('preview proxy error: $e');
          unawaited(request.response.close());
        } catch (_) {}
      }),
    );
  }
}

Future<void> _handle(HttpRequest request) async {
  final response = request.response;
  final origin = request.headers.value('origin');
  response.headers
    ..set('Access-Control-Allow-Origin', origin ?? '*')
    ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    ..set('Access-Control-Allow-Headers', 'content-type')
    ..set('Vary', 'Origin');

  if (request.method == 'OPTIONS') {
    response.statusCode = HttpStatus.noContent;
    await response.close();
    return;
  }

  final path = request.uri.path;
  if (path == '/__session/logout') {
    _cookies.clear();
    _saveCookies();
    await response.close();
    return;
  }
  if (path == '/__image') {
    await _forwardImage(request);
    return;
  }

  final body = await request.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
  final upstream = await _send(
    request.method,
    _target.replace(path: path, query: request.uri.hasQuery ? request.uri.query : null),
    body: body,
    contentType: request.headers.value(HttpHeaders.contentTypeHeader),
  );
  response.statusCode = upstream.statusCode;
  final type = upstream.headers.value(HttpHeaders.contentTypeHeader);
  if (type != null) response.headers.set(HttpHeaders.contentTypeHeader, type);
  // 把 Cloudflare 的拦截标记带回去，App 能据此提示
  final mitigated = upstream.headers.value('cf-mitigated');
  if (mitigated != null) response.headers.set('cf-mitigated', mitigated);
  await response.addStream(upstream);
  await response.close();
}

/// 发请求并手动跟随重定向（最多 5 次），过程中记录 wenku8 下发的 cookie。
Future<HttpClientResponse> _send(String method, Uri uri, {List<int> body = const [], String? contentType}) async {
  for (var hop = 0; ; hop++) {
    final req = await _http.openUrl(method, uri);
    req
      ..followRedirects = false
      ..headers.set(HttpHeaders.userAgentHeader, _userAgent)
      ..headers.set(HttpHeaders.refererHeader, '$_target/');
    if (_cookies.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    if (body.isNotEmpty) {
      if (contentType != null) req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.add(body);
    }
    final res = await req.close();
    _storeCookies(res.cookies);

    final location = res.headers.value(HttpHeaders.locationHeader);
    if (!res.isRedirect || location == null || hop >= 5) return res;
    await res.drain<void>();
    uri = uri.resolve(location);
    method = 'GET';
    body = const [];
  }
}

void _storeCookies(List<Cookie> cookies) {
  if (cookies.isEmpty) return;
  for (final c in cookies) {
    final expired = c.expires != null && c.expires!.isBefore(DateTime.now()) || c.maxAge == 0 || c.value.isEmpty || c.value == 'deleted';
    expired ? _cookies.remove(c.name) : _cookies[c.name] = c.value;
  }
  _saveCookies();
}

void _saveCookies() {
  _stateFile.writeAsStringSync(jsonEncode(_cookies));
  // cookie 等同于登录凭证，只允许自己读写
  if (!Platform.isWindows) Process.runSync('chmod', ['600', _stateFile.path]);
}

Future<void> _forwardImage(HttpRequest request) async {
  final response = request.response;
  final url = Uri.tryParse(request.uri.queryParameters['url'] ?? '');
  if (url == null || !url.isScheme('https') && !url.isScheme('http') || !_imageHosts.any((h) => url.host == h || url.host.endsWith('.$h'))) {
    response.statusCode = HttpStatus.forbidden;
    await response.close();
    return;
  }
  final upstream = await _send('GET', url);
  response.statusCode = upstream.statusCode;
  final type = upstream.headers.value(HttpHeaders.contentTypeHeader);
  if (type != null) response.headers.set(HttpHeaders.contentTypeHeader, type);
  response.headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=86400');
  await response.addStream(upstream);
  await response.close();
}
