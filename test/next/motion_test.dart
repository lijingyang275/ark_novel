import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ark_novel/models/novel_cover.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart' show PageResult;
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/motion.dart';
import 'package:ark_novel/next/pages/rules_page.dart';
import 'package:ark_novel/next/pages/settings_page.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/pages/sync_page.dart';
import 'package:ark_novel/next/reader/reader_body.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/swipe.dart';
import 'package:ark_novel/next/theme.dart';
import 'package:ark_novel/next/widgets.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/cupertino.dart' show CupertinoPageTransition;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

Widget _app(Widget child, {bool disableAnimations = false, Brightness brightness = Brightness.light}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, w) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: w!,
  ),
  home: child,
);

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}

void main() {
  late Directory dir;
  late SessionStore store;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = Directory.systemTemp.createTempSync('ark_motion_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    store = await SessionStore.open();
    await ChapterCache.open();
    final now = DateTime.now();
    final box = Hive.box('session');
    await box.put('stats:day', {
      for (var i = 0; i < 60; i++) ReadingStats.dayKey(now.subtract(Duration(days: i))): (i % 7 + 1) * 900,
    });
    await box.put('stats:book', {'1001': 36000, '1002': 18000});
    await box.put('stats:meta', {
      '1001': {'t': '测试轻小说一', 'a': '作者甲', 'i': ''},
      '1002': {'t': '测试轻小说二', 'a': '作者乙', 'i': ''},
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('AppMotion 基础节奏与减少动态效果', () {
    test('smoothSpring 临界阻尼归零无负向过冲', () {
      final sim = SpringSimulation(AppMotion.smoothSpring, 120, 0, 0, tolerance: AppMotion.pixelTolerance);
      var minVal = double.infinity;
      for (var ms = 0; ms <= 800; ms += 8) {
        final x = sim.x(ms / 1000.0);
        if (x < minVal) minVal = x;
      }
      expect(minVal, greaterThanOrEqualTo(-0.01));
      expect(sim.isDone(0.8), isTrue);
    });

    testWidgets('AppMotion.reduce 与 dur 正确响应 disableAnimations', (tester) async {
      bool? reduced;
      Duration? dur;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) {
              reduced = AppMotion.reduce(ctx);
              dur = AppMotion.dur(ctx, AppMotion.standard);
              return const SizedBox.shrink();
            },
          ),
          disableAnimations: false,
        ),
      );
      expect(reduced, isFalse);
      expect(dur, AppMotion.standard);

      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) {
              reduced = AppMotion.reduce(ctx);
              dur = AppMotion.dur(ctx, AppMotion.standard);
              return const SizedBox.shrink();
            },
          ),
          disableAnimations: true,
        ),
      );
      expect(reduced, isTrue);
      expect(dur, Duration.zero);
    });
  });

  group('AppPressScale 按压、悬停与不拦截滚动', () {
    testWidgets('按下微缩、抬起回弹，右键不下压，减少动态效果零包装', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: AppPressScale(
                scale: 0.92,
                hoverScale: 1.03,
                child: GestureDetector(
                  onTap: () => taps++,
                  child: const SizedBox(width: 120, height: 48, child: Center(child: Text('按钮'))),
                ),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.text('按钮'));
      final g = await tester.startGesture(center);
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 0.92);

      await g.up();
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
      expect(taps, 1);

      // 右键按下不应触发下压微缩（仅鼠标悬停为 1.03，绝不会下压成 0.92）
      final rightClick = await tester.startGesture(center, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, isNot(0.92));
      await rightClick.up();
      await rightClick.removePointer();
      await tester.pump();

      // 鼠标悬停轻浮起，移出恢复
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(center);
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.03);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
      await mouse.removePointer();

      // 减少动态效果时跳过 AnimatedScale 包装
      await tester.pumpWidget(
        _app(
          const Scaffold(body: Center(child: AppPressScale(child: Text('静态')))),
          disableAnimations: true,
        ),
      );
      expect(find.byType(AnimatedScale), findsNothing);
    });

    testWidgets('拖动超过 8px 自动取消下压态且不拦截列表滚动', (tester) async {
      final sc = ScrollController();
      addTearDown(sc.dispose);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: ListView.builder(
              controller: sc,
              itemCount: 40,
              itemBuilder: (_, i) => AppPressScale(
                scale: 0.94,
                child: ListTile(title: Text('项目 $i')),
              ),
            ),
          ),
        ),
      );

      final start = tester.getCenter(find.text('项目 2'));
      final g = await tester.startGesture(start);
      await tester.pump();
      expect(
        tester.widgetList<AnimatedScale>(find.byType(AnimatedScale)).any((w) => w.scale == 0.94),
        isTrue,
      );

      await g.moveBy(const Offset(0, -120));
      await tester.pump();
      // 超过 8px 滑动后下压态取消，且列表确实滚了起来
      expect(
        tester.widgetList<AnimatedScale>(find.byType(AnimatedScale)).every((w) => w.scale == 1.0),
        isTrue,
      );
      expect(sc.offset, greaterThan(40));
      await g.up();
      await tester.pumpAndSettle();
    });
  });

  group('AppCollapse 与 AppReveal 可打断显现和卸载', () {
    testWidgets('AppCollapse 展开/收起中途反复打断不卡死，收起后卸载子节点', (tester) async {
      var visible = false;
      late StateSetter setLocal;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setLocal = setState;
                return Column(
                  children: [
                    AppCollapse(
                      visible: visible,
                      child: const SizedBox(height: 80, width: double.infinity, child: Text('折叠内容')),
                    ),
                    const Text('下方内容'),
                  ],
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('折叠内容'), findsNothing);

      // 展开到一半打断为收起，再打断回展开
      setLocal(() => visible = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('折叠内容'), findsOneWidget);
      final midHeight = tester.getSize(find.byType(AppCollapse)).height;
      expect(midHeight, greaterThan(0));
      expect(midHeight, lessThan(80));

      setLocal(() => visible = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      setLocal(() => visible = true);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AppCollapse)).height, closeTo(80, 0.5));

      // 彻底收起后子节点卸载
      setLocal(() => visible = false);
      await tester.pumpAndSettle();
      expect(find.text('折叠内容'), findsNothing);
      expect(tester.getSize(find.byType(AppCollapse)).height, 0);
    });

    testWidgets('AppCollapse 与 AppReveal 在减少动态效果下首帧立即生效', (tester) async {
      var visible = false;
      late StateSetter setLocal;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setLocal = setState;
                return Column(
                  children: [
                    AppCollapse(visible: visible, child: const SizedBox(height: 40, child: Text('A'))),
                    AppReveal(visible: visible, child: const SizedBox(height: 40, child: Text('B'))),
                  ],
                );
              },
            ),
          ),
          disableAnimations: true,
        ),
      );
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);

      setLocal(() => visible = true);
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);

      setLocal(() => visible = false);
      await tester.pump();
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
    });
  });

  group('状态切换原语：AppIconSwap / AppCrossfade / AppProgressBar / AppSkeletonPulse / AnimatedStarRating', () {
    testWidgets('AppProgressBar 平滑插值，减少动态效果瞬时到位', (tester) async {
      var value = 0.2;
      late StateSetter setLocal;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setLocal = setState;
                return AppProgressBar(value: value);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, closeTo(0.2, 0.01));

      setLocal(() => value = 0.8);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final mid = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor!;
      expect(mid, greaterThan(0.2));
      expect(mid, lessThan(0.8));

      await tester.pumpAndSettle();
      expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, closeTo(0.8, 0.01));
      // 合并为单个 ImplicitlyAnimatedWidget，不再使用多层 TweenAnimationBuilder
      expect(find.descendant(of: find.byType(AppProgressBar), matching: find.byType(TweenAnimationBuilder)), findsNothing);
    });

    testWidgets('PagedNovelGrid 卸载时取消在途 CancelToken，且重建不重复执行 hide 过滤', (tester) async {
      CancelToken? capturedToken;
      final pending = Completer<PageResult>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionStoreProvider.overrideWithValue(store)],
          child: _app(
            Scaffold(
              body: PagedNovelGrid(
                fetchWithCancel: (page, token) {
                  capturedToken = token;
                  return pending.future;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(capturedToken, isNotNull);
      expect(capturedToken!.isCancelled, isFalse);

      await tester.pumpWidget(_app(const SizedBox.shrink()));
      expect(capturedToken!.isCancelled, isTrue);

      var hideCalls = 0;
      bool hideFn(String aid) {
        hideCalls++;
        return aid == '2';
      }

      late StateSetter setLocal;
      var tick = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStoreProvider.overrideWithValue(store),
            imageStoreProvider.overrideWithValue(_NullImageStore()),
          ],
          child: _app(
            Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  setLocal = setState;
                  return Column(
                    children: [
                      Text('t=$tick'),
                      Expanded(
                        child: PagedNovelGrid(
                          hide: hideFn,
                          fetch: (_) async => PageResult([NovelCover('书一', '', '1'), NovelCover('书二', '', '2')], 1),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('书一'), findsOneWidget);
      expect(find.text('书二'), findsNothing);
      final callsAfterLoad = hideCalls;

      // 相同 hide 回调下父级多次 rebuild，不重跑 .where 过滤
      setLocal(() => tick++);
      await tester.pump();
      setLocal(() => tick++);
      await tester.pump();
      expect(hideCalls, callsAfterLoad);
    });

    testWidgets('NetImage(full: true) 走异步 _Fitted 而非裸 MemoryImage，滑出卸载时取消在途请求', (tester) async {
      final png1x1 = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ]);
      final completer = Completer<Uint8List>();
      final fakeStore = _TrackingImageStore(
        onLoad: (_) => completer.future,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [imageStoreProvider.overrideWithValue(fakeStore)],
          child: const MaterialApp(
            home: SizedBox(width: 200, height: 200, child: NetImage('https://example.com/full.png', full: true)),
          ),
        ),
      );
      await tester.pump();
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.image, isNot(isA<MemoryImage>()));

      // 在途未完成前卸载 widget 应自动触发 ImageStore.cancel
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(fakeStore.cancelled, contains('https://example.com/full.png'));

      // 正常加载完成显示图片且缓存键不持有原 ImageProvider
      final readyStore = _TrackingImageStore(onLoad: (_) async => png1x1);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [imageStoreProvider.overrideWithValue(readyStore)],
          child: const MaterialApp(
            home: SizedBox(width: 200, height: 200, child: NetImage('https://example.com/full2.png', full: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final img2 = tester.widget<Image>(find.byType(Image));
      expect(img2.image, isNot(isA<MemoryImage>()));
      final key = await img2.image.obtainKey(ImageConfiguration.empty);
      expect(identical(key, img2.image), isFalse);
    });

    testWidgets('AppSkeletonPulse 开启减少动态效果时停止 Ticker，不空转', (tester) async {
      await tester.pumpWidget(
        _app(
          const Scaffold(body: AppSkeletonPulse(child: SizedBox(width: 100, height: 20))),
          disableAnimations: true,
        ),
      );
      // 没有持续 Ticker 时 pumpAndSettle 立即返回，不会超时
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppSkeletonPulse), matching: find.byType(FadeTransition)), findsNothing);
    });

    testWidgets('AppIconSwap 与 AppCrossfade 在减少动态效果下跳过 AnimatedSwitcher', (tester) async {
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Column(
              children: [
                AppIconSwap(child: Icon(Icons.bookmark, key: ValueKey(1))),
                AppCrossfade(child: Text('内容', key: ValueKey('a'))),
              ],
            ),
          ),
          disableAnimations: true,
        ),
      );
      expect(find.byType(AnimatedSwitcher), findsNothing);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('AnimatedStarRating 支持点选、再次点击清零与连续缩放动画', (tester) async {
      var rating = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) => Center(
                child: AnimatedStarRating(rating: rating, onChanged: (v) => setState(() => rating = v)),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('4 星评分'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(rating, 4);
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));

      // 再次点击当前星数清零
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('4 星评分'));
      await tester.pumpAndSettle();
      expect(rating, 0);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
    });
  });

  group('ApplePageTransitionsBuilder 跨平台转场', () {
    testWidgets('移动端使用 CupertinoPageTransition', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('二页')))),
                child: const Text('跳转'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('跳转'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(CupertinoPageTransition), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('二页'), findsOneWidget);
    });

    testWidgets('桌面端使用克制的 Slide+Fade 转场，减少动态效果仅淡入', variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('桌面二页')))),
                child: const Text('跳转'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('跳转'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CupertinoPageTransition), findsNothing);
      expect(find.byType(SlideTransition), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('桌面二页'), findsOneWidget);
    });
  });

  group('跟手手势与可打断弹簧（ChapterSwipe / PullBookmark）', () {
    testWidgets('ChapterSwipe 回弹途中再次拖动可无缝打断，松手精确归零', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _app(
            Scaffold(
              body: ListView(
                children: const [
                  ChapterSwipe(aid: 'm1', book: '书', cid: 'c1', title: '第一章', child: ListTile(title: Text('第一章'))),
                ],
              ),
            ),
          ),
        ),
      );

      // 先右滑松手进入弹簧回弹中途
      final g1 = await tester.startGesture(tester.getCenter(find.text('第一章')));
      await g1.moveBy(const Offset(24, 0));
      await g1.moveBy(const Offset(180, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(ListTile)).dx, greaterThan(80));
      await g1.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      final midDx = tester.getTopLeft(find.byType(ListTile)).dx;
      expect(midDx, greaterThan(10));

      // 回弹中途立刻再抓住继续往右拖，不能跳回 0
      final g2 = await tester.startGesture(tester.getCenter(find.byType(ListTile)));
      await g2.moveBy(const Offset(24, 0));
      await g2.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(ListTile)).dx, greaterThan(midDx));

      await g2.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(ListTile)).dx, 0);
    });

    testWidgets('PullBookmark 下拉越线触发回调，松手临界阻尼归零无负向过冲', (tester) async {
      var pulls = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: PullBookmark(
              drag: true,
              onPull: () => pulls++,
              marked: () => false,
              color: Colors.black,
              top: 0,
              child: const ColoredBox(color: Colors.white, child: SizedBox.expand(child: Center(child: Text('正文')))),
            ),
          ),
        ),
      );

      final g = await tester.startGesture(tester.getCenter(find.text('正文')));
      await g.moveBy(const Offset(0, 24));
      await g.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(find.text('松手添加书签'), findsOneWidget);
      await g.up();
      expect(pulls, 1);

      // 逐帧检查回弹过程绝不出现负向位移过冲
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final top = tester.getTopLeft(find.text('正文')).dy;
        expect(top, greaterThanOrEqualTo(0));
      }
      await tester.pumpAndSettle();
      expect(find.text('松手添加书签'), findsNothing);
      expect(find.text('下拉添加书签'), findsNothing);
    });
  });

  group('多尺寸与深浅色 / 减少动态效果兼容性冒烟', () {
    final viewports = <(String, Size)>[
      ('手机窄屏', const Size(360, 740)),
      ('窄桌面窗', const Size(760, 700)),
      ('宽屏桌面', const Size(1440, 900)),
    ];
    final pages = <(String, Widget)>[
      ('统计', const StatsPage()),
      ('设置', const SettingsPage()),
      ('规则', const RulesPage()),
      ('同步', const SyncPage()),
    ];

    for (final (vpName, size) in viewports) {
      for (final brightness in Brightness.values) {
        for (final reduce in const [false, true]) {
          testWidgets('$vpName / ${brightness.name} / reduce=$reduce 零溢出无异常', (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

            for (final (_, page) in pages) {
              await tester.pumpWidget(
                ProviderScope(
                  overrides: [sessionStoreProvider.overrideWithValue(store)],
                  child: _app(page, disableAnimations: reduce, brightness: brightness),
                ),
              );
              await tester.pump(const Duration(milliseconds: 400));
              expect(tester.takeException(), isNull);
            }
          });
        }
      }
    }
  });

  group('动效帧耗时性能基准实测', () {
    // flutter test 运行于未编译优化的 Debug JIT 模式且在共享 2 核 CI 虚拟机上并发执行，放宽墙钟 p95 守卫避免偶发抖动误报
    const ciDebugFrameBudgetMs = 40.0;

    Future<({double avgMs, double p95Ms, double maxMs})> measureFrames(
      WidgetTester tester,
      int frames,
      Future<void> Function(int frame) onFrame,
    ) async {
      // 预热 6 帧，避免首帧字体/着色器冷启动干扰
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final samples = <double>[];
      final sw = Stopwatch();
      for (var i = 0; i < frames; i++) {
        sw
          ..reset()
          ..start();
        await onFrame(i);
        await tester.pump(const Duration(milliseconds: 16));
        sw.stop();
        samples.add(sw.elapsedMicroseconds / 1000.0);
      }
      samples.sort();
      final avg = samples.reduce((a, b) => a + b) / samples.length;
      return (avgMs: avg, p95Ms: _percentile(samples, 0.95), maxMs: samples.last);
    }

    testWidgets('长网格滚动（200 项 AppPressScale 卡片）帧耗时在预算内', (tester) async {
      final sc = ScrollController();
      addTearDown(sc.dispose);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: GridView.builder(
              controller: sc,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.72, mainAxisSpacing: 12, crossAxisSpacing: 12),
              itemCount: 200,
              itemBuilder: (_, i) => AppPressScale(
                scale: 0.96,
                hoverScale: 1.015,
                child: Card(child: Center(child: Text('轻小说 #$i'))),
              ),
            ),
          ),
        ),
      );

      final m = await measureFrames(tester, 60, (i) async {
        sc.jumpTo(math.min(sc.position.maxScrollExtent, i * 48.0));
      });
      // ignore: avoid_print
      print('[PERF] 200-card AppPressScale GridView scroll (60f): avg=${m.avgMs.toStringAsFixed(2)}ms p95=${m.p95Ms.toStringAsFixed(2)}ms max=${m.maxMs.toStringAsFixed(2)}ms');
      expect(m.p95Ms, lessThan(ciDebugFrameBudgetMs));
    });

    testWidgets('复合原语连续打断（AppCollapse + AppReveal + AppProgressBar）帧耗时在预算内', (tester) async {
      var step = 0;
      late StateSetter setLocal;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                setLocal = setState;
                final on = step.isEven;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      AppCollapse(visible: on, child: const SizedBox(height: 56, child: Card(child: Center(child: Text('状态横幅'))))),
                      const SizedBox(height: 12),
                      AppProgressBar(value: (step % 10) / 10.0),
                      const SizedBox(height: 12),
                      AppReveal(visible: !on, child: const Chip(label: Text('悬浮操作栏'))),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      final m = await measureFrames(tester, 60, (i) async {
        if (i % 5 == 0) setLocal(() => step++);
      });
      // ignore: avoid_print
      print('[PERF] Interruptible Collapse+Reveal+Progress (60f): avg=${m.avgMs.toStringAsFixed(2)}ms p95=${m.p95Ms.toStringAsFixed(2)}ms max=${m.maxMs.toStringAsFixed(2)}ms');
      expect(m.p95Ms, lessThan(ciDebugFrameBudgetMs));
    });

    testWidgets('StatsPage 切换周/月/年区间图表动画帧耗时在预算内', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionStoreProvider.overrideWithValue(store)],
          child: _app(const StatsPage()),
        ),
      );
      await tester.pumpAndSettle();

      const tabs = ['月', '年', '周'];
      var switched = 0;
      final m = await measureFrames(tester, 60, (i) async {
        if (i % 20 == 0) {
          final label = tabs[(i ~/ 20) % tabs.length];
          final finder = find.text(label);
          if (finder.evaluate().isNotEmpty) {
            switched++;
            await tester.tap(finder.first);
          }
        }
      });
      expect(switched, 3);
      // ignore: avoid_print
      print('[PERF] StatsPage 30-day/yearly chart transitions (60f): avg=${m.avgMs.toStringAsFixed(2)}ms p95=${m.p95Ms.toStringAsFixed(2)}ms max=${m.maxMs.toStringAsFixed(2)}ms');
      expect(m.p95Ms, lessThan(ciDebugFrameBudgetMs));
    });

    testWidgets('ChapterSwipe 弹簧回弹与连续跟手帧耗时在预算内', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _app(
            Scaffold(
              body: ListView.builder(
                itemCount: 30,
                itemBuilder: (_, i) => ChapterSwipe(
                  aid: 'perf',
                  book: '长书',
                  cid: 'c$i',
                  title: '第 ${i + 1} 章',
                  child: ListTile(title: Text('第 ${i + 1} 章')),
                ),
              ),
            ),
          ),
        ),
      );

      final g = await tester.startGesture(tester.getCenter(find.text('第 1 章')));
      await g.moveBy(const Offset(18, 0));
      final m = await measureFrames(tester, 60, (i) async {
        if (i < 20) {
          await g.moveBy(const Offset(6, 0));
        } else if (i == 20) {
          await g.up();
        }
      });
      // ignore: avoid_print
      print('[PERF] ChapterSwipe drag+spring settle (60f): avg=${m.avgMs.toStringAsFixed(2)}ms p95=${m.p95Ms.toStringAsFixed(2)}ms max=${m.maxMs.toStringAsFixed(2)}ms');
      expect(m.p95Ms, lessThan(ciDebugFrameBudgetMs));
    });
  });
}

class _NullImageStore implements ImageStore {
  @override
  final srVersion = ValueNotifier<int>(0);

  @override
  Uint8List? peek(String rawUrl) => null;

  @override
  Future<Uint8List> load(String rawUrl) => Future<Uint8List>.error('skip');

  @override
  void cancel(String rawUrl) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackingImageStore implements ImageStore {
  _TrackingImageStore({required this.onLoad});

  final Future<Uint8List> Function(String rawUrl) onLoad;
  final cancelled = <String>[];

  @override
  final srVersion = ValueNotifier<int>(0);

  @override
  Uint8List? peek(String rawUrl) => null;

  @override
  Future<Uint8List> load(String rawUrl) => onLoad(rawUrl);

  @override
  void cancel(String rawUrl) => cancelled.add(rawUrl);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
