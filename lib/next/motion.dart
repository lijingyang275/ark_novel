import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// 全项目统一的苹果风格动效语言。
///
/// 设计原则：
/// - 同一类状态变化共用同一套时长、曲线与阻尼弹簧，不在各页面各自发明节奏；
/// - 高频操作更快更轻（100~180ms），空间与层级变化从容跟手（260~360ms）；
/// - 所有原语均自动尊重系统「减少动态效果」（[MediaQuery.disableAnimationsOf]），
///   关闭动态效果时直接到位或降级为无位移极短切换，不抖、不闪、不丢语义。
abstract final class AppMotion {
  /// 高频微反馈：按压沉下、桌面悬停微亮、细微焦点变化。
  static const Duration instant = Duration(milliseconds: 100);

  /// 轻量状态切换：图标替换、勾选、角标、数字/短文案切换、旋转箭头。
  static const Duration fast = Duration(milliseconds: 180);

  /// 标准界面变化：条幅/多选栏显隐、面板展开收起、内容区切换、搜索栏切换。
  static const Duration standard = Duration(milliseconds: 260);

  /// 宏观与仪式感：页面转场、主题/配色切换、统计图表、卷末庆祝。
  static const Duration expressive = Duration(milliseconds: 360);

  /// 氛围背景流转：封面取色渐变、毛玻璃底图过渡。
  static const Duration ambient = Duration(milliseconds: 420);

  /// 苹果标准流畅减速曲线：起速干脆、落点极柔和，无生硬急刹感。
  static const Curve curve = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 入场 / 滑入曲线：更高初速、顺滑着陆。
  static const Curve decelerate = Cubic(0.16, 1.0, 0.30, 1.0);

  /// 退场曲线：比入场更利落果断，不拖泥带水。
  static const Curve exit = Cubic(0.40, 0.0, 1.0, 1.0);

  /// 对称过渡曲线：用于进度推进、位置平移动画。
  static const Curve inOut = Cubic(0.42, 0.0, 0.18, 1.0);

  /// 轻快微反馈曲线：按压回弹、导航图标、复选框、旋转箭头。
  static const Curve snappy = Cubic(0.20, 0.90, 0.25, 1.0);

  /// 临界阻尼弹簧：无过冲，用于拖动松手后的自然承接与归位。
  static final SpringDescription smoothSpring = SpringDescription.withDampingRatio(mass: 1.0, stiffness: 380.0, ratio: 1.0);

  /// 轻盈阻尼弹簧：极克制弹性，用于下拉回弹与强触感交互。
  static final SpringDescription snappySpring = SpringDescription.withDampingRatio(mass: 1.0, stiffness: 460.0, ratio: 0.88);

  /// 舒缓阻尼弹簧：用于大尺寸缩放与仪式感元素落位。
  static final SpringDescription gentleSpring = SpringDescription.withDampingRatio(mass: 1.0, stiffness: 260.0, ratio: 0.92);

  /// 像素级弹簧收敛容差：避免在 0.001px 尾部白跑多帧，结束后配合精确归零。
  static const Tolerance pixelTolerance = Tolerance(distance: 0.25, velocity: 1.0);

  /// 当前系统是否开启了「减少动态效果」。
  static bool reduce(BuildContext context) => MediaQuery.disableAnimationsOf(context);

  /// 按「减少动态效果」折算时长：开启时归零，保证零多余运动。
  static Duration dur(BuildContext context, Duration duration) => reduce(context) ? Duration.zero : duration;
}

/// 跨平台苹果级页面路由转场：
/// - 移动端（iOS / Android）：原生 Cupertino 视差横滑 + 左侧柔和投影 + 边缘右滑跟手返回；
/// - 桌面端（macOS / Windows / Linux）：克制的轻微横移 + 柔和淡入，避免大窗口整页横扫带来的晕动；
/// - 系统开启「减少动态效果」时自动退化为无位移瞬时/轻淡切换。
class ApplePageTransitionsBuilder extends PageTransitionsBuilder {
  const ApplePageTransitionsBuilder();

