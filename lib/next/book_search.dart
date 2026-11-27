import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/cat_volume.dart';
import '../models/content.dart';
import 'cache.dart';
import 'hant.dart';
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
    this.hits = const [],
    this.newHits = const [],
    this.truncated = false,
  });

  final int scannedChapters;
  final int totalChapters;
  final int totalHits;

  /// 累计命中结果只读视图（O(1) 零拷贝视图，兼容既有调用方）。
  final List<BookSearchHit> hits;

  /// 本批次新增的命中结果，供 UI 侧按增量追加而不重建整表。
  final List<BookSearchHit> newHits;
  final bool truncated;
}

/// 书内全文搜索最终结果。
class BookSearchResult {
  const BookSearchResult({
    required this.hits,
    required this.scannedChapters,
    required this.totalChapters,
    required this.totalHits,
    this.cancelled = false,
    this.truncated = false,
    this.error,
  });

  final List<BookSearchHit> hits;
  final int scannedChapters;
  final int totalChapters;
  final int totalHits;
  final bool cancelled;
  final bool truncated;
  final String? error;
}

/// 用于中途取消正在执行的书内搜索；触发时会同步唤醒挂起的后台 Worker 立即终止。
class BookSearchCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void _addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void _removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (_listeners.isEmpty) return;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

@pragma('vm:prefer-inline')
bool _isFullWidthAlnum(int cu) =>
    (cu >= 0xFF10 && cu <= 0xFF19) || (cu >= 0xFF21 && cu <= 0xFF3A) || (cu >= 0xFF41 && cu <= 0xFF5A);

@pragma('vm:prefer-inline')
bool _isAsciiAlnum(int cu) => (cu >= 0x30 && cu <= 0x39) || (cu >= 0x41 && cu <= 0x5A) || (cu >= 0x61 && cu <= 0x7A);

@pragma('vm:prefer-inline')
bool _isAlnumAfterHalfWidth(int cu) => _isAsciiAlnum(cu) || _isFullWidthAlnum(cu);

/// 与 Dart VM `String.trim()` 100% 等价的空白码点判定（覆盖 Unicode 6.3 White_Space 与 BOM 0xFEFF）。
@pragma('vm:prefer-inline')
bool _isTrimWhitespace(int cu) {
  if (cu <= 0x20) {
    return cu == 0x20 || (cu >= 0x09 && cu <= 0x0D);
  }
  if (cu < 0x85) return false;
  if (cu == 0x3000) return true;
  if (cu > 0x3000) return cu == 0xFEFF;
  if (cu == 0x85 || cu == 0xA0) return true;
  if (cu <= 0x200A) return cu == 0x1680 || cu >= 0x2000;
  return cu == 0x2028 || cu == 0x2029 || cu == 0x202F || cu == 0x205F;
}

void _writeHalfWidthSlice(StringBuffer buf, String s, int start, int end) {
  var copied = start;
  for (var i = start; i < end; i++) {
    final cu = s.codeUnitAt(i);
    var mapped = cu;
    if (_isFullWidthAlnum(cu)) {
      mapped = cu - 0xFEE0;
    } else if ((cu == 0x3000 || cu == 0xFF0D) &&
        i > start &&
        i + 1 < end &&
        _isAlnumAfterHalfWidth(s.codeUnitAt(i - 1)) &&
        _isAlnumAfterHalfWidth(s.codeUnitAt(i + 1))) {
      mapped = cu == 0x3000 ? 0x20 : 0x2D;
    }
    if (mapped != cu) {
      if (i > copied) buf.write(s.substring(copied, i));
      buf.writeCharCode(mapped);
      copied = i + 1;
    }
  }
  if (copied < end) buf.write(s.substring(copied, end));
}

