import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HapticFeedback, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;

import 'library.dart';
import 'pages/cover_picker_page.dart' show kCoverAspect;
import 'pages/volumes_page.dart' show volumeHeroShuttle;
import 'text.dart';
import 'widgets.dart';

/// 立体书架的尺寸和每本书的摆法。
///
/// 滑动手感和卷册页（`VolumesPage`）一样，区别在摆法：卷册页是一叠书，后面的卷压在当前卷底下；
/// 这里是一架子的书，书和书之间留缝、左右各露出半本，两侧的书朝中间微微转过来。
abstract final class Shelf3DLayout {
  /// 封面下面那一块（位置指示、书名、进度、按钮）的高度。固定，切书时上下都不动。
  static double infoHeight(double textScale) => 66 + 86 * textScale;

  /// 封面上下给阴影留的空间
  static const _stagePad = 44.0;

  /// 封面宽度：按可用高度尽量放大，但不超过屏宽的 62%，左右还要各露出一截。
  static double coverWidth(double width, double stageHeight) =>
      math.min(math.min((stageHeight - _stagePad) * kCoverAspect, width * 0.62), 340.0).clamp(96.0, 340.0);

  /// 放封面的那一层的高度：封面加上下阴影
  static double stageHeight(double coverWidth) => coverWidth / kCoverAspect + _stagePad;

  /// 相邻两本书中心的距离：中间那本的一半 + 旁边那本（缩小、转过）的一半 + 一道缝
  static double step(double coverWidth) => coverWidth * 0.95;

  /// 离中间 [d] 本（可以是小数，滑动途中）的那本书：往旁边挪多少、缩多少、转多少、压多暗、多透明。
  static ({double dx, double scale, double angle, double shade, double opacity}) pose(double d, double coverWidth) {
    final a = d.abs();
    final near = math.min(a, 1.0);
    final far = math.max(a - 1, 0.0);
    return (
      // 第一本错开一整个身位，再往后的挨得紧一点（宽屏上能看到两三本）
      dx: d.sign * (step(coverWidth) * near + coverWidth * 0.42 * far),
      scale: 1 - 0.18 * near - 0.06 * math.min(far, 2.0),
      // 约 20°，右边的书向左转、左边的向右转，朝着中间
      angle: -d.clamp(-1.0, 1.0) * 0.34,
      shade: math.min(a, 1.5) * 0.22,
      opacity: (2.4 - a).clamp(0.0, 1.0),
    );
  }
}

/// 书架的「立体」显示方式：一次看一本，左右滑切书，点中间那本打开卷册页（封面直接飞过去）。
class Shelf3DView extends StatefulWidget {
  const Shelf3DView({
    super.key,
    required this.books,
    this.initialAid,
    this.onFocusChanged,
    required this.selected,
    required this.heroEnabled,
    required this.coverOf,
    required this.badgeOf,
    required this.subtitleOf,
    required this.actionOf,
    required this.onOpen,
    required this.onRead,
    required this.onToggleSelect,
  });

  final List<LibBook> books;

  /// 一开始停在哪本（上次停的位置）；找不到就停在第一本
  final String? initialAid;

  /// 停到另一本上时告诉外面，用来记住位置
  final ValueChanged<String>? onFocusChanged;
  final Set<String> selected;

  /// 只有当前标签页开 Hero：保活的相邻标签里同一本书也有这个 tag
  final bool heroEnabled;
  final String Function(LibBook book) coverOf;

  /// 封面右上角的角标（未读数、多选时的勾），没有就返回 null
  final Widget? Function(LibBook book) badgeOf;

  /// 书名下面那一行：连载状态、读到第几卷、未读几章
  final String Function(LibBook book) subtitleOf;

  /// 下面那个按钮：读过的「继续读」、没读过的「开始读」，[cid] 为空时按钮就是打开卷册页
  final ({String label, String? cid}) Function(LibBook book) actionOf;
  final void Function(LibBook book) onOpen;
  final void Function(LibBook book, String cid) onRead;
  final void Function(LibBook book) onToggleSelect;

