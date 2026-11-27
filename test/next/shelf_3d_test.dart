import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/shelf_3d.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Shelf3DLayout：封面按高度放大但给左右留出半本，两侧的书互不遮挡、朝中间转', () {
    final w = Shelf3DLayout.coverWidth(390, 420);
    expect(w, closeTo(390 * 0.62, 0.01)); // 手机竖屏：宽度说了算
    expect(Shelf3DLayout.coverWidth(390, 240), lessThan(w)); // 矮的时候按高度收
    expect(Shelf3DLayout.coverWidth(1400, 2000), 340); // 宽屏有上限

    final centre = Shelf3DLayout.pose(0, w);
    expect(centre.dx, 0);
    expect(centre.angle, 0);
    expect(centre.scale, 1);

    final right = Shelf3DLayout.pose(1, w);
    final left = Shelf3DLayout.pose(-1, w);
    expect(right.dx, -left.dx);
    expect(right.angle, lessThan(0));
    expect(left.angle, greaterThan(0));
    // 旁边那本的左边缘在中间那本右边缘的右边：留了缝
    expect(right.dx - w * right.scale / 2, greaterThan(w / 2));
  });

  final books = [
    const LibBook(aid: '1', title: '狼与香辛料', img: '', done: true),
    const LibBook(aid: '2', title: '这是一个非常非常长会在下面折成两行的轻小说书名测试标题', img: ''),
    const LibBook(aid: '3', title: '败北女角太多了！', img: ''),
  ];

  Widget shelf(List<LibBook> list, {Set<String> selected = const {}, bool hero = true, void Function(String)? log, String? initial, ValueChanged<String>? onFocus}) => ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390,
          height: 620,
          child: Shelf3DView(
            books: list,
            initialAid: initial,
            onFocusChanged: onFocus,
            selected: selected,
            heroEnabled: hero,
            coverOf: (_) => '',
            badgeOf: (_) => null,
            subtitleOf: (b) => 'sub-${b.aid}',
            actionOf: (b) => b.aid == '1' ? (label: '继续读', cid: '101') : (label: '开始读', cid: null),
            onOpen: (b) => log?.call('open ${b.aid}'),
            onRead: (b, cid) => log?.call('read ${b.aid} $cid'),
            onToggleSelect: (b) => log?.call('toggle ${b.aid}'),
          ),
        ),
      ),
    ),
  );

  testWidgets('Shelf3DView：点旁边的书滑到中间，再点打开；切书时书名区不上下跳', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(shelf(books, log: log.add));
    await tester.pumpAndSettle();
    expect(find.text('狼与香辛料'), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf-3d-dots')), findsOneWidget);
    final infoBefore = tester.getRect(find.byKey(const ValueKey('shelf-3d-info')));
    final buttonBefore = tester.getRect(find.text('继续读'));

    await tester.tap(find.text('继续读'));
    expect(log, ['read 1 101']);

    // 点右边露出来的那半本：先滑到中间，不打开
    final stage = tester.getRect(find.byKey(const ValueKey('shelf-3d-stage')));
    await tester.tapAt(Offset(stage.right - 30, stage.center.dy));
    await tester.pumpAndSettle();
    expect(find.text(books[1].title), findsOneWidget);
    expect(log, ['read 1 101']);
    // 长书名只占一行，按钮一直在原位
    expect(tester.getRect(find.byKey(const ValueKey('shelf-3d-info'))), infoBefore);
    expect(tester.getRect(find.text('开始读')).center.dy, buttonBefore.center.dy);
    await tester.tap(find.text('开始读'));
    expect(log.last, 'open 2'); // cid 为空时按钮就是打开

    await tester.tap(find.byKey(const ValueKey('shelf-3d-hit-2')));
    expect(log.last, 'open 2');

    await tester.longPress(find.byKey(const ValueKey('shelf-3d-hit-2')));
    expect(log.last, 'toggle 2');

    // 左右滑
    await tester.drag(find.byKey(const ValueKey('shelf-3d-stage')), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text('败北女角太多了！'), findsOneWidget);
  });

  testWidgets('Shelf3DView：多选时点书是选择；书单换了顺序还停在同一本；书多时用滑块', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(shelf(books, selected: {'3'}, log: log.add));
    await tester.pumpAndSettle();
    expect(find.text('继续读'), findsNothing); // 多选时按钮换成选中
    expect(find.text('选中'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shelf-3d-hit-1')));
    expect(log, ['toggle 1']);

    // 滑到第 2 本，再把书单倒过来：还是第 2 本在中间
    await tester.drag(find.byKey(const ValueKey('shelf-3d-stage')), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text(books[1].title), findsOneWidget);
    await tester.pumpWidget(shelf(books.reversed.toList(), selected: {'3'}, log: log.add));
    await tester.pumpAndSettle();
    expect(find.text(books[1].title), findsOneWidget);

    final many = [for (var i = 0; i < 20; i++) LibBook(aid: 'm$i', title: '书 $i', img: '')];
    await tester.pumpWidget(shelf(many));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-3d-slider')), findsOneWidget);
    expect(find.text('2 / 20'), findsOneWidget); // 原来那本不在了，停在原来的位置（第 2 本）
  });

  testWidgets('Shelf3DView：快速一甩划过好几本、轻拨走一本；记住停在哪本', (tester) async {
    final many = [for (var i = 0; i < 30; i++) LibBook(aid: 'm$i', title: '书 $i', img: '')];
    String? remembered;
    await tester.pumpWidget(shelf(many, initial: 'm5', onFocus: (aid) => remembered = aid));
    await tester.pumpAndSettle();
    expect(find.text('书 5'), findsOneWidget); // 从上次停的那本开始

    final stage = find.byKey(const ValueKey('shelf-3d-stage'));
    await tester.fling(stage, const Offset(-60, 0), 600); // 轻拨
    await tester.pumpAndSettle();
    expect(find.text('书 6'), findsOneWidget);
    expect(remembered, 'm6');

    await tester.fling(stage, const Offset(-300, 0), 5000); // 快甩
    await tester.pumpAndSettle();
    final at = int.parse(remembered!.substring(1));
    expect(at, greaterThan(8));
    expect(find.text('书 $at'), findsOneWidget); // 停稳在某一本上
  });

  testWidgets('Shelf3DView：只有中间那本带 Hero，非当前标签关掉', (tester) async {
    await tester.pumpWidget(shelf(books, hero: false));
    await tester.pumpAndSettle();
    final heroes = tester.widgetList<Hero>(find.byType(Hero, skipOffstage: false)).toList();
    expect(heroes.map((h) => h.tag), ['vols:1']);
    expect(tester.widget<HeroMode>(find.ancestor(of: find.byType(Hero), matching: find.byType(HeroMode)).first).enabled, isFalse);
  });

  testWidgets('Shelf3DView：圆点指示器可点击切书且封面带 Semantics', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(shelf(books));
      await tester.pumpAndSettle();
      expect(find.text('狼与香辛料'), findsOneWidget);
      expect(find.bySemanticsLabel('狼与香辛料'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('shelf-3d-dot-2')));
      await tester.pumpAndSettle();
      expect(find.text('败北女角太多了！'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('Shelf3DView：macOS 触控板惯性滚动单次手势只翻 1 本', (tester) async {
    final many = [for (var i = 0; i < 10; i++) LibBook(aid: 'm$i', title: '书 $i', img: '')];
    await tester.pumpWidget(shelf(many));
    await tester.pumpAndSettle();
    expect(find.text('书 0'), findsOneWidget);

    final center = tester.getCenter(find.byKey(const ValueKey('shelf-3d-stage')));
    // 模拟 macOS 触控板一次轻滑产生的衰减惯性滚轮序列（每 16ms 一次，持续 300ms+）
    for (final dy in [12.0, 26.0, 32.0, 28.0, 22.0, 16.0, 12.0, 9.0, 6.0, 4.0, 2.0]) {
      tester.binding.handlePointerEvent(PointerScrollEvent(position: center, scrollDelta: Offset(0, dy)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(find.text('书 1'), findsOneWidget);
  });

  testWidgets('Shelf3DView：矮窗超屏时允许滚动，不裁切底部主按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 260,
              child: Shelf3DView(
                books: books,
                selected: const {},
                heroEnabled: false,
                coverOf: (_) => '',
                badgeOf: (_) => null,
                subtitleOf: (b) => 'sub-${b.aid}',
                actionOf: (b) => (label: '继续读', cid: '101'),
                onOpen: (_) {},
                onRead: (_, _) {},
                onToggleSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollView = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scrollView.physics, isA<ClampingScrollPhysics>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('MaskedRollSwitcher：原地淡入淡出不上下位移，减弱动态时直接替换', (tester) async {
    Widget host(String label, int dir, {bool disableAnimations = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 240,
          height: 30,
          child: MaskedRollSwitcher(
            direction: dir,
            child: Text(label, key: ValueKey(label)),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host('A', 1));
    await tester.pumpAndSettle();

    // 正向切换：原地淡入淡出，基线完全不上下跳动
    await tester.pumpWidget(host('B', 1));
    await tester.pump(const Duration(milliseconds: 50));
    final aOut = tester.getCenter(find.text('A')).dy;
    final bIn = tester.getCenter(find.text('B')).dy;
    expect(bIn, closeTo(aOut, 0.01));
    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byType(FadeTransition), findsAtLeastNWidgets(1));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(find.text('A'), findsNothing);

    // 开启减弱动态效果：立即替换且无 FadeTransition
    await tester.pumpWidget(host('C', 1, disableAnimations: true));
    expect(find.text('C'), findsOneWidget);
    expect(find.text('B'), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);
  });

  testWidgets('Shelf3DView：桌面鼠标悬停中央封面倾转、悬停邻书轻微抬升，离场后自动停帧', (tester) async {
    await tester.pumpWidget(shelf(books));
    await tester.pumpAndSettle();

    final stage = tester.getRect(find.byKey(const ValueKey('shelf-3d-stage')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: stage.center);
    addTearDown(mouse.removePointer);

    // 移到中央封面偏右下位置，应产生倾转并在有限时间内停稳（pumpAndSettle 不超时）
    await mouse.moveTo(Offset(stage.center.dx + 40, stage.center.dy + 30));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 移到右侧相邻封面上：应触发悬停抬升并平滑停稳
    await mouse.moveTo(Offset(stage.right - 20, stage.center.dy));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 移出舞台：归位并停帧
    await mouse.moveTo(Offset(stage.right + 100, stage.bottom + 100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shelf3DView：开启减弱动态效果时不走滑动动画，点邻书直接切换', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 620), disableAnimations: true),
        child: shelf(books),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('狼与香辛料'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shelf-3d-dot-2')));
    await tester.pump();
    expect(find.text('败北女角太多了！'), findsOneWidget);
    expect(find.text('狼与香辛料'), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('shelf-3d-info')), matching: find.byType(SlideTransition)), findsNothing);
  });

  testWidgets('Shelf3DView：宽屏 3 本书在中央或首本位置点击左右任意可见封面均精准切换', (tester) async {
    tester.view.physicalSize = const Size(1280, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    String? focused;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1280,
              height: 760,
              child: Shelf3DView(
                books: books,
                initialAid: '2',
                onFocusChanged: (aid) => focused = aid,
                selected: const {},
                heroEnabled: true,
                coverOf: (_) => '',
                badgeOf: (_) => null,
                subtitleOf: (b) => 'sub-${b.aid}',
                actionOf: (_) => (label: '继续读', cid: '101'),
                onOpen: (_) {},
                onRead: (_, _) {},
                onToggleSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final stage = tester.getRect(find.byKey(const ValueKey('shelf-3d-stage')));
    final w = Shelf3DLayout.coverWidth(1280, 760 - Shelf3DLayout.infoHeight(1.0));

    // 点左侧第 1 本封面 -> 切换到 1
    await tester.tapAt(Offset(stage.center.dx + Shelf3DLayout.pose(-1, w).dx, stage.center.dy));
    await tester.pumpAndSettle();
    expect(focused, '1');

    // 停在第 1 本时点右侧第 3 本（d = +2 紧缩错位处）露出部分 -> 直接切换到 3，不误触第 2 本
    final pose2 = Shelf3DLayout.pose(2, w);
    await tester.tapAt(Offset(stage.center.dx + pose2.dx + w * pose2.scale * 0.35, stage.center.dy));
    await tester.pumpAndSettle();
    expect(focused, '3');
  });
}