/// 「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」这种全角英文每个字母占一个汉字宽，排出来字距很怪：字母、数字转半角，
/// 英文之间的全角空格、连字符也换成半角。一个字换一个字，阅读进度、书签的位置不变。
/// 单遍 `codeUnitAt` 线性扫描，无改动时零拷贝直接返回原串。
String halfWidth(String s) {
  final len = s.length;
  if (len == 0) return s;
  StringBuffer? buf;
  var copied = 0;
  for (var i = 0; i < len; i++) {
    final cu = s.codeUnitAt(i);
    var mapped = cu;
    if (_isFullWidthAlnum(cu)) {
      mapped = cu - 0xFEE0;
    } else if ((cu == 0x3000 || cu == 0xFF0D) &&
        i > 0 &&
        i + 1 < len &&
        _isAlnumAfterHalfWidth(s.codeUnitAt(i - 1)) &&
        _isAlnumAfterHalfWidth(s.codeUnitAt(i + 1))) {
      mapped = cu == 0x3000 ? 0x20 : 0x2D;
    }
    if (mapped != cu) {
      buf ??= StringBuffer();
      if (i > copied) buf.write(s.substring(copied, i));
      buf.writeCharCode(mapped);
      copied = i + 1;
    }
  }
  if (buf == null) return s;
  if (copied < len) buf.write(s.substring(copied));
  return buf.toString();
}

/// 每个非空行当一段：去掉网页里零散的空白，统一首行缩进两个全角空格；全角英文、数字转半角。
/// 单遍线性扫描（无正则、`split` 或多轮整章拷贝），与阅读器共享同一份实现，确保检索偏移可直接定位阅读器页面。
String formatChapterText(String raw) {
  final len = raw.length;
  if (len == 0) return '';
  final buf = StringBuffer();
  var wroteLine = false;
  var pos = 0;

  while (pos < len) {
    var lineEnd = raw.indexOf('\n', pos);
    if (lineEnd < 0) lineEnd = len;

    var start = pos;
    while (start < lineEnd && _isTrimWhitespace(raw.codeUnitAt(start))) {
      start++;
    }

    var end = lineEnd;
    while (end > start && _isTrimWhitespace(raw.codeUnitAt(end - 1))) {
      end--;
    }

    if (start < end) {
      if (wroteLine) buf.writeCharCode(0x0A);
      buf.write('　　');
      _writeHalfWidthSlice(buf, raw, start, end);
      wroteLine = true;
    }

    pos = lineEnd + 1;
  }

  return wroteLine ? buf.toString() : '';
}

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

typedef _SearchWorkerInit = ({
  SendPort mainPort,
  String pattern,
  List<ReplaceRule>? rules,
  Hant? hant,
  int maxHits,
  int maxHitsPerChapter,
  bool stopAtMaxHits,
});

typedef _SearchChapterInput = ({
  String volTitle,
  String cid,
  String chapterTitle,
  String text,
  bool alreadyFormatted,
});

typedef _SearchBatchRequest = ({
  int seq,
  List<_SearchChapterInput> chapters,
});

typedef _SearchBatchResponse = ({
  int seq,
  int scannedDelta,
  int totalHitsDelta,
  List<BookSearchHit> newHits,
  bool truncated,
});

