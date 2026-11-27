import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../motion.dart';

/// 外部（点击翻页、朗读等）驱动翻页用。
class PageCurlController {
  Object? _owner;
  VoidCallback? _next;
  VoidCallback? _prev;
  ValueChanged<int>? _goTo;

  void next() => _next?.call();

  void prev() => _prev?.call();

  /// 跳到第 [page] 页（相邻页带翻页动画）。
  void goTo(int page) => _goTo?.call(page);
}

/// 仿真翻页：手指拖住页角，纸张沿一条折线折过去，露出背面和下一页。
///
/// 折线的算法（原创，只用平面几何）：
/// 1. 被拖起的页角 C 和手指位置 T 的**垂直平分线**就是折线；
/// 2. 页面被折线分成两半：靠近 C 的一半被翻过去，另一半留在原处（连着书脊）；
/// 3. 翻过去的一半沿折线**镜像**，落在手指一侧，就是我们看到的"纸背"；
/// 4. 折线另一侧被揭开的区域露出下一页，并加上沿折线渐变的阴影；
/// 5. 翻页进度 t 从 0（平放）到 1（整页翻走）：T 沿一条略微上抬的弧线从 C 运动到页面左边之外。
///
/// 往回翻不卷页：上一页从左边水平滑进来，盖在当前页上（和常见阅读器一致）。
class PageCurl extends StatefulWidget {
  const PageCurl({super.key, this.debugT, this.debugDir = 1, this.debugCorner = 1, this.cover = false, this.dual = false, required this.pageCount, this.firstIndex = 0, required this.pageBuilder, required this.initialIndex, required this.background, this.pageBackground, this.cacheKey, this.cacheInvalidator, this.controller, this.onIndexChanged, this.onReachStart, this.onReachEnd, this.onUserDragStart});

  /// 仅用于 tool/curl_demo.dart 目测：把折叠状态固定在进度 [debugT]（方向 [debugDir]，折角在高度的 [debugCorner] 处）
  final double? debugT;
  final int debugDir;
  final double debugCorner;

  /// 覆盖翻页：往后翻时当前页水平滑出、露出下一页，不卷页。
  final bool cover;

  /// 宽屏双页：以屏幕正中竖轴（左右两页之间的书脊）为轴翻页。
  final bool dual;

  /// 页码范围是 [firstIndex] 到 [pageCount] - 1：跨章时 -1 是上一章的那一屏
  final int pageCount;
  final int firstIndex;

  /// [live] 为 true 表示这是静止时显示的那一页（可以选字）；翻页动画中同一页会被画几次，此时为 false。
  final Widget Function(BuildContext context, int index, bool live) pageBuilder;
  final int initialIndex;
  final Color background;

  /// 可选自定义页面背景层（纸张纹理 / 自定义背景图）；为 null 时使用纯色 [background]。
  final Widget? pageBackground;

  /// 翻页动画期间页面缓存的失效签名（字体、主题、正文排版等变化时更新）。
  final Object? cacheKey;

  /// 翻页动画期间的外部缓存失效通知（如页脚时间/电量每分钟刷新）。
  final ValueListenable<Object?>? cacheInvalidator;
  final PageCurlController? controller;
  final ValueChanged<int>? onIndexChanged;
  final VoidCallback? onReachStart;
  final VoidCallback? onReachEnd;
  final VoidCallback? onUserDragStart;

  @override
  State<PageCurl> createState() => _PageCurlState();
}

