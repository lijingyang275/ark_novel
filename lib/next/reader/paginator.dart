import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 超过该长度的长章按自然段分块测量，避免单个超大 [TextPainter] 阻塞主线程。
const _chunkThreshold = 16000;
const _chunkTarget = 6000;

/// 共享排版与章节标题高度 LRU 缓存：由 `PagedBody`、`ScrollBody` 与 `_bookmarkPage` 共同复用，
/// 避免切章、打开书签或跨组件重复整章排版；键不强引用整章正文字符串。
class PaginateCache {
  PaginateCache._();

  static const int maxEntries = 12;
  static const int maxHeadingEntries = 32;

  static final _pages = <Object, List<int>>{};
  static final _headings = <Object, double>{};

  static TextStyle normalizeStyle(TextStyle style) => style.copyWith(color: const Color(0xFF000000));

  static int _textFingerprint(String text) {
    final len = text.length;
    if (len == 0) return 0;
    return Object.hash(text.hashCode, text.codeUnitAt(0), text.codeUnitAt(len >> 1), text.codeUnitAt(len - 1));
  }

  static Object _pageKey({
    required String text,
    required TextStyle layoutStyle,
    required Size size,
    required String title,
    required double firstTop,
    required double paragraphSpacing,
    required TextDirection textDirection,
  }) => (size, layoutStyle, paragraphSpacing, firstTop, text.length, _textFingerprint(text), title, textDirection);

  /// 缓存章节标题高度（LRU 上限 [maxHeadingEntries]）。
  static double headingHeightCached(String title, TextStyle body, double width) {
    if (title.trim().isEmpty) return 0;
    final layoutStyle = normalizeStyle(body);
    final key = (title, layoutStyle, width);
    final hit = _headings.remove(key);
    if (hit != null) return _headings[key] = hit;
    final h = headingHeight(title, layoutStyle, width);
    if (_headings.length >= maxHeadingEntries) _headings.remove(_headings.keys.first);
    return _headings[key] = h;
  }