/// 在后台 Worker Isolate 中执行章节预处理（繁转 + 替换规则 + 格式化）、正则匹配与摘要提取。
void _searchWorkerEntry(_SearchWorkerInit init) {
  final commandPort = ReceivePort();
  init.mainPort.send(commandPort.sendPort);

  final matcher = RegExp(init.pattern, caseSensitive: false, multiLine: true);
  final rules = init.rules;
  final hant = init.hant;
  var collectedHits = 0;
  var truncated = false;

  commandPort.listen((msg) {
    if (msg == null) {
      commandPort.close();
      return;
    }
    final req = msg as _SearchBatchRequest;
    final batchHits = <BookSearchHit>[];
    var scannedDelta = 0;
    var totalHitsDelta = 0;

    for (final ch in req.chapters) {
      scannedDelta++;
      if (ch.text.isEmpty) continue;
      final String text;
      if (ch.alreadyFormatted) {
        text = ch.text;
      } else {
        var prepared = hant?.convert(ch.text) ?? ch.text;
        if (rules != null) prepared = ReplaceRules.apply(prepared, rules);
        text = formatChapterText(prepared);
      }
      if (text.isEmpty) continue;

      var chapterHits = 0;
      for (final m in matcher.allMatches(text)) {
        final len = m.end - m.start;
        if (len <= 0) continue;
        if (collectedHits >= init.maxHits) {
          truncated = true;
          if (init.stopAtMaxHits) break;
          totalHitsDelta++;
          continue;
        }
        totalHitsDelta++;
        if (chapterHits < init.maxHitsPerChapter) {
          final snip = extractSnippet(text, m.start, len);
          batchHits.add(
            BookSearchHit(
              volTitle: ch.volTitle,
              cid: ch.cid,
              chapterTitle: ch.chapterTitle,
              offset: m.start,
              matchLength: len,
              snippet: snip.snippet,
              highlightStart: snip.highlightStart,
              highlightEnd: snip.highlightEnd,
            ),
          );
          collectedHits++;
          chapterHits++;
        }
      }
      if (truncated && init.stopAtMaxHits) break;
    }

    init.mainPort.send((
      seq: req.seq,
      scannedDelta: scannedDelta,
      totalHitsDelta: totalHitsDelta,
      newHits: batchHits,
      truncated: truncated,
    ));

    if (truncated && init.stopAtMaxHits) {
      commandPort.close();
    }
  });
}

