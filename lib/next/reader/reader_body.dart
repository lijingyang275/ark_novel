import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' as material show Text;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../env.dart';
import '../image_cache.dart';
import '../rules.dart';
import '../settings.dart';
import '../text.dart';
import '../widgets.dart';
import 'page_curl.dart';
import 'page_physics.dart';
import 'paginator.dart';
import 'reader_chrome.dart';
import 'reader_image_viewer.dart';

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
  letterSpacing: 0,
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

/// 按浅色/深色背景自动校正高亮字色，避免浅黄、浅黄绿在浅色纸面发虚，或深紫、深蓝在暗色背景看不清。
Color readableHighlightColor(Color raw, {required bool darkSurface}) {
  final hsl = HSLColor.fromColor(raw);
  if (!darkSurface) {
    // 黄色～绿青色段（40°~175°）视觉明度更高，需要更深一点才锐利清晰
    final hue = hsl.hue;
    final maxLight = (hue >= 38 && hue <= 175) ? 0.34 : 0.42;
    if (hsl.lightness > maxLight) {
      return hsl.withLightness(maxLight).withSaturation(math.min(1.0, hsl.saturation * 1.05)).toColor();
    }
    return raw;
  }
  const minLight = 0.68;
  if (hsl.lightness < minLight) {
    return hsl.withLightness(minLight).withSaturation(math.min(0.85, hsl.saturation)).toColor();
  }
  return raw;
}

/// 取出 [from, to) 这一段正文，高亮的地方染色（有备注的加虚线下划线），[hl] 是朗读正在读的那一句。颜色、底色和下划线不改变字形宽度，不影响分页。
InlineSpan buildSpan(Chapter c, int from, int to, TextStyle base, Set<String> noted, [(int, int)? hl, Color? hlColor]) {
  final cuts = <int>{from, to};
  for (final m in c.marks) {
    if (m.end <= from) continue;
    if (m.start >= to) break;
    cuts..add(math.max(m.start, from))..add(math.min(m.end, to));
  }
  if (hl != null) {
    for (final x in [hl.$1, hl.$2]) {
      if (x > from && x < to) cuts.add(x);
    }
  }
  final pts = cuts.toList()..sort();
  final darkSurface = (base.color?.computeLuminance() ?? 0) > 0.45;
  final children = <InlineSpan>[];
  var j = 0;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    while (j < c.marks.length && c.marks[j].end <= a) {
      j++;
    }
    final m = j < c.marks.length && c.marks[j].start <= a ? c.marks[j] : null;
    final reading = hl != null && a >= hl.$1 && b <= hl.$2;
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
    if (reading) style = (style ?? const TextStyle()).copyWith(backgroundColor: (hlColor ?? Colors.amber).withValues(alpha: 0.35));
    children.add(TextSpan(text: c.text.substring(a, b), style: style));
  }
  return TextSpan(style: base, children: children);
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

/// 在 [key] 对应的段落里找屏幕位置 [global] 点中了哪个高亮，[base] 是这段文字在整章里的起点。
Mark? markAt(Chapter c, GlobalKey key, int base, Offset global) {
  final ro = key.currentContext?.findRenderObject();
  if (ro is! RenderParagraph) return null;
  final local = ro.globalToLocal(global);
  final pos = ro.getPositionForOffset(local).offset;
  // 只认真正落在那个字上的点击，行尾空白处不算
  final boxes = ro.getBoxesForSelection(TextSelection(baseOffset: pos, extentOffset: pos + 1));
  if (!boxes.any((b) => b.toRect().inflate(2).contains(local))) return null;
  final idx = base + pos;
  for (final m in c.marks) {
    if (idx >= m.start && idx < m.end) return m.rule.kind == RuleKind.highlight ? m : null;
  }
  return null;
}

Widget _readerImageWidget(String url, Color? color, {List<String>? gallery, int index = 0}) =>
    _ReaderIllustration(url: url, color: color, gallery: gallery, index: index);

class _ReaderIllustration extends ConsumerWidget {
  const _ReaderIllustration({required this.url, this.color, this.gallery, this.index = 0});

  final String url;
  final Color? color;
  final List<String>? gallery;
  final int index;

  void _openViewer(BuildContext context) {
    final urls = (gallery != null && gallery!.isNotEmpty) ? gallery! : [url];
    showReaderImageViewer(context, urls: urls, initialIndex: index);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = (color ?? Colors.grey).withValues(alpha: 0.55);
    final loaded = isWebPreview || (!isWebPreview && (ref.read(imageStoreProvider).peek(url) != null || ref.watch(imageBytesProvider(url)).hasValue));
    final img = NetImage(
      url,
      fit: BoxFit.contain,
      loading: SizedBox(
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
      errorBuilder: (retry) => SizedBox(
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
    );
    if (!loaded) return img;
    return GestureDetector(
      onLongPress: () => _openViewer(context),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: img),
          Positioned(
            right: 4,
            bottom: 4,
            child: Listener(
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
            ),
          ),
        ],
      ),
    );
  }
}

/// 上下滚动。进度用字符偏移：保存时取视口顶部对应的字符，恢复时再换算回滚动位置，所以改字号、延迟加载插图都不会跳位置。
class ScrollBody extends StatefulWidget {
  const ScrollBody({
    super.key,
    required this.chapter,
    required this.spanOf,
    this.spanOfHighlight,
    this.highlight,
    required this.style,
    required this.margin,
    this.title = '',
    this.headingAccent,
    required this.startOffset,
    required this.onOffset,
    required this.onEnd,
    required this.onNext,
    this.nextLabel = '下一章',
    required this.wrap,
    required this.onTapZone,
    this.menuOpen,
    required this.onMark,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.onPullDown,
    this.marked,
    this.onUserInteract,
    this.showHeader = false,
  });

  final int tapZone;
  final int tapInvert;

