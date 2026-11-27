import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' as material show Text;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../env.dart';
import '../highlights.dart';
import '../image_cache.dart';
import '../motion.dart';
import '../rules.dart';
import '../settings.dart';
import '../text.dart';
import '../widgets.dart';
import 'page_curl.dart';
import 'page_physics.dart';
import 'paginator.dart';
import 'reader_bg.dart';
import 'reader_chrome.dart';
import 'reader_image_viewer.dart';

part 'body/scroll_body.dart';
part 'body/paged_body.dart';

/// 章节：正文（已套用替换规则、统一缩进）、插图地址、高亮位置。
class Chapter {
  const Chapter({required this.text, required this.images, required this.marks, this.locked = false});

  final String text;
  final List<String> images;
  final List<Mark> marks;

  /// 受限书取不到正文，[text] 只是一句说明
  final bool locked;
}

/// 翻页时要接上的相邻章节。[cover] 是排在这章最前面的卷封面（只在双页时占一页）。
class ChapterPeek {
  const ChapterPeek({required this.chapter, required this.title, required this.spanOf, this.cover, this.volumeProgress});

  final Chapter chapter;
  final String title;
  final SpanOf spanOf;
  final String? cover;
  final double Function(double)? volumeProgress;
}

/// 双页时，紧挨在一章前后的那章开头要不要空出左页给别的页：前面有 [lead] 页、这章有 [count] 页时，奇数就是要。往前往后都是这个算法。
int adjacentLead(int lead, int count) => (lead + count) % 2;

/// 一章排好的页：可以有一页卷封面，后面是正文页和插图页。
class FlowPages {
  const FlowPages({required this.chapter, required this.title, required this.spanOf, required this.starts, required this.head, this.cover, this.volumeProgress});

  final Chapter chapter;
  final String title;
  final SpanOf spanOf;
  final List<int> starts;
  final double head; // 第一页开头章节标题的高度
  final String? cover;
  final double Function(double)? volumeProgress;

  int get textPages => chapter.text.trim().isNotEmpty ? starts.length : 0;
  int get total => textPages + chapter.images.length;
  int get covers => cover == null ? 0 : 1;
  int get count => covers + total;

  int units(int cols, int lead) => (lead + count + cols - 1) ~/ cols;

  int offsetOfPage(int page) => page < textPages ? starts[page] : chapter.text.length + 1 + (page - textPages);

  /// 第 [unit] 屏的第一页正文的字符偏移（封面、上一章的页不算）
  int offsetOfUnit(int unit, int cols, int lead) => offsetOfPage(math.min(math.max(0, unit * cols - lead - covers), math.max(total - 1, 0)));
}

/// 双页时一页显示页眉、页脚的哪部分：[full] 全部（单页、或只有这一边是正文），[left] 章节名和时间电量，[right] 页码进度。
enum _Chrome { full, left, right }

/// 往前翻章时用的"落在最后一页"标记（偏移量超出任何正文）。
const kToEnd = 1 << 30;

typedef SpanOf = InlineSpan Function(int from, int to);

/// 阅读正文样式。分页测量和实际显示必须用**完全相同**的样式，所以把会被主题继承的属性都写死。
TextStyle readerStyle(ReaderPrefs prefs, Color color, {String? family, List<String>? fallback}) => TextStyle(
  fontSize: prefs.fontSize,
  height: prefs.lineHeight,
  color: color,
  fontFamily: family,
  fontFamilyFallback: fallback,
  fontWeight: FontWeight.w400,
  fontStyle: FontStyle.normal,
  letterSpacing: prefs.letterSpacing,
  wordSpacing: 0,
  decoration: TextDecoration.none,
  leadingDistribution: TextLeadingDistribution.proportional,
);

/// 正文每一行固定高度（字号 × 行距）：变色、高亮的字所在的行不会再比别的行高，切页和显示的行高才对得上。
StrutStyle readerStrut(TextStyle s) => StrutStyle.fromTextStyle(s, forceStrutHeight: true);

/// 键盘（和其他外部操作）驱动翻页 / 滚动：正文组件把自己的动作挂到这里。
class ReaderNav {
  VoidCallback? next;
  VoidCallback? prev;

  /// 滚动模式：按像素滚动；翻页模式不用
  void Function(double)? scrollBy;

  /// 滚动模式：自动滚屏每帧直接步进像素，返回 true 正在滚 / false 已到底 / null 未就绪
  bool? Function(double)? autoScrollStep;

