import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/session.dart';

/// 构造带合法 JPEG 魔数的短字节，用于单测区分不同响应。
List<int> _jpeg(int tag) => [0xFF, 0xD8, 0xFF, 0xE0, tag];

/// 用 dart:ui 生成真实 PNG（左半红、右半蓝），用于验证缩略图烘焙裁剪与尺寸缩放。
Future<Uint8List> _makeTwoTonePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width / 2, height.toDouble()), ui.Paint()..color = const ui.Color(0xFFFF0000));
  canvas.drawRect(ui.Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()), ui.Paint()..color = const ui.Color(0xFF0000FF));
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 假网络：记下请求的地址，默认返回合法 JPEG 字节，也可按请求定制响应、取消感知或抛错
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter([this._onFetch, this._onFetchWithCancel]);

  final Future<ResponseBody> Function(RequestOptions options)? _onFetch;
  final Future<ResponseBody> Function(RequestOptions options, Future<void>? cancelFuture)? _onFetchWithCancel;
  final urls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    urls.add(options.uri.toString());
    if (_onFetchWithCancel != null) return _onFetchWithCancel(options, cancelFuture);
    if (_onFetch != null) return _onFetch(options);
    return ResponseBody.fromBytes(_jpeg(1), 200);
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
    expect(await store.load(url).timeout(const Duration(seconds: 2)), _jpeg(1));
    expect(net.urls, ['http://img.wenku8.com/image/1/1158/1158s.jpg']);
    expect(await store.load(url).timeout(const Duration(seconds: 2)), _jpeg(1));
    expect(net.urls, hasLength(1));
  });

  test('pic.777743.xyz 下载失败时自动回退到 pic.wenku8.com，并按原地址缓存', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_fallback');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') throw DioException.connectionError(requestOptions: o, reason: 'blocked');
      return ResponseBody.fromBytes(_jpeg(7), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const url = 'https://pic.777743.xyz/pictures/1/1973/100/1.jpg';
    expect(await store.load(url), _jpeg(7));
    expect(net.urls, ['https://pic.777743.xyz/pictures/1/1973/100/1.jpg', 'https://pic.wenku8.com/pictures/1/1973/100/1.jpg']);
    // 第二次直接命中缓存，不再请求网络
    expect(await store.load(url), _jpeg(7));
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
      return ResponseBody.fromBytes(_jpeg(4), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/1.jpg'), _jpeg(4));
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
      return ResponseBody.fromBytes(_jpeg(o.uri.path.endsWith('1.jpg') ? 1 : 2), 200);
    });
    final gate = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls.add(url);
          await gate.future;
          cleared = true;
          return Uint8List.fromList(_jpeg(url.endsWith('1.jpg') ? 1 : 2));
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

    expect(await f1, _jpeg(1));
    expect(await f2, _jpeg(2));
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
          return Uint8List.fromList(_jpeg(9));
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/cover.jpg'), _jpeg(9));
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
    addTearDown(Hive.close);
    await sessionStore.setNativeNet(false);
    await sessionStore.setCfCookie('https://pic.777743.xyz', 'cf_clearance=abc123');

    String? sentCookie;
    final net = _FakeAdapter((o) async {
      sentCookie = o.headers['cookie'] as String?;
      return ResponseBody.fromBytes(_jpeg(5), 200);
    });
    final c = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(sessionStore)]);
    addTearDown(c.dispose);
    c.read(imageDioProvider).httpClientAdapter = net;

    expect(await c.read(imageStoreProvider).load('https://pic.777743.xyz/pictures/1/1/1.jpg'), _jpeg(5));
    expect(sentCookie, contains('cf_clearance=abc123'));
  });

  test('非图片魔数响应拒绝落盘并回退备用图床；无备用地址时报错且不污染缓存', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_magic');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final net = _FakeAdapter((o) async {
      if (o.uri.host == 'pic.777743.xyz') return ResponseBody.fromString('{"error":"rate limited"}', 200);
      if (o.uri.path.contains('bad')) return ResponseBody.fromString('plain error body', 200);
      return ResponseBody.fromBytes(_jpeg(8), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    expect(await store.load('https://pic.777743.xyz/pictures/1/1/ok.jpg'), _jpeg(8));
    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/bad.jpg'), throwsA(isA<StateError>()));
    expect(await store.cached('https://pic.wenku8.com/pictures/1/1/bad.jpg'), isNull);
  });

  test('图床 challenge 失败后进入冷却窗口，冷却期内同域名不重复拉起过盾', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cooldown');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    var challengeCalls = 0;
    final net = _FakeAdapter((o) async => ResponseBody.fromBytes(const [], 403));
    final c = ProviderContainer(
      overrides: [
        imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net),
        imageChallengeProvider.overrideWithValue((url) async {
          challengeCalls++;
          throw CloudflareChallengeException(requestOptions: RequestOptions(path: url));
        }),
      ],
    );
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/a.jpg'), throwsA(isA<CloudflareChallengeException>()));
    await expectLater(store.load('https://pic.wenku8.com/pictures/1/1/b.jpg'), throwsA(isA<CloudflareChallengeException>()));
    expect(challengeCalls, 1);
  });

  test('cancelPrefetch 取消尚未开始的低优预取，且可见图加载优先于预取队列', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_priority');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final gates = <String, Completer<void>>{};
    final started = <String>[];
    final net = _FakeAdapter((o) async {
      final name = o.uri.pathSegments.last;
      started.add(name);
      final gate = gates[name];
      if (gate != null) await gate.future;
      return ResponseBody.fromBytes(_jpeg(started.length), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    // 先占满全部网络槽位（ImageStore.maxNet == 6），再排 2 个低优预取与 1 个高优可见加载
    const slots = ImageStore.maxNet;
    for (var i = 1; i <= slots; i++) {
      gates['slot$i.jpg'] = Completer<void>();
    }
    final slotFutures = [for (var i = 1; i <= slots; i++) store.load('https://img.example/slot$i.jpg')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, hasLength(slots));

    store.prefetch(['https://img.example/pre1.jpg', 'https://img.example/pre2.jpg']);
    final visibleFuture = store.load('https://img.example/visible.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 取消未开始的预取，仅保留 visible.jpg
    store.cancelPrefetch(['https://img.example/pre1.jpg', 'https://img.example/pre2.jpg']);
    for (final g in gates.values) {
      g.complete();
    }
    await Future.wait([...slotFutures, visibleFuture]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(started, contains('visible.jpg'));
    expect(started, isNot(contains('pre1.jpg')));
    expect(started, isNot(contains('pre2.jpg')));
  });

  test('缩略图缓存键规范化、烘焙裁剪落盘、独立内存 LRU、预热与 remove/trim/clearDisk 同步清理', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_thumb');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    await Hive.close();
    Hive.init(dir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
    addTearDown(Hive.close);

    final twoTone = await _makeTwoTonePng(800, 600);
    final net = _FakeAdapter((o) async => ResponseBody.fromBytes(twoTone, 200));
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    const base = 'https://pic.example/cover.png';
    final cropRight = withCrop(base, const ui.Rect.fromLTWH(0.5, 0, 0.5, 1));
    final trimRight = withCrop('http://pic.example/cover.png', const ui.Rect.fromLTWH(0.5, 0, 0.5, 1), auto: true);
    final cropLeft = withCrop(base, const ui.Rect.fromLTWH(0, 0, 0.5, 1));

    // 1. 缓存键：http/https 规范化、#crop 与 #trim 统一、不同裁剪框与 #sr 区分开
    expect(store.thumbKey(cropRight), equals(store.thumbKey(trimRight)));
    expect(store.thumbKey(cropRight), isNot(equals(store.thumbKey(cropLeft))));
    expect(store.thumbKey(cropRight, sr: true), isNot(equals(store.thumbKey(cropRight, sr: false))));

    // 2. 首次生成缩略图并烘焙右半裁剪框：宽 <= 360 且像素为纯蓝（右半边）
    expect(store.peekThumb(cropRight), isNull);
    final thumbBytes = await store.loadThumb(cropRight);
    expect(store.wasLoadedFromNetwork(cropRight), isTrue);
    expect(store.isThumbBaked(cropRight), isTrue);
    expect(store.peekThumb(cropRight), isNotNull);

    final sz = await imageSize(thumbBytes);
    expect(sz.width, lessThanOrEqualTo(360));
    expect(sz.width / sz.height, closeTo(400 / 600, 0.05));
    // 验证像素颜色确实来自右半边（蓝色 B > R）
    final codec = await ui.instantiateImageCodec(thumbBytes);
    final frame = await codec.getNextFrame();
    final rgba = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    frame.image.dispose();
    codec.dispose();
    expect(rgba[2], greaterThan(200)); // B
    expect(rgba[0], lessThan(30)); // R

    final thumbDir = Directory('${dir.path}/imgthumb');
    expect(thumbDir.existsSync(), isTrue);
    expect(thumbDir.listSync().whereType<File>().length, 1);
    expect(await store.diskBytes(), greaterThan(thumbBytes.length));

    // 3. 新建 ImageStore 从磁盘秒命中缩略图：不走网络、wasLoadedFromNetwork 为 false，且 warm(thumbnail: true) 可预热入内存
    final c2 = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c2.dispose);
    final store2 = c2.read(imageStoreProvider);
    final netCallsBefore = net.urls.length;
    await store2.warm([cropRight], thumbnail: true);
    expect(store2.peekThumb(cropRight), isNotNull);
    expect(net.urls.length, netCallsBefore);

    final c3 = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c3.dispose);
    final store3 = c3.read(imageStoreProvider);
    await store3.loadThumb(cropRight);
    expect(store3.wasLoadedFromNetwork(cropRight), isFalse);
    expect(net.urls.length, netCallsBefore);

    // 4. trim 保留书架封面缩略图、清理未保留缩略图
    const extraUrl = 'https://pic.example/extra.png';
    await store.loadThumb(extraUrl);
    await Hive.box('session').put('lib:books', {
      '1': {'aid': '1', 'title': '保留书', 'img': base},
    });
    expect(thumbDir.listSync().whereType<File>().length, 2);
    await store.trim(maxBytes: 1 << 30, maxThumbBytes: 1);
    expect(thumbDir.listSync().whereType<File>().length, 1);

    // 5. remove 同步清理内存与 imgthumb 磁盘文件
    await store.remove([base]);
    expect(store.peekThumb(cropRight), isNull);
    expect(thumbDir.listSync().whereType<File>(), isEmpty);

    // 6. clearDisk 同步清空 imgthumb
    await store.loadThumb(extraUrl);
    expect(thumbDir.existsSync(), isTrue);
    await store.clearDisk();
    expect(store.peekThumb(extraUrl), isNull);
    expect(thumbDir.existsSync(), isFalse);
  });

  test('网络调度：高优队列 LIFO 优先唤醒最新视口图，低优队列保持 FIFO', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_lifo');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final gates = <String, Completer<void>>{};
    final started = <String>[];
    final net = _FakeAdapter((o) async {
      final name = o.uri.pathSegments.last;
      started.add(name);
      final gate = gates[name];
      if (gate != null) await gate.future;
      return ResponseBody.fromBytes(_jpeg(started.length), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    for (var i = 1; i <= ImageStore.maxNet; i++) {
      gates['s$i.jpg'] = Completer<void>();
    }
    final slotFutures = [for (var i = 1; i <= ImageStore.maxNet; i++) store.load('https://img.example/s$i.jpg')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    started.clear();

    // 高优按 h1 → h2 → h3 入队，低优按 l1 → l2 入队
    final h1 = store.load('https://img.example/h1.jpg');
    final h2 = store.load('https://img.example/h2.jpg');
    final h3 = store.load('https://img.example/h3.jpg');
    final l1 = store.loadWithPriority('https://img.example/l1.jpg', lowPriority: true);
    final l2 = store.loadWithPriority('https://img.example/l2.jpg', lowPriority: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 逐个释放槽位，验证高优按 LIFO（h3, h2, h1）唤醒，随后低优按 FIFO（l1, l2）唤醒
    for (var i = 1; i <= 5; i++) {
      gates['s$i.jpg']!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    gates['s6.jpg']!.complete();
    await Future.wait([...slotFutures, h1, h2, h3, l1, l2]);

    expect(started, ['h3.jpg', 'h2.jpg', 'h1.jpg', 'l1.jpg', 'l2.jpg']);
  });

  test('CancelToken 取消与共享订阅计数：多订阅者未全部取消前不误杀，全取消后立即中止请求并释放槽位', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('imgstore_cancel_token');
    addTearDown(() => dir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);

    final cancelledUrls = <String>[];
    final gates = <String, Completer<void>>{};
    final started = <String>[];
    final net = _FakeAdapter(null, (o, cancelFuture) async {
      final name = o.uri.pathSegments.last;
      started.add(name);
      final gate = gates[name];
      if (gate != null) {
        var wasCancelled = false;
        cancelFuture?.then((_) {
          wasCancelled = true;
          cancelledUrls.add(name);
          if (!gate.isCompleted) gate.complete();
        });
        await gate.future;
        if (wasCancelled) throw DioException.requestCancelled(requestOptions: o, reason: 'cancelled');
      }
      return ResponseBody.fromBytes(_jpeg(1), 200);
    });
    final c = ProviderContainer(overrides: [imageDioProvider.overrideWithValue(Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = net)]);
    addTearDown(c.dispose);
    final store = c.read(imageStoreProvider);

    // 1. 两个订阅者共享同一规范 URL（一个带裁剪框、一个不带）：第一个取消不中止，第二个取消才中止 CancelToken
    gates['shared.jpg'] = Completer<void>();
    final fA = store.load('https://img.example/shared.jpg');
    final fB = store.load('https://img.example/shared.jpg#crop=0,0,0.5,1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, ['shared.jpg']);

    store.cancel('https://img.example/shared.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cancelledUrls, isEmpty);

    final expectA = expectLater(fA, throwsA(isA<ImageCancelled>()));
    final expectB = expectLater(fB, throwsA(isA<ImageCancelled>()));
    store.cancel('https://img.example/shared.jpg#crop=0,0,0.5,1');
    await Future.wait([expectA, expectB]);
    expect(cancelledUrls, ['shared.jpg']);

    // 2. 占满 6 个槽位时取消 1 个在途请求，应立即释放槽位让排队中的 waiter 开始下载
    started.clear();
    cancelledUrls.clear();
    for (var i = 1; i <= ImageStore.maxNet; i++) {
      gates['b$i.jpg'] = Completer<void>();
    }
    final blockers = [for (var i = 1; i <= ImageStore.maxNet; i++) store.load('https://img.example/b$i.jpg')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final waiter = store.load('https://img.example/waiter.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, isNot(contains('waiter.jpg')));

    final expectB1Cancelled = expectLater(blockers.first, throwsA(isA<ImageCancelled>()));
    store.cancel('https://img.example/b1.jpg');
    await expectB1Cancelled;
    expect(await waiter, _jpeg(1));
    expect(started, contains('waiter.jpg'));
    expect(cancelledUrls, ['b1.jpg']);

    // 清理剩余阻塞请求
    for (var i = 2; i <= ImageStore.maxNet; i++) {
      gates['b$i.jpg']!.complete();
    }
    await Future.wait(blockers.skip(1));
  });
}