  @override
  State<Shelf3DView> createState() => _Shelf3DViewState();
}

class _Shelf3DViewState extends State<Shelf3DView> {
  int _cur = 0;
  PageController? _pc;
  double _fraction = 0;
  final _focus = FocusNode(debugLabel: 'shelf-3d');
  DateTime _lastWheel = DateTime(0);

  @override
  void initState() {
    super.initState();
    _cur = math.max(0, widget.books.indexWhere((b) => b.aid == widget.initialAid));
  }

  /// 一页的宽度要等于两本书中心的距离，手指拖多远书就走多远。屏宽变了（转屏、拖窗口）就换一个，停在同一本。
  PageController _controller(double fraction) {
    if (_pc != null && (fraction - _fraction).abs() < 0.005) return _pc!;
    final old = _pc;
    _fraction = fraction;
    _pc = PageController(viewportFraction: fraction, initialPage: _cur);
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return _pc!;
  }

  double get _page {
    final pc = _pc;
    return pc != null && pc.hasClients && pc.position.haveDimensions ? pc.page ?? _cur.toDouble() : _cur.toDouble();
  }

  @override
  void didUpdateWidget(Shelf3DView old) {
    super.didUpdateWidget(old);
    // 换了排序、筛选、加减了书：停在原来那本上；那本没了就停在原来的位置
    if (old.books.isEmpty || widget.books.isEmpty) return;
    final aid = old.books[_cur.clamp(0, old.books.length - 1)].aid;
    final i = widget.books.indexWhere((b) => b.aid == aid);
    final target = i >= 0 ? i : math.min(_cur, widget.books.length - 1);
    if (target == _cur) return;
    _cur = target;
    widget.onFocusChanged?.call(widget.books[target].aid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pc?.hasClients == true) _pc!.jumpToPage(_cur);
    });
  }

  @override
  void dispose() {
    _pc?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int i) {
    final pc = _pc;
    if (pc == null || !pc.hasClients) return;
    final target = i.clamp(0, widget.books.length - 1);
    if (target == _cur) return;
    pc.animateToPage(
      target,
      duration: Duration(milliseconds: math.min(260 + 40 * (target - _cur).abs(), 600)),
      curve: Curves.easeOutCubic,
    );
  }

  void _tap(int i) {
    _focus.requestFocus(); // Mac 上点过一下之后方向键就能切书
    final book = widget.books[i];
    if (widget.selected.isNotEmpty) {
      widget.onToggleSelect(book);
    } else if (i == _cur) {
      widget.onOpen(book);
    } else {
      _go(i);
    }
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final delta = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
    if (delta.abs() < 4) return;
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 220)) return;
    _lastWheel = now;
    _go(_cur + (delta > 0 ? 1 : -1));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(_cur + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(_cur - 1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _tap(_cur);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    if (books.isEmpty) return const SizedBox.shrink();
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    return LayoutBuilder(
      builder: (context, c) {
        final infoH = Shelf3DLayout.infoHeight(textScale);
        final height = c.maxHeight.isFinite ? c.maxHeight : 640.0;
        final w = Shelf3DLayout.coverWidth(c.maxWidth, math.max(200.0, height - infoH));
        // 封面按宽度定下来以后，多出来的高度上下平分（整组居中），不全堆在最下面
        final stageH = Shelf3DLayout.stageHeight(w);
        final pc = _controller((Shelf3DLayout.step(w) / c.maxWidth).clamp(0.15, 0.95));
        final cur = _cur.clamp(0, books.length - 1);
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onWheel,
            child: SingleChildScrollView(
              // 字放得很大、窗口很矮时也不溢出；平时正好一屏，滚不动
              physics: const NeverScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(key: const ValueKey('shelf-3d-stage'), height: stageH, child: _stage(pc, w)),
                    SizedBox(key: const ValueKey('shelf-3d-info'), height: infoH, child: _info(books[cur], cur, textScale)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _stage(PageController pc, double w) {
    final books = widget.books;
    final h = w / kCoverAspect;
    final persp = 1 / (w * 3.2);
    // 裁掉左右伸出去的书：TabBarView 切标签时不画到相邻标签上。上下不裁，封面的影子要完整
    return ClipRect(
      clipper: const _SidesClipper(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: AnimatedBuilder(
              animation: pc,
              builder: (context, _) {
                final p = _page;
                final shown = [for (var i = math.max(0, p.floor() - 2); i <= math.min(books.length - 1, p.ceil() + 2); i++) i]
                  ..sort((a, b) => (b - p).abs().compareTo((a - p).abs())); // 远的先画，近的压在上面
                return Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [for (final i in shown) _book(i, i - p, w, h, persp)]);
              },
            ),
          ),
          PageView.builder(
            controller: pc,
            itemCount: books.length,
            // 不用 PageView 自带的一次一页：快速一甩能划过好几本，停下时再对齐到某一本
            pageSnapping: false,
            physics: const _FlingSnapPhysics(),
            onPageChanged: (i) {
              HapticFeedback.selectionClick(); // 每划过一本轻震一下
              setState(() => _cur = i);
              widget.onFocusChanged?.call(books[i].aid);
            },
            itemBuilder: (context, i) => GestureDetector(
              key: ValueKey('shelf-3d-hit-${books[i].aid}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _tap(i),
              onLongPress: () => widget.onToggleSelect(books[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _book(int i, double d, double w, double h, double persp) {
    final book = widget.books[i];
    final pose = Shelf3DLayout.pose(d, w);
    final front = d.abs() < 0.5;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final badge = widget.badgeOf(book);
    Widget cover = _Cover(
      url: widget.coverOf(book),
      shade: pose.shade,
      selected: widget.selected.contains(book.aid),
      // 中间那本影子深一点，像被抽出来一点
      shadow: (dark ? 0.5 : 0.26) * (0.55 + 0.45 * (1 - math.min(d.abs(), 1.0))),
    );
    // 只有中间那本带 Hero：点开时这张封面飞到卷册页最前面那卷
    if (front) {
      cover = HeroMode(
        enabled: widget.heroEnabled,
        child: Hero(tag: 'vols:${book.aid}', flightShuttleBuilder: volumeHeroShuttle, child: cover),
      );
    }
    return Opacity(
      opacity: pose.opacity,
      child: Transform.translate(
        offset: Offset(pose.dx, 0),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, persp)
            ..rotateY(pose.angle),
          child: Transform.scale(
            scale: pose.scale,
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  cover,
                  if (badge != null) Positioned(top: 8, right: 8, child: badge),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _info(LibBook book, int cur, double textScale) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = widget.books.length;
    final selecting = widget.selected.isNotEmpty;
    final selected = widget.selected.contains(book.aid);
    final action = widget.actionOf(book);
    // 按钮一直在：多选时是选中 / 取消，平时是继续读 / 开始读 / 打开。占位不变，切书时什么都不动
    final Widget button = selecting
        ? OutlinedButton.icon(
            key: ValueKey('select-${book.aid}-$selected'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 20)),
            onPressed: () => widget.onToggleSelect(book),
            icon: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 20),
            label: Text(selected ? '已选中' : '选中'),
          )
        : FilledButton.tonalIcon(
            key: ValueKey('action-${book.aid}'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 22)),
            onPressed: () => action.cid == null ? widget.onOpen(book) : widget.onRead(book, action.cid!),
            icon: Icon(action.cid == null ? Icons.auto_stories_outlined : Icons.play_arrow_rounded, size: 20),
            label: Text(action.label),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Center(
              child: n > 1 ? _Indicator(index: cur, count: n, onPick: (i) => _pc?.jumpToPage(i)) : null,
            ),
          ),
          const SizedBox(height: 14),
          // 书名只占一行：长短不一的书名不会把下面的字顶上顶下
          SizedBox(
            height: 26 * textScale,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                book.shown,
                key: ValueKey(book.aid),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w700, height: 1.3),
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 18 * textScale,
            child: Text(
              widget.subtitleOf(book),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 42 * textScale,
            child: Center(
              child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: button),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一本书的封面：圆角、柔和的大阴影，离中间越远越暗；多选选中时描一圈主色。
class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.shade, required this.selected, required this.shadow});

  final String url;
  final double shade;
  final bool selected;
  final double shadow;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: shadow),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CoverImage(url),
          if (shade > 0.005)
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                color: Colors.black.withValues(alpha: shade),
              ),
            ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
              ),
            ),
        ],
      ),
    );
  }
}

/// 第几本：书少（≤ 9 本）用一排小圆点，当前那颗拉长；书多用细滑块，可以拖着快速找书。
class _Indicator extends StatelessWidget {
  const _Indicator({required this.index, required this.count, required this.onPick});

  final int index;
  final int count;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (count <= 9) {
      return Row(
        key: const ValueKey('shelf-3d-dots'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(color: i == index ? scheme.primary : scheme.outlineVariant, borderRadius: BorderRadius.circular(3)),
            ),
        ],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Row(
        children: [
          Expanded(
            child: ExcludeFocus(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: scheme.primary,
                  inactiveTrackColor: scheme.outlineVariant,
                  thumbColor: scheme.primary,
                  // 细轨道、小圆点，和卷册页的一样
                  trackHeight: 2,
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0, pressedElevation: 0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  key: const ValueKey('shelf-3d-slider'),
                  value: index.toDouble(),
                  max: count - 1.0,
                  divisions: count - 1,
                  label: hz(context, '第 ${index + 1} 本'),
                  onChanged: (x) => onPick(x.round()),
                ),
              ),
            ),
          ),
          Text(
            '${index + 1} / $count',
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

/// 只裁左右两边
class _SidesClipper extends CustomClipper<Rect> {
  const _SidesClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -size.height, size.width, size.height * 2);

  @override
  bool shouldReclip(_SidesClipper oldClipper) => false;
}

/// 甩得越快划过的书越多，松手后停在离惯性终点最近的那本上。
///
/// 轻轻一拨（够得上甩的速度）至少走一本；慢慢拖完松手，回到离得最近的那本。
class _FlingSnapPhysics extends ScrollPhysics {
  const _FlingSnapPhysics({super.parent});

  /// 甩出去的速度 × 这个秒数 ≈ 惯性能走的距离
  static const _glide = 0.32;

  @override
  _FlingSnapPhysics applyTo(ScrollPhysics? ancestor) => _FlingSnapPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if (position.outOfRange || position is! PageMetrics) return super.createBallisticSimulation(position, velocity);
    final page = position.viewportDimension * position.viewportFraction;
    if (page <= 0) return super.createBallisticSimulation(position, velocity);
    final now = position.pixels / page;
    double target;
    if (velocity.abs() < minFlingVelocity) {
      target = now.roundToDouble();
    } else {
      target = ((position.pixels + velocity * _glide) / page).roundToDouble();
      // 一拨至少走一本
      if (velocity > 0 && target <= now) target = now.floorToDouble() + 1;
      if (velocity < 0 && target >= now) target = now.ceilToDouble() - 1;
    }
    final to = (target * page).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((to - position.pixels).abs() < toleranceFor(position).distance) return null;
    return _GlideSimulation(from: position.pixels, to: to, velocity: velocity, tolerance: toleranceFor(position));
  }
}

/// 从当前位置指数减速滑到 [to]：开头的速度尽量接上手指松开时的速度，不会冲过头再弹回来。
class _GlideSimulation extends Simulation {
  _GlideSimulation({required double from, required this.to, required double velocity, super.tolerance}) : _gap = to - from {
    // 速度方向和要走的方向一致时，用松手速度算衰减快慢；反方向（拖过一半又往回）就用默认的
    final k = velocity * _gap > 0 ? velocity / _gap : 10.0;
    _k = k.clamp(6.0, 40.0);
  }

  final double to;
  final double _gap;
  late final double _k;

  @override
  double x(double time) => to - _gap * math.exp(-_k * time);

  @override
  double dx(double time) => _k * _gap * math.exp(-_k * time);

  @override
  bool isDone(double time) => (_gap * math.exp(-_k * time)).abs() < tolerance.distance;
}
