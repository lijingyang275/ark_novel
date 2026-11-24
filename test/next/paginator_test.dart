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
}

