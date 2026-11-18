import 'dart:async';
import 'dart:typed_data';

import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/reader/reader_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubImageStore implements ImageStore {
  static final png1x1 = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  int calls = 0;
  Future<Uint8List> Function()? handler;

  @override
  final srVersion = ValueNotifier<int>(0);

  @override
  Uint8List? peek(String rawUrl) => null;

  @override
  Future<Uint8List> load(String rawUrl) {
    calls++;
    return handler!();
  }

  @override
  void cancel(String rawUrl) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const style = TextStyle(fontSize: 18, height: 1.8, color: Colors.black);
  const chapter = Chapter(text: '', images: ['https://pic.wenku8.com/test/1.jpg'], marks: []);

  testWidgets('滚动阅读页：插图加载中显示占位，失败显示点击重试且点重试不触发菜单', (t) async {
    final store = _StubImageStore();
    var pending = Completer<Uint8List>();
    store.handler = () => pending.future;
    var tappedMenu = 0;

    await t.pumpWidget(
      ProviderScope(
        overrides: [imageStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Scaffold(
            body: ScrollBody(
              chapter: chapter,
              spanOf: (a, b) => const TextSpan(text: ''),
              style: style,
              margin: 16,
              startOffset: 0,
              onOffset: (_) {},
              onEnd: () {},
              onNext: null,
              wrap: (w) => w,
              onTapZone: () => tappedMenu++,
              onMark: (_) {},
              hasSelection: () => false,
            ),
          ),
        ),
      ),
    );
    await t.pump();

    expect(find.text('图片加载中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.completeError(Exception('403'));
    await t.pumpAndSettle();

    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
    expect(store.calls, 1);

    pending = Completer<Uint8List>();
    await t.tap(find.text('图片加载失败，点击重试'));
    await t.pump();

    expect(tappedMenu, 0);
    expect(store.calls, 2);
    expect(find.text('图片加载中…'), findsOneWidget);

    pending.complete(_StubImageStore.png1x1);
    await t.pumpAndSettle();

    expect(find.text('图片加载失败，点击重试'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('翻页阅读页：插图失败显示点击重试，点击重试重新加载而不翻页或开菜单', (t) async {
    final store = _StubImageStore()..handler = () => Future.error(Exception('403'));
    var tappedMenu = 0;

    await t.pumpWidget(
      ProviderScope(
        overrides: [imageStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Scaffold(
            body: PagedBody(
              chapter: chapter,
              spanOf: (a, b) => const TextSpan(text: ''),
              style: style,
              margin: 16,
              title: '插图',
              curl: false,
              background: Colors.white,
              color: Colors.black,
              startOffset: 0,
              onOffset: (_) {},
              onEnd: () {},
              onPrev: null,
              onNext: null,
              wrap: (w) => w,
              onTapZone: () => tappedMenu++,
              onMark: (_) {},
              hasSelection: () => false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
    expect(store.calls, greaterThanOrEqualTo(1));
    final beforeCalls = store.calls;

    store.handler = () async => _StubImageStore.png1x1;
    await t.tap(find.text('图片加载失败，点击重试'));
    await t.pumpAndSettle();

    expect(tappedMenu, 0);
    expect(store.calls, greaterThan(beforeCalls));
    expect(find.text('图片加载失败，点击重试'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });
}
