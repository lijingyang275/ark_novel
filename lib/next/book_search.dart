import 'dart:math' as math;

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/cat_volume.dart';
import '../models/content.dart';
import 'cache.dart';
import 'hant.dart';
import 'local_books.dart';
import 'rules.dart';

/// 书内全文搜索范围。
enum BookSearchScope { currentChapter, allCached }

/// 单条全文搜索命中结果。
class BookSearchHit {
  const BookSearchHit({
    required this.volTitle,
    required this.cid,
    required this.chapterTitle,
    required this.offset,
    required this.matchLength,
    required this.snippet,
    required this.highlightStart,
    required this.highlightEnd,
  });

  final String volTitle;
  final String cid;
  final String chapterTitle;

  /// 命中在格式化章节正文里的字符偏移（与阅读器 `Chapter.text` 一致）
  final int offset;
  final int matchLength;

  /// 带前后上下文的摘要文本
  final String snippet;

  /// 命中词在 [snippet] 内的起止偏移 `[highlightStart, highlightEnd)`
  final int highlightStart;
  final int highlightEnd;
}

/// 搜索过程中的实时进度通知。
class BookSearchProgress {
  const BookSearchProgress({
    required this.scannedChapters,
    required this.totalChapters,
    required this.totalHits,
    required this.hits,
  });

  final int scannedChapters;
  final int totalChapters;
  final int totalHits;
  final List<BookSearchHit> hits;
}

/// 书内全文搜索最终结果。
class BookSearchResult {
  const BookSearchResult({
    required this.hits,
    required this.scannedChapters,
    required this.totalChapters,
    required this.totalHits,
    this.cancelled = false,
    this.error,
  });

  final List<BookSearchHit> hits;
  final int scannedChapters;
  final int totalChapters;
  final int totalHits;
  final bool cancelled;
  final String? error;
}

/// 用于中途取消正在执行的书内搜索。
class BookSearchCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 与阅读器 `formatChapter` 完全一致的正文标准化函数，确保检索偏移可直接定位阅读器页面。
String formatChapterText(String raw) => _halfWidth(raw).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).map((l) => '　　$l').join('\n');

