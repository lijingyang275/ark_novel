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
/// 网页是真浏览器，Cloudflare 通常直接放行；cookie 和登录用的网页共用，登录状态自然带上。
/// 一次只开一个网页，其余排队。网页也过不去（一直停在验证页）就照旧抛 [CloudflareChallengeException]，让界面提示去验证。
Future<String> webFetch(String url, {String? referer, String proxy = '', Future<void> Function(String cookies, String? userAgent)? onSession}) =>
    _enqueue(() => _load(url, referer, proxy, onSession));

/// 图片请求被 Cloudflare 拦下时，用不显示的网页过一次盾并取回图片字节；同时通过 [onSession] 把该图床的 `cf_clearance` 和 UA 带回给 Dio 并发下载。
Future<Uint8List> webFetchImage(String url, {String? referer, String proxy = '', Future<void> Function(String cookies, String? userAgent)? onSession}) =>
    _enqueue(() => _loadImage(url, referer, proxy, onSession));

/// WebView 的代理是整个进程共用的，跟着设置走：请求页面和网页的出口才一致，清空设置后也不会留着旧代理（只有 Android 支持）。
Future<void> applyWebViewProxy(String proxy) async {
  if (!Platform.isAndroid) return;
  try {
    final controller = ProxyController.instance();
    if (proxy.isEmpty) {
      await controller.clearProxyOverride();
    } else {
      await controller.setProxyOverride(settings: ProxySettings(proxyRules: [ProxyRule(url: 'http://$proxy')]));
    }
  } catch (_) {}
}

bool _isChallengeTitle(String title) => title.contains('Just a moment') || title.contains('请稍候') || title.contains('Checking your browser');

bool _isBlockedTitle(String title) =>
    title.startsWith('Access denied') || title.contains('Attention Required') || title.contains('已被封锁') || title.contains('have been blocked');

Future<String> _load(String url, String? referer, String proxy, Future<void> Function(String cookies, String? userAgent)? onSession) async {
  await applyWebViewProxy(proxy);
  final done = Completer<String>();
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    // 只要 HTML，不下图片，少发请求
    initialSettings: InAppWebViewSettings(blockNetworkImage: true),
    onLoadStop: (c, _) async {
      try {
        final title = await c.getTitle() ?? '';
        // Cloudflare 的验证页过了会自己跳走，等下一次加载完成
        if (_isChallengeTitle(title)) return;
        if (_isBlockedTitle(title)) {
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        final html = await c.evaluateJavascript(source: 'document.documentElement.outerHTML');
        if (done.isCompleted) return;
        if (html is String) {
          if (onSession != null) {
            try {
              final list = await CookieManager.instance().getCookies(url: WebUri(url));
              final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
              final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
              if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null);
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
      if (request.isForMainFrame != false && !done.isCompleted) done.completeError(DioException(requestOptions: RequestOptions(path: url), message: error.description));
    },
  );
  try {
    await view.run();
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    await view.dispose();
  }
}

Future<Uint8List> _loadImage(String url, String? referer, String proxy, Future<void> Function(String cookies, String? userAgent)? onSession) async {
  await applyWebViewProxy(proxy);
  final done = Completer<Uint8List>();
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: referer == null ? null : {'Referer': referer}),
    onLoadStop: (c, loadedUri) async {
      try {
        final title = await c.getTitle() ?? '';
        if (_isChallengeTitle(title)) return;
        if (_isBlockedTitle(title)) {
          if (!done.isCompleted) done.completeError(Cloudflare403Exception(requestOptions: RequestOptions(path: url)));
          return;
        }
        final hasChallengeDom = await c.evaluateJavascript(source: "!!document.querySelector('#challenge-form, #challenge-running, .cf-turnstile, #cf-challenge-running')");
        if (hasChallengeDom == true) return;
        final targetUri = loadedUri ?? WebUri(url);
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
            final list = await CookieManager.instance().getCookies(url: targetUri);
            final cookies = list.map((e) => '${e.name}=${e.value}').join('; ');
            final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
            if (cookies.isNotEmpty) await onSession(cookies, ua is String ? ua : null);
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
    await view.run();
    return await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw CloudflareChallengeException(requestOptions: RequestOptions(path: url)));
  } finally {
    await view.dispose();
  }
}
