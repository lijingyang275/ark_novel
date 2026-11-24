import 'dart:io';

import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/book_search.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/epub_codec.dart';
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/local_books.dart';
import 'package:ark_novel/next/pages/book_search_sheet.dart';
import 'package:ark_novel/next/reader/reader_page.dart' show formatChapter;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

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
      // LazyBox.get 每章走一次真实磁盘 I/O，每轮交错推进真实事件循环与假时钟微任务
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
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

    test('本地书籍（local:）默认走 LocalBooks 读取正文并检索', () async {
      final localDir = Directory('${tmp.path}/local_books');
      LocalBooks.rootProvider = () async => localDir;
      addTearDown(() {
        LocalBooks.rootProvider = null;
        LocalBooks.clearMemoryCache();
      });

      final meta = await LocalBooks.saveParsed(
        const ParsedBook(
          title: '本地轻小说测试',
          author: '测试作者',
          description: '',
          volumes: [
            EpubVolumeData(
              title: '第一卷',
              chapters: [
                EpubChapterData(title: '第一章', text: '放学后，八奈见杏菜在社办吃点心。'),
                EpubChapterData(title: '第二章', text: '没有关键词的章节。'),
              ],
            ),
          ],
        ),
        format: 'txt',
        aid: 'local:search_test_1',
      );

      final res = await BookSearchEngine.search(
        aid: meta.aid,
        catalogue: meta.catalogue,
        query: '八奈见杏菜',
        scope: BookSearchScope.allCached,
        applyReplaceRules: false,
      );

      expect(res.error, isNull);
      expect(res.scannedChapters, 2);
      expect(res.totalChapters, 2);
      expect(res.totalHits, 1);
      expect(res.hits.single.cid, meta.catalogue.first.chapters.first.cid);
    });
  });
}