  static const _cupertino = CupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduce(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    final isDesktopPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (!isDesktopPlatform) {
      return _cupertino.buildTransitions(route, context, animation, secondaryAnimation, child);
    }
    return _DesktopPageTransition(animation: animation, secondaryAnimation: secondaryAnimation, child: child);
  }
}

/// 桌面端克制横移 + 淡入转场：在独立 StatefulWidget 中管理两个 [CurvedAnimation] 生命周期，避免每次 build 泄漏监听器。
class _DesktopPageTransition extends StatefulWidget {
  const _DesktopPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_DesktopPageTransition> createState() => _DesktopPageTransitionState();
}

class _DesktopPageTransitionState extends State<_DesktopPageTransition> {
  static final _primaryOffset = Tween<Offset>(begin: const Offset(0.032, 0), end: Offset.zero);
  static final _secondaryOffset = Tween<Offset>(begin: Offset.zero, end: const Offset(-0.018, 0));

  late CurvedAnimation _primary;
  late CurvedAnimation _secondary;
  late Animation<Offset> _primarySlide;
  late Animation<Offset> _secondarySlide;

  @override
  void initState() {
    super.initState();
    _initPrimary();
    _initSecondary();
  }

  void _initPrimary() {
    _primary = CurvedAnimation(parent: widget.animation, curve: AppMotion.decelerate, reverseCurve: AppMotion.exit);
    _primarySlide = _primaryOffset.animate(_primary);
  }

  void _initSecondary() {
    _secondary = CurvedAnimation(parent: widget.secondaryAnimation, curve: AppMotion.curve, reverseCurve: AppMotion.decelerate);
    _secondarySlide = _secondaryOffset.animate(_secondary);
  }

  @override
  void didUpdateWidget(_DesktopPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation) {
      _primary.dispose();
      _initPrimary();
    }
    if (widget.secondaryAnimation != oldWidget.secondaryAnimation) {
      _secondary.dispose();
      _initSecondary();
    }
  }

  @override
  void dispose() {
    _primary.dispose();
    _secondary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
    position: _secondarySlide,
    child: FadeTransition(
      opacity: _primary,
      child: SlideTransition(position: _primarySlide, child: widget.child),
    ),
  );
}

/// 苹果风格的按压与悬停微缩反馈。
///
/// 通过 [Listener] 观测指针按下/抬起/滑动取消，完全不参与手势竞技场，不会拦截点击、长按、右键或列表滑动。
/// 仅在状态变化时驱动纯 GPU 缩放，空闲零 Ticker 开销，适合大列表与网格封面。
class AppPressScale extends StatefulWidget {
  const AppPressScale({
    super.key,
    required this.child,
    this.scale = 0.968,
    this.hoverScale = 1.0,
    this.enabled = true,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final double scale;
  final double hoverScale;
  final bool enabled;
  final Alignment alignment;

  @override
  State<AppPressScale> createState() => _AppPressScaleState();
}

class _AppPressScaleState extends State<AppPressScale> {
  bool _pressed = false;
  bool _hovered = false;
  Offset? _downPos;

  void _setPressed(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  void _setHovered(bool v) {
    if (_hovered != v && mounted) setState(() => _hovered = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || AppMotion.reduce(context)) return widget.child;
    final targetScale = _pressed ? widget.scale : (_hovered ? widget.hoverScale : 1.0);
    Widget result = AnimatedScale(
      scale: targetScale,
      alignment: widget.alignment,
      duration: _pressed ? AppMotion.instant : AppMotion.fast,
      curve: _pressed ? AppMotion.decelerate : AppMotion.snappy,
      child: widget.child,
    );
    result = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.buttons == 2) return; // 右键菜单不下压
        _downPos = e.position;
        _setPressed(true);
      },
      onPointerMove: (e) {
        final start = _downPos;
        if (start != null && (e.position - start).distanceSquared > 64) {
          _downPos = null;
          _setPressed(false);
        }
      },
      onPointerUp: (_) {
        _downPos = null;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        _downPos = null;
        _setPressed(false);
      },
      child: result,
    );
    if (widget.hoverScale != 1.0) {
      result = MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (e) {
          if (e.kind == PointerDeviceKind.mouse) _setHovered(true);
        },
        onExit: (_) => _setHovered(false),
        child: result,
      );
    }
    return result;
  }
}