class _PageCurlState extends State<PageCurl> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this)..addListener(_tick);
  // 动画帧驱动下沉至内层 ValueListenableBuilder，避免拖动/动画每帧重建外层 LayoutBuilder 与手势容器
  final _frameTick = ValueNotifier<int>(0);
  late int _index = widget.initialIndex.clamp(widget.firstIndex, math.max(widget.firstIndex, widget.pageCount - 1));

  /// 当前翻页方向：1 往后翻（第 _index 页翻走），-1 往回翻（第 _index-1 页翻回来），0 静止
  int _dir = 0;

  /// 翻页进度：0 平放，1 整页翻走。往回翻时从 1 减到 0。
  double _t = 0;
  double _from = 0, _to = 0;
  Curve _curve = AppMotion.decelerate;
  Size _size = Size.zero;

  // 翻页动画期间（_dir != 0）按 (index, sig) 缓存 RepaintBoundary 子树，避免每帧重复构建 2~3 份完整页面
  final _animPages = <(int, Object?), Widget>{};
  Object? _animSig;
  int _invalidations = 0;

  // 拖动状态
  double _startX = 0, _startY = 0, _cornerY = 0, _dy = 0;
  bool _dragging = false;
  bool _edgeFired = false; // 一次拖动里只通知一次"到头了"，否则会连续切好几章

  void _bindController(PageCurlController? controller) {
    controller
      ?.._owner = this
      .._next = (() => _auto(1))
      .._prev = (() => _auto(-1))
      .._goTo = _jump;
  }

  void _unbindController(PageCurlController? controller) {
    if (controller == null || !identical(controller._owner, this)) return;
    controller
      .._owner = null
      .._next = null
      .._prev = null
      .._goTo = null;
  }

  void _onCacheInvalidate() {
    _invalidations++;
    _animPages.clear();
    if (_dir != 0) _frameTick.value++;
  }

  @override
  void initState() {
    super.initState();
    _bindController(widget.controller);
    widget.cacheInvalidator?.addListener(_onCacheInvalidate);
  }

  @override
  void didUpdateWidget(PageCurl old) {
    super.didUpdateWidget(old);
    if (widget.controller != old.controller) {
      _unbindController(old.controller);
      _bindController(widget.controller);
    }
    if (widget.cacheInvalidator != old.cacheInvalidator) {
      old.cacheInvalidator?.removeListener(_onCacheInvalidate);
      widget.cacheInvalidator?.addListener(_onCacheInvalidate);
      _onCacheInvalidate();
    }
    if (widget.cacheKey != old.cacheKey ||
        widget.background != old.background ||
        widget.dual != old.dual ||
        widget.cover != old.cover ||
        widget.pageCount != old.pageCount ||
        widget.firstIndex != old.firstIndex) {
      _animPages.clear();
    }
    if (widget.pageCount != old.pageCount || widget.firstIndex != old.firstIndex) _index = _index.clamp(widget.firstIndex, math.max(widget.firstIndex, widget.pageCount - 1));
  }

  @override
  void dispose() {
    _unbindController(widget.controller);
    widget.cacheInvalidator?.removeListener(_onCacheInvalidate);
    _animPages.clear();
    _frameTick.dispose();
    _anim.dispose();
    super.dispose();
  }

  bool get _canNext => _index < widget.pageCount - 1;
  bool get _canPrev => _index > widget.firstIndex;

  void _tick() {
    _t = _from + (_to - _from) * _curve.transform(_anim.value);
    if (_anim.isCompleted && !_dragging) {
      _settle();
    } else {
      _frameTick.value++;
    }
  }

  /// 动画结束：翻成功了就换页，否则恢复原样。
  void _settle() {
    final turned = _dir == 1 ? _t >= 1 : _t <= 0;
    final dir = _dir;
    _animPages.clear();
    setState(() {
      if (turned) _index += dir;
      _dir = 0;
      _t = 0;
    });
    if (turned) widget.onIndexChanged?.call(_index);
  }

  /// 立即结束正在进行的动画（用户又按下手指时）。
  void _finishNow() {
    if (_dir == 0) return;
    _anim.stop();
    final turn = _dir == 1 ? _to >= 0.5 : _to <= 0.5;
    _t = _dir == 1 ? (turn ? 1 : 0) : (turn ? 0 : 1);
    _settle();
  }

  void _animateTo(double target, {double velocity = 0}) {
    if (AppMotion.reduce(context)) {
      _t = target;
      _settle();
      return;
    }
    _from = _t;
    _to = target;
    final distance = (target - _t).abs();
    _curve = AppMotion.decelerate;
    _anim.duration = Duration(milliseconds: (180 + distance * 360 / (1 + velocity.abs() / 3000)).round().clamp(140, 520));
    _anim.forward(from: 0);
  }

  void _auto(int dir) {
    if (_size.isEmpty) return;
    _finishNow();
    if (dir == 1 && !_canNext) return widget.onReachEnd?.call();
    if (dir == -1 && !_canPrev) return widget.onReachStart?.call();
    if (AppMotion.reduce(context)) {
      setState(() => _index += dir);
      widget.onIndexChanged?.call(_index);
      return;
    }
    setState(() {
      _dir = dir;
      _cornerY = _size.height;
      _dy = 0;
      _t = dir == 1 ? 0.0001 : 0.9999;
    });
    _animateTo(dir == 1 ? 1 : 0);
  }

  void _jump(int page) {
    _finishNow();
    page = page.clamp(0, math.max(0, widget.pageCount - 1));
    if (page == _index + 1) return _auto(1);
    if (page == _index - 1) return _auto(-1);
    if (page == _index) return;
    setState(() => _index = page);
    widget.onIndexChanged?.call(_index);
  }

  void _onDragStart(DragStartDetails d) {
    widget.onUserDragStart?.call();
    _finishNow();
    _startX = d.localPosition.dx;
    _startY = d.localPosition.dy;
    _dragging = true;
    _edgeFired = false;
    _dir = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging || _size.isEmpty) return;
    final dx = d.localPosition.dx - _startX;
    var enteredAnim = false;
    if (_dir == 0) {
      if (dx.abs() < 8) return;
      final dir = dx < 0 ? 1 : -1;
      if ((dir == 1 && !_canNext) || (dir == -1 && !_canPrev)) {
        if (!_edgeFired) {
          _edgeFired = true;
          (dir == 1 ? widget.onReachEnd : widget.onReachStart)?.call();
        }
        return;
      }
      _dir = dir;
      enteredAnim = true;
      // 从上 / 下三分之一处起手：折页角在上 / 下角；从中间起手：折线几乎竖直，像翻书
      final y = _startY / _size.height;
      _cornerY = y < 0.33 ? 0 : (y > 0.67 ? _size.height : _startY);
    }
    final p = (dx.abs() / (_size.width * (widget.dual ? 0.5 : 0.85))).clamp(0.0, 1.0);
    _dy = d.localPosition.dy - _startY;
    _t = _dir == 1 ? (dx < 0 ? p : 0.0001) : (dx > 0 ? 1 - p : 0.9999);
    if (enteredAnim) {
      setState(() {});
    } else {
      _frameTick.value++;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    if (_dir == 0) return;
    final v = d.velocity.pixelsPerSecond.dx;
    final complete = _dir == 1 ? (_t > 0.3 || v < -700) : (_t < 0.7 || v > 700);
    _animateTo(_dir == 1 ? (complete ? 1 : 0) : (complete ? 0 : 1), velocity: v);
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    if (_dir != 0) _animateTo(_dir == 1 ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _size = Size(box.maxWidth, box.maxHeight);
        if (widget.debugT != null) {
          _dir = widget.debugDir;
          _t = widget.debugT!;
          _cornerY = widget.debugCorner * _size.height;
        }
        final bg = widget.background;
        final bgLayer = widget.pageBackground;
        final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
        Widget withBg(Widget child) => bgLayer == null ? ColoredBox(color: bg, child: SizedBox.expand(child: child)) : Stack(fit: StackFit.expand, children: [bgLayer, child]);
        Widget livePage(int i) => withBg(widget.pageBuilder(context, i, true));

        Widget body;
        if (_dir == 0 || widget.pageCount == 0) {
          _animPages.clear();
          body = widget.pageCount == 0 ? (bgLayer ?? ColoredBox(color: bg)) : livePage(_index);
        } else {
          final spineMirror = Matrix4(-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, _size.width, 0, 0, 1);
          body = ValueListenableBuilder<int>(
            valueListenable: _frameTick,
            builder: (context, _, _) {
              final sig = Object.hash(widget.cacheKey, bg, _size, widget.dual, widget.cover, _invalidations);
              if (sig != _animSig) {
                _animSig = sig;
                _animPages.clear();
              }
              Widget cachedPage(int i) => _animPages.putIfAbsent(
                (i, sig),
                () => RepaintBoundary(child: withBg(widget.pageBuilder(context, i, false))),
              );
              if (!widget.dual && (_dir == -1 || widget.cover)) {
                // 单页模式下往回翻：上一页从左边滑进来盖住当前页；覆盖模式往后翻：当前页向左滑出，露出下一页
                // 右外沿用 18px 纯线性渐变阴影条代替整页 BoxShadow(blurRadius: 14)，零高斯模糊 Pass
                final dx = -_size.width * _t;
                final (below, above) = _dir == -1 ? (_index, _index - 1) : (_index + 1, _index);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    cachedPage(below),
                    Transform.translate(offset: Offset(dx, 0), child: cachedPage(above)),
                    Positioned(
                      left: _size.width + dx,
                      top: 0,
                      bottom: 0,
                      width: 18,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.black.withValues(alpha: dark ? 0.42 : 0.24),
                                Colors.black.withValues(alpha: dark ? 0.14 : 0.08),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.45, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }
              final turning = _dir == 1 ? _index : _index - 1;
              final under = _dir == 1 ? _index + 1 : _index;
              final underPage = cachedPage(under);
              final turningPage = cachedPage(turning);
              // 宽屏双页：以中轴线（x = width / 2）为书脊翻页；覆盖模式下折线保持竖直，仿真模式下带卷角弧度
              final fold = _Fold.at(
                size: _size,
                t: _t,
                cornerY: widget.dual && widget.cover ? _size.height / 2 : _cornerY,
                dy: widget.dual && widget.cover ? 0 : _dy,
                dual: widget.dual,
              );
              final shade = widget.dual ? math.sin(math.pi * _t.clamp(0.0, 1.0)) : 1.0;
              return Stack(
                fit: StackFit.expand,
                children: [
                  underPage,
                  if (fold.back.length >= 3) CustomPaint(painter: _UnderShadow(fold, dark)),
                  if (fold.front.length >= 3) ClipPath(clipper: _PolyClipper(fold.front), child: turningPage),
                  if (fold.flap.length >= 3) CustomPaint(painter: _FlapShadow(fold, dark)),
                  if (fold.flap.length >= 3)
                    ClipPath(
                      clipper: _PolyClipper(fold.flap),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (widget.dual) ...[
                            // 双页模式下，右页背面就是下一屏的左页：先沿中轴线镜像到右半屏，再随折线镜像回左半屏（两次镜像合成刚体旋转平移）
                            Transform(transform: fold.mirror.multiplied(spineMirror), child: underPage),
                            if (shade > 0.01) ColoredBox(color: Colors.black.withValues(alpha: (dark ? 0.16 : 0.08) * shade)),
                          ] else ...[
                            Transform(transform: fold.mirror, child: turningPage),
                            // 纸背：比正面暗一点、透出一点字迹
                            ColoredBox(color: Color.lerp(bg, dark ? Colors.black : const Color(0xFFEDE6D6), dark ? 0.35 : 0.55)!.withValues(alpha: 0.78)),
                          ],
                          CustomPaint(painter: _FlapShade(fold, dark)),
                        ],
                      ),
                    ),
                ],
              );
            },
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.trackpad, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}, // 鼠标拖动留给选字
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: _onDragCancel,
          child: ClipRect(child: body),
        );
      },
    );
  }
}

