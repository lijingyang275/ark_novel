import 'dart:async';
import 'dart:io';

import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/book_search.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/pages/book_search_sheet.dart';
import 'package:ark_novel/next/reader/reader_page.dart' show formatChapter;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

final _legacyFullWidthAlnumRe = RegExp('[０-９Ａ-Ｚａ-ｚ]');
final _legacyFullWidthJoinRe = RegExp(r'(?<=[0-9A-Za-z])[　－](?=[0-9A-Za-z])');

String _legacyHalfWidth(String s) => s
    .replaceAllMapped(_legacyFullWidthAlnumRe, (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
    .replaceAllMapped(_legacyFullWidthJoinRe, (m) => m[0] == '　' ? ' ' : '-');

String _legacyFormatChapterText(String raw) =>
    _legacyHalfWidth(raw).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).map((l) => '　　$l').join('\n');

void main() {
  final catalogue = [
    CatVolume(
      title: '第一卷',
      chapters: [
        CatChapter(title: '序章', cid: 'c1'),
        CatChapter(title: '第一章 邂逅', cid: 'c2'),
        CatChapter(title: '第二章 未缓存', cid: 'c3'),
      ],
    ),
    CatVolume(
      title: '第二卷',
      chapters: [
        CatChapter(title: '第一章 续篇', cid: 'c4'),
      ],
    ),
  ];

  final store = <String, Content>{
    'c1': Content(text: '  序章正文。\n八奈见杏菜拿着面包跑过走廊，Alice 喊住了她。\n老八回头一笑。  ', images: []),
    'c2': Content(text: '教室里大家都在讨论败犬女主的事情。\n杏菜坐在窗边看着天空。', images: []),
    'c4': Content(text: '第二卷里，八奈见杏菜与温水和彦再次来到文艺社。\nALICE 也寄来了明信片。', images: []),
  };

  Future<Content?> loader(String aid, String cid) async => store[cid];
  bool isCached(String aid, String cid) => store.containsKey(cid);

  group('formatChapterText 与 extractSnippet 偏移准确性', () {
    test('formatChapterText 与阅读器 formatChapter 输出完全一致', () {
      const sample = '  第一段　ＡＢＣ１２３\n\n   第二段测试  \n第三段';
      expect(formatChapterText(sample), formatChapter(sample));
    });

    test('halfWidth 与 formatChapterText 在 35+ 复杂边界样本上与原正则实现 100% 逐字符一致', () {
      const samples = <String>[
        '',
        '   ',
        '\t\r\n  \n\r\n　　\u00A0\uFEFF\u2003\n',
        '纯中文无任何需要转换的段落。\n第二段也没有全角字母数字。',
        '  第一段\r\n\r\n  第二段  \r\n第三段\r\n',
        '\r\n\r\n首尾都有CRLF\r\n\r\n',
        '行内孤立CR\r不拆行\n下一行\r',
        '\r开头CR和结尾CR\r\n\t制表符\v\f\u0085\u00A0\u1680\u2000\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF正文\uFEFF',
        '０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ',
        '边界码点：\uFF0F０９\uFF1A\uFF20ＡＺ\uFF3B\uFF40ａｚ\uFF5B',
        '「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」的ＤＭＭＯ－ＲＰＧ，第１章！　　中文',
        'A　B 1　2 z　9 Ａ　Ｂ ０　ｚ A　Ｂ ０　z',
        'Ａ　Ｂ　Ｃ　１　２　３',
        'A　　B 与 Ａ　　Ｂ 连续两个全角空格不能转换',
        '中文　ABC 与 ABC　中文 与 　ABC　 边缘全角空格不转',
        'A－B－C 与 ＤＭＭＯ－ＲＰＧ 与 １－２－３',
        'A－－B 与 A　－B 与 A－　B 连续分隔符不转',
        'A—B 与 Ａ—Ｂ（全角破折号 U+2014 不转换）与 A−B（U+2212 不转换）',
        '中文－A 与 A－中文 与 －A 与 A－ 与 －',
        'A－\nB 与 A\n－B 与 A　\nB 与 A\n　B 跨行不相邻',
        'A－\r\nB 与 A\r\n－B 跨CRLF不相邻',
        '   －A   \n   A－   \n   －   ',
        '　　首行缩进ＡＢＣ　ＤＥＦ－１２３　　',
        '！＂＃＄％＆＇（）＊＋，．／：；＜＝＞？＠［＼］＾＿｀｛｜｝～',
        '😀Ａ　Ｂ🚀\n𠀀Ａ－１𠀁',
        'A\n\n\n\nB',
        '单行无换行ＡＢＣ－１２３',
        '   单行带前后空白　Ａ　Ｂ   ',
        '\n开头空行\n中间空行\n   　  \n结尾空行\n',
        'a　b－c　d－e　0－9',
        '0　0－0　A－Z　a－z',
        '「ＳＡＯ」「ＡＬＯ」「ＧＧＯ」　ＶＲＭＭＯ－ＲＰＧ　Ｌｖ．９９',
        '　　「Ｈｅｌｌｏ　Ｗｏｒｌｄ！」\r\n　　他低声念出编号　Ｘ－０１　—　最终代号。',
        '---ＡＢＣ---\n－－－ＡＢＣ－－－\n———ＡＢＣ———',
        '  \u200B零宽空格不算trim空白\u200B  \n  \u3000全角空格算trim空白\u3000  ',
        '1　2　　3－4－－5—6',
      ];

      expect(samples.length, greaterThanOrEqualTo(35));
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        final hw = halfWidth(s);
        final legacyHw = _legacyHalfWidth(s);
        expect(hw, legacyHw, reason: 'halfWidth sample #$i mismatch');
        expect(hw.length, s.length, reason: 'halfWidth length invariant sample #$i');

        final fmt = formatChapterText(s);
        final legacyFmt = _legacyFormatChapterText(s);
        expect(fmt, legacyFmt, reason: 'formatChapterText sample #$i mismatch');
      }
    });

    test('formatChapterText 对全部 65536 个 BMP 码点的 trim 判定与 Dart String.trim() 100% 一致', () {
      for (var cp = 0; cp <= 0xFFFF; cp++) {
        if (cp == 0x0A) continue; // '\n' 是行分隔符
        final ch = String.fromCharCode(cp);
        final raw = '${ch}X$ch';
        expect(formatChapterText(raw), _legacyFormatChapterText(raw), reason: 'codeUnit 0x${cp.toRadixString(16)}');
      }
    });

    test('extractSnippet：高亮范围精确对应匹配文本且正确处理首尾省略号与换行折叠', () {
      final text = formatChapterText('前文一段非常长的铺垫内容用来测试前置省略号的出现位置。\n八奈见杏菜走进教室，后面还有一大段内容用于测试后置省略号。');
      final idx = text.indexOf('八奈见杏菜');
      expect(idx, greaterThan(0));

      final snip = extractSnippet(text, idx, '八奈见杏菜'.length, contextBefore: 12, contextAfter: 12);
      expect(snip.snippet.startsWith('…'), isTrue);
      expect(snip.snippet.endsWith('…'), isTrue);
      expect(snip.snippet.substring(snip.highlightStart, snip.highlightEnd), '八奈见杏菜');
      expect(snip.snippet, isNot(contains('\n')));
    });
  });

  group('BookSearchEngine 单章与全书检索', () {
    test('单章检索（直接传入 currentChapterText，忽略大小写，精确返回偏移）', () async {
      final formatted = formatChapterText(store['c1']!.text);
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: 'alice',
        scope: BookSearchScope.currentChapter,
        currentCid: 'c1',
        currentChapterText: formatted,
        applyReplaceRules: false,
      );

      expect(res.error, isNull);
      expect(res.scannedChapters, 1);
      expect(res.totalChapters, 1);
      expect(res.totalHits, 1);
      final hit = res.hits.single;
      expect(hit.volTitle, '第一卷');
      expect(hit.chapterTitle, '序章');
      expect(formatted.substring(hit.offset, hit.offset + hit.matchLength), 'Alice');
      expect(hit.snippet.substring(hit.highlightStart, hit.highlightEnd), 'Alice');
    });

    test('全书多章已缓存检索：跳过未缓存章节，按卷/章顺序返回命中与覆盖率统计', () async {
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: 'alice',
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        chapterLoader: loader,
        isCached: isCached,
      );

      expect(res.scannedChapters, 3); // 4 章中 3 章已缓存
      expect(res.totalChapters, 4);
      expect(res.totalHits, 2);
      expect(res.hits.map((h) => h.cid).toList(), ['c1', 'c4']);
      // 验证偏移与格式化正文完全对齐
      final c4Text = formatChapterText(store['c4']!.text);
      expect(c4Text.substring(res.hits[1].offset, res.hits[1].offset + res.hits[1].matchLength), 'ALICE');
    });

    test('正则与多别名 OR 检索（支持人物卡一键搜索全书出场）', () async {
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: '八奈见杏菜|杏菜|老八',
        isRegex: true,
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        chapterLoader: loader,
        isCached: isCached,
      );

      expect(res.error, isNull);
      expect(res.totalHits, 4);
      expect(res.hits.map((h) => h.snippet.substring(h.highlightStart, h.highlightEnd)).toList(), ['八奈见杏菜', '老八', '杏菜', '八奈见杏菜']);

      // 非法正则返回错误说明而不是抛异常
      final bad = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: '[未闭合',
        isRegex: true,
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        chapterLoader: loader,
        isCached: isCached,
      );
      expect(bad.error, isNotNull);
      expect(bad.hits, isEmpty);

      // orTerms 多词 OR 检索
      final byTerms = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: '',
        orTerms: const ['杏菜', '老八'],
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        chapterLoader: loader,
        isCached: isCached,
      );
      expect(byTerms.totalHits, 4);
    });

    test('正文繁体开启时支持简体关键词双匹配繁体正文', () async {
      final hant = Hant.parse('败\t敗\n犬\t犬\n见\t見\n', '');
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: '败犬',
        scope: BookSearchScope.allCached,
        hant: hant,
        applyReplaceRules: false,
        chapterLoader: loader,
        isCached: isCached,
      );

      expect(res.totalHits, 1);
      expect(res.hits.single.cid, 'c2');
      expect(res.hits.single.snippet.substring(res.hits.single.highlightStart, res.hits.single.highlightEnd), '敗犬');
    });

    test('支持中途取消检索', () async {
      final token = BookSearchCancelToken();
      var loads = 0;
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: catalogue,
        query: '杏菜',
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        cancelToken: token,
        isCached: isCached,
        chapterLoader: (aid, cid) async {
          loads++;
          if (loads == 2) token.cancel();
          return store[cid];
        },
      );

      expect(res.cancelled, isTrue);
      expect(res.scannedChapters, lessThan(3));
    });

    test('全书模式复用 currentChapterText，且达到 maxHits 后早停避免扫描剩余章节', () async {
      var loadedCids = <String>[];
      final manyVols = [
        CatVolume(
          title: '第一卷',
          chapters: [for (var i = 1; i <= 10; i++) CatChapter(title: '第 $i 章', cid: 'm$i')],
        ),
      ];
      final res = await BookSearchEngine.search(
        aid: '1',
        catalogue: manyVols,
        query: '测试',
        scope: BookSearchScope.allCached,
        currentCid: 'm1',
        currentChapterText: formatChapterText('测试 测试 测试'),
        maxHits: 5,
        maxHitsPerChapter: 50,
        applyReplaceRules: false,
        isCached: (_, _) => true,
        chapterLoader: (_, cid) async {
          loadedCids.add(cid);
          return Content(text: '测试 测试 测试', images: const []);
        },
      );

      expect(loadedCids, isNot(contains('m1'))); // 当前章直接复用 currentChapterText
      expect(res.truncated, isTrue);
      expect(res.hits.length, 5);
      expect(res.scannedChapters, lessThan(10)); // 命中满额后提前早停
    });

    test('后台 Worker 分批增量回报 newHits，拼接后与最终结果完全一致且无重复', () async {
      final manyVols = [
        CatVolume(
          title: '第一卷',
          chapters: [for (var i = 1; i <= 25; i++) CatChapter(title: '第 $i 章', cid: 'b$i')],
        ),
      ];
      final events = <BookSearchProgress>[];
      final accumulated = <BookSearchHit>[];

      final res = await BookSearchEngine.search(
        aid: '2',
        catalogue: manyVols,
        query: '星光',
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
        yieldEvery: 4,
        isCached: (_, _) => true,
        chapterLoader: (_, cid) async => Content(text: '第 $cid 章：星光洒落在窗台，远方也有星光。', images: const []),
        onProgress: (p) {
          events.add(p);
          accumulated.addAll(p.newHits);
        },
      );

      expect(res.error, isNull);
      expect(res.cancelled, isFalse);
      expect(res.scannedChapters, 25);
      expect(res.totalHits, 50);
      expect(res.hits.length, 50);
      expect(events.length, greaterThan(3));
      // 每次回调的 scannedChapters 单调递增，newHits 严格不重复且拼接等于最终 hits
      for (var i = 1; i < events.length; i++) {
        expect(events[i].scannedChapters, greaterThanOrEqualTo(events[i - 1].scannedChapters));
      }
      expect(accumulated.length, res.hits.length);
      for (var i = 0; i < res.hits.length; i++) {
        expect(accumulated[i].cid, res.hits[i].cid);
        expect(accumulated[i].offset, res.hits[i].offset);
        expect(accumulated[i].snippet, res.hits[i].snippet);
      }
    });

    test('灾难性回溯正则在后台 Isolate 中可被 cancelToken 立即强杀终止', () async {
      final token = BookSearchCancelToken();
      final evilText = formatChapterText('${'a' * 30}!');
      final sw = Stopwatch()..start();

      Timer(const Duration(milliseconds: 50), token.cancel);
      final res = await BookSearchEngine.search(
        aid: '3',
        catalogue: [
          CatVolume(title: '第一卷', chapters: [CatChapter(title: '回溯章', cid: 'evil')]),
        ],
        query: r'(a+)+b',
        isRegex: true,
        scope: BookSearchScope.currentChapter,
        currentCid: 'evil',
        currentChapterText: evilText,
        applyReplaceRules: false,
        cancelToken: token,
      );
      sw.stop();

      expect(res.cancelled, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(2000), reason: '应通过 Isolate.kill(immediate) 迅速终止，而不是卡死在灾难性回溯中');
    });

    test('后台 Isolate 正确应用正文替换规则与繁简转换，且命中偏移与阅读器管线对齐', () async {
      final dir = Directory.systemTemp.createTempSync('ark_search_rules_test_');
      addTearDown(() async {
        try {
          await Hive.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      Hive.init(dir.path);
      final box = await Hive.openBox('session');
      await box.put('rules', [
        {'p': '旧称', 'r': '新名', 'e': true, 'k': 0, 'c': 0xFFE53935, 'n': '', 'a': '', 'id': 'r1', 'ts': 1},
      ]);

      final hant = Hant.parse('旧\t舊\n称\t稱\n新\t新\n名\t名\n', '');
      const rawText = '  这里提到了旧称，以及ＡＢＣ　ＤＥＦ。  ';
      final expectedFormatted = formatChapterText(hant.convert(rawText).replaceAll('舊稱', '新名'));

      final res = await BookSearchEngine.search(
        aid: '4',
        catalogue: [
          CatVolume(title: '第一卷', chapters: [CatChapter(title: '替换测试', cid: 'rc1')]),
        ],
        query: '新名',
        scope: BookSearchScope.allCached,
        hant: hant,
        applyReplaceRules: true,
        isCached: (_, _) => true,
        chapterLoader: (_, _) async => Content(text: rawText, images: const []),
      );

      expect(res.error, isNull);
      expect(res.totalHits, 1);
      final hit = res.hits.single;
      expect(expectedFormatted.substring(hit.offset, hit.offset + hit.matchLength), '新名');
    });
  });

  group('showBookSearchSheet 交互', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('ark_book_search_sheet_test');
      Hive.init(tmp.path);
      await Hive.openBox('session');
      await ChapterCache.open();
      await ChapterCache.put('501', 'c1', store['c1']!);
      await ChapterCache.put('501', 'c4', store['c4']!);
    });

    tearDownAll(() async {
      try {
        await Hive.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets('展示覆盖率与分组命中，点击结果回调目标章与偏移', (tester) async {
      BookSearchHit? picked;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showBookSearchSheet(
                    context,
                    aid: '501',
                    catalogue: catalogue,
                    initialQuery: '八奈见杏菜|老八',
                    initialRegex: true,
                    onSelectHit: (hit) => picked = hit,
                  ),
                  child: const Text('打开书内搜索'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开书内搜索'));
      await tester.pump();
      // LazyBox.get 与后台 Isolate 均走真实异步事件循环，每轮交错推进真实事件循环与假时钟微任务直至检索完成
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        if (find.textContaining('已搜索 2/4 章已缓存章节，共找到 3 处').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();

      expect(find.textContaining('已搜索 2/4 章已缓存章节，共找到 3 处'), findsOneWidget);
      expect(find.text('第一卷 · 序章'), findsOneWidget);
      expect(find.text('第二卷 · 第一章 续篇'), findsOneWidget);

      await tester.tap(find.textContaining('文艺社', findRichText: true));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.cid, 'c4');
      final formatted = formatChapterText(store['c4']!.text);
      expect(formatted.substring(picked!.offset, picked!.offset + picked!.matchLength), '八奈见杏菜');
    });
  });
}
