import 'dart:math' as math;

import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/shelf_spine.dart';
import 'package:ark_novel/next/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ShelfSpineLayout：平滑步进函数推开邻书不重叠，外侧书脊等距排列，几何命中精确', () {
    final m = ShelfSpineLayout.metrics(390, 420);
    expect(m.d, lessThanOrEqualTo(390 * 0.56 + 0.01));
    expect(m.ws, inInclusiveRange(38.0, 68.0));

    expect(ShelfSpineLayout.smoothStepB(0), 0);
    expect(ShelfSpineLayout.smoothStepB(1), 0.5);
    expect(ShelfSpineLayout.smoothStepB(-1), -0.5);
    expect(ShelfSpineLayout.smoothStepB(0.4), closeTo(-ShelfSpineLayout.smoothStepB(-0.4), 1e-9));

    final x0 = ShelfSpineLayout.centerX(0, m.ws, m.d, m.gap);
    final x1 = ShelfSpineLayout.centerX(1, m.ws, m.d, m.gap);
    final x2 = ShelfSpineLayout.centerX(2, m.ws, m.d, m.gap);
    expect(x0, 0);
    // 第 1 根书脊左边缘严格位于中央封面右边缘之外，留有缝隙
    expect(x1 - m.ws / 2, greaterThan(m.d / 2));
    // 第 2 根与第 1 根书脊间距恰好为 ws + gap
    expect(x2 - x1, closeTo(m.ws + m.gap, 1e-6));

    // 宽封面左右边缘附近都应命中当前书（0），右侧第 1 根书脊命中 1
    expect(ShelfSpineLayout.hitTest(localDx: 0, page: 0, count: 6, stageW: 1000, ws: m.ws, d: m.d, gap: m.gap), 0);
    expect(ShelfSpineLayout.hitTest(localDx: m.d * 0.45, page: 0, count: 6, stageW: 1000, ws: m.ws, d: m.d, gap: m.gap), 0);
    expect(ShelfSpineLayout.hitTest(localDx: x1, page: 0, count: 6, stageW: 1000, ws: m.ws, d: m.d, gap: m.gap), 1);
    expect(ShelfSpineLayout.hitTest(localDx: x2, page: 0, count: 6, stageW: 1000, ws: m.ws, d: m.d, gap: m.gap), 2);
    expect(ShelfSpineLayout.hitTest(localDx: -m.d * 2, page: 0, count: 6, stageW: 1000, ws: m.ws, d: m.d, gap: m.gap), isNull);

    final activePose = ShelfSpineLayout.pose(0, m.h, m.ws, m.d, m.gap);
    expect(activePose.o, 1.0);
    expect(activePose.rotY, closeTo(math.pi / 2, 1e-6));
    expect(activePose.coverShade, 0.0);
    expect(activePose.dy, 0.0);
    // 高窗口关掉继续阅读条后，上下安全留白充足且书高收束在上限内，不超出舞台上边界
    final tall = ShelfSpineLayout.metrics(1280, 680);
    expect(tall.h, lessThanOrEqualTo(380.0));
    expect(ShelfSpineLayout.stagePad(tall.h), greaterThanOrEqualTo(68.0));
    final spinePose = ShelfSpineLayout.pose(1, m.h, m.ws, m.d, m.gap);
    expect(spinePose.o, 0.0);
    expect(spinePose.rotY, 0.0);
    expect(spinePose.spineShade, 0.0);
  });

  final books = [
    const LibBook(aid: '1', title: '狼与香辛料', img: '', done: true),
    const LibBook(aid: '2', title: '86―不存在的战区―', img: ''),
    const LibBook(aid: '3', title: 'Re:从零开始的异世界生活超长书名测试标题', img: ''),
    const LibBook(aid: '4', title: '败北女角太多了！', img: ''),
  ];

  Widget shelf(
    List<LibBook> list, {
    Key? viewKey,
    double width = 390,
    double height = 620,
    Set<String> selected = const {},
    bool hero = true,
    void Function(String)? log,
    String? initial,
    ValueChanged<String>? onFocus,
  }) => ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: height,
          child: ShelfSpineView(
            key: viewKey,
            books: list,
            initialAid: initial,
            onFocusChanged: onFocus,
            selected: selected,
            heroEnabled: hero,
            coverOf: (_) => '',
            badgeOf: (_) => null,
            subtitleOf: (b) => 'sub-${b.aid}',
            actionOf: (b) => b.aid == '1' ? (label: '继续读', cid: '101') : (label: '开始读', cid: null),
            unreadOf: (b) => b.aid == '2' ? 3 : 0,
            onOpen: (b) => log?.call('open ${b.aid}'),
            onRead: (b, cid) => log?.call('read ${b.aid} $cid'),
            onToggleSelect: (b) => log?.call('toggle ${b.aid}'),
          ),
        ),
      ),
    ),
  );

  testWidgets('ShelfSpineView：点侧面书脊抽出到中间，再点展开封面打开，长按多选，底部不跳动', (tester) async {
    final log = <String>[];
    String? focused;
    await tester.pumpWidget(shelf(books, log: log.add, onFocus: (aid) => focused = aid));
    await tester.pumpAndSettle();

    expect(find.text('狼与香辛料'), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf-spine-dots')), findsOneWidget);
    final infoBefore = tester.getRect(find.byKey(const ValueKey('shelf-spine-info')));
    final buttonBefore = tester.getRect(find.text('继续读'));

    await tester.tap(find.text('继续读'));
    expect(log, ['read 1 101']);

    // 点右侧书脊：抽出第 2 本到中间，不触发打开
    final stage = tester.getRect(find.byKey(const ValueKey('shelf-spine-stage')));
    final m = ShelfSpineLayout.metrics(390, 620 - ShelfSpineLayout.infoHeight(1.0));
    final spine1X = stage.center.dx + ShelfSpineLayout.centerX(1, m.ws, m.d, m.gap);
    await tester.tapAt(Offset(spine1X, stage.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('86―不存在的战区―'), findsOneWidget);
    expect(focused, '2');
    expect(log, ['read 1 101']);
    expect(tester.getRect(find.byKey(const ValueKey('shelf-spine-info'))), infoBefore);
    expect(tester.getRect(find.text('开始读')).center.dy, buttonBefore.center.dy);

    // 点中央展开封面（偏右侧边缘也应命中第 2 本）：打开分卷页
    await tester.tapAt(Offset(stage.center.dx + m.d * 0.35, stage.center.dy));
    expect(log.last, 'open 2');

    // 长按中央封面触发多选
    await tester.longPressAt(stage.center);
    expect(log.last, 'toggle 2');
  });

  testWidgets('ShelfSpineView：宽屏显示左右箭头，支持桌面悬停抬升与封面倾转、停稳自动停帧', (tester) async {
    await tester.pumpWidget(shelf(books, width: 1080, height: 720));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shelf-spine-prev')), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf-spine-next')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shelf-spine-next')));
    await tester.pumpAndSettle();
    expect(find.text('86―不存在的战区―'), findsOneWidget);

    final stage = tester.getRect(find.byKey(const ValueKey('shelf-spine-stage')));
    final m = ShelfSpineLayout.metrics(1080, 720 - ShelfSpineLayout.infoHeight(1.0));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: stage.center);
    addTearDown(mouse.removePointer);

    // 悬停中央封面偏右上方触发 3D 倾转
    await mouse.moveTo(Offset(stage.center.dx + 45, stage.center.dy - 35));
    await tester.pumpAndSettle();

    // 悬停右侧书脊触发上抽抬升
    final spineRight = stage.center.dx + ShelfSpineLayout.centerX(1, m.ws, m.d, m.gap);
    await mouse.moveTo(Offset(spineRight, stage.center.dy));
    await tester.pumpAndSettle();

    // 移出舞台后归位停帧
    await mouse.moveTo(Offset(stage.right + 100, stage.bottom + 100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShelfSpineView：Hero 仅绑定当前书、多选与滑块、减弱动态和矮窗均正常', (tester) async {
    await tester.pumpWidget(shelf(books, hero: false));
    await tester.pumpAndSettle();
    final heroes = tester.widgetList<Hero>(find.byType(Hero, skipOffstage: false)).toList();
    expect(heroes.map((h) => h.tag), ['vols:1']);
    expect(tester.widget<HeroMode>(find.ancestor(of: find.byType(Hero), matching: find.byType(HeroMode)).first).enabled, isFalse);

    // 书多时显示滑块，并停在 initialAid 指定的那本
    final many = [for (var i = 0; i < 20; i++) LibBook(aid: 'm$i', title: '书 $i', img: '')];
    await tester.pumpWidget(shelf(many, viewKey: const ValueKey('many'), initial: 'm5'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-spine-slider')), findsOneWidget);
    expect(find.text('6 / 20'), findsOneWidget);

    // 减弱动态直接切书且 info 内无 SlideTransition
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 620), disableAnimations: true),
        child: shelf(books),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shelf-spine-dot-3')));
    await tester.pump();
    expect(find.text('败北女角太多了！'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('shelf-spine-info')), matching: find.byType(SlideTransition)), findsNothing);

    // 矮窗超屏不溢出、可滚动
    await tester.pumpWidget(shelf(books, width: 390, height: 260));
    await tester.pumpAndSettle();
    final scrollView = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scrollView.physics, isA<ClampingScrollPhysics>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShelfSpineView：内层 CoverImage 无二次圆角，开启无障碍快速切书语义稳定', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final many = [for (var i = 0; i < 30; i++) LibBook(aid: 's$i', title: '测试轻小说 $i', img: '')];
      await tester.pumpWidget(shelf(many, width: 1080, height: 720));
      await tester.pumpAndSettle();

      // 封面与书脊内层 CoverImage 均关闭自身 10px 圆角，避免外层小圆角露四角黑点
      final covers = tester.widgetList<CoverImage>(find.byType(CoverImage));
      expect(covers, isNotEmpty);
      for (final c in covers) {
        expect(c.borderRadius, 0);
      }

      // 连续高频点击与滑块拖动下无障碍语义树不异常、当前书语义标签同步更新
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('shelf-spine-next')));
        await tester.pump(const Duration(milliseconds: 24));
      }
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('测试轻小说 1'), findsAtLeastNWidgets(1));

      final slider = tester.widget<Slider>(find.byKey(const ValueKey('shelf-spine-slider')));
      for (final v in [10.0, 20.0, 29.0, 0.0, 14.0]) {
        slider.onChanged?.call(v);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('测试轻小说 14'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('ShelfSpineView：仅 3 本书宽屏停在中间时点击左右两侧书脊均可准确切换，出血封面无浅白底衬', (tester) async {
    tester.view.physicalSize = const Size(1080, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final three = books.take(3).toList();
    final log = <String>[];
    String? focused;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1080,
              height: 720,
              child: ShelfSpineView(
                books: three,
                initialAid: '2',
                onFocusChanged: (aid) => focused = aid,
                selected: const {},
                heroEnabled: true,
                coverOf: (b) => 'https://example.com/${b.aid}.jpg',
                badgeOf: (_) => null,
                subtitleOf: (b) => 'sub-${b.aid}',
                actionOf: (_) => (label: '继续读', cid: '101'),
                onOpen: (b) => log.add('open ${b.aid}'),
                onRead: (_, _) {},
                onToggleSelect: (b) => log.add('toggle ${b.aid}'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 封面与书脊出血图的 CoverImage 均显式指定书脊底色，不再落回浅白 surfaceContainer
    for (final c in tester.widgetList<CoverImage>(find.byType(CoverImage))) {
      expect(c.backgroundColor, isNotNull);
    }

    final stage = tester.getRect(find.byKey(const ValueKey('shelf-spine-stage')));
    final m = ShelfSpineLayout.metrics(1080, 720 - ShelfSpineLayout.infoHeight(1.0));

    // 点左侧第 1 本书脊（位于 PageView 窄页范围之外的 padEnds 区）-> 切到第 1 本
    final leftSpineX = stage.center.dx + ShelfSpineLayout.centerX(-1, m.ws, m.d, m.gap);
    await tester.tapAt(Offset(leftSpineX, stage.center.dy));
    await tester.pumpAndSettle();
    expect(focused, '1');
    expect(find.text('狼与香辛料'), findsOneWidget);

    // 停在第 1 本时点封面左外侧边缘也能正常打开，不会落空
    await tester.tapAt(Offset(stage.center.dx - m.d * 0.4, stage.center.dy));
    expect(log, ['open 1']);

    // 点右侧最外侧第 3 本书脊（r = +2）-> 直接切到第 3 本
    final thirdSpineX = stage.center.dx + ShelfSpineLayout.centerX(2, m.ws, m.d, m.gap);
    await tester.tapAt(Offset(thirdSpineX, stage.center.dy));
    await tester.pumpAndSettle();
    expect(focused, '3');
  });

  testWidgets('ShelfSpineView：竖排书脊标题改用单层 CustomPaint 绘制且正常兼容中英混合与超长省略', (tester) async {
    await tester.pumpWidget(shelf(books, width: 1080, height: 720));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 书脊里不再为每个字符构建独立 Text（除底部信息栏与徽章外，书脊标题走 CustomPaint）
    expect(find.descendant(of: find.byKey(const ValueKey('shelf-spine-stage')), matching: find.byType(CustomPaint)), findsAtLeastNWidgets(3));
  });
}