/// 一帧的折叠几何。
class _Fold {
  _Fold._(this.m, this.n, this.front, this.back, this.flap, this.mirror);

  /// 折线上的一点（C 和 T 的中点）
  final Offset m;

  /// 折线的单位法向量，从 T 指向 C（C 那一侧是被翻过去的部分）
  final Offset n;

  /// 留在原处的部分（连着书脊）
  final List<Offset> front;

  /// 被翻过去的部分（原位置，这里露出下一页）
  final List<Offset> back;

  /// 翻过去的部分镜像后的位置（纸背）
  final List<Offset> flap;

  /// 把页面镜像到 [flap] 位置的变换
  final Matrix4 mirror;

  factory _Fold.at({required Size size, required double t, required double cornerY, required double dy, bool dual = false}) {
    final w = size.width, h = size.height;
    final corner = Offset(w, cornerY);
    final towardCenter = (h / 2 - cornerY).sign;
    final lift = towardCenter * h * (dual ? 0.18 : 0.26) * math.sin(math.pi * t);
    final follow = dy * 0.35 * (1 - t);
    final Offset touch;
    if (dual) {
      // 双页模式：右页外沿从 x = w 翻到左页外沿 x = 0，折线最终落在正中书脊 x = w / 2；
      // 限制纵向抬起幅度使整条折线始终位于中轴线右侧（x >= w / 2），贴近书脊时自然展平。
      final xT = (w * (1 - t)).clamp(0.0, w);
      final maxDy = h > 0 ? xT * (w - xT) / (2 * h) : 0.0;
      final rawY = (cornerY + lift + follow).clamp(0.0, h);
      touch = Offset(xT, cornerY + (rawY - cornerY).clamp(-maxDy, maxDy));
    } else {
      // 单页模式：手指（页角）从 C 沿一条向页面中部略微上抬的弧线运动到左边之外
      touch = Offset(w + (-1.15 * w - w) * t, (cornerY + lift + follow).clamp(0.0, h));
    }
    final diff = corner - touch;
    final len = diff.distance;
    final rect = [Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)];
    if (len < 0.5) return _Fold._(corner, const Offset(1, 0), rect, const [], const [], Matrix4.identity());

