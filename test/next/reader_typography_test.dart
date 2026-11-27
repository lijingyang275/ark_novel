import 'package:ark_novel/next/highlights.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/reader/paginator.dart';
import 'package:ark_novel/next/reader/reader_body.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/settings.dart';
import 'package:ark_novel/next/sync_validation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paginate with paragraphSpacing produces more pages and strictly increasing offsets', (tester) async {
    final paragraphs = List.generate(30, (i) => '　　这是第${i + 1}段正文内容，用来测试段间距排版与分页偏移准确性。');
    final text = paragraphs.join('\n');
    const style = TextStyle(fontSize: 18, height: 1.8);
    const size = Size(320, 420);

    final compact = paginate(text, style, size, strut: readerStrut(style));
    final spaced = paginate(text, style, size, strut: readerStrut(style), paragraphSpacing: 16);

    expect(compact.first, 0);
    expect(spaced.first, 0);
    expect(spaced.length, greaterThan(compact.length));
    for (var i = 1; i < spaced.length; i++) {
      expect(spaced[i], greaterThan(spaced[i - 1]));
      expect(spaced[i], lessThan(text.length));
    }
  });

  test('splitParagraphRanges strips trailing newline without creating phantom paragraph', () {
    const text = '第一段\n第二段\n第三段';
    expect(splitParagraphRanges(text, 0, 8), [(0, 3), (4, 7)]);
    expect(splitParagraphRanges(text, 0, text.length), [(0, 3), (4, 7), (8, 11)]);
  });

  test('buildSpan uses binary search for marks and merges user highlights without changing text', () {
    const text = '　　爱丽丝走在阳光明媚的街道上，看到了白兔先生。';
    const rule = ReplaceRule(pattern: '爱丽丝', replacement: '', kind: RuleKind.highlight, color: 0xFF2E7D32, id: 'r1');
    final chapter = Chapter(
      text: text,
      images: const [],
      marks: const [Mark(2, 5, rule)],
    );
    const base = TextStyle(fontSize: 18, color: Color(0xFF2B2A27));

    // 无重叠区间走快速单 TextSpan 路径
    final plain = buildSpan(chapter, 6, 12, base, const {}) as TextSpan;
    expect(plain.children, isNull);
    expect(plain.text, text.substring(6, 12));

    // 规则高亮 + 用户自由划线 + 朗读高亮叠加时，拼接原文零丢字、零漂移
    final userHl = [
      HighlightEntry(
        id: 'hl_1',
        aid: '1',
        cid: '1',
        chapter: 'c1',
        start: 4,
        end: 12,
        quote: text.substring(4, 12),
        note: '摘录',
        color: 2,
        at: 1,
      ),
    ];
    final span = buildSpan(chapter, 0, text.length, base, {'r1'}, (10, 16), Colors.amber, userHl) as TextSpan;
    expect(span.toPlainText(), text);
    expect(span.children, isNotEmpty);
  });

  test('ReaderPrefs letterSpacing & paragraphSpacing validation and readerStyle wiring', () {
    const prefs = ReaderPrefs(letterSpacing: 1.5, paragraphSpacing: 12);
    final style = readerStyle(prefs, Colors.black);
    expect(style.letterSpacing, 1.5);
    expect(syncPreference('r.letterSpacing', 1.5), 1.5);
    expect(syncPreference('r.letterSpacing', 10.0), isNull);
    expect(syncPreference('r.paragraphSpacing', 12), 12.0);
    expect(syncPreference('r.paragraphSpacing', 40), isNull);
  });

  test('ImageStore pauseSr / resumeSr reference counting', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(imageStoreProvider);
    expect(store.isSrPaused, isFalse);
    store.pauseSr();
    store.pauseSr();
    expect(store.isSrPaused, isTrue);
    store.resumeSr();
    expect(store.isSrPaused, isTrue);
    store.resumeSr();
    expect(store.isSrPaused, isFalse);
  });
}