  /// 命中时直接返回缓存的分页结果，未命中返回 null（供书签分帧队列判断是否需排队）。
  static List<int>? peek({
    required String text,
    required TextStyle style,
    required Size size,
    required String title,
    double? firstTop,
    double paragraphSpacing = 0,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    if (text.isEmpty) return const [0];
    final layoutStyle = normalizeStyle(style);
    final head = firstTop ?? headingHeightCached(title, layoutStyle, size.width);
    final key = _pageKey(
      text: text,
      layoutStyle: layoutStyle,
      size: size,
      title: title,
      firstTop: head,
      paragraphSpacing: paragraphSpacing,
      textDirection: textDirection,
    );
    final hit = _pages.remove(key);
    if (hit != null) return _pages[key] = hit;
    return null;
  }

  /// 查询或计算并缓存整章分页结果（LRU 上限 [maxEntries] 章）。
  static List<int> paginateCached({
    required String text,
    required TextStyle style,
    required Size size,
    required String title,
    double? firstTop,
    double paragraphSpacing = 0,
    StrutStyle? strut,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    if (text.isEmpty) return const [0];
    final layoutStyle = normalizeStyle(style);
    final head = firstTop ?? headingHeightCached(title, layoutStyle, size.width);
    final key = _pageKey(
      text: text,
      layoutStyle: layoutStyle,
      size: size,
      title: title,
      firstTop: head,
      paragraphSpacing: paragraphSpacing,
      textDirection: textDirection,
    );
    final hit = _pages.remove(key);
    if (hit != null) return _pages[key] = hit;
    final effectiveStrut = strut ?? StrutStyle.fromTextStyle(layoutStyle, forceStrutHeight: true);
    final starts = List<int>.unmodifiable(
      paginate(text, layoutStyle, size, textDirection: textDirection, strut: effectiveStrut, firstTop: head, paragraphSpacing: paragraphSpacing),
    );
    if (_pages.length >= maxEntries) _pages.remove(_pages.keys.first);
    return _pages[key] = starts;
  }

  static void clear() {
    _pages.clear();
    _headings.clear();
  }
}

/// 把一章文字按页面大小切页，返回每页第一个字符的偏移（第一页恒为 0）。
///
/// 只负责排版，不关心界面：翻页、进度保存、改字号后重新切页都只用这一个函数。
/// [strut] 要和实际显示正文时用的一样：变色、高亮的文字所在的行会比普通行高一点，不统一行高的话，
/// 切页时量出来每页装得下的行数，和显示出来的对不上，最后一行就被页脚盖住。
/// [firstTop] 是第一页顶上让给章节标题的高度（[headingHeight]）。
/// [paragraphSpacing] 为自然段之间额外留白（像素），大于 0 时按自然段逐段排版累加高度，字符偏移与原文完全一致。
List<int> paginate(
  String text,
  TextStyle style,
  Size size, {
  TextDirection textDirection = TextDirection.ltr,
  StrutStyle? strut,
  double firstTop = 0,
  double paragraphSpacing = 0,
}) {
  if (text.isEmpty) return [0];
  if (paragraphSpacing > 0) {
    return _paginateParagraphs(text, style, size, textDirection: textDirection, strut: strut, firstTop: firstTop, paragraphSpacing: paragraphSpacing);
  }
  if (text.length <= _chunkThreshold) {
    return _paginateRange(text, style, size, textDirection: textDirection, strut: strut, firstTop: firstTop);
  }
  return _paginateChunked(text, style, size, textDirection: textDirection, strut: strut, firstTop: firstTop);
}

List<int> _paginateRange(String text, TextStyle style, Size size, {required TextDirection textDirection, StrutStyle? strut, required double firstTop}) {
  final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: textDirection, strutStyle: strut)..layout(maxWidth: size.width);
  final starts = <int>[0];
  var pageTop = -firstTop;
  for (final line in painter.computeLineMetrics()) {
    final bottom = line.baseline + line.descent;
    if (bottom - pageTop > size.height && line.baseline - line.ascent > pageTop) {
      pageTop = line.baseline - line.ascent;
      final offset = painter.getPositionForOffset(Offset(0, pageTop + line.height / 2)).offset;
      if (offset > starts.last) starts.add(offset);
    }
  }
  painter.dispose();
  return starts;
}

/// 超长章节按自然段（`\n`）分块测量：块间仅在非末尾的硬换行处断开，保持逐行高度累加与全局字符偏移与单 [TextPainter] 完全一致。
List<int> _paginateChunked(String text, TextStyle style, Size size, {required TextDirection textDirection, StrutStyle? strut, required double firstTop}) {
  final starts = <int>[0];
  var pageTop = -firstTop;
  var yOffset = 0.0;
  var chunkStart = 0;
  final len = text.length;

  while (chunkStart < len) {
    var chunkEnd = len;
    var hasNext = false;
    if (len - chunkStart > _chunkTarget) {
      final probe = chunkStart + _chunkTarget;
      // 优先在目标位置附近找非末尾的自然段换行；找不到再往后找，确保不把同一自然段从中劈开
      var nl = text.indexOf('\n', probe);
      if (nl < 0 || nl >= len - 1) {
        final back = text.lastIndexOf('\n', probe);
        if (back > chunkStart && back < len - 1) nl = back;
      }
      if (nl >= chunkStart && nl < len - 1) {
        chunkEnd = nl;
        hasNext = true;
      }
    }

    final chunk = text.substring(chunkStart, chunkEnd);
    final painter = TextPainter(text: TextSpan(text: chunk, style: style), textDirection: textDirection, strutStyle: strut)..layout(maxWidth: size.width);
    final lines = painter.computeLineMetrics();
    for (final line in lines) {
      final top = yOffset + line.baseline - line.ascent;
      final bottom = yOffset + line.baseline + line.descent;
      if (bottom - pageTop > size.height && top > pageTop) {
        pageTop = top;
        final localOffset = painter.getPositionForOffset(Offset(0, (line.baseline - line.ascent) + line.height / 2)).offset;
        final offset = chunkStart + localOffset;
        if (offset > starts.last) starts.add(offset);
      }
    }
    if (lines.isNotEmpty) {
      final last = lines.last;
      yOffset += last.baseline + last.descent;
    } else if (painter.height > 0) {
      yOffset += painter.height;
    }
    painter.dispose();

    if (!hasNext) break;
    chunkStart = chunkEnd + 1; // 跳过作为块分隔符的单个 '\n'
  }
  return starts;
}

/// 段间距大于 0 时按自然段逐段排版：每段后累加 [paragraphSpacing] 像素留白，与 `_ParagraphRichText` 逐像素对齐。
/// 启用固定行高（`strut.forceStrutHeight == true`）时对保守单行短段跳过 `TextPainter.layout`，直接按单行 strut 度量累加。
List<int> _paginateParagraphs(
  String text,
  TextStyle style,
  Size size, {
  required TextDirection textDirection,
  StrutStyle? strut,
  required double firstTop,
  required double paragraphSpacing,
}) {
  final starts = <int>[0];
  var pageTop = -firstTop;
  var yOffset = 0.0;
  var pStart = 0;
  final len = text.length;

  double? singleTop;
  double? singleBottom;
  final fontSize = style.fontSize ?? 14.0;
  final extraSpace = math.max(0.0, style.letterSpacing ?? 0.0) + math.max(0.0, style.wordSpacing ?? 0.0);
  // 保守单字符宽上界（覆盖 CJK 全角、宽标点、Ahem 等宽测试字体及西文宽字形）
  final maxCharAdvance = (fontSize + extraSpace) * 1.25;
  final canProbeFast = strut != null &&
      strut.forceStrutHeight == true &&
      textDirection == TextDirection.ltr &&
      size.width > 0 &&
      (style.fontWeight == null || style.fontWeight!.value <= 500);
  if (canProbeFast) {
    final probe = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: textDirection,
      strutStyle: strut,
    )..layout(maxWidth: size.width);
    final probeLines = probe.computeLineMetrics();
    if (probeLines.length == 1) {
      singleTop = probeLines.first.baseline - probeLines.first.ascent;
      singleBottom = probeLines.first.baseline + probeLines.first.descent;
    }
    probe.dispose();
  }

