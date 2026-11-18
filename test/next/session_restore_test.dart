import 'dart:io';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/next/session.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Blocked implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async => ResponseBody.fromBytes(const [], 403);

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tmp = Directory.systemTemp.createTempSync('ark_session').path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp);

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
}

class _FnAdapter implements HttpClientAdapter {
  _FnAdapter(this.fn);

  final ResponseBody Function(RequestOptions) fn;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async => fn(options);

  @override
  void close({bool force = false}) {}
}
