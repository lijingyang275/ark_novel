import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/wenku8_node.dart';
import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/pages/novel_page.dart';
import 'package:ark_novel/next/reader/page_curl.dart';
import 'package:ark_novel/next/reader/reader_body.dart';
import 'package:ark_novel/next/reader/reader_page.dart';
import 'package:ark_novel/next/reader/reader_sheets.dart';
import 'package:ark_novel/next/reader/reader_tts.dart';
import 'package:ark_novel/next/routes.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/text.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' as material show Text;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';

class _StubImageStore implements ImageStore {
  static final png1x1 = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  @override
  final srVersion = ValueNotifier<int>(0);

  @override
  Uint8List? peek(String rawUrl) => png1x1;

  @override
  Future<Uint8List> load(String rawUrl) async => png1x1;

  @override
  void cancel(String rawUrl) {}

  @override
  void prefetch(Iterable<String> urls) {}

  @override
  void cancelPrefetch([Iterable<String>? urls]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopTtsEngine implements TtsEngine {
  @override
  void setCompletionHandler(void Function() handler) {}
  @override
  void setErrorHandler(void Function(dynamic message) handler) {}
  @override
  Future<void> setLanguage(String language) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<void> setSpeechRate(double rate) async {}
  @override
  Future<void> setVoice(Map<String, String> voice) async {}
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<List<TtsVoice>> zhVoices() async => const [];
}

class _NoopNotice implements TtsNoticePort {
  @override
  void clearCallbacks() {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> show({
    required String book,
    required String chapter,
    String? cover,
    required bool playing,
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onStop,
    required VoidCallback onNext,
    required VoidCallback onPrev,
  }) async {}
}

class _StubSession extends SessionController {
  @override
  SessionState build() => const SessionLoggedOut();
}

class _StubNode extends NodeController {
  @override
  Wenku8Node build() => Wenku8Node.wwwWenku8Net;
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ark_reader_ux_test');
    Hive.init(tempDir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  setUp(() async {
    await Hive.box('session').clear();
    await AppPrefs.write('r.tapHintShown', true);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('正文绕开 UiHant', () {
    final hant = Hant.parse('简\t簡\n体\t體\n阅\t閱\n读\t讀\n章\t章\n软\t軟\n件\t件\n', '');
    const style = TextStyle(fontSize: 18, height: 1.8, color: Colors.black);
    const bodyText = '　　这是简体阅读软件正文，不应被界面繁体误伤。';
    const chapter = Chapter(text: bodyText, images: [], marks: []);

    testWidgets('ScrollBody 正文与章节标题不经过 UiHant，界面按钮照常转换', (t) async {
      await t.pumpWidget(
        UiHant(
          hant: hant,
          child: MaterialApp(
            home: Scaffold(
              body: ScrollBody(
                chapter: chapter,
                title: '简体章节标题',
                spanOf: (a, b) => TextSpan(text: chapter.text.substring(a, b), style: style),
                style: style,
                margin: 16,
                startOffset: 0,
                onOffset: (_) {},
                onEnd: () {},
                onNext: () {},
                nextLabel: '继续阅读',
                wrap: (w) => w,
                onTapZone: () {},
                onMark: (_) {},
                hasSelection: () => false,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // 正文与章节标题保持简体（material.Text / material.Text.rich）
      expect(find.textContaining('简体阅读软件正文', findRichText: true), findsOneWidget);
      expect(find.textContaining('簡體閱讀軟體正文', findRichText: true), findsNothing);
      expect(find.text('简体章节标题'), findsOneWidget);
      // 按钮文字走 UiHant，正常转为繁体
      expect(find.text('继续閱讀'), findsOneWidget);
    });

    testWidgets('PagedBody 正文与章节标题不经过 UiHant', (t) async {
      await t.pumpWidget(
        UiHant(
          hant: hant,
          child: MaterialApp(
            home: Scaffold(
              body: PagedBody(
                chapter: chapter,
                title: '简体章节标题',
                spanOf: (a, b) => TextSpan(text: chapter.text.substring(a, b), style: style),
                style: style,
                margin: 16,
                curl: false,
                background: Colors.white,
                color: Colors.black,
                startOffset: 0,
                onOffset: (_) {},
                onEnd: () {},
                onPrev: null,
                onNext: null,
                wrap: (w) => w,
                onTapZone: () {},
                onMark: (_) {},
                hasSelection: () => false,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.textContaining('简体阅读软件正文', findRichText: true), findsOneWidget);
      expect(find.textContaining('簡體閱讀軟體正文', findRichText: true), findsNothing);
      expect(find.text('简体章节标题'), findsOneWidget);
    });
  });

  group('PageCurl 翻页动画 RepaintBoundary 缓存', () {
    testWidgets('翻页动画多帧内不重复重建 under/turning，状态通知变化时失效缓存', (t) async {
      final controller = PageCurlController();
      final status = ValueNotifier<String>('20:00');
      addTearDown(status.dispose);
      final animBuilds = <int, int>{};

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCurl(
              controller: controller,
              pageCount: 3,
              initialIndex: 0,
              background: Colors.white,
              cacheKey: 'v1',
              cacheInvalidator: status,
              pageBuilder: (_, i, live) {
                if (!live) animBuilds[i] = (animBuilds[i] ?? 0) + 1;
                return Center(child: material.Text('第 $i 页 · ${status.value}'));
              },
            ),
          ),
        ),
      );
      await t.pump();
      expect(animBuilds, isEmpty);

      // 触发仿真翻页动画并推进 4 帧：第 0/1 页各只构建 1 次
      controller.next();
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      await t.pump(const Duration(milliseconds: 40));
      await t.pump(const Duration(milliseconds: 40));

      expect(animBuilds[0], 1);
      expect(animBuilds[1], 1);
      expect(find.byType(RepaintBoundary), findsWidgets);

      // 分钟变化触发失效后，下一动画帧重新构建缓存子树
      status.value = '20:01';
      await t.pump(const Duration(milliseconds: 40));
      expect(animBuilds[0], 2);
      expect(animBuilds[1], 2);

      await t.pumpAndSettle();
    });
  });

  group('ScrollWheelTurnFilter macOS 触控板惯性防连翻', () {
    test('单次 1.5 秒触控板惯性衰减流最多翻 1 页', () {
      final filter = ScrollWheelTurnFilter();
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final deltas = <double>[
        10, 22, 36, 32, 26, 21, 17, 13, 10, 8, 6, 5, 4, 3, 2.5, 2, 1.5, 1, 1, 0.8, 0.5, 0.5,
        0.5, 0.5, 0.4, 0.3, 0.3, 0.2, 0.2, 0.2, 0.1, 0.1,
      ];
      final turns = <int>[];
      for (final d in deltas) {
        final r = filter.feed(d, now, kind: PointerDeviceKind.trackpad);
        if (r != 0) turns.add(r);
        now = now.add(const Duration(milliseconds: 16));
      }
      expect(turns, [1]);

      // 停顿超过手势间隔后再次轻滑，可以翻下一页
      now = now.add(const Duration(milliseconds: 200));
      expect(filter.feed(18, now, kind: PointerDeviceKind.trackpad), 0);
      now = now.add(const Duration(milliseconds: 16));
      expect(filter.feed(18, now, kind: PointerDeviceKind.trackpad), 1);
    });

    test('方向反转、惯性尾声重新加速与离散鼠标滚轮正常响应，微小抖动被忽略', () {
      final filter = ScrollWheelTurnFilter();
      var now = DateTime(2026, 1, 1, 12, 0, 0);

      // 微小抖动不触发
      expect(filter.feed(3, now, kind: PointerDeviceKind.trackpad), 0);
      now = now.add(const Duration(milliseconds: 16));
      expect(filter.feed(4, now, kind: PointerDeviceKind.trackpad), 0);

      // 离散鼠标滚轮逐格翻页
      now = now.add(const Duration(milliseconds: 300));
      expect(filter.feed(40, now, kind: PointerDeviceKind.mouse), 1);
      now = now.add(const Duration(milliseconds: 300));
      expect(filter.feed(40, now, kind: PointerDeviceKind.mouse), 1);
      now = now.add(const Duration(milliseconds: 300));
      expect(filter.feed(-40, now, kind: PointerDeviceKind.mouse), -1);

      // 触控板惯性衰减到很低后用户再次猛滑：允许触发新翻页
      now = now.add(const Duration(milliseconds: 300));
      expect(filter.feed(35, now, kind: PointerDeviceKind.trackpad), 1);
      for (final d in [20.0, 12.0, 5.0, 2.0]) {
        now = now.add(const Duration(milliseconds: 60));
        expect(filter.feed(d, now, kind: PointerDeviceKind.trackpad), 0);
      }
      now = now.add(const Duration(milliseconds: 60));
      expect(filter.feed(32, now, kind: PointerDeviceKind.trackpad), 1);
    });
  });

  test('combineReaderColorMatrix 与三层叠加 ColorFilter 数值一致', () {
    expect(combineReaderColorMatrix(warm: 0, grayscale: false, invert: false), isNull);

    List<double> apply(List<double> m, List<double> rgba) => [
      for (var r = 0; r < 4; r++) m[r * 5] * rgba[0] + m[r * 5 + 1] * rgba[1] + m[r * 5 + 2] * rgba[2] + m[r * 5 + 3] * rgba[3] + m[r * 5 + 4],
    ];

    const warm = 0.4;
    final mWarm = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1 - 0.6 * warm, 0.0, 0.0, 0.0, 0.0, 0.0, 1 - 1.4 * warm, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0];
    const mGray = [0.2126, 0.7152, 0.0722, 0.0, 0.0, 0.2126, 0.7152, 0.0722, 0.0, 0.0, 0.2126, 0.7152, 0.0722, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0];
    const mInv = [-1.0, 0.0, 0.0, 0.0, 255.0, 0.0, -1.0, 0.0, 0.0, 255.0, 0.0, 0.0, -1.0, 0.0, 255.0, 0.0, 0.0, 0.0, 1.0, 0.0];

    final combined = combineReaderColorMatrix(warm: warm, grayscale: true, invert: true)!;
    const sample = [180.0, 120.0, 60.0, 255.0];
    final expected = apply(mInv, apply(mGray, apply(mWarm, sample)));
    final actual = apply(combined, sample);
    for (var i = 0; i < 4; i++) {
      expect(actual[i], closeTo(expected[i], 1e-6));
    }
  });

  group('ReaderPage 加载态返回、canPop 兜底与深浅主题同步', () {
    testWidgets('无返回栈冷启动在加载态可点返回直达书架，不抛 GoError，且可轻触唤出顶栏', (t) async {
      final pending = Completer<Chapter>();
      final router = GoRouter(
        initialLocation: '/reader/1/100',
        routes: [
          GoRoute(path: Routes.bookshelf, builder: (_, _) => const Scaffold(body: Center(child: material.Text('BOOKSHELF_HOME')))),
          GoRoute(path: '/reader/:aid/:cid', builder: (_, s) => ReaderPage(aid: s.pathParameters['aid']!, cid: s.pathParameters['cid']!)),
        ],
      );
      addTearDown(router.dispose);

      await t.pumpWidget(
        ProviderScope(
          overrides: [
            chapterProvider(('1', '100')).overrideWith((ref) => pending.future),
            novelProvider('1').overrideWith((ref) => const Stream.empty()),
            imageStoreProvider.overrideWithValue(_StubImageStore()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await t.pump();

      expect(find.text('正在加载章节…'), findsOneWidget);
      // 加载态左上角常驻返回按钮可见
      expect(find.byIcon(Icons.arrow_back), findsWidgets);

      // 菜单收起时：顶栏与底栏彻底卸载，不保留屏幕外 SlideTransition / Slider
      expect(find.descendant(of: find.byKey(const ValueKey('reader_top_bar')), matching: find.byType(SlideTransition)), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('reader_bottom_bar')), matching: find.byType(SlideTransition)), findsNothing);
      expect(find.byType(Slider), findsNothing);

      // 轻触中央唤出菜单栏（加载中含无限旋转指示器，不能用 pumpAndSettle；需先起帧再推进 300ms 完成滑入）
      await t.tap(find.text('正在加载章节…'));
      await t.pump();
      // 滑入动画中途：顶栏应从上方滑下（dy < 0），底栏应从下方滑上（dy > 0），不可错位复用状态
      await t.pump(const Duration(milliseconds: 60));
      final topSlideBox = t.widget<SlideTransition>(find.descendant(of: find.byKey(const ValueKey('reader_top_bar')), matching: find.byType(SlideTransition)));
      final bottomSlideBox = t.widget<SlideTransition>(find.descendant(of: find.byKey(const ValueKey('reader_bottom_bar')), matching: find.byType(SlideTransition)));
      expect(topSlideBox.position.value.dy, lessThan(0));
      expect(bottomSlideBox.position.value.dy, greaterThan(0));

      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('目录'), findsOneWidget);
      expect(find.text('朗读设置'), findsNothing); // 非朗读时已精简底栏槽位

      // 再次轻触中央收起菜单：退场动画结束后彻底卸载顶栏与底栏
      await t.tap(find.text('正在加载章节…'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.descendant(of: find.byKey(const ValueKey('reader_top_bar')), matching: find.byType(SlideTransition)), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('reader_bottom_bar')), matching: find.byType(SlideTransition)), findsNothing);
      expect(find.text('目录'), findsNothing);

      // 点击加载态左上角返回：无上层路由时不崩，安全回到书架
      await t.tap(find.byIcon(Icons.arrow_back).first);
      await t.pumpAndSettle();
      expect(find.text('BOOKSHELF_HOME'), findsOneWidget);
    });

    testWidgets('夜间阅读主题下 AnnotatedRegion 状态栏与错误态 StatePanel 同步为深色', (t) async {
      // 设为夜间主题 (r.theme: 2)
      await t.runAsync(() => Hive.box('session').putAll({'r.theme': 2, 'r.mode': 1, 'r.fullscreen': false}));

      await t.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            chapterProvider(('1', '200')).overrideWith((ref) => Future<Chapter>.error(Exception('network timeout'))),
            novelProvider('1').overrideWith((ref) => const Stream.empty()),
            imageStoreProvider.overrideWithValue(_StubImageStore()),
            sessionProvider.overrideWith(_StubSession.new),
            nodeProvider.overrideWith(_StubNode.new),
          ],
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: const ReaderPage(aid: '1', cid: '200'),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final region = t.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first);
      expect(region.value.statusBarIconBrightness, Brightness.light);

      // 错误态 StatePanel 使用阅读器派生的深色主题
      final errCtx = t.element(find.text('章节加载失败'));
      expect(Theme.of(errCtx).brightness, Brightness.dark);
    });
  });

  group('TTS 控制条与目录/书签弹窗、插图查看器', () {
    testWidgets('ReaderTtsBar 同步暂停/继续图标与定时徽标', (t) async {
      final tts = ReaderTtsController(engine: _NoopTtsEngine(), notice: _NoopNotice(), requestNotificationPermission: () {});
      addTearDown(tts.dispose);
      await tts.start('第一句测试。第二句测试。');

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReaderTtsBar(
                tts: tts,
                palette: const ReaderPalette(Color(0xFF1C1C1A), Color(0xFFBDBBB2)),
                accent: Colors.amber,
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      await t.tap(find.byIcon(Icons.pause_rounded));
      await t.pump();
      expect(tts.isPaused, isTrue);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      tts.setSleepOption(30);
      await t.pump();
      expect(find.text('30m'), findsOneWidget);
    });

    testWidgets('目录弹窗按展开态懒构建，书签 Tab 支持直接删除', (t) async {
      await t.runAsync(() => Bookmarks.toggle('1', '测试书', 'c1', '第一章', 10, '这是一段书签摘录'));
      final volumes = [
        CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: 'c1'), CatChapter(title: '第二章', cid: 'c2')]),
        CatVolume(title: '第二卷', chapters: [CatChapter(title: '第三章', cid: 'c3')]),
      ];
      var bookmarkChanged = 0;

      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showReaderCatalogueSheet(
                    context,
                    aid: '1',
                    volumes: volumes,
                    currentCid: 'c1',
                    palette: const ReaderPalette(Color(0xFF1C1C1A), Color(0xFFBDBBB2)),
                    accent: Colors.amber,
                    resolveBookmarkPage: (_, _) async => (1, 5),
                    onSelectChapter: (_) {},
                    onSelectBookmark: (_) {},
                    onEditNote: (_) {},
                    onBookmarksChanged: () => bookmarkChanged++,
                  ),
                  child: const material.Text('打开目录'),
                ),
              ),
            ),
          ),
        ),
      );

      await t.tap(find.text('打开目录'));
      await t.pumpAndSettle();

      // 当前卷展开可见，未展开卷的章节未懒构建
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第三章'), findsNothing);

      // 展开第二卷后可见
      await t.tap(find.text('第二卷'));
      await t.pumpAndSettle();
      expect(find.text('第三章'), findsOneWidget);

      // 切到书签 Tab 并删除书签
      await t.tap(find.text('书签'));
      await t.pumpAndSettle();
      expect(find.text('这是一段书签摘录'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.byIcon(Icons.delete_outline));
        for (var i = 0; i < 40 && bookmarkChanged == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await t.pumpAndSettle();
      expect(find.text('还没有书签'), findsOneWidget);
      expect(bookmarkChanged, 1);
      expect(Bookmarks.all('1'), isEmpty);
    });

    testWidgets('内嵌插图放大按钮热区 ≥40dp 且带 tooltip，全屏查看器支持多图切图与单击显隐工具栏', (t) async {
      final store = _StubImageStore();
      const chapter = Chapter(text: '', images: ['https://pic.wenku8.com/1.jpg', 'https://pic.wenku8.com/2.jpg'], marks: []);

      await t.pumpWidget(
        ProviderScope(
          overrides: [imageStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(
              body: ScrollBody(
                chapter: chapter,
                spanOf: (_, _) => const TextSpan(text: ''),
                style: const TextStyle(fontSize: 18, height: 1.8, color: Colors.black),
                margin: 16,
                startOffset: 0,
                onOffset: (_) {},
                onEnd: () {},
                onNext: null,
                wrap: (w) => w,
                onTapZone: () {},
                onMark: (_) {},
                hasSelection: () => false,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final tooltipFinder = find.byTooltip('全屏查看插图');
      expect(tooltipFinder, findsNWidgets(2));
      final btnSize = t.getSize(tooltipFinder.first);
      expect(btnSize.width, greaterThanOrEqualTo(40));
      expect(btnSize.height, greaterThanOrEqualTo(40));

      // 点击放大按钮打开多图查看器
      await t.tap(tooltipFinder.first);
      await t.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);

      // 左滑切到第 2 张
      await t.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await t.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);

      // 单击隐藏工具栏（同时挂了 onDoubleTap，需等待双击判定超时 300ms 才派发单击）
      await t.tapAt(const Offset(200, 300));
      await t.pump(const Duration(milliseconds: 350));
      await t.pumpAndSettle();
      final barOpacity = t.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(barOpacity.opacity, 0);
    });
  });

  group('阅读器引擎核心优化回归验证', () {
    testWidgets('ScrollBody 长章按段落惰性虚拟化构建，TTS 高亮只重建受影响的 1~2 个块', (t) async {
      t.view.physicalSize = const Size(400, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);

      final text = List.generate(300, (i) => '　　这是第$i段测试正文内容，用于验证滚屏虚拟化与局部高亮刷新。').join('\n');
      final chapter = Chapter(text: text, images: const [], marks: const []);
      const style = TextStyle(fontSize: 18, height: 1.8, color: Colors.black);
      final highlight = ValueNotifier<(int, int)?>(null);
      addTearDown(highlight.dispose);
      final builtRanges = <(int, int)>[];

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollBody(
              chapter: chapter,
              spanOf: (a, b) => TextSpan(text: text.substring(a, b), style: style),
              spanOfHighlight: (a, b, hl) {
                builtRanges.add((a, b));
                return TextSpan(text: text.substring(a, b), style: style);
              },
              highlight: highlight,
              style: style,
              margin: 16,
              paragraphSpacing: 12,
              title: '长章',
              startOffset: 0,
              onOffset: (_) {},
              onEnd: () {},
              onNext: null,
              wrap: (w) => w,
              onTapZone: () {},
              onMark: (_) {},
              hasSelection: () => false,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // 300 段正文仅挂载可见区域与缓存区段落块，绝不一次性构建全部 300 段
      expect(builtRanges.length, lessThan(45));
      builtRanges.clear();

      // 高亮切入第 0 段：只重建该 1 个段落块
      final p0End = text.indexOf('\n');
      highlight.value = (2, p0End);
      await t.pump();
      expect(builtRanges.length, 1);

      // 高亮从第 0 段移动到第 1 段：只重建切出与切入的 2 个段落块
      builtRanges.clear();
      final p1Start = p0End + 1;
      final p1End = text.indexOf('\n', p1Start);
      highlight.value = (p1Start + 2, p1End);
      await t.pump();
      expect(builtRanges.length, 2);
    });

    testWidgets('PagedBody 双页模式按页过滤 TTS 高亮，不重建未命中高亮的另一页', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);

      final text = List.generate(200, (i) => '　　这是第$i段双页正文，用于测试双页局部高亮过滤机制。').join('\n');
      final chapter = Chapter(text: text, images: const [], marks: const []);
      const style = TextStyle(fontSize: 18, height: 1.8, color: Colors.black);
      final highlight = ValueNotifier<(int, int)?>(null);
      addTearDown(highlight.dispose);
      final builtRanges = <(int, int)>[];

      await t.pumpWidget(
        MaterialApp(
          home: PagedBody(
            chapter: chapter,
            spanOf: (a, b) => TextSpan(text: text.substring(a, b), style: style),
            spanOfHighlight: (a, b, hl) {
              builtRanges.add((a, b));
              return TextSpan(text: text.substring(a, b), style: style);
            },
            highlight: highlight,
            style: style,
            margin: 20,
            title: '双页高亮',
            curl: false,
            dual: true,
            background: Colors.white,
            color: Colors.black,
            startOffset: 0,
            onOffset: (_) {},
            onEnd: () {},
            onPrev: null,
            onNext: null,
            wrap: (w) => w,
            onTapZone: () {},
            onMark: (_) {},
            hasSelection: () => false,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(builtRanges.length, 2); // 首屏左、右两页各建 1 次
      builtRanges.clear();

      // 高亮落在左页开头区间：仅左页重建 1 次，右页零重建
      highlight.value = (0, 12);
      await t.pump();
      expect(builtRanges.length, 1);
      expect(builtRanges.single.$1, 0);
    });

    testWidgets('PageCurl 覆盖翻页与仿真翻页动画正常渲染，dispose 正确解绑 controller', (t) async {
      for (final cover in const [true, false]) {
        final controller = PageCurlController();
        var index = 0;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PageCurl(
                controller: controller,
                cover: cover,
                pageCount: 3,
                initialIndex: 0,
                background: const Color(0xFFF6F1E7),
                pageBuilder: (_, i, _) => Center(child: material.Text('页$i')),
                onIndexChanged: (i) => index = i,
              ),
            ),
          ),
        );
        await t.pump();
        controller.next();
        await t.pump();
        await t.pump(const Duration(milliseconds: 60));
        await t.pumpAndSettle();
        expect(index, 1, reason: 'cover=$cover');
        expect(t.takeException(), isNull);

        // 卸载后调用 controller 不抛异常且不触发已销毁 State 回调
        await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await t.pump();
        controller.next();
        controller.prev();
        controller.goTo(0);
        expect(index, 1);
      }
    });

    testWidgets('暖色护眼带插图章不退化为全屏 ColorFiltered，仅对插图施加局部滤镜', (t) async {
      await t.runAsync(() => Hive.box('session').putAll({'r.warm': 0.35, 'r.mode': 0, 'r.fullscreen': false, 'incognito': true}));
      const illustrated = Chapter(text: '　　带插图正文段落。', images: ['https://pic.wenku8.com/w1.jpg'], marks: []);

      await t.pumpWidget(
        ProviderScope(
          overrides: [
            chapterProvider(('1', '300')).overrideWith((ref) async => illustrated),
            novelProvider('1').overrideWith((ref) => const Stream.empty()),
            imageStoreProvider.overrideWithValue(_StubImageStore()),
          ],
          child: const MaterialApp(home: ReaderPage(aid: '1', cid: '300')),
        ),
      );
      await t.pumpAndSettle();

      // 仅对插图节点施加局部 ColorFiltered（不包含整个 Scaffold.body 的全屏 ColorFiltered）
      final filters = find.byType(ColorFiltered);
      expect(filters, findsOneWidget);
      expect(find.descendant(of: filters, matching: find.byType(ScrollBody)), findsNothing);
      expect(find.descendant(of: filters, matching: find.byType(Image)), findsOneWidget);
    });

    test('Bookmarks 索引缓存：has 零分配精确匹配且 toggle / remove / 外部写入自动失效', () async {
      expect(Bookmarks.has('5', 'c1', 100), isFalse);
      expect(Bookmarks.bookmarkedAids(), isEmpty);
      expect(Bookmarks.bookmarkedCids('5'), isEmpty);

      expect(await Bookmarks.toggle('5', '测试书', 'c1', '第一章', 100, '摘录'), isTrue);
      expect(Bookmarks.has('5', 'c1', 100), isTrue);
      expect(Bookmarks.has('5', 'c1', 140), isTrue);
      expect(Bookmarks.has('5', 'c1', 141), isFalse);
      expect(Bookmarks.bookmarkedAids(), {'5'});
      expect(Bookmarks.bookmarkedCids('5'), {'c1'});

      expect(await Bookmarks.toggle('5', '测试书', 'c1', '第一章', 110, '摘录'), isFalse);
      expect(Bookmarks.has('5', 'c1', 100), isFalse);
      expect(Bookmarks.bookmarkedAids(), isEmpty);
    });
  });
}