    final n = diff / len;
    final m = (corner + touch) / 2;
    final rightRect = dual ? [Offset(w / 2, 0), Offset(w, 0), Offset(w, h), Offset(w / 2, h)] : rect;
    final back = _clip(rightRect, m, n, true);
    final front = _clip(rect, m, n, false);
    final flap = [for (final p in back) p - n * (2 * ((p - m).dx * n.dx + (p - m).dy * n.dy))];
    final d = m.dx * n.dx + m.dy * n.dy;
    final mirror = Matrix4(1 - 2 * n.dx * n.dx, -2 * n.dx * n.dy, 0, 0, -2 * n.dx * n.dy, 1 - 2 * n.dy * n.dy, 0, 0, 0, 0, 1, 0, 2 * n.dx * d, 2 * n.dy * d, 0, 1);
    return _Fold._(m, n, front, back, flap, mirror);
  }

  /// 用折线裁剪凸多边形，保留法向量正侧（[positive]）或负侧。
  static List<Offset> _clip(List<Offset> poly, Offset m, Offset n, bool positive) {
    double side(Offset p) => ((p - m).dx * n.dx + (p - m).dy * n.dy) * (positive ? 1 : -1);
    final out = <Offset>[];
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final da = side(a), db = side(b);
      if (da >= 0) out.add(a);
      if ((da >= 0) != (db >= 0)) out.add(a + (b - a) * (da / (da - db)));
    }
    return out;
  }

  Path path(List<Offset> poly) => Path()..addPolygon(poly, true);
}

