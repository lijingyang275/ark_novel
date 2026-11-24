import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/custom_exception.dart';

Future<void> _tail = Future.value();

/// 相邻两次加载至少隔这么久：网页一页带出好几个请求，连着开会被 Cloudflare 限流成 Access denied
const _gap = Duration(seconds: 1);

Future<T> _enqueue<T>(Future<T> Function() run) {
  final result = _tail.then((_) => run());
  _tail = result.then<void>((_) {}, onError: (_) {}).then((_) => Future<void>.delayed(_gap));
  return result;
}

/// App 自己的请求被 Cloudflare 拦下时，改用不显示的网页加载同一地址并取整页 HTML。
/// 网页是真浏览器，Cloudflare 通常直接放行；请求前会把本地登录 cookie（`jieqi*`）同步进 WebView，避免切换节点或开 VPN 走兜底时丢登录态。
/// 一次只开一个网页，其余排队。网页也过不去（20 秒内一直停在验证页）就照旧抛 [CloudflareChallengeException]，让界面提示去验证。
Future<String> webFetch(
  String url, {
  String? referer,
  String proxy = '',
  String? loginCookies,
  Future<void> Function(String cookies, String? userAgent, String origin)? onSession,
}) => _enqueue(() => _load(url, referer, proxy, loginCookies, onSession));

/// 图片请求被 Cloudflare 拦下时，用不显示的网页过一次盾并取回图片字节；同时通过 [onSession] 把该图床的 `cf_clearance` 和 UA 带回给 Dio 并发下载。
Future<Uint8List> webFetchImage(String url, {String? referer, String proxy = '', Future<void> Function(String cookies, String? userAgent, String origin)? onSession}) =>
    _enqueue(() => _loadImage(url, referer, proxy, onSession));

/// 将本地保存的登录 cookie（仅 `jieqi*`）同步写入系统 WebView 的 [CookieManager]，
/// 避免用户只在一个线路登录过、切到另一线路或开 VPN 触发 WebView 兜底时因缺登录态被站点踢去 `login.php`。
Future<void> syncWebViewLoginCookies(String? cookieHeader, Iterable<String> origins) async {
  if (cookieHeader == null || cookieHeader.isEmpty || cookieHeader == 'preview') return;
  final pairs = <(String, String)>[];
  for (final raw in cookieHeader.split(';')) {
    final trimmed = raw.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final name = trimmed.substring(0, eq).trim();
    if (!name.startsWith('jieqi')) continue;
    pairs.add((name, trimmed.substring(eq + 1)));
  }
  if (pairs.isEmpty) return;
  final cm = CookieManager.instance();
  final seen = <String>{};
  for (final origin in origins) {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) continue;
    final norm = 'https://${uri.host}/';
    if (!seen.add(norm)) continue;
    final webUri = WebUri(norm);
    for (final (name, value) in pairs) {
      try {
        await cm.setCookie(url: webUri, name: name, value: value, path: '/', isSecure: true);
      } catch (_) {}
    }
  }
}

/// WebView 的代理是整个进程共用的，跟着设置走：请求页面和网页的出口才一致，清空设置后也不会留着旧代理（只有 Android 支持）。
Future<void> applyWebViewProxy(String proxy) async {
  if (!Platform.isAndroid) return;
  try {
    final controller = ProxyController.instance();
    final clean = proxy.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').trim();
    if (clean.isEmpty) {
      await controller.clearProxyOverride();
    } else {
      await controller.setProxyOverride(settings: ProxySettings(proxyRules: [ProxyRule(url: 'http://$clean')]));
    }
  } catch (_) {}
}

bool _isChallengeTitle(String title) => title.contains('Just a moment') || title.contains('请稍候') || title.contains('Checking your browser');

bool _isBlockedTitle(String title) =>
    title.startsWith('Access denied') || title.contains('Attention Required') || title.contains('已被封锁') || title.contains('have been blocked');

const _challengeDomQuery = "!!document.querySelector('#challenge-form, #challenge-running, .cf-turnstile, #cf-challenge-running')";

String _originOf(String fallbackUrl, WebUri? loadedUri) {
  final loadedHost = loadedUri?.host ?? '';
  final host = loadedHost.isNotEmpty ? loadedHost : (Uri.tryParse(fallbackUrl)?.host ?? '');
  return 'https://$host';
}

bool _isMainSiteHost(String host) => host == 'wenku8.net' || host.endsWith('.wenku8.net') || host == 'wenku8.cc' || host.endsWith('.wenku8.cc');

Uri? _upgradeMainSiteHttp(Uri uri) => uri.scheme == 'http' && _isMainSiteHost(uri.host) ? uri.replace(scheme: 'https') : null;

bool isEmptyShellHtml(String html) {
  final stripped = html.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '').replaceAll(RegExp(r'<[^>]+>'), '').trim();
  if (stripped.isNotEmpty) return false;
  return !RegExp(r'<(form|input|img|iframe|table|a\s)', caseSensitive: false).hasMatch(html);
}