  /// 翻页模式：当前第几屏（从 0 起）、共几屏，底部进度条用；滚动模式不用
  final page = ValueNotifier<(int, int)>((0, 0));

  /// 翻页模式跳到第几屏；滚动模式跳到本章的某个比例（0~1）
  void Function(int)? toPage;
  void Function(double)? toFraction;
}

final _hlColorCache = <(int, bool), Color>{};

/// 按浅色/深色背景自动校正高亮字色，避免浅黄、浅黄绿在浅色纸面发虚，或深紫、深蓝在暗色背景看不清。
Color readableHighlightColor(Color raw, {required bool darkSurface}) {
  final key = (raw.toARGB32(), darkSurface);
  final cached = _hlColorCache[key];
  if (cached != null) return cached;
  final hsl = HSLColor.fromColor(raw);
  final Color out;
  if (!darkSurface) {
    // 黄色～绿青色段（40°~175°）视觉明度更高，需要更深一点才锐利清晰
    final hue = hsl.hue;
    final maxLight = (hue >= 38 && hue <= 175) ? 0.34 : 0.42;
    out = hsl.lightness > maxLight ? hsl.withLightness(maxLight).withSaturation(math.min(1.0, hsl.saturation * 1.05)).toColor() : raw;
  } else {
    const minLight = 0.68;
    out = hsl.lightness < minLight ? hsl.withLightness(minLight).withSaturation(math.min(0.85, hsl.saturation)).toColor() : raw;
  }
  if (_hlColorCache.length >= 128) _hlColorCache.clear();
  return _hlColorCache[key] = out;
}