class _PolyClipper extends CustomClipper<Path> {
  const _PolyClipper(this.poly);

  final List<Offset> poly;

  @override
  Path getClip(Size size) => Path()..addPolygon(poly, true);

  @override
  bool shouldReclip(_PolyClipper old) => old.poly != poly;
}

/// 下一页被揭开的区域靠近折线的一侧加阴影。
class _UnderShadow extends CustomPainter {
  _UnderShadow(this.f, this.dark);

  final _Fold f;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipPath(f.path(f.back));
    // 从折线起沿法向量（进入被揭开的区域）由深到浅
    canvas.drawRect(Offset.zero & size, Paint()..shader = _along(f.m, f.n, 34, [Colors.black.withValues(alpha: dark ? 0.5 : 0.34), Colors.transparent]));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_UnderShadow old) => old.f != f;
}

/// 纸背投在正面上的阴影：沿翻起纸背各外缘绘制纯线性渐变阴影带与转角径向过渡，移除每帧 `MaskFilter.blur` 开销。
class _FlapShadow extends CustomPainter {
  _FlapShadow(this.f, this.dark);

  final _Fold f;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final flap = f.flap;
    final count = flap.length;
    if (count < 3) return;
    canvas.save();
    canvas.clipPath(f.path(f.front));

    var cx = 0.0, cy = 0.0;
    for (final p in flap) {
      cx += p.dx;
      cy += p.dy;
    }
    final centroid = Offset(cx / count, cy / count);

