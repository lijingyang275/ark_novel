import 'dart:io';
import 'dart:typed_data';

import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/main.dart' show configureAppImageCache, enterCompactImageCache, exitCompactImageCache;
import 'package:ark_novel/next/reader/reader_page.dart' show applyReaderWarmColor, combineReaderColorMatrix, trimReaderChapterCache;
import 'package:ark_novel/next/volume_covers.dart';
import 'package:ark_novel/next/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test('enterCompactImageCache 与 exitCompactImageCache 支持引用计数嵌套切换', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    configureAppImageCache(compact: false);
    final normalBytes = PaintingBinding.instance.imageCache.maximumSizeBytes;
    final normalCount = PaintingBinding.instance.imageCache.maximumSize;

    enterCompactImageCache();
    final compactBytes = PaintingBinding.instance.imageCache.maximumSizeBytes;
    final compactCount = PaintingBinding.instance.imageCache.maximumSize;
    expect(compactBytes, lessThan(normalBytes));
    expect(compactCount, lessThan(normalCount));

    // 二次进入（如阅读中退到后台）保持紧凑上限
    enterCompactImageCache();
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes, compactBytes);

    // 退出一层（如回前台但仍在阅读页）仍保持紧凑上限
    exitCompactImageCache();
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes, compactBytes);

    // 全部退出后恢复常规上限
    exitCompactImageCache();
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes, normalBytes);
    expect(PaintingBinding.instance.imageCache.maximumSize, normalCount);
  });

  test('applyReaderWarmColor 与 combineReaderColorMatrix 纯暖色变换数值一致', () {
    const samples = [
      Color(0xFFF6F1E7),
      Color(0xFF2B2A27),
      Color(0xFF1C1C1A),
      Color(0xFFA8452F),
    ];
    for (final warm in const [0.0, 0.15, 0.3, 0.5]) {
      final matrix = combineReaderColorMatrix(warm: warm, grayscale: false, invert: false);
      for (final c in samples) {
        final direct = applyReaderWarmColor(c, warm);
        if (matrix == null) {
          expect(direct, c);
          continue;
        }
        int ch(double v) => (v * 255.0).round().clamp(0, 255);
        final r0 = ch(c.r), g0 = ch(c.g), b0 = ch(c.b);
        final mr = (matrix[0] * r0 + matrix[1] * g0 + matrix[2] * b0 + matrix[4]).round().clamp(0, 255);
        final mg = (matrix[5] * r0 + matrix[6] * g0 + matrix[7] * b0 + matrix[9]).round().clamp(0, 255);
        final mb = (matrix[10] * r0 + matrix[11] * g0 + matrix[12] * b0 + matrix[14]).round().clamp(0, 255);
        expect((ch(direct.r) - mr).abs(), lessThanOrEqualTo(1));
        expect((ch(direct.g) - mg).abs(), lessThanOrEqualTo(1));
        expect((ch(direct.b) - mb).abs(), lessThanOrEqualTo(1));
      }
    }
  });

  test('ImageStore.enterReaderMode / exitReaderMode 与后台队列暂停引用计数配对工作', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('ark_mem_opt_test_');
    Hive.init(dir.path);
    await Hive.openBox('session');
    final container = ProviderContainer();
    addTearDown(() async {
      LibraryController.resetBackgroundPause();
      container.dispose();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final store = container.read(imageStoreProvider);
    expect(store.isSrPaused, isFalse);
    store.enterReaderMode();
    expect(store.isSrPaused, isTrue);
    store.enterReaderMode();
    store.exitReaderMode();
    expect(store.isSrPaused, isTrue);
    store.exitReaderMode();
    expect(store.isSrPaused, isFalse);

    final queue = container.read(volumeCoverQueueProvider);
    expect(queue.isBackgroundPaused, isFalse);
    queue.pauseBackground();
    LibraryController.pauseBackground();
    expect(queue.isBackgroundPaused, isTrue);
    expect(LibraryController.isBackgroundPaused, isTrue);

    queue.resumeBackground();
    LibraryController.resumeBackground();
    expect(queue.isBackgroundPaused, isFalse);
    expect(LibraryController.isBackgroundPaused, isFalse);

    trimReaderChapterCache(clearAll: true);
  });

  testWidgets('NetImage 使用轻量键缓存，不将原始 Uint8List 作为 ImageCache 键实例保存', (t) async {
    final png1x1 = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
    final store = _FakeStore(png1x1);
    await t.pumpWidget(
      ProviderScope(
        overrides: [imageStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(
          home: SizedBox(width: 100, height: 100, child: NetImage('https://example.com/1.png', decodeSize: Size(100, 100))),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final imgWidget = t.widget<Image>(find.byType(Image));
    final key = await imgWidget.image.obtainKey(ImageConfiguration.empty);
    expect(identical(key, imgWidget.image), isFalse);
  });

  testWidgets('CoverImage 在 TickerMode(false) 后台分支/被遮挡路由下自动卸下 Image 监听，恢复可见后即时重挂', (t) async {
    final png1x1 = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
    final store = _FakeStore(png1x1);
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);

    await t.pumpWidget(
      ProviderScope(
        overrides: [imageStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, enabled, _) => TickerMode(
              enabled: enabled,
              child: const SizedBox(
                width: 120,
                height: 160,
                child: CoverImage('https://example.com/cover.png', decodeSize: Size(120, 160)),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.byType(Image), findsOneWidget);

    // 切入后台路由/分支后卸下 Image，释放 _liveImages 纹理钉住
    active.value = false;
    await t.pump();
    expect(find.byType(Image, skipOffstage: false), findsNothing);

    // 返回前台首帧立即同步重挂 Image
    active.value = true;
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
  });
}

class _FakeStore implements ImageStore {
  _FakeStore(this._bytes);
  final Uint8List _bytes;

  @override
  final srVersion = ValueNotifier<int>(0);

  @override
  Uint8List? peek(String rawUrl) => _bytes;

  @override
  Future<Uint8List> load(String rawUrl) async => _bytes;

  @override
  void cancel(String rawUrl) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