/// 统一的流内出现/消失容器：单一动画控制器同步驱动高度/宽度展开、淡入淡出与轻位移，
/// 支持中途无缝打断反转；收起归零后彻底卸载子节点，不留空占位也不干扰焦点和无障碍。
class AppCollapse extends StatefulWidget {
  const AppCollapse({
    super.key,
    required this.visible,
    required this.child,
    this.axis = Axis.vertical,
    this.axisAlignment = -1.0,
    this.duration = AppMotion.standard,
    this.reverseDuration = AppMotion.fast,
    this.fade = true,
  });

  final bool visible;
  final Widget child;
  final Axis axis;
  final double axisAlignment;
  final Duration duration;
  final Duration reverseDuration;
  final bool fade;

  @override
  State<AppCollapse> createState() => _AppCollapseState();
}

class _AppCollapseState extends State<AppCollapse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1.0 : 0.0,
    duration: widget.duration,
    reverseDuration: widget.reverseDuration,
  );
  late final CurvedAnimation _sizeCurve = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.curve,
    reverseCurve: AppMotion.exit,
  );
  late final CurvedAnimation _fadeCurve = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.15, 1.0, curve: Curves.easeOut),
    reverseCurve: const Interval(0.0, 0.75, curve: Curves.easeIn),
  );
  bool _mountedChild = false;

  @override
  void initState() {
    super.initState();
    _mountedChild = widget.visible;
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.visible && _mountedChild && mounted) {
      setState(() => _mountedChild = false);
    }
  }

  @override
  void didUpdateWidget(AppCollapse old) {
    super.didUpdateWidget(old);
    _controller.duration = widget.duration;
    _controller.reverseDuration = widget.reverseDuration;
    if (widget.visible != old.visible) {
      if (AppMotion.reduce(context)) {
        _controller.value = widget.visible ? 1.0 : 0.0;
        _mountedChild = widget.visible;
      } else if (widget.visible) {
        _mountedChild = true;
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _sizeCurve.dispose();
    _fadeCurve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mountedChild) return const SizedBox.shrink();
    if (AppMotion.reduce(context)) {
      return widget.visible ? widget.child : const SizedBox.shrink();
    }
    Widget content = widget.child;
    if (widget.fade) {
      content = FadeTransition(opacity: _fadeCurve, child: content);
    }
    return ClipRect(
      child: SizeTransition(
        axis: widget.axis,
        alignment: widget.axis == Axis.horizontal ? Alignment(widget.axisAlignment, 0) : Alignment(0, widget.axisAlignment),
        sizeFactor: _sizeCurve,
        child: ExcludeFocus(
          excluding: !widget.visible,
          child: IgnorePointer(ignoring: !widget.visible, child: content),
        ),
      ),
    );
  }
}

/// 悬浮浮层（底部胶囊、撤销条、多选操作栏等）的统一显现与退场：
/// 轻位移 + 淡入 + 极轻缩放（0.96 → 1.0），中途可打断，退场归零后卸载子节点。
class AppReveal extends StatefulWidget {
  const AppReveal({
    super.key,
    required this.visible,
    required this.child,
    this.offset = const Offset(0, 0.24),
    this.beginScale = 0.96,
    this.duration = AppMotion.standard,
    this.reverseDuration = AppMotion.fast,
  });

  final bool visible;
  final Widget child;
  final Offset offset;
  final double beginScale;
  final Duration duration;
  final Duration reverseDuration;

  @override
  State<AppReveal> createState() => _AppRevealState();
}

