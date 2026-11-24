import 'package:flutter/painting.dart';

/// 超过该长度的长章按自然段分块测量，避免单个超大 [TextPainter] 阻塞主线程。
const _chunkThreshold = 16000;
const _chunkTarget = 6000;

/// 把一章文字按页面大小切页，返回每页第一个字符的偏移（第一页恒为 0）。
///
/// 只负责排版，不关心界面：翻页、进度保存、改字号后重新切页都只用这一个函数。
/// [strut] 要和实际显示正文时用的一样：变色、高亮的文字所在的行会比普通行高一点，不统一行高的话，
/// 切页时量出来每页装得下的行数，和显示出来的对不上，最后一行就被页脚盖住。
/// [firstTop] 是第一页顶上让给章节标题的高度（[headingHeight]）。
List<int> paginate(String text, TextStyle style, Size size, {TextDirection textDirection = TextDirection.ltr, StrutStyle? strut, double firstTop = 0}) {
  if (text.isEmpty) return [0];
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

/// 把正文切成句子：按 。！？… 和换行切，太短的并入下一句，纯符号分隔线跳过；返回每句的 [start, end)。
List<(int, int)> splitSentences(String text) {
  final out = <(int, int)>[];
  int? start;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    final blank = ch == '\n' || ch == ' ' || ch == '\u3000';
    if (start == null) {
      if (!blank) start = i;
      continue;
    }
    final stop = ch == '\n' || '。！？!?…'.contains(ch);
    if (!stop) continue;
    var end = i + 1;
    if (ch != '\n') {
      while (end < text.length && '。！？!?…”」』）"\''.contains(text[end])) {
        end++;
      }
    }
    if (!_speakable.hasMatch(text.substring(start, end))) {
      i = end - 1;
      start = null;
      continue;
    }
    if (ch != '\n' && end - start < 8 && end < text.length && text[end] != '\n') {
      i = end - 1;
      continue; // 太短，并入下一句
    }
    out.add((start, end));
    i = end - 1;
    start = null;
  }
  if (start != null && _speakable.hasMatch(text.substring(start))) out.add((start, text.length));
  return out;
}