  while (pStart < len) {
    final nl = text.indexOf('\n', pStart);
    final pEnd = nl < 0 ? len : nl;

    if (singleTop != null && singleBottom != null && _canSkipSingleLineLayout(text, pStart, pEnd, maxCharAdvance, size.width)) {
      final top = yOffset + singleTop;
      final bottom = yOffset + singleBottom;
      if (bottom - pageTop > size.height && top > pageTop) {
        pageTop = top;
        if (pStart > starts.last) starts.add(pStart);
      }
      yOffset += singleBottom;
    } else {
      final para = text.substring(pStart, pEnd);
      final painter = TextPainter(
        text: TextSpan(text: para.isEmpty ? ' ' : para, style: style),
        textDirection: textDirection,
        strutStyle: strut,
      )..layout(maxWidth: size.width);
      final lines = painter.computeLineMetrics();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
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
        final last = lines.last;
        yOffset += last.baseline + last.descent;
      } else if (painter.height > 0) {
        yOffset += painter.height;
      }
      painter.dispose();
    }

    if (nl < 0) break;
    yOffset += paragraphSpacing;
    pStart = nl + 1;
  }
  return starts;
}

bool _canSkipSingleLineLayout(String text, int start, int end, double maxCharAdvance, double maxWidth) {
  final len = end - start;
  if (len == 0) return true;
  if (len * maxCharAdvance >= maxWidth - 1.0) return false;
  for (var i = start; i < end; i++) {
    final cu = text.codeUnitAt(i);
    if (cu < 0x20) return false; // 控制字符（\t \r 等）
    if (cu >= 0x0300 && cu <= 0x036F) return false; // 组合变音符号
    if (cu >= 0x0590 && cu <= 0x08FF) return false; // RTL 脚本
    if (cu >= 0x200B && cu <= 0x200F) return false; // 零宽/方向控制
    if (cu >= 0x2028 && cu <= 0x202F) return false; // 行分隔/BiDi 控制
    if (cu >= 0x2060 && cu <= 0x206F) return false; // 格式控制
    if (cu >= 0xD800 && cu <= 0xDFFF) return false; // 代理对 / Emoji
    if (cu >= 0xFB00 && cu <= 0xFEFF) return false; // 表现形式/变体选择符/BOM
  }
  return true;
}