class _AppRevealState extends State<AppReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1.0 : 0.0,
    duration: widget.duration,
    reverseDuration: widget.reverseDuration,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.decelerate,
    reverseCurve: AppMotion.exit,
  );
  bool _mountedChild = false;

  @override
  void initState() {
    super.initState();
    _mountedChild = widget.visible;
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.visible && _mountedChild && mounted) {
      setState(() => _mountedChild = false);
    }
  }

  @override
  void didUpdateWidget(AppReveal old) {
    super.didUpdateWidget(old);
    _controller.duration = widget.duration;
    _controller.reverseDuration = widget.reverseDuration;
    if (widget.visible != old.visible) {
      if (AppMotion.reduce(context)) {
        _controller.value = widget.visible ? 1.0 : 0.0;
        _mountedChild = widget.visible;
      } else if (widget.visible) {
        _mountedChild = true;
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mountedChild) return const SizedBox.shrink();
    if (AppMotion.reduce(context)) {
      return widget.visible ? widget.child : const SizedBox.shrink();
    }
    Widget content = widget.child;
    if (widget.beginScale != 1.0) {
      content = ScaleTransition(
        scale: Tween<double>(begin: widget.beginScale, end: 1.0).animate(_curve),
        child: content,
      );
    }
    if (widget.offset != Offset.zero) {
      content = SlideTransition(
        position: Tween<Offset>(begin: widget.offset, end: Offset.zero).animate(_curve),
        child: content,
      );
    }
    return ExcludeFocus(
      excluding: !widget.visible,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: FadeTransition(opacity: _curve, child: content),
      ),
    );
  }
}

/// 图标状态切换：极轻缩放 + 淡入交叉过渡，清晰交代图标含义已变。
class AppIconSwap extends StatelessWidget {
  const AppIconSwap({
    super.key,
    required this.child,
    this.duration = AppMotion.fast,
    this.rotate = false,
  });

  final Widget child;
  final Duration duration;
  final bool rotate;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduce(context)) return child;
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration(milliseconds: math.max(80, duration.inMilliseconds - 40)),
      switchInCurve: AppMotion.snappy,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (w, anim) {
        Widget out = ScaleTransition(
          scale: Tween<double>(begin: 0.76, end: 1.0).animate(anim),
          child: FadeTransition(opacity: anim, child: w),
        );
        if (rotate) {
          out = RotationTransition(turns: Tween<double>(begin: -0.08, end: 0.0).animate(anim), child: out);
        }
        return out;
      },
      child: child,
    );
  }
}

/// 内容区域状态平滑交叉淡换（骨架 ↔ 内容 ↔ 空态 ↔ 错误态、子页切换、模式切换等）。
class AppCrossfade extends StatelessWidget {
  const AppCrossfade({
    super.key,
    required this.child,
    this.duration = AppMotion.fast,
    this.alignment = Alignment.center,
    this.fill = false,
  });

  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  /// 为 true 时使用 [StackFit.expand]，适用于铺满剩余空间的页面主体（ListView / GridView 等）。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduce(context)) return child;
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration(milliseconds: math.max(90, duration.inMilliseconds - 40)),
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (current, previous) => Stack(
        fit: fill ? StackFit.expand : StackFit.loose,
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (w, anim) => FadeTransition(opacity: anim, child: w),
      child: child,
    );
  }
}

/// 平滑线性进度条：单个 [ImplicitlyAnimatedWidget] 同步驱动进度值与前后景色插值，避免多层嵌套动画控制器开销。
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.minHeight = 4,
    this.borderRadius = 2,
    this.color,
    this.backgroundColor,
    this.duration = AppMotion.standard,
  });

  final double value;
  final double minHeight;
  final double borderRadius;
  final Color? color;
  final Color? backgroundColor;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? scheme.primary;
    final bg = backgroundColor ?? fg.withValues(alpha: 0.14);
    return _AnimatedProgressBar(
      value: value.clamp(0.0, 1.0),
      minHeight: minHeight,
      borderRadius: borderRadius,
      color: fg,
      backgroundColor: bg,
      duration: AppMotion.dur(context, duration),
      curve: AppMotion.curve,
    );
  }
}

class _AnimatedProgressBar extends ImplicitlyAnimatedWidget {
  const _AnimatedProgressBar({
    required this.value,
    required this.minHeight,
    required this.borderRadius,
    required this.color,
    required this.backgroundColor,
    required super.duration,
    required super.curve,
  });

