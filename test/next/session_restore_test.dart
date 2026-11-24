import 'dart:async';
import 'dart:io';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/common/wenku8_node.dart';
import 'package:ark_novel/next/session.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _Blocked implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async => ResponseBody.fromBytes(const [], 403);

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tmpDir = Directory.systemTemp.createTempSync('ark_session');
  final tmp = tmpDir.path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp);

  tearDownAll(() async {
    await Hive.close();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const loginPage = '<form action="login.php"><input name="username"><input name="password" type="password"></form>';
  final userPage = File('test/data/wenku8/fixtures/user_info.html').readAsStringSync();

  /// 直连都被 Cloudflare 拦，走网页兜底：[swapCookies] 表示兜底时收下 WebView 的 cookie（和 session.dart 的 onSession 一样）
  Future<(ProviderContainer, SessionStore)> start(String page, {required bool swapCookies, String? cachedUser}) async {
    final store = await SessionStore.open();
    await store.setCookie('jieqiUserInfo=x');
    await store.setUserHtml(cachedUser);
    late ProviderContainer c;
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.net',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()..httpClientAdapter = _Blocked(),
      challengeFallback: (url, {referer}) async {
        if (swapCookies) await c.read(sessionProvider.notifier).acceptWebCookies('cf_clearance=1', login: false);
        return page;
      },
    );
    c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), wenku8ClientProvider.overrideWithValue(client)]);
    addTearDown(c.dispose);
    c.listen(sessionProvider, (_, _) {});
    return (c, store);
  }

  Future<void> settle(ProviderContainer c, bool Function(SessionState) done) async {
    for (var i = 0; i < 100 && !done(c.read(sessionProvider)); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('确认登录途中走网页兜底：拿到用户页后不能停在检查中', () async {
    final (c, _) = await start(userPage, swapCookies: true);
    expect(c.read(sessionProvider), isA<SessionChecking>());
    await settle(c, (s) => s is! SessionChecking);
    expect(c.read(sessionProvider), isA<SessionLoggedIn>());
  });

  test('确认途中换过 cookie 后收到登录页：不可信，保留登录并按离线处理', () async {
    final (c, store) = await start(loginPage, swapCookies: true, cachedUser: userPage);
    await settle(c, (s) => s is SessionLoggedIn && s.offline);
    final s = c.read(sessionProvider);
    expect(s, isA<SessionLoggedIn>());
    expect((s as SessionLoggedIn).offline, true);
    expect(store.cookie, isNotNull);
  });

  test('cookie 没换过时收到登录页：登录确实过期，清除', () async {
    final (c, store) = await start(loginPage, swapCookies: false, cachedUser: userPage);
    await settle(c, (s) => s is SessionLoggedOut);
    expect(c.read(sessionProvider), isA<SessionLoggedOut>());
    expect(store.cookie, isNull);
  });

  test('无感重连（silent: true）：保持离线状态不切到 SessionChecking 闪回启动页', () async {
    final (c, _) = await start(loginPage, swapCookies: true, cachedUser: userPage);
    await settle(c, (s) => s is SessionLoggedIn && s.offline);
    final seen = <SessionState>[];
    c.listen(sessionProvider, (_, next) => seen.add(next));
    final err = await c.read(sessionProvider.notifier).restore(silent: true);
    expect(err, isNotNull);
    expect(seen.any((s) => s is SessionChecking), isFalse);
    expect(c.read(sessionProvider), isA<SessionLoggedIn>());
    expect((c.read(sessionProvider) as SessionLoggedIn).offline, isTrue);
  });

  test('校验登录不带 charset=gbk，且 nginx 403 返回具体 HTTP 错误原因', () async {
    final store = await SessionStore.open();
    await store.setCookie('jieqiUserInfo=x');
    await store.setUserHtml(userPage);
    final requested = <Uri>[];
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.cc',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()
        ..httpClientAdapter = _FnAdapter((o) {
          requested.add(o.uri);
          return ResponseBody.fromBytes(const [], 403, headers: {'server': ['nginx']});
        }),
    );
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), wenku8ClientProvider.overrideWithValue(client)]);
    addTearDown(c.dispose);
    c.listen(sessionProvider, (_, _) {});
    await settle(c, (s) => s is SessionLoggedIn && s.offline);
    expect(requested.first.query, isEmpty);
    final err = await c.read(sessionProvider.notifier).restore(silent: true);
    expect(err, '网站返回 HTTP 403');
  });

  test('acceptWebCookies 按实际 origin 原位覆盖写入，不清空已有登录 cookie', () async {
    final store = await SessionStore.open();
    await store.setCookie('jieqiUserInfo=keepme');
    await store.setUserHtml(userPage);
    await store.setNode(Wenku8Node.wwwWenku8Net);
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.net',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()..httpClientAdapter = _FnAdapter((_) => ResponseBody.fromBytes(const [], 503)),
    );
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), wenku8ClientProvider.overrideWithValue(client)]);
    addTearDown(c.dispose);
    c.listen(sessionProvider, (_, _) {});
    await c.read(sessionProvider.notifier).ready;

    // 传入实际 origin 为 wenku8.cc，即使当前 node 是 wenku8.net，也应写入 wenku8.cc 且不丢失 jieqiUserInfo
    await c.read(sessionProvider.notifier).acceptWebCookies('cf_clearance=fresh_cc', login: false, origin: 'https://www.wenku8.cc/index.php');
    expect(store.cfCookie('https://www.wenku8.cc'), 'cf_clearance=fresh_cc');
    expect(store.cfCookieTimestamp('https://www.wenku8.cc'), isNotNull);
    final ccCookies = await client.exportCookies('https://www.wenku8.cc');
    expect(ccCookies['cf_clearance'], 'fresh_cc');
    expect(ccCookies['jieqiUserInfo'], 'keepme');
    final netCookies = await client.exportCookies('https://www.wenku8.net');
    expect(netCookies['jieqiUserInfo'], 'keepme');
  });

  test('pruneExpiredCfCookies 清理过期 cf_clearance，保留有效记录并为旧版无时间戳记录补打时间戳', () async {
    final store = await SessionStore.open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.setCfCookie('https://fresh.example', 'cf_clearance=good', timestampMs: now - const Duration(hours: 2).inMilliseconds);
    await store.setCfCookie('https://expired.example', 'cf_clearance=old', timestampMs: now - const Duration(hours: 30).inMilliseconds);
    // 模拟旧版本直接写入但无 cf:ts: 的记录
    await Hive.box('session').put('cf:https://legacy.example', 'cf_clearance=legacy');

    final removed = await store.pruneExpiredCfCookies(nowMs: now);
    expect(removed, 1);
    expect(store.cfCookie('https://fresh.example'), 'cf_clearance=good');
    expect(store.cfCookie('https://expired.example'), isNull);
    expect(store.cfCookie('https://legacy.example'), 'cf_clearance=legacy');
    expect(store.cfCookieTimestamp('https://legacy.example'), now);
  });

  test('nativeNetProvider 响应式切换并持久化，imageDioProvider 切换节点不重建且动态读取 Referer', () async {
    final store = await SessionStore.open();
    await store.setNativeNet(true);
    await store.setNode(Wenku8Node.wwwWenku8Net);
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);

    expect(c.read(nativeNetProvider), isTrue);
    await c.read(nativeNetProvider.notifier).set(false);
    expect(c.read(nativeNetProvider), isFalse);
    expect(store.nativeNet, isFalse);

    final dio1 = c.read(imageDioProvider);
    await c.read(nodeProvider.notifier).set(Wenku8Node.wwwWenku8Cc);
    final dio2 = c.read(imageDioProvider);
    expect(identical(dio1, dio2), isTrue);
  });

  test('restore 超时通过 CancelToken 真正中断底层请求，且 markNeedsVerify 正确更新状态', () async {
    final store = await SessionStore.open();
    await store.setCookie('jieqiUserInfo=x');
    await store.setUserHtml(userPage);
    var aborted = false;
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.net',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()
        ..httpClientAdapter = _CancelAwareAdapter((options, cancelFuture) {
          final comp = Completer<ResponseBody>();
          cancelFuture?.then((_) {
            aborted = true;
            if (!comp.isCompleted) comp.completeError(DioException.requestCancelled(requestOptions: options, reason: 'cancelled'));
          });
          return comp.future;
        }),
    );
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), wenku8ClientProvider.overrideWithValue(client)]);
    addTearDown(c.dispose);
    c.listen(sessionProvider, (_, _) {});
    await c.read(sessionProvider.notifier).ready;

    final err = await c.read(sessionProvider.notifier).restore(silent: true, timeout: const Duration(milliseconds: 60));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    expect(err, '连接超时（15 秒）');

    c.read(sessionProvider.notifier).markNeedsVerify();
    final state = c.read(sessionProvider);
    expect(state, isA<SessionLoggedIn>().having((s) => s.needsVerify, 'needsVerify', isTrue));
  });

  test('friendlyError 覆盖 Cronet 与 NSURLSession 常见网络错误文案', () {
    final ro = RequestOptions(path: '/');
    expect(friendlyError(DioException(requestOptions: ro, error: 'NetworkClientException: net::ERR_NAME_NOT_RESOLVED')), contains('无法解析域名'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'net::ERR_CONNECTION_REFUSED')), contains('连接被拒绝'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'net::ERR_CONNECTION_TIMED_OUT')), contains('连接超时'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'net::ERR_INTERNET_DISCONNECTED')), contains('网络已断开'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'net::ERR_SSL_PROTOCOL_ERROR')), contains('TLS'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'net::ERR_PROXY_CONNECTION_FAILED')), contains('代理服务器'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'NSURLErrorDomain Code=-1001 "The request timed out."')), contains('连接超时'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'NSURLErrorCannotFindHost Code=-1003')), contains('无法解析域名'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'NSURLErrorNetworkConnectionLost Code=-1005')), contains('网络连接被中断'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'NSURLErrorNotConnectedToInternet Code=-1009')), contains('网络已断开'));
    expect(friendlyError(DioException(requestOptions: ro, error: 'NSURLErrorSecureConnectionFailed Code=-1200')), contains('TLS'));
  });
}

class _CancelAwareAdapter implements HttpClientAdapter {
  _CancelAwareAdapter(this.fn);

  final Future<ResponseBody> Function(RequestOptions options, Future<void>? cancelFuture) fn;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) => fn(options, cancelFuture);

  @override
  void close({bool force = false}) {}
}

class _FnAdapter implements HttpClientAdapter {
  _FnAdapter(this.fn);

  final ResponseBody Function(RequestOptions) fn;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async => fn(options);

  @override
  void close({bool force = false}) {}
}