  /// 在章首继续往下拉：加 / 取消书签；[marked] 是当前位置有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final VoidCallback? onUserInteract;
  final bool showHeader;
  final Chapter chapter;
  final SpanOf spanOf;
  final InlineSpan Function(int from, int to, (int, int)? hl)? spanOfHighlight;
  final ValueListenable<(int, int)?>? highlight;
  final TextStyle style;
  final double margin;

  /// 章节名，显示在正文开头
  final String title;
  final (Color, Widget Function(double width))? headingAccent;
  final int startOffset;
  final ValueChanged<int> onOffset;

  /// 滚到章末
  final VoidCallback onEnd;
  final VoidCallback? onNext;

  /// 章末按钮的字：全书最后一章是「读完了」
  final String nextLabel;
  final Widget Function(Widget) wrap;

  /// 点在空白处（切换菜单栏）
  final VoidCallback onTapZone;

  /// 菜单开着时点哪里都只收起菜单（[onTapZone]），不翻页、不点备注
  final bool Function()? menuOpen;
  final void Function(Mark) onMark;

  /// 朗读正在读的位置（字符偏移）：不在当前屏幕内时自动翻页 / 滚动过去
  final int? follow;
  final ReaderNav? nav;
  final bool Function() hasSelection;

  @override
  State<ScrollBody> createState() => _ScrollBodyState();
}

class _ScrollBodyState extends State<ScrollBody> {
  final _controller = ScrollController();
  final _textKey = GlobalKey();
  double _padTop = 0; // 正文第一行到滚动内容顶部的距离（含章节标题）
  DateTime _lastAutoReport = DateTime.fromMillisecondsSinceEpoch(0);