/// 在按 `start` 升序排列的列表里二分定位第一个 `end > target` 的下标。
int _firstMarkOverlapping(List<Mark> marks, int target) {
  var lo = 0;
  var hi = marks.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (marks[mid].end <= target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _firstHighlightOverlapping(List<HighlightEntry> highlights, int target) {
  var lo = 0;
  var hi = highlights.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (highlights[mid].end <= target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// 取出 [from, to) 这一段正文，高亮的地方染色（有备注的加虚线下划线），[hl] 是朗读正在读的那一句，
/// [userHighlights] 是本章的自由划线摘录。颜色、底色和下划线不改变字形宽度，不影响分页。
InlineSpan buildSpan(
  Chapter c,
  int from,
  int to,
  TextStyle base,
  Set<String> noted, [
  (int, int)? hl,
  Color? hlColor,
  List<HighlightEntry> userHighlights = const [],
]) {
  if (from >= to) return TextSpan(style: base, text: '');
  final firstMark = c.marks.isEmpty ? 0 : _firstMarkOverlapping(c.marks, from);
  final firstUser = userHighlights.isEmpty ? 0 : _firstHighlightOverlapping(userHighlights, from);
  final hasMark = firstMark < c.marks.length && c.marks[firstMark].start < to;
  final hasUser = firstUser < userHighlights.length && userHighlights[firstUser].start < to;
  final hasReading = hl != null && hl.$2 > from && hl.$1 < to;
  if (!hasMark && !hasUser && !hasReading) {
    return TextSpan(style: base, text: c.text.substring(from, to));
  }

  final cuts = <int>{from, to};
  if (hasMark) {
    for (var i = firstMark; i < c.marks.length; i++) {
      final m = c.marks[i];
      if (m.start >= to) break;
      if (m.end <= from) continue;
      cuts..add(math.max(m.start, from))..add(math.min(m.end, to));
    }
  }
  if (hasUser) {
    for (var i = firstUser; i < userHighlights.length; i++) {
      final h = userHighlights[i];
      if (h.start >= to) break;
      if (h.end <= from) continue;
      cuts..add(math.max(h.start, from))..add(math.min(h.end, to));
    }
  }
  if (hasReading) {
    if (hl.$1 > from && hl.$1 < to) cuts.add(hl.$1);
    if (hl.$2 > from && hl.$2 < to) cuts.add(hl.$2);
  }
  final pts = cuts.toList()..sort();
  final darkSurface = (base.color?.computeLuminance() ?? 0) > 0.45;
  final children = <InlineSpan>[];
  var j = firstMark;
  var k = firstUser;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    while (j < c.marks.length && c.marks[j].end <= a) {
      j++;
    }
    final m = j < c.marks.length && c.marks[j].start <= a ? c.marks[j] : null;
    while (k < userHighlights.length && userHighlights[k].end <= a) {
      k++;
    }
    final uh = k < userHighlights.length && userHighlights[k].start <= a ? userHighlights[k] : null;
    final reading = hasReading && a >= hl.$1 && b <= hl.$2;
    TextStyle? style;
    if (m != null) {
      final rawColor = Color(m.rule.color);
      final fg = readableHighlightColor(rawColor, darkSurface: darkSurface);
      style = m.rule.kind == RuleKind.color
          ? TextStyle(color: fg)
          : TextStyle(
              color: fg,
              backgroundColor: rawColor.withValues(alpha: darkSurface ? 0.18 : 0.11),
              decoration: noted.contains(m.rule.id) ? TextDecoration.underline : null,
              decorationStyle: TextDecorationStyle.dotted,
              decorationColor: fg,
            );
    }
    if (uh != null) {
      final uc = Color(uh.colorValue);
      style = (style ?? const TextStyle()).copyWith(
        backgroundColor: style?.backgroundColor ?? uc.withValues(alpha: darkSurface ? 0.22 : 0.16),
        decoration: TextDecoration.underline,
        decorationStyle: uh.note.isNotEmpty ? TextDecorationStyle.solid : TextDecorationStyle.solid,
        decorationThickness: uh.note.isNotEmpty ? 2.0 : 1.4,
        decorationColor: uc.withValues(alpha: darkSurface ? 0.85 : 0.9),
      );
    }
    if (reading) style = (style ?? const TextStyle()).copyWith(backgroundColor: (hlColor ?? Colors.amber).withValues(alpha: 0.35));
    children.add(TextSpan(text: c.text.substring(a, b), style: style));
  }
  return TextSpan(style: base, children: children);
}

/// 把 `[from, to)` 按自然段换行 `\n` 切成段范围列表；页尾紧挨换行符时不产生尾随空段。
List<(int, int)> splitParagraphRanges(String text, int from, int to) {
  final end = to > from && text.codeUnitAt(to - 1) == 0x0A ? to - 1 : to;
  if (from >= end) return [(from, end)];
  final out = <(int, int)>[];
  var pStart = from;
  while (pStart <= end) {
    final nl = text.indexOf('\n', pStart);
    if (nl < 0 || nl >= end) {
      out.add((pStart, end));
      break;
    }
    out.add((pStart, nl));
    pStart = nl + 1;
  }
  return out;
}

/// 每章开头的章节标题，高度固定成 [headingHeight] 算的值（分页按这个高度给第一页留位置；调用方已算好时直接传 [height] 避免重复排版）。
/// [accent]：标题染色，并在标题下面的留白里画一条装饰线（「晴空」背景的三角旗、角色主题的蜡笔线；不占额外高度，不影响分页）
Widget chapterHeading(String title, TextStyle body, double width, {double? height, (Color, Widget Function(double width))? accent}) {
  final text = material.Text(title, style: headingStyle(body).copyWith(color: accent?.$1), textScaler: TextScaler.noScaling);
  return SizedBox(
    height: height ?? headingHeight(title, body, width),
    child: Align(
      alignment: Alignment.topLeft,
      child: accent == null
          ? text
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [text, SizedBox(height: (body.fontSize ?? 18) * 0.35), accent.$2(math.min(width * 0.45, 160))],
            ),
    ),
  );
}

/// 点击检测：用原始指针事件，不进手势竞技场，所以不会被 [SelectionArea] 或翻页手势吞掉。
/// 按下后移动不到 14 像素、300 毫秒内抬起算一次点击；按下时已有选中文字则这次点击只用来取消选择。
/// 点击翻了页之后的一小会儿，正文不接收触摸：连点翻页时第二下不会被选字组件当成双击选词。
class TapDetector extends StatefulWidget {
  const TapDetector({super.key, required this.child, required this.onTap, this.hasSelection});

  final Widget child;

  /// [local] 是点击在本组件内的位置，[size] 是组件大小，[global] 是屏幕位置；返回这次点击有没有翻页
  final bool Function(Offset local, Size size, Offset global) onTap;
  final bool Function()? hasSelection;

  @override
  State<TapDetector> createState() => _TapDetectorState();
}

bool _retryTap = false;

class _TapDetectorState extends State<TapDetector> {
  Offset? _down;
  DateTime _at = DateTime.now();
  bool _ignore = false;
  bool _turning = false;
  Timer? _turned;

  @override
  void dispose() {
    _turned?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) {
      _retryTap = false;
      _down = e.position;
      _at = DateTime.now();
      _ignore = widget.hasSelection?.call() ?? false;
    },
    onPointerMove: (e) {
      if (_down != null && (e.position - _down!).distance > 14) _down = null;
    },
    onPointerCancel: (_) {
      _retryTap = false;
      _down = null;
    },
    onPointerUp: (e) {
      final d = _down;
      _down = null;
      if (_retryTap) {
        _retryTap = false;
        return;
      }
      if (d == null || _ignore || DateTime.now().difference(_at) > const Duration(milliseconds: 300)) return;
      final box = context.findRenderObject() as RenderBox;
      if (!widget.onTap(box.globalToLocal(e.position), box.size, e.position)) return;
      setState(() => _turning = true);
      _turned?.cancel();
      // 比系统双击的判定时间（300 毫秒）长一点
      _turned = Timer(const Duration(milliseconds: 350), () => setState(() => _turning = false));
    },
    child: IgnorePointer(ignoring: _turning, child: widget.child),
  );
}

enum TapAction { prev, next, menu }

/// 点击分区（Mihon 的几种方案）：[zone] 0 默认 1 L 型 2 Kindle 式 3 边缘式 4 只呼出菜单；
/// [invert] 0 不反转 1 水平 2 垂直 3 两者（反转 = 把点的位置镜像一下）。
/// 默认方案：翻页模式点左右两边翻页，滚动模式（[paged] 为 false）点哪里都呼出菜单，和以前一样。
TapAction tapActionAt(int zone, int invert, Offset local, Size size, {required bool paged}) {
  if (!paged) return TapAction.menu;
  var x = (local.dx / size.width).clamp(0.0, 1.0);
  var y = (local.dy / size.height).clamp(0.0, 1.0);
  if (invert == 1 || invert == 3) x = 1 - x;
  if (invert == 2 || invert == 3) y = 1 - y;
  const a = 1 / 3, b = 2 / 3;
  switch (zone) {
    case 1: // 上和左中是上一页，下和右中是下一页
      if (y < a || (x < a && y < b)) return TapAction.prev;
      if (y >= b || x >= b) return TapAction.next;
      return TapAction.menu;
    case 2: // 上面一排呼出菜单，左边上一页，其余下一页
      if (y < a) return TapAction.menu;
      return x < a ? TapAction.prev : TapAction.next;
    case 3: // 左右两边下一页，底部中间上一页
      if (x < a || x >= b) return TapAction.next;
      return y >= b ? TapAction.prev : TapAction.menu;
    case 4:
      return TapAction.menu;
    default:
      return x < 0.3 ? TapAction.prev : (x > 0.7 ? TapAction.next : TapAction.menu);
  }
}

/// 3×3 点击区域示意图，直观展示上一页 / 菜单 / 下一页的分布。
class TapZoneDiagram extends StatelessWidget {
  const TapZoneDiagram({super.key, required this.zone, required this.invert});

  final int zone;
  final int invert;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const box = Size(90, 120);
    (String, Color, Color) styleOf(TapAction a) => switch (a) {
      TapAction.prev => ('上一页', scheme.secondary.withValues(alpha: 0.16), scheme.onSurface),
      TapAction.menu => ('菜单', scheme.onSurface.withValues(alpha: 0.07), scheme.onSurfaceVariant),
      TapAction.next => ('下一页', scheme.primary.withValues(alpha: 0.18), scheme.primary),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Row(
        children: [
          Container(
            width: 114,
            height: 84,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outline),
            ),
            child: Column(
              children: [
                for (var r = 0; r < 3; r++)
                  Expanded(
                    child: Row(
                      children: [
                        for (var c = 0; c < 3; c++)
                          () {
                            final act = tapActionAt(zone, invert, Offset((c + 0.5) / 3 * box.width, (r + 0.5) / 3 * box.height), box, paged: true);
                            final (label, bg, fg) = styleOf(act);
                            return Expanded(
                              child: Container(
                                margin: const EdgeInsets.all(1.5),
                                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
                                alignment: Alignment.center,
                                child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
                              ),
                            );
                          }(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              zone == 4 ? '点击屏幕任意位置只呼出菜单，用滑动、滚轮或按键翻页。' : '点击对应区域即可翻页或呼出菜单；在页面顶部下拉可添加书签。',
              style: TextStyle(fontSize: 12.5, height: 1.45, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页脚：左边时间和电量（[status] 每分钟刷新，只重建这一行，不影响正文和分页），右边页码 / 进度。
class ReaderFooter extends StatelessWidget {
  const ReaderFooter({super.key, required this.right, required this.style, this.status});

  final String right;
  final TextStyle style;
  final ValueListenable<String>? status;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      status == null ? const SizedBox.shrink() : ValueListenableBuilder<String>(valueListenable: status!, builder: (_, v, _) => Text(v, style: style)),
      Text(right, style: style),
    ],
  );
}

/// 查找屏幕位置 [global] 在 [key] 对应的段落中命中的全局字符偏移（未落在字形上返回 null）。
int? _hitOffsetInKey(GlobalKey key, int base, Offset global) {
  final ro = key.currentContext?.findRenderObject();
  if (ro is! RenderParagraph) return null;
  final local = ro.globalToLocal(global);
  if (local.dx < -2 || local.dy < -2 || local.dx > ro.size.width + 2 || local.dy > ro.size.height + 2) return null;
  final pos = ro.getPositionForOffset(local).offset;
  // 只认真正落在那个字上的点击，行尾空白处不算
  final boxes = ro.getBoxesForSelection(TextSelection(baseOffset: pos, extentOffset: pos + 1));
  if (!boxes.any((b) => b.toRect().inflate(2).contains(local))) return null;
  return base + pos;
}

int? _hitOffsetInKeys(List<(int, GlobalKey)> keys, Offset global) {
  for (final (base, key) in keys) {
    final hit = _hitOffsetInKey(key, base, global);
    if (hit != null) return hit;
  }
  return null;
}

Mark? _markAtOffset(Chapter c, int idx) {
  if (c.marks.isEmpty) return null;
  final i = _firstMarkOverlapping(c.marks, idx);
  if (i < c.marks.length) {
    final m = c.marks[i];
    if (idx >= m.start && idx < m.end) return m.rule.kind == RuleKind.highlight ? m : null;
  }
  return null;
}

HighlightEntry? _highlightAtOffset(List<HighlightEntry> highlights, int idx) {
  if (highlights.isEmpty) return null;
  final i = _firstHighlightOverlapping(highlights, idx);
  if (i < highlights.length) {
    final h = highlights[i];
    if (idx >= h.start && idx < h.end) return h;
  }
  return null;
}

/// 在 [key] 对应的段落里找屏幕位置 [global] 点中了哪个高亮，[base] 是这段文字在整章里的起点。
Mark? markAt(Chapter c, GlobalKey key, int base, Offset global) {
  final idx = _hitOffsetInKey(key, base, global);
  return idx == null ? null : _markAtOffset(c, idx);
}

/// 在 [key] 对应的段落里找屏幕位置 [global] 点中了哪条自由划线摘录。
HighlightEntry? highlightAt(List<HighlightEntry> highlights, GlobalKey key, int base, Offset global) {
  final idx = _hitOffsetInKey(key, base, global);
  return idx == null ? null : _highlightAtOffset(highlights, idx);
}

/// 按 `[start, end)` 区间过滤朗读高亮通知：仅当高亮切入、移动于本区间内或切出时才重建子组件，
/// 避免双页另一页或滚屏其余段落块随逐句朗读无效重建。
class _ScopedHighlightBuilder extends StatefulWidget {
  const _ScopedHighlightBuilder({
    required this.highlight,
    required this.start,
    required this.end,
    required this.builder,
  });

  final ValueListenable<(int, int)?> highlight;
  final int start;
  final int end;
  final Widget Function(BuildContext context, (int, int)? hl) builder;

  @override
  State<_ScopedHighlightBuilder> createState() => _ScopedHighlightBuilderState();
}

class _ScopedHighlightBuilderState extends State<_ScopedHighlightBuilder> {
  (int, int)? _active;

  (int, int)? _clipped((int, int)? hl) => (hl != null && hl.$2 > widget.start && hl.$1 < widget.end) ? hl : null;

  void _onHighlight() {
    final next = _clipped(widget.highlight.value);
    if (next != _active) setState(() => _active = next);
  }

  @override
  void initState() {
    super.initState();
    _active = _clipped(widget.highlight.value);
    widget.highlight.addListener(_onHighlight);
  }

  @override
  void didUpdateWidget(_ScopedHighlightBuilder old) {
    super.didUpdateWidget(old);
    if (widget.highlight != old.highlight) {
      old.highlight.removeListener(_onHighlight);
      widget.highlight.addListener(_onHighlight);
    }
    _active = _clipped(widget.highlight.value);
  }

  @override
  void dispose() {
    widget.highlight.removeListener(_onHighlight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _active);
}

Widget _readerImageWidget(
  String url,
  Color? color, {
  List<String>? gallery,
  int index = 0,
  Size? decodeSize,
  ColorFilter? colorFilter,
}) => _ReaderIllustration(url: url, color: color, gallery: gallery, index: index, decodeSize: decodeSize, colorFilter: colorFilter);

class _ReaderIllustration extends ConsumerStatefulWidget {
  const _ReaderIllustration({
    required this.url,
    this.color,
    this.gallery,
    this.index = 0,
    this.decodeSize,
    this.colorFilter,
  });

  final String url;
  final Color? color;
  final List<String>? gallery;
  final int index;
  final Size? decodeSize;
  final ColorFilter? colorFilter;

  @override
  ConsumerState<_ReaderIllustration> createState() => _ReaderIllustrationState();
}

class _ReaderIllustrationState extends ConsumerState<_ReaderIllustration> {
  late final ValueNotifier<bool> _ready;
  int _activePlaceholders = 0;
  bool _syncScheduled = false;

  bool _peekReady(String url) {
    if (isWebPreview) return true;
    try {
      return ref.read(imageStoreProvider).peek(url) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _ready = ValueNotifier<bool>(_peekReady(widget.url));
  }

  @override
  void didUpdateWidget(_ReaderIllustration old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url) {
      _ready.value = _peekReady(widget.url);
    }
  }

  @override
  void dispose() {
    _ready.dispose();
    super.dispose();
  }

  void _onPlaceholderDelta(int delta) {
    _activePlaceholders = math.max(0, _activePlaceholders + delta);
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final next = _activePlaceholders == 0;
      if (_ready.value != next) _ready.value = next;
    });
  }

  void _openViewer(BuildContext context) {
    if (!_ready.value) return;
    final urls = (widget.gallery != null && widget.gallery!.isNotEmpty) ? widget.gallery! : [widget.url];
    showReaderImageViewer(context, urls: urls, initialIndex: widget.index);
  }

  @override
  Widget build(BuildContext context) {
    final muted = (widget.color ?? Colors.grey).withValues(alpha: 0.55);
    Widget img = NetImage(
      widget.url,
      fit: BoxFit.contain,
      decodeSize: widget.decodeSize,
      loading: _IllustrationPlaceholderTrack(
        onDelta: _onPlaceholderDelta,
        child: SizedBox(
          height: 220,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: muted)),
                const SizedBox(height: 12),
                Text('图片加载中…', style: TextStyle(fontSize: 13, color: muted)),
              ],
            ),
          ),
        ),
      ),
      errorBuilder: (retry) => _IllustrationPlaceholderTrack(
        onDelta: _onPlaceholderDelta,
        child: SizedBox(
          height: 220,
          child: Center(
            child: Listener(
              onPointerUp: (_) => _retryTap = true,
              child: TextButton.icon(
                onPressed: retry,
                style: TextButton.styleFrom(foregroundColor: muted),
                icon: const Icon(Icons.broken_image_outlined, size: 22),
                label: const Text('图片加载失败，点击重试'),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.colorFilter != null) {
      img = ColorFiltered(colorFilter: widget.colorFilter!, child: img);
    }
    return GestureDetector(
      onLongPress: () => _openViewer(context),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: img),
          Positioned(
            right: 4,
            bottom: 4,
            child: ValueListenableBuilder<bool>(
              valueListenable: _ready,
              builder: (context, ready, _) {
                if (!ready) return const SizedBox.shrink();
                return Listener(
                  onPointerUp: (_) => _retryTap = true,
                  child: Tooltip(
                    message: hz(context, '全屏查看插图'),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => _openViewer(context),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(Icons.zoom_out_map_rounded, size: 16, color: Colors.white70),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _IllustrationPlaceholderTrack extends StatefulWidget {
  const _IllustrationPlaceholderTrack({required this.onDelta, required this.child});

  final ValueChanged<int> onDelta;
  final Widget child;

  @override
  State<_IllustrationPlaceholderTrack> createState() => _IllustrationPlaceholderTrackState();
}

class _IllustrationPlaceholderTrackState extends State<_IllustrationPlaceholderTrack> {
  @override
  void initState() {
    super.initState();
    widget.onDelta(1);
  }

  @override
  void dispose() {
    widget.onDelta(-1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

