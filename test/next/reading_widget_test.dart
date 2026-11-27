import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ark_novel/next/history.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/reading_widget.dart';
import 'package:ark_novel/next/routes.dart';
import 'package:ark_novel/next/theme.dart';
import 'package:ark_novel/next/volume_covers.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _FakeCoverQueue implements VolumeCoverQueue {
  _FakeCoverQueue(this._covers);

  final Map<String, String> _covers;

  @override
  String bookCover(String aid, String fallback) => _covers[aid] ?? fallback;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageStore implements ImageStore {
  _FakeImageStore(this._paths);

  final Map<String, String> _paths;

  @override
  Future<String> path(String rawUrl) async => _paths[rawUrl] ?? '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ark/widget');
  const codec = StandardMethodCodec();

  tearDown(() {
    ReadingWidget.supportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('点桌面小组件打开的链接对应到 App 里的页面', () {
    expect(ReadingWidget.route(Uri.parse('ark://reader/123/456')), Routes.reader('123', '456'));
    expect(ReadingWidget.route(Uri.parse('ark://updates')), Routes.updates);
    expect(ReadingWidget.route(Uri.parse('ark://shelf')), Routes.bookshelf);
    expect(ReadingWidget.route(Uri.parse('ark://reader/123')), isNull);
    expect(ReadingWidget.route(Uri.parse('https://shelf')), isNull);
    expect(ReadingWidget.route(null), isNull);
  });

  test('initialUri 按平台支持状态与原生返回值解析', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return 'ark://reader/12/34';
    });

    ReadingWidget.supportedOverride = false;
    expect(await ReadingWidget.initialUri(), isNull);
    expect(calls, isEmpty);

    ReadingWidget.supportedOverride = true;
    expect(await ReadingWidget.initialUri(), Uri.parse('ark://reader/12/34'));
    expect(calls, ['getInitialUri']);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => '');
    expect(await ReadingWidget.initialUri(), isNull);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'ERR'));
    expect(await ReadingWidget.initialUri(), isNull);
  });

  test('clicked 流接收原生 onWidgetClick 并在全部取消订阅后注销处理器', () async {
    ReadingWidget.supportedOverride = false;
    expect(await ReadingWidget.clicked.isEmpty, isTrue);

    ReadingWidget.supportedOverride = true;
    final received = <Uri>[];
    final sub = ReadingWidget.clicked.listen(received.add);

    Future<ByteData?> sendFromNative(String method, Object? args) {
      final completer = Completer<ByteData?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, args)),
        completer.complete,
      );
      return completer.future;
    }

    final r1 = await sendFromNative('onWidgetClick', 'ark://shelf');
    final r2 = await sendFromNative('onWidgetClick', '');
    final r3 = await sendFromNative('onWidgetClick', 'ark://reader/7/8');
    await Future<void>.delayed(Duration.zero);

    expect(r1, isNotNull);
    expect(r2, isNotNull);
    expect(r3, isNotNull);
    expect(received, [Uri.parse('ark://shelf'), Uri.parse('ark://reader/7/8')]);

    // 取消最后一个监听后应注销 handler，原生再发消息会收到 null（notImplemented）从而走 getInitialUri 兜底
    await sub.cancel();
    final afterCancel = await sendFromNative('onWidgetClick', 'ark://updates');
    expect(afterCancel, isNull);
  });

  test('push 批量调用 saveAll 并随后触发 updateWidget', () async {
    final tmp = Directory.systemTemp.createTempSync('ark_widget_test');
    addTearDown(() async {
      if (Hive.isBoxOpen('session')) await Hive.box('session').close();
      await Hive.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    Hive.init(tmp.path);
    await Hive.openBox('session');

    for (var i = 1; i <= 5; i++) {
      await ReadingHistory.record('$i', '书$i', 'https://example.com/$i.jpg', 'c$i', '第$i章');
    }

    final recorded = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      recorded.add(call);
      return null;
    });

    final covers = _FakeCoverQueue({'5': 'https://example.com/5.jpg#crop=0.1,0.2,0.6,0.7'});
    final images = _FakeImageStore({
      'https://example.com/5.jpg': '/cache/5.jpg',
      'https://example.com/4.jpg': '/cache/4.jpg',
      'https://example.com/3.jpg': '/cache/3.jpg',
      'https://example.com/2.jpg': '/cache/2.jpg',
    });
    final plainPalette = appPalettes.firstWhere((p) => p.art == null);

    ReadingWidget.supportedOverride = true;
    await ReadingWidget.push(covers, images, plainPalette, ThemeMode.dark);

    expect(recorded.map((c) => c.method).toList(), ['saveAll', 'updateWidget']);
    final payload = Map<String, Object?>.from(recorded.first.arguments as Map);
    expect(payload['mode'], 'dark');
    expect(payload['icon'], isNull);
    expect(payload['bgLight'], startsWith('#'));
    expect(payload['bgDark'], startsWith('#'));
    expect(payload['accentLight'], startsWith('#'));
    expect(payload['accentDark'], startsWith('#'));
    expect(payload['subLight'], startsWith('#'));
    expect(payload['subDark'], startsWith('#'));

    final books = (jsonDecode(payload['books']! as String) as List).cast<Map<String, dynamic>>();
    expect(books, hasLength(4));
    expect(books.first['aid'], '5');
    expect(books.first['cid'], 'c5');
    expect(books.first['cover'], '/cache/5.jpg');
    expect(books.first['crop'], [0.1, 0.2, 0.6, 0.7]);
    expect(books[1].containsKey('crop'), isFalse);
  });
}