  void _followOffset(int f) {
    if (!mounted || !_controller.hasClients) return;
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final y = _padTop + ro.getOffsetForCaret(TextPosition(offset: math.min(f, widget.chapter.text.length)), Rect.zero).dy;
    final view = _controller.position;
    if (y < view.pixels || y > view.pixels + view.viewportDimension - 120) {
      _controller.animateTo((y - 80).clamp(0.0, view.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _onHighlight() {
    final hl = widget.highlight?.value;
    if (hl != null) _followOffset(hl.$1);
  }

  bool? _autoStep(double dy) {
    if (!mounted || !_controller.hasClients) return null;
    final pos = _controller.position;
    if (pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 1.5) {
      widget.onEnd();
      return false;
    }
    final next = (pos.pixels + dy).clamp(0.0, pos.maxScrollExtent);
    _controller.jumpTo(next);
    final now = DateTime.now();
    if (now.difference(_lastAutoReport) >= const Duration(milliseconds: 500) || next >= pos.maxScrollExtent - 1.5) {
      _lastAutoReport = now;
      widget.onOffset(_charAtTop());
    }
    if (next >= pos.maxScrollExtent - 1.5) {
      widget.onEnd();
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    widget.highlight?.addListener(_onHighlight);
    widget.nav
      ?..next = (() => _page(1))
      ..prev = (() => _page(-1))
      ..scrollBy = _nudge
      ..autoScrollStep = _autoStep
      ..toPage = null
      ..toFraction = ((f) {
        if (_controller.hasClients) _controller.jumpTo(f.clamp(0.0, 1.0) * _controller.position.maxScrollExtent);
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void didUpdateWidget(ScrollBody old) {
    super.didUpdateWidget(old);
    if (widget.highlight != old.highlight) {
      old.highlight?.removeListener(_onHighlight);
      widget.highlight?.addListener(_onHighlight);
    }
    final f = widget.follow;
    if (f != null && f != old.follow) _followOffset(f);
  }

  @override
  void dispose() {
    widget.highlight?.removeListener(_onHighlight);
    _controller.dispose();
    super.dispose();
  }

  void _nudge(double dy) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    _controller.animateTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent), duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
  }

  /// 滚一屏（留一点重叠）；已经到底再往后就去下一章。
  void _page(int dir) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    if (dir > 0 && p.pixels >= p.maxScrollExtent - 2) return widget.onNext?.call();
    _nudge(dir * p.viewportDimension * 0.9);
  }

  void _restore() {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final off = widget.startOffset;
    final ro = _textKey.currentContext?.findRenderObject();
    if (off >= kToEnd) {
      _controller.jumpTo(max);
      widget.onOffset(_charAtTop());
      return;
    }
    if (off > 0 && widget.chapter.text.trim().isEmpty && widget.chapter.images.isNotEmpty && max > 0) {
      final idx = (off - 1).clamp(0, widget.chapter.images.length - 1);
      _controller.jumpTo((idx / widget.chapter.images.length * max).clamp(0.0, max));
    } else if (off > 0 && ro is RenderParagraph) {
      final caret = ro.getOffsetForCaret(TextPosition(offset: math.min(off, widget.chapter.text.length)), Rect.zero);
      _controller.jumpTo((_padTop + caret.dy).clamp(0.0, max));
    }
    if (max <= 0 || _controller.position.pixels >= max - 40) widget.onEnd();
  }

  int _charAtTop() {
    if (widget.chapter.text.trim().isEmpty) {
      if (!_controller.hasClients || widget.chapter.images.isEmpty) return 0;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) return 0;
      final ratio = (_controller.position.pixels / max).clamp(0.0, 0.9999);
      return 1 + (ratio * widget.chapter.images.length).floor();
    }
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return 0;
    final top = (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy;
    final y = top - ro.localToGlobal(Offset.zero).dy;
    return y <= 0 ? 0 : ro.getPositionForOffset(Offset(0, y)).offset;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chapter;
    final hasText = c.text.trim().isNotEmpty;
    final width = MediaQuery.sizeOf(context).width - widget.margin * 2;
    final head = hasText ? headingHeight(widget.title, widget.style, width) : 0.0;
    final padTop = MediaQuery.viewPaddingOf(context).top + (widget.showHeader ? 36 : 24);
    _padTop = padTop + head;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          widget.onUserInteract?.call();
        } else if (n is ScrollEndNotification) {
          widget.onOffset(_charAtTop());
          if (n.metrics.maxScrollExtent <= 0 || n.metrics.pixels >= n.metrics.maxScrollExtent - 40) widget.onEnd();
        }
        return false;
      },
      child: TapDetector(
        hasSelection: widget.hasSelection,
        onTap: (local, size, global) {
          if (widget.menuOpen?.call() ?? false) {
            widget.onTapZone();
            return false;
          }
          final m = markAt(c, _textKey, 0, global);
          if (m != null) {
            widget.onMark(m);
            return false;
          }
          switch (tapActionAt(widget.tapZone, widget.tapInvert, local, size, paged: false)) {
            case TapAction.prev:
              widget.onUserInteract?.call();
              _page(-1);
            case TapAction.next:
              widget.onUserInteract?.call();
              _page(1);
            case TapAction.menu:
              widget.onTapZone();
              return false;
          }
          return true;
        },
        child: PullBookmark(
          onPull: widget.onPullDown,
          marked: widget.marked,
          color: widget.style.color ?? Colors.grey,
          top: MediaQuery.viewPaddingOf(context).top,
          child: widget.wrap(
          SingleChildScrollView(
            controller: _controller,
            padding: EdgeInsets.fromLTRB(widget.margin, padTop, widget.margin, MediaQuery.viewPaddingOf(context).bottom + 48), // 底部留出页脚的高度，别挡字
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (head > 0) chapterHeading(widget.title, widget.style, width, height: head, accent: widget.headingAccent),
                if (widget.highlight != null && widget.spanOfHighlight != null)
                  ValueListenableBuilder<(int, int)?>(
                    valueListenable: widget.highlight!,
                    builder: (_, hl, _) => material.Text.rich(widget.spanOfHighlight!(0, c.text.length, hl), key: _textKey, textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
                  )
                else
                  material.Text.rich(widget.spanOf(0, c.text.length), key: _textKey, textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
                for (var idx = 0; idx < c.images.length; idx++) Padding(padding: const EdgeInsets.only(top: 16), child: _readerImageWidget(c.images[idx], widget.style.color, gallery: c.images, index: idx)),
                if (widget.onNext != null) Padding(padding: const EdgeInsets.only(top: 32), child: OutlinedButton(onPressed: widget.onNext, child: Text(widget.nextLabel))),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// 下拉加书签：往下拉时整页跟着手指往下移（越拉越沉），顶上露出一条，中间是书签图标和提示；
/// 拉过 [_threshold] 图标变实心、轻震一下，松手加 / 取消书签，页面带一点回弹缩回去。平时什么都不显示。
/// 翻页模式（[drag]）直接认竖向拖动；滚动模式只认滚到顶后继续往下拉（滚动视图的越界通知）。
class PullBookmark extends StatefulWidget {
  const PullBookmark({super.key, required this.child, required this.onPull, required this.marked, required this.color, required this.top, this.drag = false});

  final Widget child;
  final VoidCallback? onPull;
  final bool Function()? marked;
  final Color color;
  final double top; // 状态栏高度
  final bool drag;

  @override
  State<PullBookmark> createState() => _PullBookmarkState();
}

class _PullBookmarkState extends State<PullBookmark> with SingleTickerProviderStateMixin {
  static const _threshold = 72.0, _max = 120.0;
  double _pull = 0; // 手指拉下的距离（原始值）
  late final _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 380))..addListener(() => setState(() {}));
  double _from = 0; // 松手时露出的高度，回弹从这里开始

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  /// 页面实际下移的距离：越往下越拉不动
  double get _shown {
    if (_back.isAnimating) return _from * (1 - Curves.easeOutBack.transform(_back.value));
    return _pull <= 0 ? 0 : _max * (1 - math.exp(-_pull / _max));
  }

  void _update(double v) {
    if (_back.isAnimating) _back.stop();
    final was = _pull >= _threshold;
    setState(() => _pull = v.clamp(0, _max * 3));
    if (!was && _pull >= _threshold) HapticFeedback.mediumImpact();
  }

  void _release() {
    if (_pull <= 0) return;
    if (_pull >= _threshold) widget.onPull?.call();
    _from = _shown;
    _pull = 0;
    _back.forward(from: 0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _update(_pull - n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // iOS 回弹式滚动：顶部越界是负的 pixels；正常往下滚就收回
      n.metrics.pixels < 0 ? _update(-n.metrics.pixels) : (_pull > 0 ? _update(_pull - (n.scrollDelta ?? 0)) : null);
    } else if (n is ScrollEndNotification) {
      _release();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPull == null) return widget.child;
    final shown = _shown;
    final ready = _pull >= _threshold;
    final marked = widget.marked?.call() ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    final progress = (_pull / _threshold).clamp(0.0, 1.0);
    Widget child = Transform.translate(offset: Offset(0, shown), child: widget.child);
    child = widget.drag
        ? GestureDetector(
            supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}, // 鼠标拖动留给选字，触控板双指留给翻页
            onVerticalDragUpdate: (d) => _update(_pull + d.delta.dy),
            onVerticalDragEnd: (_) => _release(),
            onVerticalDragCancel: _release,
            child: child,
          )
        : NotificationListener<ScrollNotification>(onNotification: _onScroll, child: child);
    return Stack(
      children: [
        child,
        // 页面下移后露出来的那一条（画在页面上面：仿真翻页的页面不透明）
        if (shown > 1)
          Positioned(
            top: widget.top,
            left: 0,
            right: 0,
            height: math.max(0, shown),
            child: IgnorePointer(
              child: Opacity(
                opacity: (shown / 48).clamp(0.0, 1.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.scale(
                      scale: 0.8 + 0.25 * progress,
                      child: Icon(
                        ready ? (marked ? Icons.bookmark_remove : Icons.bookmark_added) : (marked ? Icons.bookmark : Icons.bookmark_add_outlined),
                        size: 26,
                        color: ready ? accent : widget.color.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ready ? (marked ? '松手取消书签' : '松手添加书签') : (marked ? '下拉取消书签' : '下拉添加书签'),
                      style: TextStyle(fontSize: 13, color: ready ? accent : widget.color.withValues(alpha: 0.55), fontWeight: ready ? FontWeight.w600 : null),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 左右翻页（滑动 / 仿真）。页面大小或字号、字体变了会重新分页，并按"当前读到的字符"回到同一处。
class PagedBody extends StatefulWidget {
  const PagedBody({
    super.key,
    required this.chapter,
    required this.spanOf,
    this.spanOfHighlight,
    this.highlight,
    required this.style,
    required this.margin,
    required this.title,
    required this.curl,
    this.cover = false,
    this.dual = false,
    required this.background,
    required this.color,
    required this.startOffset,
    required this.onOffset,
    required this.onEnd,
    required this.onPrev,
    required this.onNext,
    required this.wrap,
    required this.onTapZone,
    this.menuOpen,
    required this.onMark,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.status,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.showFooter = true,
    this.animate = true,
    this.volumeProgress,
    this.onPullDown,
    this.marked,
    this.headingAccent,
    this.prevChapter,
    this.nextChapter,
    this.volumeCover,
    this.lead = 0,
    this.arrivedBack = false,
    this.onTurn,
    this.pageBackground,
    this.backgroundKey,
    this.chromeConfig,
    this.onUserInteract,
  });

  final Widget? pageBackground;
  final Object? backgroundKey;
  final ReaderChromeConfig? chromeConfig;
  final VoidCallback? onUserInteract;

  /// 相邻章节已经加载好时传进来：翻到头时接着翻过去，不用另外的换章动画，双页时还用来补空着的半边
  final ChapterPeek? prevChapter;
  final ChapterPeek? nextChapter;

  /// 这章在一卷开头时那一卷的封面：双页时放在第一页前面
  final String? volumeCover;

  /// 双页时第一屏左页是不是留给上一章的最后一页（或上一章接过来的页）：0 或 1
  final int lead;

  /// 是往回翻过来的，落在最后一屏也不算读完
  final bool arrivedBack;

  /// 翻进相邻章节后调用：方向、那章的 [lead]、落点的字符偏移
  final void Function(int dir, int lead, int offset)? onTurn;

  /// 在页面上往下拉：加 / 取消书签；[marked] 是当前页有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final (Color, Widget Function(double width))? headingAccent;

  /// 最近一次排版用的单页大小和一屏几页：书签算页码时用，和正文排版一模一样
  static (Size, int)? lastLayout;

  /// 滑动翻页时要不要动画
  final bool animate;

  /// 本章读到的比例（0~1）换算成本卷进度，页脚右边的百分比用它；没有时显示本章进度
  final double Function(double)? volumeProgress;

  final int tapZone;
  final int tapInvert;
  final bool showFooter;

  final Chapter chapter;
  final SpanOf spanOf;
  final InlineSpan Function(int from, int to, (int, int)? hl)? spanOfHighlight;
  final ValueListenable<(int, int)?>? highlight;
  final TextStyle style;
  final double margin;
  final String title;

  /// 页脚左边的"时间 电量"
  final ValueListenable<String>? status;
  final bool curl;
  final bool cover;

  /// 宽屏双页：一屏显示左右两页，像摊开的书
  final bool dual;
  final Color background;
  final Color color;
  final int startOffset;
  final ValueChanged<int> onOffset;
  final VoidCallback onEnd;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final Widget Function(Widget) wrap;
  final VoidCallback onTapZone;

  /// 菜单开着时点哪里都只收起菜单（[onTapZone]），不翻页、不点备注
  final bool Function()? menuOpen;
  final void Function(Mark) onMark;

  /// 朗读正在读的位置（字符偏移）：不在当前屏幕内时自动翻页 / 滚动过去
  final int? follow;
  final ReaderNav? nav;
  final bool Function() hasSelection;

  @override
  State<PagedBody> createState() => _PagedBodyState();
}

class _PagedBodyState extends State<PagedBody> {
  // 分页结果留几章：翻过去时刚排过的相邻章不用再排一遍
  static final _pageCache = <(Size, TextStyle, String, String), List<int>>{};

  final _curl = PageCurlController();
  final _keys = <int, GlobalKey>{};
  PageController? _controller;
  List<int> _starts = const [0];
  Object? _sig;
  int _page = 0;
  int _cur = 0; // 当前页开头的字符偏移
  // 重新分页时按它定位：打开时的位置，之后是用户翻到的页的开头。重新分页只会落到包含它的那页，
  // 不改它，所以来回改字号、转屏不会每次往前吸附一点、越漂越远
  int _anchor = 0;
  double _overscroll = 0;
  double? _dragFrom; // 这次拖动开始时在第几页，翻页手感按它算（见 SwipePagePhysics）
  int _cols = 1; // 一屏几页（1 或 2）；_page、翻页动画的"页"都以一屏为单位
  double _head = 0; // 第一页开头章节标题的高度
  double _width = 0;
  Size _imgBox = Size.zero; // 插图页的大小（整页，双页时一半），按它提前解码
  Size _layoutSize = Size.zero;
  Chapter? _fetched; // 已经开始在后台下载整章插图的那一章
  FlowPages? _prev, _next;
  int _base = 0; // 滑动翻页时 PageView 的第 0 项是不是上一章（是的话为 1）
  bool _peekScheduled = false;
  bool _scrolling = false;

  void _followOffset(int f) {
    if (!mounted || _total == 0) return;
    final p = _pageOf(f);
    if (p == _page) return;
    if (widget.curl) {
      _curl.goTo(p);
    } else {
      _controller?.animateToPage(p + _base, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  void _onHighlight() {
    final hl = widget.highlight?.value;
    if (hl != null) _followOffset(hl.$1);
  }

  @override
  void initState() {
    super.initState();
    _cur = widget.startOffset;
    _anchor = widget.startOffset;
    widget.highlight?.addListener(_onHighlight);
    widget.nav
      ?..next = (() => _step(1))
      ..prev = (() => _step(-1))
      ..autoScrollStep = null
      ..toFraction = null
      ..toPage = _jump;
  }

  @override
  void didUpdateWidget(PagedBody old) {
    super.didUpdateWidget(old);
    _meCache = null; // spanOf、volumeProgress 是阅读页每次 build 新建的闭包
    if (widget.highlight != old.highlight) {
      old.highlight?.removeListener(_onHighlight);
      widget.highlight?.addListener(_onHighlight);
    }
    final f = widget.follow;
    if (f != null && f != old.follow) _followOffset(f);
  }

  @override
  void dispose() {
    widget.highlight?.removeListener(_onHighlight);
    _controller?.dispose();
    super.dispose();
  }

  Chapter get _c => widget.chapter;

  bool get _hasText => _c.text.trim().isNotEmpty;

  // 本章的 FlowPages：每帧会被 _units、_total、_slot 等用很多次，排版变了或者 widget 换了才重建
  FlowPages? _meCache;
  FlowPages get _me => _meCache ??= FlowPages(chapter: _c, title: widget.title, spanOf: widget.spanOf, starts: _starts, head: _head, cover: _cols == 2 ? widget.volumeCover : null, volumeProgress: widget.volumeProgress);

  int get _lead => _cols == 2 && widget.prevChapter != null ? widget.lead : 0;

  int get _textPages => _me.textPages;

  /// 单页总数
  int get _total => _me.total;

  /// 翻页的单位数（双页时两页算一屏）
  int get _units => _me.units(_cols, _lead);

  int _offsetOf(int unit) => _me.offsetOfUnit(unit, _cols, _lead);

  /// 最后一页在左页、右页已经接上了下一章
  bool get _trailing => (_lead + _me.count) % _cols != 0;

  int get _nextLead => _cols == 2 ? adjacentLead(_lead, _me.count) : 0;

  int get _prevLead => _cols == 2 && _prev != null ? adjacentLead(_lead, _prev!.count) : 0;

  /// 下一屏 / 上一屏在相邻章节里，可以直接翻过去。章节短到接不出新的一屏时不翻，直接换（画面不变）。
  bool get _canTurnNext => _next != null && (!_trailing || _next!.count >= 2);

  bool get _canTurnPrev => _prev != null && (_lead == 0 || _prev!.units(_cols, _prevLead) >= 2);

  /// 已经翻到相邻章节那一屏了：交给阅读页真正换章。新的正文第一帧和这一屏一模一样，看不出切换。
  void _land(int dir) {
    if (dir > 0) {
      final lead = _nextLead;
      widget.onTurn?.call(1, lead, _next!.offsetOfUnit(math.max(0, math.min(lead, _next!.units(_cols, lead) - 1)), _cols, lead));
    } else {
      final lead = _prevLead;
      widget.onTurn?.call(-1, lead, _prev!.offsetOfUnit(math.max(0, _prev!.units(_cols, lead) - 1 - _lead), _cols, lead));
    }
  }

  void _reachEnd() => _next != null ? _land(1) : widget.onNext?.call();

  void _reachStart() => _prev != null ? _land(-1) : widget.onPrev?.call();

  // 相邻章节的标题高度和分页：同一个版面（排版变了就清空）里按章节对象、标题记住，菜单开关、拖滑块这类重建不再重新排标题
  final _peekLayout = <(Chapter, String), (double, List<int>)>{};
  (String?, String?)? _covers; // 上次提前解码过的相邻章节卷封面

  bool get _wantPrev => widget.prevChapter != null && (_page <= 1 || (_cols == 2 && _lead > 0 && _page == 0));
  bool get _wantNext => widget.nextChapter != null && (_page >= _units - 2 || (_cols == 2 && _trailing && _page >= _units - 1));
  bool get _needPrevSync => _cols == 2 && _lead > 0 && _page == 0;
  bool get _needNextSync => _cols == 2 && _trailing && _page >= _units - 1;

  FlowPages? _flowIfCached(ChapterPeek? p) {
    if (p == null) return null;
    final layout = _peekLayout[(p.chapter, p.title)];
    if (layout == null) return null;
    final (head, starts) = layout;
    return FlowPages(chapter: p.chapter, title: p.title, spanOf: p.spanOf, starts: starts, head: head, cover: _cols == 2 ? p.cover : null, volumeProgress: p.volumeProgress);
  }

  FlowPages? _flowOf(ChapterPeek? p, Size size) {
    if (p == null) return null;
    final key = (p.chapter, p.title);
    var layout = _peekLayout[key];
    if (layout == null) {
      if (_peekLayout.length >= 4) _peekLayout.remove(_peekLayout.keys.first);
      final has = p.chapter.text.trim().isNotEmpty;
      final h = has ? headingHeight(p.title, widget.style, size.width) : 0.0;
      layout = _peekLayout[key] = (h, has ? _paged(p.chapter, p.title, size, h) : const [0]);
    }
    final (head, starts) = layout;
    return FlowPages(chapter: p.chapter, title: p.title, spanOf: p.spanOf, starts: starts, head: head, cover: _cols == 2 ? p.cover : null, volumeProgress: p.volumeProgress);
  }

  /// 将相邻章节分页推迟到帧后且仅在翻近章首/章末时执行，避免切章/改字号/转屏时同帧 3 倍排版峰值。
  void _schedulePeek() {
    if (_peekScheduled || _scrolling || _layoutSize.isEmpty) return;
    final needPrev = _wantPrev && _flowIfCached(widget.prevChapter) == null;
    final needNext = _wantNext && _flowIfCached(widget.nextChapter) == null;
    if (!needPrev && !needNext) return;
    _peekScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _peekScheduled = false;
      if (!mounted || _scrolling || _layoutSize.isEmpty) return;
      var changed = false;
      if (_wantPrev && _flowIfCached(widget.prevChapter) == null) {
        _prev = _flowOf(widget.prevChapter, _layoutSize);
        changed = true;
      }
      if (_wantNext && _flowIfCached(widget.nextChapter) == null) {
        _next = _flowOf(widget.nextChapter, _layoutSize);
        changed = true;
      }
      if (changed) setState(() {});
    });
  }

  List<int> _paged(Chapter c, String title, Size size, double head) {
    final key = (size, widget.style, c.text, title);
    // 用过的挪到最后（LRU）：满了删最久没用的，正在读的这章不会被相邻章节挤掉
    final hit = _pageCache.remove(key);
    if (hit != null) return _pageCache[key] = hit;
    if (_pageCache.length >= 6) _pageCache.remove(_pageCache.keys.first);
    return _pageCache[key] = paginate(c.text, widget.style, size, strut: readerStrut(widget.style), firstTop: head);
  }

  /// 字符偏移所在的那一屏。
  int _pageOf(int offset) {
    if (_total == 0) return 0;
    final int page;
    if (offset >= kToEnd) {
      page = _total - 1;
    } else if (offset > _c.text.length) {
      page = math.min(_textPages + (offset - _c.text.length - 1), _total - 1);
    } else {
      page = _hasText ? pageOfOffset(_starts, offset) : 0;
    }
    return (page + _me.covers + _lead) ~/ _cols;
  }

  GlobalKey _keyFor(int page) => _keys.putIfAbsent(page, GlobalKey.new);

  /// 底部进度条拖到第几屏
  void _jump(int unit) {
    final p = unit.clamp(0, math.max(_units - 1, 0)).toInt();
    if (widget.curl) {
      _curl.goTo(p);
    } else {
      _controller?.jumpToPage(p + _base);
    }
  }

  void _publish() {
    final nav = widget.nav;
    if (nav == null) return;
    // 在 build 里分页后也要更新，推迟到这一帧画完，免得在 build 期间通知别的组件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) nav.page.value = (_page, _units);
    });
  }

  void _changed(int page) {
    if (page < 0) return _land(-1);
    if (page >= _units) return _land(1);
    _page = page;
    _publish();
    _cur = _offsetOf(page);
    _anchor = _cur;
    widget.onOffset(_cur);
    if (page >= _units - 1) widget.onEnd();
    _prefetch();
    if (widget.curl || !_scrolling) _schedulePeek();
  }

  /// 本章和相邻章节的卷封面（只在双页时有）提前解码
  void _precacheCovers() {
    if (_imgBox.isEmpty || _cols != 2) return;
    for (final cover in [widget.volumeCover, _prev?.cover, _next?.cover]) {
      if (cover != null) NetImage.precache(context, cover, _imgBox, fit: BoxFit.contain);
    }
  }

  /// 插图章：整章的图按顺序在后台下好；前后一屏的图提前解码，翻过去直接出图（翻页时下一页才建出来）
  void _prefetch() {
    if (_imgBox.isEmpty) return;
    _precacheCovers();
    if (_c.images.isEmpty) return;
    if (!identical(_fetched, _c)) {
      _fetched = _c;
      for (final url in _c.images) {
        NetImage.precache(context, url, _imgBox, decode: false);
      }
    }
    final skip = _lead + _me.covers;
    for (var i = (_page - 1) * _cols - skip; i < (_page + 2) * _cols - skip; i++) {
      if (i >= _textPages && i < _total) NetImage.precache(context, _c.images[i - _textPages], _imgBox, fit: BoxFit.contain);
    }
  }

  Widget _pageContent(BuildContext context, int unit, bool live, EdgeInsets pad) {
    if (_cols == 1) return _slot(context, unit, live, pad);
    final line = widget.color.withValues(alpha: 0.12);
    // 页眉、页脚一屏只显示一份：两边都是正文页时，左页放章节名和时间电量，右页放页码进度；
    // 只有一边是正文页（另一边是插图、封面或空着）时，那一页显示完整的一份
    final left = unit * _cols, right = left + 1;
    final split = _isText(left) && _isText(right);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch, // 两页都占满高度，不然字数不同时上下错开
      children: [
        for (var k = 0; k < _cols; k++) ...[
          Expanded(child: _slot(context, left + k, live, pad, chrome: !split ? _Chrome.full : (k == 0 ? _Chrome.left : _Chrome.right))),
          if (k < _cols - 1) VerticalDivider(width: 1, thickness: 1, indent: 24, endIndent: 24, color: line),
        ],
      ],
    );
  }

  /// 第 [slot] 个位置是哪一章的第几页（含封面）；相邻章节没加载好、超出范围时为 null。
  (FlowPages, int, bool)? _at(int slot) {
    final me = _me;
    final i = slot - _lead;
    if (i >= 0 && i < me.count) return (me, i, true);
    final (other, j) = i < 0 ? (_prev, (_prev?.count ?? 0) + i) : (_next, i - me.count);
    return other == null || j < 0 || j >= other.count ? null : (other, j, false);
  }

  /// 第 [slot] 个位置是正文页（不是封面、插图、空白）
  bool _isText(int slot) {
    final at = _at(slot);
    if (at == null) return false;
    final (f, i, _) = at;
    return i >= f.covers && i - f.covers < f.textPages;
  }

  Widget _readerImage(String url, {List<String>? gallery, int index = 0}) => _readerImageWidget(url, widget.style.color, gallery: gallery, index: index);

  /// 排在第 [slot] 个位置的页：前面、后面排不下的是相邻章节的页，还没加载好就空着。
  Widget _slot(BuildContext context, int slot, bool live, EdgeInsets pad, {_Chrome chrome = _Chrome.full}) {
    final at = _at(slot);
    if (at == null) return const SizedBox.shrink();
    final (f, i, mine) = at;
    if (i < f.covers) return Center(child: _readerImage(f.cover!));
    return _single(context, f, i - f.covers, live && mine, pad, chrome);
  }

  Widget _single(BuildContext context, FlowPages f, int i, bool live, EdgeInsets pad, _Chrome chrome) {
    final c = f.chapter;
    if (i >= f.textPages) {
      final imgIdx = i - f.textPages;
      return Center(child: _readerImage(c.images[imgIdx], gallery: c.images, index: imgIdx));
    }
    final end = i + 1 < f.starts.length ? f.starts[i + 1] : c.text.length;
    final faint = TextStyle(fontSize: 11, color: widget.color.withValues(alpha: 0.5));
    final view = MediaQuery.viewPaddingOf(context);
    final cfg = widget.chromeConfig ?? const ReaderChromeConfig();
    final frac = f.total > 0 ? (i + 1) / f.total : 1.0;
    final volProg = f.volumeProgress?.call(frac) ?? frac;
    final pageProgress = '${i + 1}/${f.total} · ${(volProg * 100).floor()}%';
    final volProgressText = '本卷 ${(volProg * 100).floor()}%';
    final needEta = cfg.headerLeft == ReaderChromeField.volumeEta ||
        cfg.headerRight == ReaderChromeField.volumeEta ||
        cfg.footerLeft == ReaderChromeField.volumeEta ||
        cfg.footerRight == ReaderChromeField.volumeEta;
    final etaText = needEta ? (cfg.volumeEta?.call(frac) ?? volProgressText) : '';
    var hLeft = chrome == _Chrome.right ? ReaderChromeField.empty : cfg.headerLeft;
    var hRight = chrome == _Chrome.left ? ReaderChromeField.empty : cfg.headerRight;
    // 首屏已展示大号章节标题时，页眉不再重复显示章节名
    if (i == 0 && f.head > 0) {
      if (hLeft == ReaderChromeField.chapterTitle) hLeft = ReaderChromeField.empty;
      if (hRight == ReaderChromeField.chapterTitle) hRight = ReaderChromeField.empty;
    }
    final fLeft = chrome == _Chrome.right ? ReaderChromeField.empty : cfg.footerLeft;
    final fRight = chrome == _Chrome.left ? ReaderChromeField.empty : cfg.footerRight;
    final useLiveHighlight = live && identical(c, _c) && widget.highlight != null && widget.spanOfHighlight != null;
    return Stack(
      children: [
        // 页尾的换行会多出一个空行超出页面，所以不用 Column：标题单独放，正文往下让出标题的高度
        if (i == 0 && f.head > 0) Positioned(top: pad.top, left: pad.left, right: pad.right, child: chapterHeading(f.title, widget.style, _width, height: f.head, accent: widget.headingAccent)),
        Padding(
          padding: i == 0 ? pad.copyWith(top: pad.top + f.head) : pad,
          child: useLiveHighlight
              ? ValueListenableBuilder<(int, int)?>(
                  valueListenable: widget.highlight!,
                  builder: (_, hl, _) => material.Text.rich(widget.spanOfHighlight!(f.starts[i], end, hl), key: _keyFor(i), textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
                )
              : material.Text.rich(f.spanOf(f.starts[i], end), key: live ? _keyFor(i) : null, textScaler: TextScaler.noScaling, strutStyle: readerStrut(widget.style)),
        ),
        if (hLeft != ReaderChromeField.empty || hRight != ReaderChromeField.empty)
          Positioned(
            top: view.top + 10,
            left: widget.margin,
            right: widget.margin,
            child: ReaderChromeRow(
              leftField: hLeft,
              rightField: hRight,
              style: faint,
              chapterTitle: f.title,
              bookTitle: cfg.bookTitle,
              status: widget.status,
              pageProgress: pageProgress,
              volumeEta: etaText,
              volumeProgressText: volProgressText,
            ),
          ),
        if (widget.showFooter && (fLeft != ReaderChromeField.empty || fRight != ReaderChromeField.empty))
          Positioned(
            bottom: view.bottom + 10,
            left: widget.margin,
            right: widget.margin,
            child: ReaderChromeRow(
              leftField: fLeft,
              rightField: fRight,
              style: faint,
              chapterTitle: f.title,
              bookTitle: cfg.bookTitle,
              status: widget.status,
              pageProgress: pageProgress,
              volumeEta: etaText,
              volumeProgressText: volProgressText,
            ),
          ),
      ],
    );
  }

  bool _tap(Offset local, Size size, Offset global) {
    if (widget.menuOpen?.call() ?? false) {
      widget.onTapZone();
      return false;
    }
    for (var k = 0; k < _cols; k++) {
      final p = _page * _cols + k - _lead - _me.covers;
      final m = p >= 0 && p < _textPages ? markAt(_c, _keyFor(p), _starts[p], global) : null;
      if (m != null) {
        widget.onMark(m);
        return false;
      }
    }
    switch (tapActionAt(widget.tapZone, widget.tapInvert, local, size, paged: true)) {
      case TapAction.prev:
        widget.onUserInteract?.call();
        _step(-1);
      case TapAction.next:
        widget.onUserInteract?.call();
        _step(1);
      case TapAction.menu:
        widget.onTapZone();
        return false;
    }
    return true;
  }

  /// 换一个新的 PageController。旧的还挂在这一帧要卸载的 PageView 上，等这帧画完再释放。
  void _dropController() {
    final old = _controller;
    _controller = null;
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _step(int delta) => widget.curl ? (delta > 0 ? _curl.next() : _curl.prev()) : _slide(delta);

  void _slide(int delta) {
    final target = _page + delta;
    if (target < 0 && (!_canTurnPrev || !widget.animate)) return _reachStart();
    if (target >= _units && (!_canTurnNext || !widget.animate)) return _reachEnd();
    if (widget.animate) {
      _controller?.animateToPage(target + _base, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } else {
      _controller?.jumpToPage(target + _base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.viewPaddingOf(context);
    final pad = EdgeInsets.fromLTRB(widget.margin, view.top + 36, widget.margin, view.bottom + 36);
    return LayoutBuilder(
      builder: (context, box) {
        final cols = widget.dual && box.maxWidth >= 900 ? 2 : 1;
        final size = Size(box.maxWidth / cols - pad.horizontal, box.maxHeight - pad.vertical);
        _layoutSize = size;
        PagedBody.lastLayout = (size, cols);
        // 同样的版面（大小、样式、正文）不重复分页；开关菜单栏、拖滑块这类重建不会触发全文排版
        final sig = Object.hash(size, cols, widget.style, _c.text.length, _c.text.hashCode, widget.title, widget.volumeCover != null);
        if (sig != _sig) {
          final keep = _anchor;
          _sig = sig;
          _cols = cols;
          _width = size.width;
          _head = _hasText ? headingHeight(widget.title, widget.style, size.width) : 0;
          _starts = _hasText ? _paged(_c, widget.title, size, _head) : const [0];
          _meCache = null;
          _peekLayout.clear();
          _dropController();
          _page = _pageOf(keep);
          _cur = _offsetOf(_page);
          // 往回翻进来（落在最后一页）：把实际那页的位置报给阅读页，之后按这页定位。
          // 其他情况不报：进度留着原来的位置（页中间也行），换了版面还能回到同一处
          final report = keep >= kToEnd;
          if (report) _anchor = _cur;
          _keys.clear();
          _publish();
          _imgBox = Size(box.maxWidth / cols, box.maxHeight);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (report && _cur != widget.startOffset) widget.onOffset(_cur);
            // 往回翻落在上一章最后一页不算读完
            if (_page >= _units - 1 && widget.startOffset < kToEnd && !widget.arrivedBack) widget.onEnd();
            _prefetch();
          });
        }
        // 双页拼接屏立即可见时才同步排可见邻章，其余情况延后到帧后且靠近章首/章末再排
        _prev = _needPrevSync ? _flowOf(widget.prevChapter, size) : _flowIfCached(widget.prevChapter);
        _next = _needNextSync ? _flowOf(widget.nextChapter, size) : _flowIfCached(widget.nextChapter);
        _schedulePeek();
        // 相邻章节后来才加载好（预加载完成）时也要提前解码它们的卷封面，不然翻到那一屏时封面要现解码
        final covers = (_prev?.cover, _next?.cover);
        if (covers != _covers) {
          _covers = covers;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _precacheCovers();
          });
        }
        final Widget pages;
        if (widget.curl) {
          pages = PageCurl(
            key: ValueKey(sig),
            controller: _curl,
            cover: widget.cover,
            dual: cols == 2,
            pageCount: _units + (_canTurnNext ? 1 : 0),
            firstIndex: _canTurnPrev ? -1 : 0,
            initialIndex: _page,
            background: widget.background,
            pageBackground: widget.pageBackground,
            cacheKey: Object.hash(sig, widget.background, widget.backgroundKey, widget.chromeConfig?.layoutSignature, widget.color, widget.showFooter, widget.headingAccent?.$1, _prev?.starts.length, _next?.starts.length, _c.marks.length),
            cacheInvalidator: widget.status,
            pageBuilder: (context, i, live) => _pageContent(context, i, live, pad),
            onIndexChanged: _changed,
            onReachStart: _reachStart,
            onReachEnd: _reachEnd,
            onUserDragStart: widget.onUserInteract,
          );
        } else {
          final base = _canTurnPrev ? 1 : 0;
          if (base != _base) {
            _base = base;
            _dropController();
          }
          _controller ??= PageController(initialPage: _page + _base);
          pages = NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification) {
                _scrolling = true;
                _dragFrom = n.dragDetails == null ? null : _controller?.page;
                if (n.dragDetails != null) widget.onUserInteract?.call();
              }
              // 第一页往前滑、最后一页往后滑：松手后切到上一章 / 下一章
              if (n is OverscrollNotification) _overscroll = n.overscroll;
              if (n is ScrollEndNotification) {
                _scrolling = false;
                _dragFrom = null;
                final at = _controller?.page ?? 0;
                final unit = at.round() - _base;
                // 只认停稳的时候：手指按住正在滑的页面也会发结束通知
                if ((at - at.round()).abs() < 0.01 && (unit < 0 || unit >= _units)) {
                  _land(unit < 0 ? -1 : 1);
                } else {
                  if (_overscroll > 0) _reachEnd();
                  if (_overscroll < 0) _reachStart();
                }
                _overscroll = 0;
                _schedulePeek();
              }
              return false;
            },
            child: PageView.builder(
              key: ValueKey((sig, _base)),
              controller: _controller,
              // 拖一小段就翻页（不用拖过半屏）；对齐到整页由 SwipePagePhysics 自己做，所以关掉 pageSnapping
              pageSnapping: false,
              physics: SwipePagePhysics(origin: () => _dragFrom, parent: const ClampingScrollPhysics()),
              itemCount: _base + _units + (_canTurnNext ? 1 : 0),
              // 划到相邻章节那一屏时这里先不管，等停稳了才换章（见上面）
              onPageChanged: (i) {
                if (i - _base >= 0 && i - _base < _units) _changed(i - _base);
              },
              itemBuilder: (context, i) => _pageContent(context, i - _base, true, pad),
            ),
          );
        }
        return TapDetector(
          hasSelection: widget.hasSelection,
          onTap: _tap,
          child: PullBookmark(onPull: widget.onPullDown, marked: widget.marked, drag: true, color: widget.color, top: view.top, child: widget.wrap(pages)),
        );
      },
    );
  }
}