Future<String> _load(
  String url,
  String? referer,
  String proxy,
  String? loginCookies,
  Future<void> Function(String cookies, String? userAgent, String origin)? onSession,
) async {
  await applyWebViewProxy(proxy);
  final reqOrigin = _originOf(url, null);
  await syncWebViewLoginCookies(loginCookies, [reqOrigin, 'https://www.wenku8.net', 'https://www.wenku8.cc']);
  final done = Completer<String>();
  var upgradingToHttps = false;

  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    // 只要 HTML，不下图片，少发请求；拦截主站明文 HTTP 跳转并升级为 HTTPS，避免 Android ERR_CLEARTEXT_NOT_PERMITTED
    initialSettings: InAppWebViewSettings(blockNetworkImage: true, useShouldOverrideUrlLoading: true),
    shouldOverrideUrlLoading: (c, action) async {
      final target = action.request.url;
      if (target == null || action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
      final upgraded = _upgradeMainSiteHttp(target);
      if (upgraded != null) {
        upgradingToHttps = true;
        await c.loadUrl(urlRequest: URLRequest(url: WebUri.uri(upgraded)));
        return NavigationActionPolicy.CANCEL;
      }
      return NavigationActionPolicy.ALLOW;
    },
    onLoadStop: (c, loadedUri) async {
      try {
        if (loadedUri == null || loadedUri.toString() == 'about:blank') return;
        if (upgradingToHttps) {
          if (loadedUri.scheme == 'http') return;
          upgradingToHttps = false;
        }
        final title = await c.getTitle() ?? '';
        if (_isBlockedTitle(title)) {
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        // Cloudflare 的验证页过了会自己跳走；保留完整 20 秒自然放行等待，避免把 5~8 秒内能自动通过的无感挑战提前掐断
        final hasChallengeDom = _isChallengeTitle(title) || await c.evaluateJavascript(source: _challengeDomQuery) == true;
        if (hasChallengeDom) return;
        final html = await c.evaluateJavascript(source: 'document.documentElement.outerHTML');
        if (done.isCompleted) return;
        if (html is String) {
          // 取消旧跳转或首帧空白壳（<html><head></head><body></body></html>）不能当有效页面返回，否则调用方会静默解析出空列表
          if (isEmptyShellHtml(html)) return;
          if (onSession != null) {
            try {
              final origin = _originOf(url, loadedUri);
              final list = await CookieManager.instance().getCookies(url: WebUri(origin));
              final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
              final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
              if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null, origin);
            } catch (_) {}
          }
          if (!done.isCompleted) done.complete(html);
        } else {
          done.completeError(DioException(requestOptions: RequestOptions(path: url), message: 'empty webview html'));
        }
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    },
    onReceivedError: (_, request, error) {
      if (upgradingToHttps && request.url.scheme == 'http') return;
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 10), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    await view.dispose();
  }
}

Future<Uint8List> _loadImage(String url, String? referer, String proxy, Future<void> Function(String cookies, String? userAgent, String origin)? onSession) async {
  await applyWebViewProxy(proxy);
  final done = Completer<Uint8List>();

  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    onLoadStop: (c, loadedUri) async {
      try {
        final title = await c.getTitle() ?? '';
        if (_isBlockedTitle(title)) {
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        if (_isChallengeTitle(title) || await c.evaluateJavascript(source: _challengeDomQuery) == true) return;
        final origin = _originOf(url, loadedUri);
        final res = await c.callAsyncJavaScript(
          functionBody: '''
            const res = await fetch(location.href, { credentials: 'include' });
            if (!res.ok) return { error: 'http:' + res.status };
            const ct = (res.headers.get('content-type') || '').toLowerCase();
            if (ct.includes('text/html')) return { error: 'html:' + (document.title || '') };
            const buf = await res.arrayBuffer();
            const bytes = new Uint8Array(buf);
            if (bytes.length === 0 || (bytes.length > 5 && bytes[0] === 0x3C)) return { error: 'html-body' };
            let bin = '';
            for (let i = 0; i < bytes.length; i += 0x8000) {
              bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            }
            return { b64: btoa(bin) };
          ''',
        );
        if (done.isCompleted) return;
        if (onSession != null) {
          try {
            final list = await CookieManager.instance().getCookies(url: WebUri(origin));
            final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
            final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
            if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null, origin);
          } catch (_) {}
        }
        final map = res?.value is Map ? Map<String, dynamic>.from(res!.value as Map) : null;
        final b64 = map?['b64'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          done.complete(base64Decode(b64));
        } else {
          final err = map?['error'] ?? res?.error ?? 'empty image response';
          done.completeError(DioException(requestOptions: RequestOptions(path: url), message: '$err'));
        }
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 10), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    await view.dispose();
  }
}