  final double value;
  final double minHeight;
  final double borderRadius;
  final Color color;
  final Color backgroundColor;

  @override
  ImplicitlyAnimatedWidgetState<_AnimatedProgressBar> createState() => _AnimatedProgressBarState();
}

class _AnimatedProgressBarState extends AnimatedWidgetBaseState<_AnimatedProgressBar> {
  Tween<double>? _value;
  ColorTween? _color;
  ColorTween? _bg;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _value = visitor(_value, widget.value, (dynamic v) => Tween<double>(begin: v as double)) as Tween<double>?;
    _color = visitor(_color, widget.color, (dynamic v) => ColorTween(begin: v as Color?)) as ColorTween?;
    _bg = visitor(_bg, widget.backgroundColor, (dynamic v) => ColorTween(begin: v as Color?)) as ColorTween?;
  }

  @override
  Widget build(BuildContext context) {
    final v = _value?.evaluate(animation) ?? widget.value;
    final fill = _color?.evaluate(animation) ?? widget.color;
    final track = _bg?.evaluate(animation) ?? widget.backgroundColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        height: widget.minHeight,
        width: double.infinity,
        child: ColoredBox(
          color: track,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v,
            child: ColoredBox(color: fill),
          ),
        ),
      ),
    );
  }
}

/// 克制的骨架屏柔和呼吸：纯 GPU 透明度缓动（0.52 ↔ 1.0），无刺眼白条扫光，尊重减少动态效果。
class AppSkeletonPulse extends StatefulWidget {
  const AppSkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  State<AppSkeletonPulse> createState() => _AppSkeletonPulseState();
}

class _AppSkeletonPulseState extends State<AppSkeletonPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final CurvedAnimation _curved = CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine);
  late final Animation<double> _opacity = Tween<double>(begin: 0.52, end: 1.0).animate(_curved);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduce(context)) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = 1.0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduce(context)) return widget.child;
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// 统一的苹果触感星级评分条（卷册详情、阅读报告、卷末庆祝卡片共用）。
///
/// 点击某颗星时，点亮的星逐颗轻柔弹性缩放并伴随轻触觉反馈；再次点击当前星数取消评分。
class AnimatedStarRating extends StatefulWidget {
  const AnimatedStarRating({
    super.key,
    required this.rating,
    required this.onChanged,
    this.starSize = 24,
    this.itemSize = 40,
    this.color = const Color(0xFFFFC53D),
    this.labelBuilder,
    this.haptic = true,
  });

  final int rating;
  final ValueChanged<int> onChanged;
  final double starSize;
  final double itemSize;
  final Color color;
  final String Function(int star)? labelBuilder;
  final bool haptic;

  @override
  State<AnimatedStarRating> createState() => _AnimatedStarRatingState();
}

class _AnimatedStarRatingState extends State<AnimatedStarRating> with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1.0,
  );
  int _popUpTo = 0;

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _tapStar(int star) {
    if (widget.haptic) HapticFeedback.selectionClick();
    final next = widget.rating == star ? 0 : star;
    if (next > 0 && !AppMotion.reduce(context)) {
      _popUpTo = next;
      _pop.forward(from: 0);
    } else {
      _popUpTo = 0;
    }
    widget.onChanged(next);
  }

  double _starScale(int star) {
    if (_popUpTo <= 0 || star > _popUpTo || !_pop.isAnimating) return 1.0;
    final delay = (star - 1) * 0.08;
    final t = ((_pop.value - delay) / (1.0 - delay)).clamp(0.0, 1.0);
    // 先轻弹放大至 1.18 再柔滑落回 1.0
    return 1.0 + 0.18 * math.sin(math.pi * Curves.easeOut.transform(t));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pop,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Semantics(
              button: true,
              selected: i <= widget.rating,
              label: widget.labelBuilder?.call(i) ?? '$i 星评分',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _tapStar(i),
                  child: SizedBox(
                    width: widget.itemSize,
                    height: widget.itemSize,
                    child: Center(
                      child: Transform.scale(
                        scale: _starScale(i),
                        child: Icon(
                          i <= widget.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                          color: widget.color,
                          size: widget.starSize,
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
