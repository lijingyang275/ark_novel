import 'dart:async';
import 'dart:io';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_parser.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/models/user_info.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/chapter_list.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/pages/novel_page.dart';
import 'package:ark_novel/next/routes.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/widgets.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';

class _FakeApi extends Api {
  _FakeApi({this.savedPage, this.freshPage, this.onVote})
    : super(
        Wenku8Client(baseUrl: () => 'https://www.wenku8.net', charset: () => CharsetType.gbk, headers: const {}),
        const Wenku8Urls('https://www.wenku8.net', CharsetType.gbk),
        'https://www.wenku8.net',
        'guest',
      );

  final NovelPage? savedPage;
  final NovelPage? freshPage;
  final Future<String> Function(String aid)? onVote;
  int novelCalls = 0;
  int voteCalls = 0;

  @override
  Future<NovelPage?> saved(String aid) async => savedPage;

  @override
  Future<NovelPage> novel(String aid, {CancelToken? cancelToken}) async {
    novelCalls++;
    return freshPage ?? savedPage!;
  }

  @override
  Future<String> vote(String aid) async {
    voteCalls++;
    if (onVote != null) return onVote!(aid);
    return '推荐成功';
  }
}

class _FixedSession extends SessionController {
  _FixedSession(this._initial);

  final SessionState _initial;

  @override
  SessionState build() => _initial;
}

NovelPage _makeNovel({String title = '测试轻小说', required List<CatVolume> catalogue, String introduce = '这是一段足够长的简介内容，用来测试详情页滚动与展示。'}) => NovelPage(
  Wenku8NovelDetail(
    title: title,
    author: '测试作者',
    status: '连载中',
    lastUpdate: '2026-11-22',
    imgUrl: '',
    introduce: introduce,
    tags: const ['校园', '恋爱'],
    heat: '1234',
    trending: '56',
    isAnimated: false,
  ),
  catalogue,
);