String _halfWidth(String s) => s
    .replaceAllMapped(RegExp('[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
    .replaceAllMapped(RegExp(r'(?<=[0-9A-Za-z])[　－](?=[0-9A-Za-z])'), (m) => m[0] == '　' ? ' ' : '-');

/// 从 [text] 中提取以 `[matchStart, matchStart + matchLength)` 为中心的上下文摘要，
/// 折叠换行与连续空白的同时精确映射命中高亮区间 `[highlightStart, highlightEnd)`。
({String snippet, int highlightStart, int highlightEnd}) extractSnippet(
  String text,
  int matchStart,
  int matchLength, {
  int contextBefore = 24,
  int contextAfter = 36,
}) {
  final start = matchStart.clamp(0, text.length);
  final end = (start + matchLength).clamp(start, text.length);
  final rawStart = math.max(0, start - contextBefore);
  final rawEnd = math.min(text.length, end + contextAfter);

  final buf = StringBuffer();
  if (rawStart > 0) buf.write('…');
  var hlStart = -1;
  var hlEnd = -1;
  var lastSpace = false;

  bool isSpace(int cu) => cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D || cu == 0x3000;

  for (var i = rawStart; i < rawEnd; i++) {
    if (i == start) hlStart = buf.length;
    final cu = text.codeUnitAt(i);
    if (isSpace(cu)) {
      if (!lastSpace && buf.isNotEmpty && (rawStart == 0 || buf.length > 1)) {
        buf.write(' ');
        lastSpace = true;
      }
    } else {
      buf.writeCharCode(cu);
      lastSpace = false;
    }
    if (i + 1 == end) hlEnd = buf.length;
  }
  if (hlStart < 0) hlStart = buf.length;
  if (hlEnd < hlStart) hlEnd = buf.length;

  var snippet = buf.toString();
  if (snippet.endsWith(' ') && hlEnd < snippet.length) {
    snippet = snippet.substring(0, snippet.length - 1);
  }
  if (rawEnd < text.length) snippet = '$snippet…';
  return (snippet: snippet, highlightStart: hlStart.clamp(0, snippet.length), highlightEnd: hlEnd.clamp(0, snippet.length));
}

typedef ChapterContentLoader = Future<Content?> Function(String aid, String cid);
typedef ChapterCachedChecker = bool Function(String aid, String cid);

/// 书内全文搜索引擎：支持当前章与全书已缓存章节检索、普通词/简繁双匹配/多词 OR/正则模式，
/// 每扫描若干章主动让出事件循环并支持随时取消。
class BookSearchEngine {
  BookSearchEngine._();

  /// 构建检索正则；语法无效时抛出 [FormatException]。
  static RegExp buildMatcher(String query, {bool isRegex = false, List<String>? orTerms, Hant? hant}) {
    if (orTerms != null && orTerms.isNotEmpty) {
      final variants = <String>{};
      for (final raw in orTerms) {
        final t = raw.trim();
        if (t.isEmpty) continue;
        variants.add(t);
        if (hant != null) {
          final ht = hant.convert(t);
          if (ht.isNotEmpty) variants.add(ht);
        }
      }
      final sorted = variants.toList()..sort((a, b) => b.length.compareTo(a.length));
      if (sorted.isEmpty) throw const FormatException('搜索关键词不能为空');
      return RegExp(sorted.map(RegExp.escape).join('|'), caseSensitive: false, multiLine: true);
    }

    final q = query.trim();
    if (q.isEmpty) throw const FormatException('搜索关键词不能为空');
    if (isRegex) {
      // 先验证原正则
      final primary = RegExp(q, caseSensitive: false, multiLine: true);
      if (hant == null) return primary;
      final hq = hant.convert(q);
      if (hq == q) return primary;
      try {
        return RegExp('(?:$q)|(?:$hq)', caseSensitive: false, multiLine: true);
      } on FormatException {
        return primary;
      }
    }

    final variants = <String>{q};
    if (hant != null) {
      final hq = hant.convert(q);
      if (hq.isNotEmpty) variants.add(hq);
    }
    final sorted = variants.toList()..sort((a, b) => b.length.compareTo(a.length));
    return RegExp(sorted.map(RegExp.escape).join('|'), caseSensitive: false, multiLine: true);
  }

  /// 在单章或全书已缓存章节中执行检索。
  ///
  /// - [currentChapterText]：搜索当前章时若阅读器已有格式化好的正文，可直接传入（即使未进缓存也能搜）。
  /// - [chapterLoader] / [isCached]：便于单元测试注入，默认读取 [ChapterCache]。
  static Future<BookSearchResult> search({
    required String aid,
    required List<CatVolume> catalogue,
    required String query,
    BookSearchScope scope = BookSearchScope.allCached,
    String? currentCid,
    String? currentChapterText,
    bool isRegex = false,
    List<String>? orTerms,
    Hant? hant,
    bool applyReplaceRules = true,
    BookSearchCancelToken? cancelToken,
    void Function(BookSearchProgress progress)? onProgress,
    int yieldEvery = 10,
    int maxHits = 500,
    int maxHitsPerChapter = 50,
    ChapterContentLoader? chapterLoader,
    ChapterCachedChecker? isCached,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty && (orTerms == null || orTerms.every((e) => e.trim().isEmpty))) {
      return const BookSearchResult(hits: [], scannedChapters: 0, totalChapters: 0, totalHits: 0);
    }

    final RegExp matcher;
    try {
      matcher = buildMatcher(trimmed, isRegex: isRegex, orTerms: orTerms, hant: hant);
    } on FormatException catch (e) {
      return BookSearchResult(hits: const [], scannedChapters: 0, totalChapters: 0, totalHits: 0, error: '正则表达式无效：${e.message}');
    }

    final loadChapter =
        chapterLoader ??
        (String aid, String cid) async {
          if (isLocalAid(aid)) {
            try {
              return await LocalBooks.loadChapter(aid, cid);
            } catch (_) {
              return null;
            }
          }
          return ChapterCache.get(aid, cid);
        };
    final hasChapter = isCached ?? (String aid, String cid) => isLocalAid(aid) || (Hive.isBoxOpen('chapter_index') && ChapterCache.has(aid, cid));

    // 预取替换规则（与 reader_page.dart 的 chapterProvider 管线一致）
    List<ReplaceRule>? rules;
    if (applyReplaceRules && Hive.isBoxOpen('session')) {
      final rawRules = ReplaceRules.all();
      rules = hant == null ? rawRules : [for (final r in rawRules) r.copyWith(pattern: hant.convert(r.pattern), replacement: hant.convert(r.replacement))];
    }

    String prepareText(String raw) {
      final converted = hant?.convert(raw) ?? raw;
      final replaced = rules == null ? converted : ReplaceRules.apply(converted, rules);
      return formatChapterText(replaced);
    }

    final targets = <(String volTitle, String cid, String chapterTitle)>[];
    if (scope == BookSearchScope.currentChapter) {
      if (currentCid != null && currentCid.isNotEmpty) {
        String volTitle = '';
        String chTitle = '';
        for (final v in catalogue) {
          for (final c in v.chapters) {
            if (c.cid == currentCid) {
              volTitle = v.title;
              chTitle = c.title;
              break;
            }
          }
          if (chTitle.isNotEmpty) break;
        }
        targets.add((volTitle, currentCid, chTitle));
      }
    } else {
      for (final v in catalogue) {
        for (final c in v.chapters) {
          targets.add((v.title, c.cid, c.title));
        }
      }
    }

    final totalChapters = targets.length;
    final hits = <BookSearchHit>[];
    var scanned = 0;
    var totalHits = 0;
    var processedSinceYield = 0;

    for (final (volTitle, cid, chTitle) in targets) {
      if (cancelToken?.isCancelled == true) {
        return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true);
      }

      String? text;
      if (scope == BookSearchScope.currentChapter && currentCid == cid && currentChapterText != null) {
        text = currentChapterText;
        scanned++;
      } else {
        if (!hasChapter(aid, cid)) continue;
        final content = await loadChapter(aid, cid);
        if (cancelToken?.isCancelled == true) {
          return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true);
        }
        scanned++;
        if (content != null && content.text.isNotEmpty) {
          text = prepareText(content.text);
        }
      }

      if (text != null && text.isNotEmpty) {
        var chapterHits = 0;
        for (final m in matcher.allMatches(text)) {
          final len = m.end - m.start;
          if (len <= 0) continue;
          totalHits++;
          if (hits.length < maxHits && chapterHits < maxHitsPerChapter) {
            final snip = extractSnippet(text, m.start, len);
            hits.add(
              BookSearchHit(
                volTitle: volTitle,
                cid: cid,
                chapterTitle: chTitle,
                offset: m.start,
                matchLength: len,
                snippet: snip.snippet,
                highlightStart: snip.highlightStart,
                highlightEnd: snip.highlightEnd,
              ),
            );
            chapterHits++;
          }
        }
      }

      processedSinceYield++;
      if (yieldEvery > 0 && processedSinceYield >= yieldEvery) {
        processedSinceYield = 0;
        onProgress?.call(BookSearchProgress(scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, hits: List<BookSearchHit>.unmodifiable(hits)));
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (cancelToken?.isCancelled == true) {
      return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true);
    }

    onProgress?.call(BookSearchProgress(scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, hits: List<BookSearchHit>.unmodifiable(hits)));
    return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits);
  }
}
