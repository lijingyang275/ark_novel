import 'dart:async';
import 'dart:io';

import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/models/novel_cover.dart';
import 'package:ark_novel/models/recommend_block.dart';
import 'package:ark_novel/models/user_info.dart';
import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/history.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/pages/bookmarks_page.dart';
import 'package:ark_novel/next/pages/discover_page.dart';
import 'package:ark_novel/next/pages/library_pages.dart';
import 'package:ark_novel/next/pages/login_page.dart';
import 'package:ark_novel/next/pages/profile_page.dart';
import 'package:ark_novel/next/pages/report_page.dart';
import 'package:ark_novel/next/pages/search_page.dart';
import 'package:ark_novel/next/pages/settings_page.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/pages/sync_page.dart';
import 'package:ark_novel/next/pages/updates_page.dart';
import 'package:ark_novel/next/pages/wall_page.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/routes.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/settings.dart';
import 'package:ark_novel/next/shelf_tabs.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/sync.dart';
import 'package:ark_novel/next/theme.dart';
import 'package:ark_novel/next/theme_squire.dart';
import 'package:ark_novel/next/updates.dart';
import 'package:ark_novel/next/x_list.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';

UserInfo _user() => UserInfo(
  avatar: '',
  uid: '1',
  username: 'test',
  userLevel: 'LV1',
  email: 't@example.com',
  registerDate: '2024-01-01',
  contribution: '0',
  experience: '0',
  point: '0',
  maxBookshelfNum: '100',
  maxRecommendNum: '10',
);

class _FakeApi implements Api {
  _FakeApi({this.recommendCompleter});

  final Completer<List<RecommendBlock>>? recommendCompleter;

  @override
  Future<List<RecommendBlock>> recommend({CancelToken? cancelToken}) {
    if (recommendCompleter != null) return recommendCompleter!.future;
    return Future.value([
      RecommendBlock('今日推荐', [NovelCover('测试轻小说', '', '1001')]),
    ]);
  }

  @override
  Future<PageResult> completed(int page, {CancelToken? cancelToken}) async => PageResult([NovelCover('完结作品', '', '2001')], 1);

  @override
  Future<PageResult> ranking(String sort, int page, {CancelToken? cancelToken}) async => const PageResult([], 1);