    const shadowW = 18.0;
    final colors = [
      Colors.black.withValues(alpha: dark ? 0.44 : 0.24),
      Colors.black.withValues(alpha: dark ? 0.14 : 0.07),
      Colors.transparent,
    ];
    const stops = [0.0, 0.45, 1.0];

    bool onFold(Offset p) => ((p - f.m).dx * f.n.dx + (p - f.m).dy * f.n.dy).abs() < 0.75;

    final normals = List<Offset?>.filled(count, null);
    for (var i = 0; i < count; i++) {
      final a = flap[i];
      final b = flap[(i + 1) % count];
      if (onFold(a) && onFold(b)) continue;
      final e = b - a;
      final el = e.distance;
      if (el < 0.5) continue;
      var perp = Offset(e.dy / el, -e.dx / el);
      if ((centroid.dx - a.dx) * perp.dx + (centroid.dy - a.dy) * perp.dy > 0) {
        perp = -perp;
      }
      normals[i] = perp;
      final quad = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(b.dx + perp.dx * shadowW, b.dy + perp.dy * shadowW)
        ..lineTo(a.dx + perp.dx * shadowW, a.dy + perp.dy * shadowW)
        ..close();
      canvas.drawPath(quad, Paint()..shader = _along(a, perp, shadowW, colors, stops));
    }

    // 补齐相邻外缘交点处扇形过渡，无接缝且不重叠变黑
    for (var i = 0; i < count; i++) {
      final n1 = normals[(i - 1 + count) % count];
      final n2 = normals[i];
      if (n1 == null || n2 == null) continue;
      final v = flap[i];
      final a1 = math.atan2(n1.dy, n1.dx);
      var sweep = math.atan2(n2.dy, n2.dx) - a1;
      while (sweep <= -math.pi) {
        sweep += math.pi * 2;
      }
      while (sweep > math.pi) {
        sweep -= math.pi * 2;
      }
      if (sweep.abs() < 0.02) continue;
      final wedge = Path()
        ..moveTo(v.dx, v.dy)
        ..lineTo(v.dx + n1.dx * shadowW, v.dy + n1.dy * shadowW)
        ..arcTo(Rect.fromCircle(center: v, radius: shadowW), a1, sweep, false)
        ..close();
      canvas.drawPath(wedge, Paint()..shader = ui.Gradient.radial(v, shadowW, colors, stops));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlapShadow old) => old.f != f || old.dark != dark;
}

/// 纸背靠近折线处的明暗：模拟纸卷起来的弧度。
class _FlapShade extends CustomPainter {
  _FlapShade(this.f, this.dark);

  final _Fold f;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final dir = -f.n; // 从折线进入纸背的方向
    canvas.drawRect(Offset.zero & size, Paint()..shader = _along(f.m, dir, 46, [Colors.black.withValues(alpha: dark ? 0.35 : 0.22), Colors.transparent]));
  }

  @override
  bool shouldRepaint(_FlapShade old) => old.f != f;
}

/// 从 [from] 出发沿 [dir] 方向、长 [length] 的线性渐变。
Shader _along(Offset from, Offset dir, double length, List<Color> colors, [List<double>? stops]) => ui.Gradient.linear(from, from + dir * length, colors, stops);
