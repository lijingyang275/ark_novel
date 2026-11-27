import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/paginator.dart';
import 'package:ark_novel/next/reader/reader_body.dart' show readerStrut;
import 'package:ark_novel/next/reader/reader_page.dart' show formatChapter, halfWidth;

void main() {
  const style = TextStyle(fontSize: 16, height: 1.5);
  final text = List.generate(300, (i) => '这是第$i行文字，用来测试分页。').join('\n');

  test('切成多页，起点递增且从 0 开始', () {
    final starts = paginate(text, style, const Size(200, 300));
    expect(starts.first, 0);
    expect(starts.length, greaterThan(5));
    for (var i = 1; i < starts.length; i++) {
      expect(starts[i], greaterThan(starts[i - 1]));
    }
    expect(starts.last, lessThan(text.length));
  });

  test('页面更大页数更少', () {
    final small = paginate(text, style, const Size(200, 300)).length;
    final big = paginate(text, style, const Size(200, 600)).length;
    expect(big, lessThan(small));
  });

  test('偏移能找回所在页', () {
    final starts = paginate(text, style, const Size(200, 300));
    expect(pageOfOffset(starts, 0), 0);
    expect(pageOfOffset(starts, starts[3]), 3);
    expect(pageOfOffset(starts, starts[3] + 1), 3);
    expect(pageOfOffset(starts, text.length), starts.length - 1);
  });

  test('章节标题：第一页给标题让出高度，后面每页照常', () {
    final head = headingHeight('第一章 很长很长的标题', style, 200);
    expect(head, greaterThan(16 * 1.35));
    final plain = paginate(text, style, const Size(200, 300));
    final titled = paginate(text, style, const Size(200, 300), firstTop: head);
    expect(titled[1], lessThan(plain[1]));
    expect(titled.length, greaterThanOrEqualTo(plain.length));
    expect(headingHeight('  ', style, 200), 0);
  });

  test('空文本只有一页', () => expect(paginate('', style, const Size(200, 300)), [0]));

  test('章节格式化：每段两个全角空格缩进，去掉空行和多余空白', () {
    expect(formatChapter('   第一段\n\n  第二段  \n\n'), '　　第一段\n　　第二段');
    expect(formatChapter(''), '');
  });

  test('全角英文、数字转半角，长度不变；中文标点和缩进不动', () {
    const raw = '「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」的ＤＭＭＯ－ＲＰＧ，第１章！　　中文';
    expect(halfWidth(raw), '「Dive Massively」的DMMO-RPG，第1章！　　中文');
    expect(halfWidth(raw).length, raw.length);
  });

  test('固定行高：带颜色的文字所在的行和别的行一样高，每页行数和切页时算的一致', () {
    final strut = readerStrut(style);
    final plain = TextPainter(text: TextSpan(text: List.filled(80, '一二三四五六七八九十').join(), style: style), textDirection: TextDirection.ltr, strutStyle: strut)..layout(maxWidth: 200);
    final colored = TextPainter(
      text: TextSpan(style: style, children: [const TextSpan(text: '一二三四五六'), TextSpan(text: '七八九十一二三四五六七八九十', style: style.copyWith(color: const Color(0xFFE53935), backgroundColor: const Color(0x22E53935))), TextSpan(text: List.filled(60, '一二三四五六七八九十').join())]),
      textDirection: TextDirection.ltr,
      strutStyle: strut,
    )..layout(maxWidth: 200);
    final a = plain.computeLineMetrics().map((l) => l.height.toStringAsFixed(2)).toSet();
    final b = colored.computeLineMetrics().map((l) => l.height.toStringAsFixed(2)).toSet();
    expect(a, hasLength(1));
    expect(b, a);
  });

  test('pageOfOffset 二分查找覆盖边界、中间值、空列表与越界偏移', () {
    expect(pageOfOffset(const [], 0), 0);
    expect(pageOfOffset(const [0], 0), 0);
    expect(pageOfOffset(const [0], 100), 0);
    final starts = [for (var i = 0; i < 500; i++) i * 37];
    expect(pageOfOffset(starts, -10), 0);
    expect(pageOfOffset(starts, 0), 0);
    expect(pageOfOffset(starts, 36), 0);
    expect(pageOfOffset(starts, 37), 1);
    expect(pageOfOffset(starts, 38), 1);
    expect(pageOfOffset(starts, 250 * 37 - 1), 249);
    expect(pageOfOffset(starts, 250 * 37), 250);
    expect(pageOfOffset(starts, 499 * 37), 499);
    expect(pageOfOffset(starts, 999999), 499);
  });

  test('超长章节（>16000 字）分块分页与单 TextPainter 逐字符偏移完全一致', () {
    List<int> referencePaginate(String t, TextStyle s, Size sz, {StrutStyle? strut, double firstTop = 0}) {
      final p = TextPainter(text: TextSpan(text: t, style: s), textDirection: TextDirection.ltr, strutStyle: strut)..layout(maxWidth: sz.width);
      final starts = <int>[0];
      var pageTop = -firstTop;
      for (final line in p.computeLineMetrics()) {
        final bottom = line.baseline + line.descent;
        if (bottom - pageTop > sz.height && line.baseline - line.ascent > pageTop) {
          pageTop = line.baseline - line.ascent;
          final offset = p.getPositionForOffset(Offset(0, pageTop + line.height / 2)).offset;
          if (offset > starts.last) starts.add(offset);
        }
      }
      p.dispose();
      return starts;
    }

    final strut = readerStrut(style);
    final head = headingHeight('终章 漫长的旅途', style, 280);
    // 含单换行、连续空行、中英混排、标点与超过 22000 字的真实长章结构
    final longText = List.generate(
      420,
      (i) => i % 15 == 0
          ? ''
          : '　　第$i段：在漫长的夜色里，Hero-0$i 穿过石阶与长廊，回望身后的灯火与远方的山谷，轻声说道「明天一定会抵达终点」。',
    ).join('\n');
    expect(longText.length, greaterThan(16000));

    final actual = paginate(longText, style, const Size(280, 420), strut: strut, firstTop: head);
    final expected = referencePaginate(longText, style, const Size(280, 420), strut: strut, firstTop: head);
    expect(actual, equals(expected));

    // 不带 strut、末尾带换行的长章同样逐偏移一致
    final withTrailingNewline = '$longText\n';
    expect(
      paginate(withTrailingNewline, style, const Size(240, 360)),
      equals(referencePaginate(withTrailingNewline, style, const Size(240, 360))),
    );

    // 极端场景：超长单段（无任何换行符）不吞字、不重叠且与参考实现一致
    final megaPara = List.filled(2000, '轻小说长段落排版测试').join();
    expect(megaPara.length, greaterThan(16000));
    expect(
      paginate(megaPara, style, const Size(260, 380), strut: strut),
      equals(referencePaginate(megaPara, style, const Size(260, 380), strut: strut)),
    );
  });

  test('段间距分页短单行快路径：26 组多样样本与逐段 TextPainter 参考实现 100% 逐元素一致', () {
    List<int> referencePaginateParagraphs(
      String text,
      TextStyle style,
      Size size, {
      StrutStyle? strut,
      double firstTop = 0,
      required double paragraphSpacing,
    }) {
      if (text.isEmpty) return [0];
      final starts = <int>[0];
      var pageTop = -firstTop;
      var yOffset = 0.0;
      var pStart = 0;
      final len = text.length;
      while (pStart < len) {
        final nl = text.indexOf('\n', pStart);
        final pEnd = nl < 0 ? len : nl;
        final para = text.substring(pStart, pEnd);
        final painter = TextPainter(
          text: TextSpan(text: para.isEmpty ? ' ' : para, style: style),
          textDirection: TextDirection.ltr,
          strutStyle: strut,
        )..layout(maxWidth: size.width);
        final lines = painter.computeLineMetrics();
        for (final line in lines) {
          final top = yOffset + line.baseline - line.ascent;
          final bottom = yOffset + line.baseline + line.descent;
          if (bottom - pageTop > size.height && top > pageTop) {
            pageTop = top;
            final localOffset = para.isEmpty ? 0 : painter.getPositionForOffset(Offset(0, (line.baseline - line.ascent) + line.height / 2)).offset;
            final offset = pStart + localOffset;
            if (offset > starts.last) starts.add(offset);
          }
        }
        if (lines.isNotEmpty) {
          yOffset += lines.last.baseline + lines.last.descent;
        } else if (painter.height > 0) {
          yOffset += painter.height;
        }
        painter.dispose();
        if (nl < 0) break;
        yOffset += paragraphSpacing;
        pStart = nl + 1;
      }
      return starts;
    }

    final dialogue = List.generate(80, (i) => i.isEven ? '　　「好。」' : '　　「嗯，我知道了！」').join('\n');
    final mixedLen = List.generate(
      60,
      (i) => i % 3 == 0
          ? '　　「走吧。」'
          : (i % 3 == 1
                ? '　　第$i段：在漫长的夜色里，Hero-0$i 穿过石阶与长廊，回望身后的灯火与山谷，轻声说道「明天见」。'
                : '　　短句 $i。'),
    ).join('\n');
    final cjkEngMix = List.generate(50, (i) => '　　Chapter $i: 勇者 Lv.${i + 1} HP=100% [OK]').join('\n');
    final fullwidthPunct = List.generate(50, (i) => '　　「……！？——『测试』」').join('\n');
    final withEmpties = List.generate(60, (i) => i % 4 == 0 ? '' : '　　第$i行短句').join('\n');
    final leadingTrailingNl = '\n\n${List.generate(40, (i) => '　　段落$i').join('\n')}\n\n';
    final japaneseKana = List.generate(45, (i) => '　　「ありがとう！カタカナ$i」').join('\n');
    final asciiSymbols = List.generate(50, (i) => '  (a+b)*c = ${i * 3} / [x-y]').join('\n');
    final withEmoji = List.generate(40, (i) => i % 3 == 0 ? '　　微笑😀第$i段' : '　　普通短段$i').join('\n');
    final withTabs = List.generate(40, (i) => i % 3 == 0 ? '　　甲\t乙\t$i' : '　　普通$i').join('\n');
    final withRtl = List.generate(35, (i) => i % 4 == 0 ? '　　مرحبا $i' : '　　你好$i').join('\n');
    final boundaryWidths = List.generate(50, (i) => '　　${'字' * (5 + (i % 15))}').join('\n');
    final singleChars = List.generate(90, (i) => '一二三四五六七八九十'[i % 10]).join('\n');

    final cases = <({String name, String text, TextStyle style, Size size, double spacing, double firstTop, bool useStrut})>[
      (name: '1.纯短对话-常规屏', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(340, 520), spacing: 12, firstTop: 0, useStrut: true),
      (name: '2.纯短对话-宽屏', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(520, 600), spacing: 16, firstTop: 0, useStrut: true),
      (name: '3.长短混排-常规', text: mixedLen, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(320, 480), spacing: 10, firstTop: 0, useStrut: true),
      (name: '4.长短混排-窄屏', text: mixedLen, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(140, 320), spacing: 8, firstTop: 0, useStrut: true),
      (name: '5.长短混排-带标题', text: mixedLen, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(320, 480), spacing: 14, firstTop: headingHeight('第一章 序幕', const TextStyle(fontSize: 18, height: 1.8), 320), useStrut: true),
      (name: '6.中英混排-小字号', text: cjkEngMix, style: const TextStyle(fontSize: 14, height: 1.3), size: const Size(360, 400), spacing: 6, firstTop: 0, useStrut: true),
      (name: '7.中英混排-大字号', text: cjkEngMix, style: const TextStyle(fontSize: 28, height: 2.2), size: const Size(420, 640), spacing: 20, firstTop: 0, useStrut: true),
      (name: '8.全角标点密集', text: fullwidthPunct, style: const TextStyle(fontSize: 20, height: 1.7), size: const Size(360, 450), spacing: 12, firstTop: 0, useStrut: true),
      (name: '9.含连续空段', text: withEmpties, style: const TextStyle(fontSize: 16, height: 1.6), size: const Size(300, 360), spacing: 10, firstTop: 0, useStrut: true),
      (name: '10.首尾多换行', text: leadingTrailingNl, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(320, 400), spacing: 12, firstTop: 0, useStrut: true),
      (name: '11.日文假名混排', text: japaneseKana, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(380, 440), spacing: 12, firstTop: 0, useStrut: true),
      (name: '12.ASCII符号数字', text: asciiSymbols, style: const TextStyle(fontSize: 16, height: 1.5), size: const Size(420, 360), spacing: 8, firstTop: 0, useStrut: true),
      (name: '13.含代理对Emoji回退', text: withEmoji, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(340, 420), spacing: 10, firstTop: 0, useStrut: true),
      (name: '14.含制表符回退', text: withTabs, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(340, 420), spacing: 10, firstTop: 0, useStrut: true),
      (name: '15.含RTL阿语回退', text: withRtl, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(340, 420), spacing: 10, firstTop: 0, useStrut: true),
      (name: '16.正字间距2.5', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8, letterSpacing: 2.5), size: const Size(340, 480), spacing: 12, firstTop: 0, useStrut: true),
      (name: '17.负字间距-0.5', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8, letterSpacing: -0.5), size: const Size(340, 480), spacing: 12, firstTop: 0, useStrut: true),
      (name: '18.大段间距24', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(360, 420), spacing: 24, firstTop: 0, useStrut: true),
      (name: '19.小段间距4', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(360, 420), spacing: 4, firstTop: 0, useStrut: true),
      (name: '20.临界宽度段', text: boundaryWidths, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(260, 420), spacing: 10, firstTop: 0, useStrut: true),
      (name: '21.单字短段', text: singleChars, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(240, 300), spacing: 12, firstTop: 0, useStrut: true),
      (name: '22.超高单页', text: dialogue, style: const TextStyle(fontSize: 16, height: 1.5), size: const Size(400, 10000), spacing: 8, firstTop: 0, useStrut: true),
      (name: '23.极矮多页', text: dialogue, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(320, 90), spacing: 12, firstTop: 0, useStrut: true),
      (name: '24.无strut关闭快路径', text: mixedLen, style: const TextStyle(fontSize: 18, height: 1.8), size: const Size(320, 420), spacing: 12, firstTop: 0, useStrut: false),
      (name: '25.大标题+正字间距', text: mixedLen, style: const TextStyle(fontSize: 22, height: 2.0, letterSpacing: 1.5), size: const Size(420, 560), spacing: 16, firstTop: headingHeight('终章 很长很长的章节标题测试', const TextStyle(fontSize: 22, height: 2.0, letterSpacing: 1.5), 420), useStrut: true),
      (name: '26.双页窄列高行距', text: boundaryWidths, style: const TextStyle(fontSize: 20, height: 2.3), size: const Size(220, 500), spacing: 14, firstTop: 0, useStrut: true),
    ];

    for (final c in cases) {
      final strut = c.useStrut ? readerStrut(c.style) : null;
      final actual = paginate(c.text, c.style, c.size, strut: strut, firstTop: c.firstTop, paragraphSpacing: c.spacing);
      final expected = referencePaginateParagraphs(c.text, c.style, c.size, strut: strut, firstTop: c.firstTop, paragraphSpacing: c.spacing);
      expect(actual, equals(expected), reason: '样本不一致：${c.name}');
    }
  });

  test('PaginateCache 共享 LRU 缓存（上限 12 章）与 headingHeightCached、clear', () {
    PaginateCache.clear();
    addTearDown(PaginateCache.clear);
    const s = TextStyle(fontSize: 18, height: 1.8, color: Color(0xFF111111));
    const sAltColor = TextStyle(fontSize: 18, height: 1.8, color: Color(0xFFEEEEEE));
    const sz = Size(300, 420);

    final chapters = [for (var i = 0; i < 15; i++) List.generate(40, (j) => '　　第$i章第$j段正文内容测试。').join('\n')];

    // 换文字颜色不失效分页缓存（内部归一化 color）
    final first = PaginateCache.paginateCached(text: chapters[0], style: s, size: sz, title: '第0章');
    final hitDiffColor = PaginateCache.peek(text: chapters[0], style: sAltColor, size: sz, title: '第0章');
    expect(identical(first, hitDiffColor), isTrue);

    // 写入 14 章超过上限 12：最早未访问的第 1 章会被淘汰，但刚被访问过的第 0 章按 LRU 保留策略验证
    for (var i = 1; i < 14; i++) {
      PaginateCache.paginateCached(text: chapters[i], style: s, size: sz, title: '第$i章');
    }
    expect(PaginateCache.peek(text: chapters[0], style: s, size: sz, title: '第0章'), isNull);
    expect(PaginateCache.peek(text: chapters[13], style: s, size: sz, title: '第13章'), isNotNull);

    final h1 = PaginateCache.headingHeightCached('第一章', s, 300);
    final h2 = PaginateCache.headingHeightCached('第一章', sAltColor, 300);
    expect(h1, h2);
    expect(h1, greaterThan(0));

    PaginateCache.clear();
    expect(PaginateCache.peek(text: chapters[13], style: s, size: sz, title: '第13章'), isNull);
  });
}