  @override
  Future<PageResult> category(String tag, String sort, int page, {CancelToken? cancelToken}) async => const PageResult([], 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession extends SessionController {
  _FakeSession(this._initial);

  final SessionState _initial;

  @override
  SessionState build() => _initial;
}

class _FakeUpdateController extends UpdateController {
  _FakeUpdateController(this._initial);

  final UpdateProgress _initial;
  bool cancelled = false;

  @override
  UpdateProgress build() => _initial;

  @override
  void cancel() {
    cancelled = true;
    state = UpdateProgress(done: state.done, total: state.total);
  }
}

class _FakeSyncController extends SyncController {
  _FakeSyncController(this._initial);

  final SyncStatus _initial;

  @override
  SyncStatus build() => _initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late SessionStore store;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ark_pages_polish_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    store = await SessionStore.open();
    await ChapterCache.open();
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> resetBox(WidgetTester tester) => tester.runAsync(() => Hive.box('session').clear());

  testWidgets('DiscoverPage：推荐骨架屏 -> CustomScrollView+SliverGrid；完结 Tab 具备隐藏书架筛选按钮；题材面板用 Wrap', (tester) async {
    await resetBox(tester);
    final completer = Completer<List<RecommendBlock>>();
    final api = _FakeApi(recommendCompleter: completer);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(() => _FakeSession(SessionLoggedIn(_user()))),
        ],
        child: const MaterialApp(home: DiscoverPage()),
      ),
    );
    await tester.pump();
    // 加载态不再使用裸转圈，改为骨架屏
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SliverGrid), findsAtLeastNWidgets(1));

    // 完成加载后渲染 CustomScrollView + SliverGrid，不再嵌套 GridView(shrinkWrap: true)
    completer.complete([
      RecommendBlock('热门轻小说', [NovelCover('狼与香辛料', '', '101')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('热门轻小说'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(SliverGrid), findsOneWidget);

    // 切到题材 Tab 并展开全部标签面板，确认用 Wrap 替代 GridView.count
    await tester.tap(find.text('题材'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全部标签'));
    await tester.pumpAndSettle();
    expect(find.byType(Wrap), findsOneWidget);
    expect(find.byType(GridView), findsNothing);

    // 切到完结 Tab，确认右上角「隐藏书架里的书」筛选按钮存在且可切换
    await tester.tap(find.text('完结'));
    await tester.pumpAndSettle();
    final filterBtn = find.byTooltip('隐藏书架里的书');
    expect(filterBtn, findsOneWidget);
    expect(AppPrefs.read(P.hideShelved, false), isFalse);
    await tester.runAsync(() async {
      await tester.tap(filterBtn);
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle();
    expect(AppPrefs.read(P.hideShelved, false), isTrue);
  });

  testWidgets('UpdatesPage：含 RefreshIndicator、空态 XEmpty、运行中支持取消按钮', (tester) async {
    await resetBox(tester);
    final ctrl = _FakeUpdateController(const UpdateProgress(running: true, done: 2, total: 10));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          updateProvider.overrideWith(() => ctrl),
        ],
        child: const MaterialApp(home: UpdatesPage()),
      ),
    );
    await tester.pump();
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(ctrl.cancelled, isTrue);
    expect(find.byType(XEmpty), findsOneWidget);
  });

  testWidgets(
    'SettingsPage 搜索清空、子页定位高亮、网络页 nativeNet 热切换与 Apple 代理提示',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await resetBox(tester);
      await tester.runAsync(() async {
        await store.setProxy('127.0.0.1:7890');
        await store.setNativeNet(true);
      });

    // 1. 搜索清空按钮
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.enterText(find.byType(TextField), '代理');
    await tester.pump();
    expect(find.text('HTTP 代理'), findsOneWidget);
    expect(find.byTooltip('清空搜索'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(find.byTooltip('清空搜索'), findsNothing);

    // 2. 网络子页：定位高亮 + Apple 代理提示 + nativeNet 热切换
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: SettingsSectionPage(section: SettingsSection.network, highlight: '系统网络栈')),
      ),
    );
    await tester.pump();
    expect(find.textContaining('出口 IP'), findsOneWidget);
    expect(find.textContaining('重启后生效'), findsNothing);
    expect(find.textContaining('切换后立即生效'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.nativeNet, isFalse);
  });

  testWidgets('SyncPage：同步中按钮 Spinner 用 onPrimary 且状态卡圆角跟随主题', (tester) async {
    await resetBox(tester);
    // 预置 sync:passMoved，避免 SyncPage.initState 在 macOS 路径里于 FakeAsync 中触发未 await 的 Hive.put 锁
    await tester.runAsync(() => Hive.box('session').put('sync:passMoved', true));
    final ruins = appPalettes.firstWhere((p) => p.scene);
    final theme = buildAppTheme(Brightness.dark, ruins);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          syncProvider.overrideWith(() => _FakeSyncController(const SyncStatus(busy: true))),
        ],
        child: MaterialApp(theme: theme, home: const SyncPage()),
      ),
    );
    await tester.pump();
    final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(spinner.color, equals(theme.colorScheme.onPrimary));
    final card = tester.widget<Container>(find.ancestor(of: find.text('未配置同步'), matching: find.byType(Container)).first);
    final dec = card.decoration! as BoxDecoration;
    expect(dec.borderRadius, equals(BorderRadius.circular(6)));
  });

  testWidgets('LoginPage：密码显隐切换、通栏登录按钮、nativeNet 热切换', (tester) async {
    await resetBox(tester);
    await tester.runAsync(() => store.setNativeNet(true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          sessionProvider.overrideWith(() => _FakeSession(const SessionLoggedOut())),
        ],
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.pump();
    // 密码框显隐切换
    final passFinder = find.widgetWithText(TextField, '密码');
    expect(tester.widget<TextField>(passFinder).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(tester.widget<TextField>(passFinder).obscureText, isFalse);

    // 登录主按钮外层通栏 SizedBox(width: double.infinity)
    final loginBtn = find.widgetWithText(FilledButton, '登录');
    final box = tester.widget<SizedBox>(find.ancestor(of: loginBtn, matching: find.byType(SizedBox)).first);
    expect(box.width, equals(double.infinity));

    // 系统网络栈热切换
    expect(find.textContaining('重启后生效'), findsNothing);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.runAsync(() async {
      await tester.tap(find.byType(SwitchListTile));
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle();
    expect(store.nativeNet, isFalse);
  });

  testWidgets('ProfilePage：sceneMotion 开关实时生效且未登录点头像可跳登录页', (tester) async {
    await resetBox(tester);
    final ruinsIdx = appPalettes.indexWhere((p) => p.scene);
    await tester.runAsync(() async {
      await Hive.box('session').put('palette', ruinsIdx);
      await AppPrefs.write(P.sceneMotion, true);
    });
    var pushedLogin = false;
    final router = GoRouter(
      initialLocation: Routes.profile,
      routes: [
        GoRoute(path: Routes.profile, builder: (_, _) => const ProfilePage()),
        GoRoute(
          path: Routes.login,
          builder: (_, _) {
            pushedLogin = true;
            return const Scaffold(body: Text('LOGIN_ROUTE'));
          },
        ),
      ],
    );
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          sessionProvider.overrideWith(() => _FakeSession(const SessionLoggedOut())),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp.router(routerConfig: router);
          },
        ),
      ),
    );
    await tester.pump();
    expect(tester.widget<RuinsScene>(find.byType(RuinsScene)).animate, isTrue);

    await tester.runAsync(() async {
      container.read(appPrefsProvider.notifier).set(P.sceneMotion, false);
      await Hive.box('session').flush();
    });
    await tester.pump();
    expect(tester.widget<RuinsScene>(find.byType(RuinsScene)).animate, isFalse);

    await tester.tap(find.byType(CircleAvatar));
    await tester.pumpAndSettle();
    expect(pushedLogin, isTrue);
  });

  testWidgets('HistoryPage 左滑删除带红底与撤销恢复', (tester) async {
    await resetBox(tester);
    await tester.runAsync(() => ReadingHistory.record('10', '测试历史书', '', '100', '第一章'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: HistoryPage()),
      ),
    );
    await tester.pump();
    expect(find.text('测试历史书'), findsOneWidget);
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    final bg = dismissible.background! as Container;
    expect(bg.color, isNotNull);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('删除记录'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle();
    expect(ReadingHistory.all(), isEmpty);
    expect(find.text('撤销'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('撤销'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await Hive.box('session').flush();
    });
    ScaffoldMessenger.of(tester.element(find.byType(HistoryPage))).clearSnackBars();
    await tester.pumpAndSettle();
    expect(ReadingHistory.all().length, 1);
    expect(ReadingHistory.all().first.aid, '10');
  });

  testWidgets('CachePage 整本删除二次确认', (tester) async {
    await resetBox(tester);
    await tester.runAsync(() async {
      await ChapterCache.put('30', '1', Content(text: '正文内容', images: []));
      await ChapterCache.setMeta('30', '缓存测试书', 1, '', '1');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: CachePage()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除缓存'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(ChapterCache.count('30'), 1);

    // 从 PopupMenuButton 开始就在 runAsync 真实异步区触发 showMenu -> onSelected -> showDialog -> ChapterCache.remove + compact，避免在 FakeAsync 滞留 Hive 锁
    await tester.runAsync(() => tester.tap(find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('删除缓存')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Hive.box('chapter_index').flush();
      await Hive.lazyBox('chapters').flush();
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle();
    expect(ChapterCache.count('30'), 0);
  });

  testWidgets('BookmarksPage 圆角跟随主题', (tester) async {
    await resetBox(tester);
    await tester.runAsync(() => Bookmarks.toggle('40', '书签书', '1', '第一章', 10, '这是一段摘录'));
    final ruins = appPalettes.firstWhere((p) => p.scene);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: MaterialApp(theme: buildAppTheme(Brightness.light, ruins), home: const BookmarksPage()),
      ),
    );
    await tester.pumpAndSettle();
    final mat = tester.widget<Material>(find.ancestor(of: find.text('书签书'), matching: find.byType(Material)).first);
    expect(mat.borderRadius, equals(BorderRadius.circular(6)));
  });

  testWidgets('SearchPage：清空按钮由 ValueListenableBuilder 驱动', (tester) async {
    await resetBox(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          apiProvider.overrideWithValue(_FakeApi()),
          sessionProvider.overrideWith(() => _FakeSession(SessionLoggedIn(_user()))),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('清空输入'), findsNothing);
    await tester.enterText(find.byType(TextField), '魔禁');
    await tester.pump();
    expect(find.byTooltip('清空输入'), findsOneWidget);
    await tester.tap(find.byTooltip('清空输入'));
    await tester.pump();
    expect(find.byTooltip('清空输入'), findsNothing);
  });

  testWidgets('WallPage 大字号不溢出且不触发 coverColor 预计算；StatsPage 卡片圆角跟随主题且热力图点击看单日详情', (tester) async {
    await resetBox(tester);
    final now = DateTime.now();
    final todayKey = ReadingStats.dayKey(now);
    await tester.runAsync(() async {
      await Hive.box('session').put('vols:50', [
        {'t': '第一卷', 'c': ['1'], 'i': null},
      ]);
      await Hive.box('session').put('vdone:50', {'第一卷': now.millisecondsSinceEpoch});
      await Hive.box('session').put('stats:info:50', {'t': '测试轻小说', 'a': '作者', 'i': ''});
      await Hive.box('session').put('stats:day', {todayKey: 1800});
      await Hive.box('session').put('stats:book', {'50': 1800});
      await Hive.box('session').put('stats:ch:50', {
        '1': {todayKey: 1800},
      });
    });

    // 1. WallPage 2.0x 大字号不溢出
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(2.0)),
            child: WallPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('第一卷'), findsOneWidget);

    // 2. StatsPage 主题圆角 + 热力图点击单日详情
    final ruins = appPalettes.firstWhere((p) => p.scene);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: MaterialApp(theme: buildAppTheme(Brightness.light, ruins), home: const StatsPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final todayCard = tester.widget<Material>(find.ancestor(of: find.text('今天'), matching: find.byType(Material)).first);
    expect(todayCard.borderRadius, equals(BorderRadius.circular(6)));

    final semantics = tester.ensureSemantics();
    try {
      final todayLabel = '${now.year}年${now.month}月${now.day}日，30 分钟';
      final heatmap = find.byKey(const ValueKey('stats-heatmap'));
      await tester.scrollUntilVisible(heatmap, 300, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.semantics.byLabel(todayLabel), findsOneWidget);
      final hmTopLeft = tester.getTopLeft(heatmap);
      final hmSize = tester.getSize(heatmap);
      final weeks = ((hmSize.width + 3) / 16).round();
      final todayCell = hmTopLeft + Offset((weeks - 1) * 16.0 + 6.5, (now.weekday - 1) * 16.0 + 6.5);
      await tester.tapAt(todayCell);
      await tester.pump();
      expect(find.textContaining('${now.year}年${now.month}月${now.day}日 · 30 分钟'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('ReportPage：AnnotatedRegion<SystemUiOverlayStyle> 浅色状态栏 + 五星热区 ≥44dp 且带 Semantics', (tester) async {
    await resetBox(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: ReportPage(aid: '60')),
      ),
    );
    await tester.pump();
    final regions = tester.widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).toList();
    expect(regions.any((r) => r.value == SystemUiOverlayStyle.light), isTrue);

    final star3 = find.bySemanticsLabel('3 星，还不错');
    expect(star3, findsOneWidget);
    final size = tester.getSize(star3);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));

    await tester.ensureVisible(star3);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(star3);
      await Hive.box('session').flush();
    });
    await tester.pump();
    expect(ReadState.rating('60'), 3);
    expect(find.text('还不错'), findsOneWidget);
  });

  test('shelf_tabs：Set 加速 shelfBooksIn 与秩映射排序 allShelfTabs / shelfTabs', () async {
    final box = Hive.box('session');
    await box.clear();
    await box.put('shelfTabOrder', ['c2', doneShelfTab, '']);

    final lib = LibraryState(
      const {
        '1': LibBook(aid: '1', title: '连载书', img: '', done: false),
        '2': LibBook(aid: '2', title: '完结书', img: '', done: true),
        '3': LibBook(aid: '3', title: '手动归完结', img: '', done: false, cats: ['cat_done']),
        '4': LibBook(aid: '4', title: '手动归连载', img: '', done: true, cats: ['cat_ongoing']),
        '5': LibBook(aid: '5', title: '自定义分类', img: '', done: false, cats: ['c2']),
      },
      const [
        LibCategory('cat_done', '完结'),
        LibCategory('cat_ongoing', '连载'),
        LibCategory('c1', '轻改'),
        LibCategory('c2', '推理'),
      ],
    );

    expect(shelfBooksIn(lib, '').map((b) => b.aid).toSet(), {'1', '2', '3', '4', '5'});
    expect(shelfBooksIn(lib, ongoingShelfTab).map((b) => b.aid).toSet(), {'1', '4', '5'});
    expect(shelfBooksIn(lib, doneShelfTab).map((b) => b.aid).toSet(), {'2', '3', '4'});
    expect(shelfBooksIn(lib, 'c2').map((b) => b.aid).toSet(), {'5'});

    final ordered = allShelfTabs(lib.cats).map((c) => c.id).toList();
    expect(ordered, ['c2', doneShelfTab, '', ongoingShelfTab, 'c1']);

    final shown = shelfTabs(lib.cats, hidden: ['c2', 'c1']).map((c) => c.id).toList();
    expect(shown, [doneShelfTab, '', ongoingShelfTab]);
  });

  testWidgets('SettingsSectionPage：数据页缓存 diskBytes 不重复扫盘；阅读滑块本地预览且松手落盘', (tester) async {
    await resetBox(tester);
    var diskBytesCalls = 0;
    final fakeStore = _CountingImageStore(onDiskBytes: () async {
      diskBytesCalls++;
      return 2 * 1024 * 1024;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          imageStoreProvider.overrideWithValue(fakeStore),
        ],
        child: const MaterialApp(home: SettingsSectionPage(section: SettingsSection.data)),
      ),
    );
    await tester.pumpAndSettle();
    expect(diskBytesCalls, 1);
    expect(find.textContaining('2.0 MB'), findsOneWidget);

    // 切换本页无关开关触发 rebuild，不应再次调用 diskBytes()
    await tester.runAsync(() async {
      await tester.tap(find.text('启动时自动清理章节缓存'));
      await Hive.box('session').flush();
    });
    await tester.pumpAndSettle();
    expect(diskBytesCalls, 1);

    // 切到阅读页，测试字号滑块 onChanged 仅更新本地预览，onChangeEnd 才写 readerPrefsProvider
    final container = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsSectionPage(section: SettingsSection.reading)),
      ),
    );
    await tester.pumpAndSettle();
    final beforeFont = container.read(readerPrefsProvider).fontSize;
    final fontSliderFinder = find.byType(Slider).first;
    await tester.scrollUntilVisible(fontSliderFinder, 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(fontSliderFinder);
    slider.onChanged?.call(24);
    await tester.pump();
    expect(container.read(readerPrefsProvider).fontSize, beforeFont);
    expect(find.text('24'), findsOneWidget);
    await tester.runAsync(() async {
      slider.onChangeEnd?.call(24);
      await Hive.box('session').flush();
    });
    await tester.pump();
    expect(container.read(readerPrefsProvider).fontSize, 24);
  });

  testWidgets('AccountAvatar：自定义本地头像使用 ResizeImage 限制解码尺寸', (tester) async {
    await resetBox(tester);
    const png1x1 = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ];
    final dummyFile = File('${dir.path}/avatar_dummy.png')..writeAsBytesSync(png1x1);
    await tester.runAsync(() async {
      await Hive.box('session').put('avatar', dummyFile.path);
      await Hive.box('session').flush();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: Scaffold(body: AccountAvatar(radius: 28))),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.foregroundImage, isA<ResizeImage>());
    final resized = avatar.foregroundImage! as ResizeImage;
    expect(resized.width, inInclusiveRange(64, 512));
    await tester.pumpWidget(const SizedBox());
  });
}

class _CountingImageStore implements ImageStore {
  _CountingImageStore({required this.onDiskBytes});

  final Future<int> Function() onDiskBytes;

  @override
  Future<int> diskBytes() => onDiskBytes();

  @override
  Future<void> clearDisk() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