void main() {
  late Directory tempDir;
  late SessionStore store;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('ark_novel_page_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempDir.path,
    );
    store = await SessionStore.open();
    await ChapterCache.open();
  });

  setUp(() {
    CoverImage.clearFailed();
    CoverImage.clock = DateTime.now;
  });

  tearDownAll(() async {
    CoverImage.clearFailed();
    CoverImage.clock = DateTime.now;
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('P0：流式刷新追加新章节后开启标题序号不再显示 null.', (tester) async {
    const aid = '1001';
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      ChapterListOptions.save(aid, const ChapterListOptions(showIndex: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    final v1 = _makeNovel(
      catalogue: [
        CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: '1'), CatChapter(title: '第二章', cid: '2')]),
      ],
    );
    final v2 = _makeNovel(
      catalogue: [
        CatVolume(
          title: '第一卷',
          chapters: [CatChapter(title: '第一章', cid: '1'), CatChapter(title: '第二章', cid: '2'), CatChapter(title: '新增第三章', cid: '3')],
        ),
      ],
    );

    final ctrl = StreamController<NovelPage>();
    addTearDown(ctrl.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          novelProvider(aid).overrideWith((ref) => ctrl.stream),
        ],
        child: const MaterialApp(home: NovelPageView(aid: aid)),
      ),
    );
    // 初始加载展示骨架屏，而非裸菊花
    expect(find.byType(CircularProgressIndicator), findsNothing);

    ctrl.add(v1);
    await tester.pumpAndSettle();
    expect(find.text('1. 第一章'), findsOneWidget);
    expect(find.text('2. 第二章'), findsOneWidget);

    ctrl.add(v2);
    await tester.pumpAndSettle();
    expect(find.text('3. 新增第三章'), findsOneWidget);
    expect(find.textContaining('null.'), findsNothing);
  });

  test('novelProvider：45s 短 TTL 内复用 PageStore 缓存不重复请求，过期后自动刷新', () async {
    const aid = '2002';
    final base = siteBase(store.node);
    final saved = _makeNovel(
      title: '旧标题',
      catalogue: [CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: '1')])],
    );
    final fresh = _makeNovel(
      title: '新标题',
      catalogue: [CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: '1'), CatChapter(title: '第二章', cid: '2')])],
    );

    // 写入刚保存的时间戳（在 45s 内）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final stampBox = Hive.box('chapter_index');
    await stampBox.put('pt|$base/modules/article/articleinfo.php?id=$aid', nowMs);
    await stampBox.put('pt|$base/modules/article/reader.php?aid=$aid', nowMs);
    expect(isNovelCacheFresh(base, aid), isTrue);

    final apiFresh = _FakeApi(savedPage: saved, freshPage: fresh);
    final c1 = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), apiProvider.overrideWithValue(apiFresh)]);
    addTearDown(c1.dispose);
    final sub1 = c1.listen(novelProvider(aid), (_, _) {});
    addTearDown(sub1.close);
    await c1.read(novelProvider(aid).future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(apiFresh.novelCalls, 0);
    expect(c1.read(novelProvider(aid)).value?.detail.title, '旧标题');

    // 将时间戳设为 60s 前（已过 45s TTL）
    final oldMs = nowMs - const Duration(seconds: 60).inMilliseconds;
    await stampBox.put('pt|$base/modules/article/articleinfo.php?id=$aid', oldMs);
    await stampBox.put('pt|$base/modules/article/reader.php?aid=$aid', oldMs);
    expect(isNovelCacheFresh(base, aid), isFalse);

    final apiExpired = _FakeApi(savedPage: saved, freshPage: fresh);
    final c2 = ProviderContainer(overrides: [sessionStoreProvider.overrideWithValue(store), apiProvider.overrideWithValue(apiExpired)]);
    addTearDown(c2.dispose);
    final sub2 = c2.listen(novelProvider(aid), (_, _) {});
    addTearDown(sub2.close);
    await c2.read(novelProvider(aid).future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(apiExpired.novelCalls, 1);
    expect(c2.read(novelProvider(aid)).value?.detail.title, '新标题');
  });

  testWidgets('详情页：360px 窄屏四按钮不溢出、推荐防连点、按卷懒构建、吸顶书名与 Esc 退出多选', (tester) async {
    const aid = '3003';
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final voteDone = Completer<String>();
    final api = _FakeApi(onVote: (_) => voteDone.future);
    final page = _makeNovel(
      title: '吸顶测试书名',
      catalogue: [
        CatVolume(
          title: '第一卷',
          chapters: [for (var i = 1; i <= 10; i++) CatChapter(title: '卷一第 $i 章', cid: '10$i')],
        ),
        CatVolume(
          title: '第二卷',
          chapters: [for (var i = 1; i <= 5; i++) CatChapter(title: '卷二第 $i 章', cid: '20$i')],
        ),
      ],
    );

    final user = UserInfo(
      avatar: '',
      uid: '1',
      username: 'tester',
      userLevel: 'Lv1',
      email: '',
      registerDate: '',
      contribution: '0',
      experience: '0',
      point: '0',
      maxBookshelfNum: '100',
      maxRecommendNum: '10',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(() => _FixedSession(SessionLoggedIn(user))),
          novelProvider(aid).overrideWith((ref) => Stream.value(page)),
        ],
        child: const MaterialApp(home: NovelPageView(aid: aid)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 360px 窄屏四按钮均在同一行且无溢出
    final yVote = tester.getCenter(find.text('推荐')).dy;
    expect(tester.getCenter(find.text('书评')).dy, closeTo(yVote, 2));
    expect(tester.getCenter(find.text('分卷')).dy, closeTo(yVote, 2));
    expect(tester.getCenter(find.text('网页')).dy, closeTo(yVote, 2));

    // 推荐按钮防连点锁：在途期间重复点击只发 1 次
    await tester.tap(find.text('推荐'));
    await tester.pump();
    await tester.tap(find.text('推荐'));
    await tester.pump();
    expect(api.voteCalls, 1);
    voteDone.complete('已投票');
    await tester.pumpAndSettle();
    // 等投票提示 SnackBar 自动消失，避免遮挡下方目录项
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 卷二默认折叠，章节按展开态懒构建（不在最新 3 章里的卷二第 1 章未展开前不在树中）
    expect(find.text('卷二第 1 章'), findsNothing);

    // 展开第一卷并向下滚动后，AppBar 吸顶显示书名
    await tester.scrollUntilVisible(find.text('第一卷'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final appBarOpacity = tester.widget<AnimatedOpacity>(
      find.descendant(of: find.byType(AppBar), matching: find.byType(AnimatedOpacity)),
    );
    expect(appBarOpacity.opacity, 1.0);

    await tester.tap(find.text('第一卷'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('卷一第 2 章'), 150, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('卷一第 2 章'), findsOneWidget);

    // 长按章节进入多选，按 Esc 退出多选
    await tester.longPress(find.text('卷一第 2 章'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 章'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 章'), findsNothing);
  });

  testWidgets('StatePanel：去验证返回 true 后自动触发 onRetry 恢复', (tester) async {
    var retried = 0;
    final router = GoRouter(
      initialLocation: '/err',
      routes: [
        GoRoute(
          path: '/err',
          builder: (context, state) => Scaffold(
            body: StatePanel(
              title: '加载失败',
              error: CloudflareChallengeException(requestOptions: RequestOptions(path: '/')),
              onRetry: () => retried++,
            ),
          ),
        ),
        GoRoute(
          path: Routes.verify,
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(onPressed: () => context.pop(true), child: const Text('完成验证')),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWithValue(store)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('去验证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成验证'));
    await tester.pumpAndSettle();

    expect(retried, 1);
  });

  test('CoverImage：失败记录使用 30s 短 TTL 并支持手动清除', () {
    var now = DateTime(2026, 11, 22, 12, 0, 0);
    CoverImage.clock = () => now;
    const url = 'https://pic.wenku8.com/test/cover.jpg';
    expect(CoverImage.isMarkedFailed(url), isFalse);
    // 手动 clearFailed 幂等
    CoverImage.clearFailed(url);
    expect(CoverImage.isMarkedFailed(url), isFalse);
    now = now.add(const Duration(seconds: 31));
    expect(CoverImage.isMarkedFailed(url), isFalse);
  });
}
