import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/session.dart';

/// 假网络：记下请求的地址，默认返回固定字节，也可按请求定制响应或抛错
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter([this._onFetch]);

  final Future<ResponseBody> Function(RequestOptions options)? _onFetch;
  final urls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    urls.add(options.uri.toString());
    if (_onFetch != null) return _onFetch(options);
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('trimDir 超限时删最旧的，未超限不动', () async {
    final dir = await Directory.systemTemp.createTemp('trim');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      final f = File('${dir.path}/f$i')..writeAsBytesSync(List.filled(100, 0));
      f.setLastModifiedSync(now.subtract(Duration(minutes: 5 - i))); // f0 最旧
    }
    await trimDir(dir, 500);
    expect(dir.listSync().length, 5);

    await trimDir(dir, 400); // 总 500 > 400：删到 ≤320，即只留最新的 3 个
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {'f2', 'f3', 'f4'});
  });

  test('load 下载完能返回（不会自己等自己卡死），封面图床走 http，第二次从缓存拿', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter();
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://img.wenku8.com/image/1/1158/1158s.jpg';
    expect(await store.load(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(net.urls, ['http://img.wenku8.com/image/1/1158/1158s.jpg']);
    expect(await store.load(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(net.urls, hasLength(1));
  });

  test('pic.777743.xyz 下载失败时自动回退到 pic.wenku8.com，并按原地址缓存', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_fallback');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') throw DioException.connectionError(requestOptions: o, reason: 'blocked');
      return ResponseBody.fromBytes([7, 8, 9], 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://pic.777743.xyz/pictures/1/1973/100/1.jpg';
    expect(await store.load(url), [7, 8, 9]);
    expect(net.urls, ['https://pic.777743.xyz/pictures/1/1973/100/1.jpg', 'https://pic.wenku8.com/pictures/1/1973/100/1.jpg']);
    // 第二次直接命中缓存，不再请求网络
    expect(await store.load(url), [7, 8, 9]);
    expect(net.urls, hasLength(2));
  });

  test('pic.777743.xyz 返回 HTML 拦截页时也回退到 pic.wenku8.com；无备用地址的失败不重复请求', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_html');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') return ResponseBody.fromString('<html>blocked</html>', 200);
      if (o.uri.path.contains('fail')) return ResponseBody.fromBytes([], 404);
      return ResponseBody.fromBytes([4, 5, 6], 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/1.jpg'), [4, 5, 6]);
    expect(net.urls, ['https://pic.777743.xyz/pictures/1/1/1.jpg', 'https://pic.wenku8.com/pictures/1/1/1.jpg']);

    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/fail.jpg'), throwsA(isA<Object>()));
    expect(net.urls, hasLength(3));
  });

  test('图床 403 时同域名并发只拉起一次网页过盾，放行后其余图继续走 Dio 下载', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cf_dedup');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    var cleared = false;
    final challengeCalls = <String>[];
    final net = _FakeAdapter((o) async {
      if (!cleared) return ResponseBody.fromBytes(const [], 403);
      return ResponseBody.fromBytes([o.uri.path.endsWith('1.jpg') ? 1 : 2], 200);
    });
    final gate = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls.add(url);
          await gate.future;
          cleared = true;
          return Uint8List.fromList([url.endsWith('1.jpg') ? 1 : 2]);
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    final f1 = store.load('https://pic.wenku8.com/pictures/1/1/1.jpg');
    final f2 = store.load('https://pic.wenku8.com/pictures/1/1/2.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(challengeCalls, hasLength(1));
    gate.complete();

    expect(await f1, [1]);
    expect(await f2, [2]);
    expect(challengeCalls, hasLength(1));
  });

  test('主地址断连且备用域名 403 时，只对备用域名过盾；404 不触发网页过盾', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cf_alt');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final challengeCalls = <String>[];
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') throw DioException.connectionError(requestOptions: o, reason: 'dns fail');
      if (o.uri.path.endsWith('404.jpg')) return ResponseBody.fromBytes(const [], 404);
      return ResponseBody.fromBytes(const [], 403);
    });
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls.add(url);
          return Uint8List.fromList([9, 9]);
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/cover.jpg'), [9, 9]);
    expect(challengeCalls, ['https://pic.wenku8.com/pictures/1/1/cover.jpg']);

    await expectLater(store.load('https://pic.777743.xyz/pictures/1/1/404.jpg'), throwsA(isA<Object>()));
    expect(challengeCalls, hasLength(1));
  });

  test('imageDioProvider 会自动恢复并携带该图床保存的 cf_clearance cookie', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cookie');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final sessionStore = await SessionStore.open();
    await sessionStore.setNativeNet(false);
    await sessionStore.setCfCookie('https://pic.777743.xyz', 'cf_clearance=abc123');

    String? sentCookie;
    final net = _FakeAdapter((o) async {
      sentCookie = o.headers['cookie'] as String?;
      return ResponseBody.fromBytes([5, 5], 200);
    });
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(sessionStore)]);
    addTearDown(c.dispose);
    c.read(imageDioProvider).httpClientAdapter = net;

    expect(await c.read(imageStoreProvider).load('https://pic.777743.xyz/pictures/1/1/1.jpg'), [5, 5]);
    expect(sentCookie, contains('cf_clearance=abc123'));
  });
}