/// 书内全文搜索引擎：支持当前章与全书已缓存章节检索、普通词/简繁双匹配/多词 OR/正则模式，
/// 原生端在可即时 `Isolate.kill` 的后台 Worker 中执行重 CPU 流水线并分批增量回报命中结果。
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
    bool stopAtMaxHits = true,
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

    final loadChapter = chapterLoader ?? ChapterCache.get;
    final hasChapter = isCached ?? (String aid, String cid) => Hive.isBoxOpen('chapter_index') && ChapterCache.has(aid, cid);

    // 预取启用的替换规则（与 reader_page.dart 的 chapterProvider 管线一致）
    List<ReplaceRule>? rules;
    if (applyReplaceRules && Hive.isBoxOpen('session')) {
      final rawRules = ReplaceRules.allView();
      final active = <ReplaceRule>[];
      for (final r in rawRules) {
        if (!r.enabled || r.kind != RuleKind.replace || r.pattern.isEmpty) continue;
        active.add(hant == null ? r : r.copyWith(pattern: hant.convert(r.pattern), replacement: hant.convert(r.replacement)));
      }
      if (active.isNotEmpty) rules = active;
    }

    final targets = <(String volTitle, String cid, String chapterTitle)>[];
    if (scope == BookSearchScope.currentChapter) {
      if (currentCid != null && currentCid.isNotEmpty) {
        var volTitle = '';
        var chTitle = '';
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

    if (cancelToken?.isCancelled == true) {
      return BookSearchResult(hits: const [], scannedChapters: 0, totalChapters: targets.length, totalHits: 0, cancelled: true);
    }

    if (targets.isEmpty) {
      onProgress?.call(const BookSearchProgress(scannedChapters: 0, totalChapters: 0, totalHits: 0));
      return const BookSearchResult(hits: [], scannedChapters: 0, totalChapters: 0, totalHits: 0);
    }

    if (!kIsWeb) {
      return _searchWithWorker(
        aid: aid,
        targets: targets,
        pattern: matcher.pattern,
        currentCid: currentCid,
        currentChapterText: currentChapterText,
        rules: rules,
        hant: hant,
        cancelToken: cancelToken,
        onProgress: onProgress,
        yieldEvery: yieldEvery,
        maxHits: maxHits,
        maxHitsPerChapter: maxHitsPerChapter,
        stopAtMaxHits: stopAtMaxHits,
        loadChapter: loadChapter,
        hasChapter: hasChapter,
      );
    }

    return _searchLocal(
      aid: aid,
      targets: targets,
      matcher: matcher,
      currentCid: currentCid,
      currentChapterText: currentChapterText,
      rules: rules,
      hant: hant,
      cancelToken: cancelToken,
      onProgress: onProgress,
      yieldEvery: yieldEvery,
      maxHits: maxHits,
      maxHitsPerChapter: maxHitsPerChapter,
      stopAtMaxHits: stopAtMaxHits,
      loadChapter: loadChapter,
      hasChapter: hasChapter,
    );
  }

  /// 原生端后台 Worker Isolate 管线：主 Isolate 仅分批读取缓存正文并喂给 Worker，
  /// 取消时通过 `Isolate.kill(priority: Isolate.immediate)` 立即终止（即使正则发生灾难性回溯）。
  static Future<BookSearchResult> _searchWithWorker({
    required String aid,
    required List<(String volTitle, String cid, String chapterTitle)> targets,
    required String pattern,
    required String? currentCid,
    required String? currentChapterText,
    required List<ReplaceRule>? rules,
    required Hant? hant,
    required BookSearchCancelToken? cancelToken,
    required void Function(BookSearchProgress progress)? onProgress,
    required int yieldEvery,
    required int maxHits,
    required int maxHitsPerChapter,
    required bool stopAtMaxHits,
    required ChapterContentLoader loadChapter,
    required ChapterCachedChecker hasChapter,
  }) async {
    final totalChapters = targets.length;
    final hits = <BookSearchHit>[];
    final hitsView = UnmodifiableListView<BookSearchHit>(hits);
    var scanned = 0;
    var totalHits = 0;
    var truncated = false;
    var emittedProgress = false;

    Isolate? worker;
    SendPort? workerPort;
    ReceivePort? receivePort;
    ReceivePort? errorPort;
    ReceivePort? exitPort;
    Completer<SendPort?>? readyCompleter;
    Completer<_SearchBatchResponse?>? pendingBatch;
    var pendingSeq = -1;
    var workerClosed = false;
    var workerFailed = false;

    void closeWorker({required bool immediate}) {
      if (workerClosed) return;
      workerClosed = true;
      if (immediate) {
        worker?.kill(priority: Isolate.immediate);
      } else {
        workerPort?.send(null);
      }
      receivePort?.close();
      errorPort?.close();
      exitPort?.close();
      final ready = readyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete(null);
      final batch = pendingBatch;
      if (batch != null && !batch.isCompleted) batch.complete(null);
    }

    void onCancel() => closeWorker(immediate: true);
    cancelToken?._addListener(onCancel);

    Future<SendPort?> ensureWorker() async {
      if (workerPort != null) return workerPort;
      if (workerClosed || cancelToken?.isCancelled == true) return null;

      final rx = receivePort = ReceivePort();
      final errRx = errorPort = ReceivePort();
      final exitRx = exitPort = ReceivePort();
      final ready = readyCompleter = Completer<SendPort?>();

      rx.listen((msg) {
        if (msg is SendPort) {
          workerPort = msg;
          if (!ready.isCompleted) ready.complete(msg);
          return;
        }
        if (msg is _SearchBatchResponse) {
          final completer = pendingBatch;
          if (completer != null && !completer.isCompleted && msg.seq == pendingSeq) {
            completer.complete(msg);
          }
        }
      });

      errRx.listen((_) {
        workerFailed = true;
        closeWorker(immediate: true);
      });

      exitRx.listen((_) {
        if (!workerClosed) closeWorker(immediate: false);
      });

      try {
        final spawned = await Isolate.spawn<_SearchWorkerInit>(
          _searchWorkerEntry,
          (
            mainPort: rx.sendPort,
            pattern: pattern,
            rules: rules,
            hant: hant,
            maxHits: maxHits,
            maxHitsPerChapter: maxHitsPerChapter,
            stopAtMaxHits: stopAtMaxHits,
          ),
          onError: errRx.sendPort,
          onExit: exitRx.sendPort,
          debugName: 'ark_book_search',
        );
        if (workerClosed || cancelToken?.isCancelled == true) {
          spawned.kill(priority: Isolate.immediate);
          closeWorker(immediate: true);
          return null;
        }
        worker = spawned;
        return await ready.future;
      } catch (_) {
        workerFailed = true;
        closeWorker(immediate: true);
        return null;
      }
    }

    final maxBatch = yieldEvery > 0 ? yieldEvery.clamp(1, 16) : 10;
    var batchLimit = math.min(2, maxBatch);
    var batchSeq = 0;
    final batch = <_SearchChapterInput>[];
    // 预启动后台 Worker，与首批章节磁盘 I/O 并行重叠，减少首屏命中等待时间
    Future<SendPort?>? workerFuture;

    Future<SendPort?> getWorker() => workerFuture ??= ensureWorker();

    Future<bool> flushBatch() async {
      if (batch.isEmpty) return true;
      final port = await getWorker();
      if (port == null || cancelToken?.isCancelled == true) return false;

      final payload = List<_SearchChapterInput>.of(batch);
      batch.clear();

      final seq = ++batchSeq;
      pendingSeq = seq;
      final completer = pendingBatch = Completer<_SearchBatchResponse?>();
      port.send((seq: seq, chapters: payload));

      final resp = await completer.future;
      pendingBatch = null;
      if (resp == null || cancelToken?.isCancelled == true) return false;

      scanned += resp.scannedDelta;
      totalHits += resp.totalHitsDelta;
      if (resp.newHits.isNotEmpty) hits.addAll(resp.newHits);
      truncated = truncated || resp.truncated;

      emittedProgress = true;
      onProgress?.call(
        BookSearchProgress(
          scannedChapters: scanned,
          totalChapters: totalChapters,
          totalHits: totalHits,
          hits: hitsView,
          newHits: resp.newHits,
          truncated: truncated,
        ),
      );

      if (batchLimit < maxBatch) {
        batchLimit = math.min(maxBatch, batchLimit * 2);
      }
      return !(truncated && stopAtMaxHits);
    }

    BookSearchResult buildResult({bool cancelled = false, String? error}) => BookSearchResult(
      hits: hits,
      scannedChapters: scanned,
      totalChapters: totalChapters,
      totalHits: totalHits,
      cancelled: cancelled,
      truncated: truncated,
      error: error,
    );

    try {
      for (final (volTitle, cid, chTitle) in targets) {
        if (cancelToken?.isCancelled == true) return buildResult(cancelled: true);

        if (currentCid == cid && currentChapterText != null) {
          workerFuture ??= ensureWorker();
          batch.add((volTitle: volTitle, cid: cid, chapterTitle: chTitle, text: currentChapterText, alreadyFormatted: true));
        } else {
          if (!hasChapter(aid, cid)) continue;
          workerFuture ??= ensureWorker();
          final content = await loadChapter(aid, cid);
          if (cancelToken?.isCancelled == true) return buildResult(cancelled: true);
          batch.add((volTitle: volTitle, cid: cid, chapterTitle: chTitle, text: content?.text ?? '', alreadyFormatted: false));
        }

        if (batch.length >= batchLimit) {
          final keepGoing = await flushBatch();
          if (cancelToken?.isCancelled == true) return buildResult(cancelled: true);
          if (workerFailed) return buildResult(error: '后台检索异常中断');
          if (!keepGoing) break;
        }
      }

      if (!(truncated && stopAtMaxHits) && batch.isNotEmpty && cancelToken?.isCancelled != true && !workerFailed) {
        await flushBatch();
      }
    } finally {
      cancelToken?._removeListener(onCancel);
      closeWorker(immediate: cancelToken?.isCancelled == true || workerFailed);
    }

    if (cancelToken?.isCancelled == true) return buildResult(cancelled: true);
    if (workerFailed) return buildResult(error: '后台检索异常中断');

    if (!emittedProgress) {
      onProgress?.call(
        BookSearchProgress(
          scannedChapters: scanned,
          totalChapters: totalChapters,
          totalHits: totalHits,
          hits: hitsView,
          truncated: truncated,
        ),
      );
    }
    return buildResult();
  }

  /// Web 端单线程协作式回退路径（同样按批次增量汇报 `newHits`，零全表拷贝）。
  static Future<BookSearchResult> _searchLocal({
    required String aid,
    required List<(String volTitle, String cid, String chapterTitle)> targets,
    required RegExp matcher,
    required String? currentCid,
    required String? currentChapterText,
    required List<ReplaceRule>? rules,
    required Hant? hant,
    required BookSearchCancelToken? cancelToken,
    required void Function(BookSearchProgress progress)? onProgress,
    required int yieldEvery,
    required int maxHits,
    required int maxHitsPerChapter,
    required bool stopAtMaxHits,
    required ChapterContentLoader loadChapter,
    required ChapterCachedChecker hasChapter,
  }) async {
    String prepareText(String raw) {
      final converted = hant?.convert(raw) ?? raw;
      final replaced = rules == null ? converted : ReplaceRules.apply(converted, rules);
      return formatChapterText(replaced);
    }

    final totalChapters = targets.length;
    final hits = <BookSearchHit>[];
    final hitsView = UnmodifiableListView<BookSearchHit>(hits);
    var batchHits = <BookSearchHit>[];
    var scanned = 0;
    var totalHits = 0;
    var truncated = false;
    var processedSinceYield = 0;
    var emittedProgress = false;
    final cpuClock = Stopwatch();

    for (final (volTitle, cid, chTitle) in targets) {
      if (cancelToken?.isCancelled == true) {
        return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true, truncated: truncated);
      }

      String? text;
      if (currentCid == cid && currentChapterText != null) {
        text = currentChapterText;
        scanned++;
      } else {
        if (!hasChapter(aid, cid)) continue;
        final content = await loadChapter(aid, cid);
        if (cancelToken?.isCancelled == true) {
          return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true, truncated: truncated);
        }
        scanned++;
        if (content != null && content.text.isNotEmpty) {
          cpuClock.start();
          text = prepareText(content.text);
          cpuClock.stop();
        }
      }

      if (text != null && text.isNotEmpty) {
        cpuClock.start();
        var chapterHits = 0;
        for (final m in matcher.allMatches(text)) {
          final len = m.end - m.start;
          if (len <= 0) continue;
          if (hits.length >= maxHits) {
            truncated = true;
            if (stopAtMaxHits) break;
            totalHits++;
            continue;
          }
          totalHits++;
          if (chapterHits < maxHitsPerChapter) {
            final snip = extractSnippet(text, m.start, len);
            final hit = BookSearchHit(
              volTitle: volTitle,
              cid: cid,
              chapterTitle: chTitle,
              offset: m.start,
              matchLength: len,
              snippet: snip.snippet,
              highlightStart: snip.highlightStart,
              highlightEnd: snip.highlightEnd,
            );
            hits.add(hit);
            batchHits.add(hit);
            chapterHits++;
          }
        }
        cpuClock.stop();
      }

      if (truncated && stopAtMaxHits) break;

      processedSinceYield++;
      final shouldYield = (yieldEvery > 0 && processedSinceYield >= yieldEvery) || cpuClock.elapsedMilliseconds >= 8;
      if (shouldYield) {
        processedSinceYield = 0;
        emittedProgress = true;
        final delta = batchHits;
        batchHits = <BookSearchHit>[];
        onProgress?.call(
          BookSearchProgress(
            scannedChapters: scanned,
            totalChapters: totalChapters,
            totalHits: totalHits,
            hits: hitsView,
            newHits: delta,
            truncated: truncated,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        cpuClock.reset();
      }
    }

    if (cancelToken?.isCancelled == true) {
      return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, cancelled: true, truncated: truncated);
    }

    if (!emittedProgress || batchHits.isNotEmpty || scanned > 0) {
      onProgress?.call(
        BookSearchProgress(
          scannedChapters: scanned,
          totalChapters: totalChapters,
          totalHits: totalHits,
          hits: hitsView,
          newHits: batchHits,
          truncated: truncated,
        ),
      );
    }
    return BookSearchResult(hits: hits, scannedChapters: scanned, totalChapters: totalChapters, totalHits: totalHits, truncated: truncated);
  }
}
