import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/reader_body.dart';
import 'package:ark_novel/next/widgets.dart';

void main() {
  flowTests();

  Future<void> pump(WidgetTester t, {required double width, required bool dual, required ReaderNav nav, required List<int> offsets}) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final text = List.generate(400, (i) => '　　这是第$i段，用来凑够很多页的正文内容。').join('\n');
    final style = const TextStyle(fontSize: 18, height: 1.8);
    final c = Chapter(text: text, images: const [], marks: const []);
    await t.pumpWidget(
      MaterialApp(
        home: PagedBody(
          chapter: c,
          spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
          style: style,
          margin: 20,
          title: '标题',
          curl: false,
          dual: dual,
          background: Colors.white,
          color: Colors.black,
          startOffset: 0,
          onOffset: offsets.add,
          onEnd: () {},
          onPrev: null,
          onNext: null,
          wrap: (w) => w,
          onTapZone: () {},
          onMark: (_) {},
          hasSelection: () => false,
          nav: nav,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('宽屏双页：一屏两页，键盘翻页一次前进一屏', (t) async {
    final nav = ReaderNav();
    final offsets = <int>[];
    await pump(t, width: 1200, dual: true, nav: nav, offsets: offsets);
    // 页脚一屏一份：页码进度只在右页
    expect(find.textContaining('1/'), findsNothing);
    expect(find.textContaining('2/'), findsOneWidget);
    nav.next!();
    await t.pumpAndSettle();
    expect(find.textContaining('3/'), findsNothing);
    expect(find.textContaining('4/'), findsOneWidget);
    // 页眉的章节名只在左页
    expect(find.text('标题'), findsOneWidget);
    expect(t.getTopLeft(find.text('标题')).dx, lessThan(600));
    expect(t.getTopLeft(find.textContaining('4/')).dx, greaterThan(600));
    expect(offsets.last, greaterThan(0));
    nav.prev!();
    await t.pumpAndSettle();
    expect(find.textContaining('2/'), findsOneWidget);
  });

  Widget body(Chapter c, int start, List<int> offsets) {
    const style = TextStyle(fontSize: 18, height: 1.8);
    return MaterialApp(
      home: PagedBody(
        chapter: c,
        spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
        style: style,
        margin: 20,
        title: '标题',
        curl: false,
        dual: false,
        background: Colors.white,
        color: Colors.black,
        startOffset: start,
        onOffset: offsets.add,
        onEnd: () {},
        onPrev: null,
        onNext: null,
        wrap: (w) => w,
        onTapZone: () {},
        onMark: (_) {},
        hasSelection: () => false,
        nav: ReaderNav(),
      ),
    );
  }

  testWidgets('版面变了（转屏、改窗口）按原来的位置重新分页：来回改不会往前漂，也不改进度', (t) async {
    addTearDown(t.view.reset);
    t.view.devicePixelRatio = 1;
    final text = List.generate(400, (i) => '　　这是第$i段，用来凑够很多页的正文内容。').join('\n');
    final c = Chapter(text: text, images: const [], marks: const []);
    final start = text.indexOf('这是第200段');
    final offsets = <int>[];
    for (final width in [600.0, 700.0, 600.0, 700.0, 600.0, 700.0]) {
      t.view.physicalSize = Size(width, 800);
      await t.pumpWidget(body(c, start, offsets));
      await t.pumpAndSettle();
      expect(find.textContaining('这是第200段', findRichText: true), findsWidgets, reason: '宽 $width');
    }
    expect(offsets, isEmpty);
  });

  testWidgets('往回翻进来落在最后一页：报出那一页的实际位置', (t) async {
    addTearDown(t.view.reset);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(600, 800);
    final text = List.generate(400, (i) => '　　这是第$i段，用来凑够很多页的正文内容。').join('\n');
    final offsets = <int>[];
    await t.pumpWidget(body(Chapter(text: text, images: const [], marks: const []), kToEnd, offsets));
    await t.pumpAndSettle();
    expect(offsets, hasLength(1));
    expect(offsets.single, inExclusiveRange(text.length ~/ 2, text.length));
  });

  testWidgets('窄屏或关闭双页时仍是单页', (t) async {
    await pump(t, width: 600, dual: true, nav: ReaderNav(), offsets: []);
    expect(find.textContaining('2/'), findsNothing);
    await pump(t, width: 1200, dual: false, nav: ReaderNav(), offsets: []);
    expect(find.textContaining('2/'), findsNothing);
  });
}

/// 跨章连续翻页：相邻章节接在同一条页序里。
void flowTests() {
  final style = const TextStyle(fontSize: 18, height: 1.8);
  // 一章 [paras] 段，段数决定页数
  Chapter chapter(String tag, int paras) => Chapter(text: List.generate(paras, (i) => '　　$tag第$i段，用来凑够很多页的正文内容。').join('\n'), images: const [], marks: const []);
  ChapterPeek peek(Chapter c, String title, {String? cover}) => ChapterPeek(chapter: c, title: title, cover: cover, spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style));

  Future<(ReaderNav, List<(int, int, int)>, List<int>)> pump(WidgetTester t, Chapter c, {ChapterPeek? prev, ChapterPeek? next, int lead = 0, int start = 0, double width = 1200, bool curl = true, String? cover}) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final nav = ReaderNav();
    final turns = <(int, int, int)>[];
    final fallback = <int>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [imageBytesProvider.overrideWith((ref, url) => Future.error('test'))],
        child: MaterialApp(
        home: PagedBody(
          key: UniqueKey(),
          chapter: c,
          spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
          style: style,
          margin: 20,
          title: '本章',
          curl: curl,
          dual: true,
          background: Colors.white,
          color: Colors.black,
          startOffset: start,
          onOffset: (_) {},
          onEnd: () {},
          onPrev: () => fallback.add(-1),
          onNext: () => fallback.add(1),
          wrap: (w) => w,
          onTapZone: () {},
          onMark: (_) {},
          hasSelection: () => false,
          nav: nav,
          prevChapter: prev,
          nextChapter: next,
          lead: lead,
          volumeCover: cover,
          onTurn: (d, l, o) => turns.add((d, l, o)),
        ),
      )),
    );
    await t.pumpAndSettle();
    return (nav, turns, fallback);
  }

  // 翻到本章最后一屏，返回屏数
  Future<int> toEnd(WidgetTester t, ReaderNav nav) async {
    final (_, units) = nav.page.value;
    nav.toPage!(units - 1);
    await t.pumpAndSettle();
    return units;
  }

  test('相邻章节的留白算法：奇数页才接', () {
    expect(adjacentLead(0, 3), 1);
    expect(adjacentLead(0, 4), 0);
    expect(adjacentLead(1, 3), 0);
    expect(adjacentLead(1, 4), 1);
  });

  for (final curl in [true, false]) {
    testWidgets('没有下一章时还是走原来的换章（curl=$curl）', (t) async {
      final (nav, turns, fallback) = await pump(t, chapter('甲', 60), curl: curl);
      await toEnd(t, nav);
      nav.next!();
      await t.pumpAndSettle();
      expect(turns, isEmpty);
      expect(fallback, [1]);
    });

    testWidgets('有下一章时翻过去再换章，落点不是右页空白（curl=$curl）', (t) async {
      final next = chapter('乙', 60);
      final (nav, turns, fallback) = await pump(t, chapter('甲', 60), next: peek(next, '下章'), curl: curl);
      await toEnd(t, nav);
      nav.next!();
      await t.pumpAndSettle();
      expect(fallback, isEmpty);
      expect(turns.single.$1, 1);
    });

    testWidgets('有上一章时往回翻也接得上（curl=$curl）', (t) async {
      final prev = chapter('乙', 60);
      final (nav, turns, fallback) = await pump(t, chapter('甲', 60), prev: peek(prev, '上章'), curl: curl);
      nav.prev!();
      await t.pumpAndSettle();
      expect(fallback, isEmpty);
      expect(turns.single.$1, -1);
      expect(turns.single.$3, greaterThan(0)); // 落在上一章靠后的位置
    });
  }

  testWidgets('奇数页的章：最后一屏右页接下一章第一页，翻过去 lead 为 1、落在下一章第二屏', (t) async {
    // 找一个单页数为奇数的段数
    Chapter? odd;
    for (var n = 40; n < 80 && odd == null; n++) {
      final c = chapter('甲', n);
      final (nav, _, _) = await pump(t, c);
      final (_, units) = nav.page.value;
      await toEnd(t, nav);
      if (find.textContaining('${units * 2 - 1}/${units * 2 - 1}').evaluate().isNotEmpty) odd = c;
    }
    expect(odd, isNotNull);
    final next = chapter('乙', 60);
    final (nav, turns, _) = await pump(t, odd!, next: peek(next, '下章'));
    await toEnd(t, nav);
    expect(find.textContaining('乙第0段'), findsOneWidget); // 右页接上了
    nav.next!();
    await t.pumpAndSettle();
    expect(turns.single.$1, 1);
    expect(turns.single.$2, 1);
    expect(turns.single.$3, greaterThan(0));

    // 新的一章按这个落点打开：停在第二屏，第一屏左页是上一章最后一页；再往回翻到上一章时不重复那一屏
    final (_, lead, offset) = turns.single;
    final (nav2, turns2, _) = await pump(t, next, prev: peek(odd, '上章'), lead: lead, start: offset);
    expect(nav2.page.value.$1, 1);
    nav2.prev!();
    await t.pumpAndSettle();
    expect(nav2.page.value.$1, 0);
    expect(find.textContaining('乙第0段'), findsOneWidget);
    expect(find.textContaining('甲'), findsWidgets);
    nav2.prev!();
    await t.pumpAndSettle();
    expect(turns2.single.$1, -1);
    expect(turns2.single.$2, 0); // 上一章从左页开始，最后一页仍在左页
    final (nav3, _, _) = await pump(t, odd, next: peek(next, '下章'), lead: turns2.single.$2, start: turns2.single.$3);
    final (page3, units3) = nav3.page.value;
    expect(page3, units3 - 2);
  });

  testWidgets('卷首双页：左页封面、右页第一页；单页不放封面', (t) async {
    final c = chapter('甲', 60);
    await pump(t, c, cover: 'cover.png');
    expect(find.byType(NetImage), findsOneWidget);
    expect(find.textContaining('1/'), findsOneWidget);
    expect(find.textContaining('2/'), findsNothing);
    await pump(t, c, cover: 'cover.png', width: 600);
    expect(find.byType(NetImage), findsNothing);
  });

  testWidgets('双页：页面撑满高度，短页不会竖着居中', (t) async {
    t.view.physicalSize = const Size(1265, 832);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = chapter('甲', 3);
    await t.pumpWidget(
      MaterialApp(
        home: PagedBody(
          chapter: c,
          spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
          style: style,
          margin: 20,
          title: '本章',
          curl: true,
          cover: true,
          dual: true,
          background: Colors.white,
          color: Colors.black,
          startOffset: 0,
          onOffset: (_) {},
          onEnd: () {},
          onPrev: null,
          onNext: null,
          wrap: (w) => SelectionArea(child: w),
          onTapZone: () {},
          onMark: (_) {},
          hasSelection: () => false,
        ),
      ),
    );
    await t.pumpAndSettle();
    // 短章只占一点高度：不撑满的话这一页会竖着居中，和另一页错开
    expect(t.getTopLeft(find.textContaining('甲第0段')).dy, lessThan(200));
    expect(find.byType(ClipPath), findsNothing);
  });

  testWidgets('连点翻页不会触发双击选词，翻页也不丢', (t) async {
    t.view.physicalSize = const Size(600, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = chapter('甲', 200);
    final nav = ReaderNav();
    final selected = <String>[];
    await t.pumpWidget(
      MaterialApp(
        home: PagedBody(
          chapter: c,
          spanOf: (a, b) => TextSpan(text: c.text.substring(a, b), style: style),
          style: style,
          margin: 20,
          title: '本章',
          curl: true,
          cover: true,
          background: Colors.white,
          color: Colors.black,
          startOffset: 0,
          onOffset: (_) {},
          onEnd: () {},
          onPrev: null,
          onNext: null,
          wrap: (w) => SelectionArea(onSelectionChanged: (s) => selected.add(s?.plainText ?? ''), child: w),
          onTapZone: () {},
          onMark: (_) {},
          hasSelection: () => selected.isNotEmpty && selected.last.isNotEmpty,
          nav: nav,
        ),
      ),
    );
    await t.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await t.tapAt(const Offset(500, 400));
      await t.pump(const Duration(milliseconds: 120));
    }
    await t.pumpAndSettle();
    expect(selected.where((s) => s.isNotEmpty), isEmpty);
    expect(nav.page.value.$1, 4);
  });
}