/// 每章开头的章节标题：比正文大、加粗。
TextStyle headingStyle(TextStyle body) => body.copyWith(fontSize: (body.fontSize ?? 18) * 1.35, fontWeight: FontWeight.w700, height: 1.4);

/// 章节标题连同下面空出的一行占多高；正文显示和分页都按这个高度留位置，两边才对得上。
double headingHeight(String title, TextStyle body, double width) {
  if (title.trim().isEmpty) return 0;
  final painter = TextPainter(text: TextSpan(text: title, style: headingStyle(body)), textDirection: TextDirection.ltr)..layout(maxWidth: width);
  final h = painter.height + (body.fontSize ?? 18) * 1.2;
  painter.dispose();
  return h;
}

/// 字符偏移所在的页码（二分查找）。
int pageOfOffset(List<int> starts, int offset) {
  if (starts.isEmpty) return 0;
  var lo = 0;
  var hi = starts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

final _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isBlankCu(int cu) => cu == 0x0A || cu == 0x20 || cu == 0x3000;

bool _isSentenceStopCu(int cu) => switch (cu) {
  0x0A || 0x3002 || 0xFF01 || 0xFF1F || 0x21 || 0x3F || 0x2026 => true,
  _ => false,
};

bool _isTrailingStopCu(int cu) => switch (cu) {
  0x3002 || 0xFF01 || 0xFF1F || 0x21 || 0x3F || 0x2026 || 0x201D || 0x300D || 0x300F || 0xFF09 || 0x22 || 0x27 => true,
  _ => false,
};

bool _hasSpeakable(String text, int start, int end) {
  var needsUnicodeCheck = false;
  for (var i = start; i < end; i++) {
    final cu = text.codeUnitAt(i);
    if ((cu >= 0x4E00 && cu <= 0x9FFF) ||
        (cu >= 0x30 && cu <= 0x39) ||
        (cu >= 0x41 && cu <= 0x5A) ||
        (cu >= 0x61 && cu <= 0x7A) ||
        (cu >= 0x3040 && cu <= 0x30FF) ||
        (cu >= 0x3400 && cu <= 0x4DBF) ||
        (cu >= 0xAC00 && cu <= 0xD7AF) ||
        (cu >= 0xFF10 && cu <= 0xFF19) ||
        (cu >= 0xFF21 && cu <= 0xFF3A) ||
        (cu >= 0xFF41 && cu <= 0xFF5A)) {
      return true;
    }
    if (cu > 0x7F &&
        !(cu >= 0x2000 && cu <= 0x206F) &&
        !(cu >= 0x3000 && cu <= 0x303F) &&
        !(cu >= 0xFF00 && cu <= 0xFF0F) &&
        !(cu >= 0xFF1A && cu <= 0xFF20) &&
        !(cu >= 0xFF3B && cu <= 0xFF40) &&
        !(cu >= 0xFF5B && cu <= 0xFF65)) {
      needsUnicodeCheck = true;
    }
  }
  return needsUnicodeCheck && _speakable.hasMatch(text.substring(start, end));
}

/// 把正文切成句子：按 。！？… 和换行切，太短的并入下一句，纯符号分隔线跳过；返回每句的 [start, end)。
List<(int, int)> splitSentences(String text) {
  final out = <(int, int)>[];
  final len = text.length;
  int? start;
  for (var i = 0; i < len; i++) {
    final cu = text.codeUnitAt(i);
    if (start == null) {
      if (!_isBlankCu(cu)) start = i;
      continue;
    }
    if (!_isSentenceStopCu(cu)) continue;
    var end = i + 1;
    if (cu != 0x0A) {
      while (end < len && _isTrailingStopCu(text.codeUnitAt(end))) {
        end++;
      }
    }
    if (!_hasSpeakable(text, start, end)) {
      i = end - 1;
      start = null;
      continue;
    }
    if (cu != 0x0A && end - start < 8 && end < len && text.codeUnitAt(end) != 0x0A) {
      i = end - 1;
      continue; // 太短，并入下一句
    }
    out.add((start, end));
    i = end - 1;
    start = null;
  }
  if (start != null && _hasSpeakable(text, start, len)) out.add((start, len));
  return out;
}
