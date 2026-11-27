import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerHoverEvent, PointerScrollEvent, PointerScrollInertiaCancelEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cover_color.dart';
import 'library.dart';
import 'motion.dart';
import 'pages/cover_picker_page.dart' show kCoverAspect;
import 'pages/volumes_page.dart' show volumeHeroShuttle;
import 'shelf_3d.dart';
import 'text.dart';
import 'volumes.dart' show volumeChangeForProvider;
import 'widgets.dart';

/// 书脊书架的几何布局与 3D 翻出模型。
///
/// 未选中的书紧凑竖插在架子上（书脊朝外），当前选中的书向前抽出、微倾并旋转 90° 展示完整封面，
/// 同时用平滑阶跃函数 [smoothStepB] 将左右相邻书脊自然推开，形成实体书架穿插感。
abstract final class ShelfSpineLayout {
  static double infoHeight(double textScale) => Shelf3DLayout.infoHeight(textScale);

  /// 按书高动态预留上下安全呼吸区：覆盖 3D 透视拉近、微倾角旋转包围盒、悬停上抽与底部阴影，防止关闭顶部横幅后封面顶角越界。
  static double stagePad(double h) => math.max(68.0, h * 0.22);

  /// 由可用宽高推导单本书的高度 [h]、封面宽 [d]、书脊宽 [ws] 与紧凑书脊间距 [gap]。
  static ({double h, double d, double ws, double gap}) metrics(double width, double availStageHeight) {
    final maxByHeight = math.min(availStageHeight - 68.0, availStageHeight / 1.22).clamp(160.0, 380.0);
    // 封面宽不超过屏宽 56%，保证手机竖屏左右至少各露两根书脊
    final maxByWidth = (width * 0.56) / kCoverAspect;
    final h = math.min(maxByHeight, maxByWidth).clamp(160.0, 380.0);
    final d = h * kCoverAspect;
    final ws = (h * 0.172).clamp(38.0, 64.0);
    // 书脊紧凑排列（2.5~4px 缝隙），贴近实体排满一架的视觉密度
    final gap = (h * 0.009).clamp(2.5, 4.5);
    return (h: h, d: d, ws: ws, gap: gap);
  }

  static double stageHeight(double h) => h + stagePad(h);

  /// $C^2$ 连续的平滑阶跃函数：$r \in (-1, 1)$ 时为 $(r + \sin(\pi r)/\pi)/2$，否则 $\pm 0.5$。
  static double smoothStepB(double r) {
    if (r.abs() < 1.0) return (r + math.sin(math.pi * r) / math.pi) / 2.0;
    return r.sign * 0.5;
  }

  /// 展开度 `o ∈ [0, 1]`：`1` 表示当前抽出的封面，`0` 表示竖插书脊，滑动经过时平滑半开合。
  static double openness(double r) {
    final t = (1.0 - r.abs()).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  /// 相对中心偏移 [r] 本书的水平中心坐标：书脊紧凑等距排列，中央展开封面紧贴推开两侧邻书。
  static double centerX(double r, double ws, double d, double gap) => r * (ws + gap) + (d - ws + 2.0 * gap + 12.0) * smoothStepB(r);

  /// 计算相对位置 [r] 处书盒的 3D 姿态与双面受光压暗系数。
  static ({double x, double o, double rotY, double rotZ, double z, double dy, double spineShade, double coverShade}) pose(
    double r,
    double h,
    double ws,
    double d,
    double gap, {
    double lift = 0,
    double tiltY = 0,
    bool reduceMotion = false,
  }) {
    final o = openness(r);
    final rotY = (math.pi / 2) * o + (reduceMotion ? 0.0 : tiltY * o);
    final rotZ = reduceMotion ? 0.0 : -0.056 * o; // 抽出时逆时针微倾约 3.2°，克制稳重
    // z_world 负方向朝向观察者：竖插时书脊落在 z=0，抽出后封面向观察者推近 0.14H
    final z = (1.0 - o) * (d / 2) + o * (ws / 2) - (reduceMotion ? 0.0 : o * 0.14 * h);
    // 中央展开封面严格垂直居中，仅侧面书脊悬停时轻轻上抽，避免顶部越界
    final dy = reduceMotion ? 0.0 : -(lift * 0.042 * h);
    return (
      x: centerX(r, ws, d, gap),
      o: o,
      rotY: rotY,
      rotZ: rotZ,
      z: z,
      dy: dy,
      spineShade: (o * 0.40) * (1.0 - lift * 0.35),
      coverShade: (1.0 - o) * 0.34,
    );
  }

  /// 计算当前视口内可见的书籍序号，按离中心由远及近排序（远的先画，近的叠在上面）。
  static List<int> visibleIndices(double page, int count, double stageW, double ws, double d, double gap) {
    if (count <= 0) return const [];
    final step = ws + gap;
    final limitX = stageW / 2 + d * 1.1;
    final span = ((limitX / math.max(step, 1.0)).ceil() + 2).clamp(2, count);
    final lo = math.max(0, page.floor() - span);
    final hi = math.min(count - 1, page.ceil() + span);
    final out = <int>[];
    for (var i = lo; i <= hi; i++) {
      if (centerX(i - page, ws, d, gap).abs() <= limitX) out.add(i);
    }
    out.sort((a, b) => (b - page).abs().compareTo((a - page).abs()));
    return out;
  }

  /// 根据舞台相对中心的横坐标 [localDx]，从前到后精确命中对应的书（兼顾宽封面与窄书脊）。
  static int? hitTest({
    required double localDx,
    required double page,
    required int count,
    required double stageW,
    required double ws,
    required double d,
    required double gap,
  }) {
    final visible = visibleIndices(page, count, stageW, ws, d, gap);
    for (var idx = visible.length - 1; idx >= 0; idx--) {
      final i = visible[idx];
      final r = i - page;
      final o = openness(r);
      final cx = centerX(r, ws, d, gap);
      final rotY = (math.pi / 2) * o;
      final halfW = (ws * math.cos(rotY).abs() + d * math.sin(rotY).abs()) / 2 + gap * 0.5;
      if ((localDx - cx).abs() <= halfW) return i;
    }
    return null;
  }
}

/// 书架的「书脊」显示方式：成排日系文库本书脊紧凑竖插在架上，当前书物理抽出并 3D 旋转展示完整封面。
class ShelfSpineView extends StatefulWidget {
  const ShelfSpineView({
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
    this.unreadOf,
    this.volumeCountOf,
  });

  final List<LibBook> books;
  final String? initialAid;
  final ValueChanged<String>? onFocusChanged;
  final Set<String> selected;
  final bool heroEnabled;
  final String Function(LibBook book) coverOf;
  final Widget? Function(LibBook book) badgeOf;
  final String Function(LibBook book) subtitleOf;
  final ({String label, String? cid}) Function(LibBook book) actionOf;
  final void Function(LibBook book) onOpen;
  final void Function(LibBook book, String cid) onRead;
  final void Function(LibBook book) onToggleSelect;
  final int Function(LibBook book)? unreadOf;
  final int Function(LibBook book)? volumeCountOf;

  @override
  State<ShelfSpineView> createState() => _ShelfSpineViewState();
}

class _ShelfSpineViewState extends State<ShelfSpineView> with SingleTickerProviderStateMixin {
  int _cur = 0;
  int _dir = 1;
  PageController? _pc;
  double _fraction = 0;
  final _focus = FocusNode(debugLabel: 'shelf-spine');
  final _stageKey = GlobalKey();
  DateTime _lastScrollEvent = DateTime(0);
  DateTime _lastWheelStep = DateTime(0);
  double _wheelAccum = 0;
  double _lastAbsDelta = 0;
  bool _wheelLocked = false;
  double _lastCoverWidth = 0;
  final _precached = <String>{};
  int _lastPrecachedCur = -1;

  // 桌面端微交互：中央封面 3D 视差倾转 + 侧面书脊悬停上抽（空闲自动停帧）
  late final Ticker _ticker = createTicker(_onTick);
  final _motion = ValueNotifier<int>(0);
  Duration _lastTick = Duration.zero;
  double _tiltX = 0, _tiltY = 0;
  double _targetTiltX = 0, _targetTiltY = 0;
  int? _hoveredIndex;
  final _lifts = <int, double>{};
  bool _reduceMotion = false;
  bool _pointerOverBook = false;

  // 记录最近一次布局尺寸供点击坐标命中计算使用
  double _h = 260, _d = 182, _ws = 44, _gap = 3;

  void _ensureTicking() {
    if (_reduceMotion) return;
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _resetPointerMotion() {
    _hoveredIndex = null;
    _targetTiltX = 0;
    _targetTiltY = 0;
    if (_pointerOverBook) setState(() => _pointerOverBook = false);
    if (_reduceMotion) {
      _tiltX = _tiltY = 0;
      _lifts.clear();
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_tiltX != 0 || _tiltY != 0 || _lifts.isNotEmpty) _ensureTicking();
  }

  void _onStageHover(PointerHoverEvent e, double stageW, double stageH) {
    if (e.kind != PointerDeviceKind.mouse) return;
    final dx = e.localPosition.dx - stageW / 2;
    final dy = e.localPosition.dy - stageH / 2;
    final inVert = dy.abs() <= _h * 0.56;
    final hit = inVert ? ShelfSpineLayout.hitTest(localDx: dx, page: _page, count: widget.books.length, stageW: stageW, ws: _ws, d: _d, gap: _gap) : null;
    final overBook = hit != null;
    if (overBook != _pointerOverBook) setState(() => _pointerOverBook = overBook);

    if (_reduceMotion) return;
    final p = _page;
    final settled = (p - _cur).abs() < 0.3;
    final onCover = settled && hit == _cur && dx.abs() <= _d * 0.56 && dy.abs() <= _h * 0.55;
    final nextHover = (!onCover && hit != null && (hit - p).abs() > 0.5) ? hit : null;
    if (onCover) {
      _targetTiltY = -(dx / (_d * 0.55)).clamp(-1.0, 1.0) * 0.11;
      _targetTiltX = (dy / (_h * 0.55)).clamp(-1.0, 1.0) * 0.08;
      _hoveredIndex = null;
      _ensureTicking();
    } else {
      _targetTiltY = 0;
      _targetTiltX = 0;
      if (nextHover != _hoveredIndex) {
        _hoveredIndex = nextHover;
        if (nextHover != null) _lifts.putIfAbsent(nextHover, () => 0);
      }
      if (_hoveredIndex != null || _tiltX != 0 || _tiltY != 0 || _lifts.isNotEmpty) {
        _ensureTicking();
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? 1 / 60 : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;
    final tiltAlpha = 1 - math.exp(-7.0 * dt);
    final liftAlpha = 1 - math.exp(-12.0 * dt);
    final p = _page;
    final settled = (p - _cur).abs() < 0.3;
    final tx = settled ? _targetTiltX : 0.0;
    final ty = settled ? _targetTiltY : 0.0;

    var active = false;
    _tiltX += (tx - _tiltX) * tiltAlpha;
    _tiltY += (ty - _tiltY) * tiltAlpha;
    if ((tx - _tiltX).abs() < 0.0005) {
      _tiltX = tx;
    } else {
      active = true;
    }
    if ((ty - _tiltY).abs() < 0.0005) {
      _tiltY = ty;
    } else {
      active = true;
    }

    final hov = _hoveredIndex;
    if (hov != null && (hov - p).abs() > 0.5) _lifts.putIfAbsent(hov, () => 0);
    final remove = <int>[];
    for (final entry in _lifts.entries.toList()) {
      final target = (hov == entry.key && (entry.key - p).abs() > 0.5) ? 1.0 : 0.0;
      var next = entry.value + (target - entry.value) * liftAlpha;
      if ((target - next).abs() < 0.001) {
        next = target;
      } else {
        active = true;
      }
      if (next == 0) {
        remove.add(entry.key);
      } else {
        _lifts[entry.key] = next;
      }
    }
    for (final k in remove) {
      _lifts.remove(k);
    }

    _motion.value++;
    if (!active) _ticker.stop();
  }

  void _precacheAround(int center) {
    if (!mounted || widget.books.isEmpty || _lastCoverWidth <= 0) return;
    _lastPrecachedCur = center;
    final size = Size(_lastCoverWidth, _lastCoverWidth / kCoverAspect);
    // 提前预解码前后 2 本封面，兼顾旋转翻出流畅度与显存占用
    for (var d = 0; d <= 2; d++) {
      for (final idx in d == 0 ? [center] : [center + d, center - d]) {
        if (idx < 0 || idx >= widget.books.length) continue;
        final url = widget.coverOf(widget.books[idx]);
        if (url.isEmpty || _precached.contains(url)) continue;
        if (_precached.length >= 128) _precached.remove(_precached.first);
        _precached.add(url);
        NetImage.precache(context, url, size).ignore();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _cur = math.max(0, widget.books.indexWhere((b) => b.aid == widget.initialAid));
  }

  PageController _controller(double fraction) {
    if (_pc != null && (fraction - _fraction).abs() < 0.004) return _pc!;
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
  void didUpdateWidget(ShelfSpineView old) {
    super.didUpdateWidget(old);
    if (old.books.isEmpty || widget.books.isEmpty) return;
    final aid = old.books[_cur.clamp(0, old.books.length - 1)].aid;
    final i = widget.books.indexWhere((b) => b.aid == aid);
    final target = i >= 0 ? i : math.min(_cur, widget.books.length - 1);
    if (target == _cur) {
      if (!identical(old.books, widget.books)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _precacheAround(_cur);
        });
      }
      return;
    }
    _dir = target >= _cur ? 1 : -1;
    _cur = target;
    _lifts.clear();
    _hoveredIndex = null;
    widget.onFocusChanged?.call(widget.books[target].aid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pc?.hasClients == true) _pc!.jumpToPage(_cur);
      if (mounted) _precacheAround(_cur);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _motion.dispose();
    _pc?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int i) {
    final pc = _pc;
    if (pc == null || !pc.hasClients) return;
    final target = i.clamp(0, widget.books.length - 1);
    if (target == _cur) return;
    _dir = target > _cur ? 1 : -1;
    if (_reduceMotion) {
      pc.jumpToPage(target);
      return;
    }
    pc.animateToPage(
      target,
      duration: Duration(milliseconds: math.min(320 + 50 * (target - _cur).abs(), 720)),
      curve: kShelfEase,
    );
  }

  void _tapIndex(int i) {
    _focus.requestFocus();
    final book = widget.books[i];
    if (widget.selected.isNotEmpty) {
      widget.onToggleSelect(book);
    } else if (i == _cur) {
      widget.onOpen(book);
    } else {
      _go(i);
    }
  }

  int? _hitAtGlobal(Offset globalPos) {
    final box = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPos);
    return ShelfSpineLayout.hitTest(localDx: local.dx - box.size.width / 2, page: _page, count: widget.books.length, stageW: box.size.width, ws: _ws, d: _d, gap: _gap);
  }

  void _onTapGlobal(Offset globalPos) {
    final i = _hitAtGlobal(globalPos);
    if (i != null) _tapIndex(i);
  }

  void _onSelectGlobal(Offset globalPos) {
    final i = _hitAtGlobal(globalPos);
    if (i != null) widget.onToggleSelect(widget.books[i]);
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is PointerScrollInertiaCancelEvent) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
      return;
    }
    if (e is! PointerScrollEvent) return;
    final delta = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
    if (delta == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastScrollEvent) > const Duration(milliseconds: 140)) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
    }
    _lastScrollEvent = now;
    if (_wheelAccum != 0 && delta.sign != _wheelAccum.sign) {
      _wheelAccum = 0;
      _wheelLocked = false;
    }
    final absDelta = delta.abs();
    if (_wheelLocked) {
      final reaccelerated = absDelta > _lastAbsDelta * 1.8 && absDelta >= 12;
      _lastAbsDelta = absDelta;
      if (!reaccelerated || now.difference(_lastWheelStep) < const Duration(milliseconds: 240)) return;
      _wheelLocked = false;
      _wheelAccum = 0;
    }
    _lastAbsDelta = absDelta;
    _wheelAccum += delta;
    if (_wheelAccum.abs() < 18) return;
    if (now.difference(_lastWheelStep) < const Duration(milliseconds: 220)) return;
    _lastWheelStep = now;
    _wheelLocked = true;
    final step = _wheelAccum > 0 ? 1 : -1;
    _wheelAccum = 0;
    _go(_cur + step);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(_cur + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(_cur - 1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _tapIndex(_cur);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    if (books.isEmpty) return const SizedBox.shrink();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      if (reduceMotion) _resetPointerMotion();
    }
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    return LayoutBuilder(
      builder: (context, c) {
        final infoH = ShelfSpineLayout.infoHeight(textScale);
        final height = c.maxHeight.isFinite ? c.maxHeight : 640.0;
        final m = ShelfSpineLayout.metrics(c.maxWidth, math.max(200.0, height - infoH));
        _h = m.h;
        _d = m.d;
        _ws = m.ws;
        _gap = m.gap;
        final stageH = ShelfSpineLayout.stageHeight(m.h);
        final canScroll = stageH + infoH > height + 1;
        final pc = _controller(((m.ws + m.gap) / math.max(c.maxWidth, 1.0)).clamp(0.08, 0.85));
        final cur = _cur.clamp(0, books.length - 1);
        final widthChanged = (_lastCoverWidth - m.d).abs() > 8;
        if (widthChanged) {
          _lastCoverWidth = m.d;
          _precached.clear();
        }
        if (widthChanged || _lastPrecachedCur != cur) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _precacheAround(cur);
          });
        }
        return Focus(
          autofocus: true,
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onWheel,
            child: SingleChildScrollView(
              physics: canScroll ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(key: const ValueKey('shelf-spine-stage'), height: stageH, child: _stage(pc, c.maxWidth, stageH)),
                    SizedBox(key: const ValueKey('shelf-spine-info'), height: infoH, child: _info(books[cur], cur, textScale, c.maxWidth)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _stage(PageController pc, double stageW, double stageH) {
    final books = widget.books;
    final cur = _cur.clamp(0, books.length - 1);
    final curBook = books[cur];
    final persp = 1 / (_h * 3.8);
    // 在 AnimatedBuilder 外预计算未读数、卷数、角标与静态书脊体，避免滑动/悬停每帧重复计算与重建书脊印刷体
    final approxSpan = ((stageW / 2 + _d * 1.1) / math.max(_ws + _gap, 1.0)).ceil() + 3;
    final preLo = math.max(0, cur - approxSpan);
    final preHi = math.min(books.length - 1, cur + approxSpan);
    final unreadCounts = <String, int>{};
    final volumeCounts = <String, int>{};
    final badges = <String, Widget?>{};
    final spineBodies = <String, Widget>{};
    for (var i = preLo; i <= preHi; i++) {
      final b = books[i];
      final unread = widget.unreadOf?.call(b) ?? 0;
      final volCount = widget.volumeCountOf?.call(b) ?? 0;
      unreadCounts[b.aid] = unread;
      volumeCounts[b.aid] = volCount;
      spineBodies[b.aid] = _StaticSpineBody(
        book: b,
        coverOf: widget.coverOf,
        unreadCount: unread,
        volumeCount: volCount,
        spineWidth: _ws,
      );
    }
    Widget spineBodyFor(LibBook b) => spineBodies.putIfAbsent(
      b.aid,
      () => _StaticSpineBody(
        book: b,
        coverOf: widget.coverOf,
        unreadCount: unreadCounts.putIfAbsent(b.aid, () => widget.unreadOf?.call(b) ?? 0),
        volumeCount: volumeCounts.putIfAbsent(b.aid, () => widget.volumeCountOf?.call(b) ?? 0),
        spineWidth: _ws,
      ),
    );
    Widget? badgeFor(LibBook b) => badges.containsKey(b.aid) ? badges[b.aid] : (badges[b.aid] = widget.badgeOf(b));
    // 舞台对外只暴露一个稳定的 Semantics 节点，屏蔽内部窄页 PageView 高频增删/重挂，规避 macOS AXNode 闪退
    return Semantics(
      button: true,
      selected: widget.selected.contains(curBook.aid),
      label: curBook.shown,
      hint: hz(context, '点击打开分卷，左右滑动或方向键切书'),
      onTap: () => _tapIndex(cur),
      onIncrease: cur < books.length - 1 ? () => _go(cur + 1) : null,
      onDecrease: cur > 0 ? () => _go(cur - 1) : null,
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: _pointerOverBook ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onHover: (e) => _onStageHover(e, stageW, stageH),
          onExit: (_) => _resetPointerMotion(),
          child: ClipRect(
            key: _stageKey,
            clipper: const ShelfSidesClipper(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) => _onTapGlobal(d.globalPosition),
              onLongPressStart: (d) => _onSelectGlobal(d.globalPosition),
              onSecondaryTapUp: (d) => _onSelectGlobal(d.globalPosition),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([pc, _motion]),
                      builder: (context, _) {
                        final p = _page;
                        final shown = ShelfSpineLayout.visibleIndices(p, books.length, stageW, _ws, _d, _gap);
                        return Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [for (final i in shown) _cuboidBook(i, i - p, persp, spineBodyFor, badgeFor)],
                        );
                      },
                    ),
                  ),
                  PageView.builder(
                    controller: pc,
                    itemCount: books.length,
                    pageSnapping: false,
                    physics: const ShelfFlingSnapPhysics(),
                    onPageChanged: (i) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        if (i != _cur) _dir = i > _cur ? 1 : -1;
                        _cur = i;
                      });
                      if (_lifts.isNotEmpty || _tiltX != 0 || _tiltY != 0) _ensureTicking();
                      widget.onFocusChanged?.call(books[i].aid);
                      _precacheAround(i);
                    },
                    itemBuilder: (context, i) => SizedBox.expand(key: ValueKey('shelf-spine-hit-${books[i].aid}')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一本书的双面 3D 盒子：书脊面在正面（z = -d/2），封面在右侧面（x = +ws/2 绕 Y 轴转 -90°）。
  /// 整盒绕 Y 轴旋转 `0 -> +90°` 时，书脊平滑隐去，封面沿同一条折脊边自然转到正面面向读者。
  Widget _cuboidBook(
    int i,
    double r,
    double persp,
    Widget Function(LibBook) spineBodyFor,
    Widget? Function(LibBook) badgeFor,
  ) {
    final book = widget.books[i];
    final lift = _reduceMotion ? 0.0 : (_lifts[i] ?? 0.0);
    final pose = ShelfSpineLayout.pose(r, _h, _ws, _d, _gap, lift: lift, tiltY: _tiltY, reduceMotion: _reduceMotion);
    final effTiltX = _reduceMotion ? 0.0 : _tiltX * pose.o;
    final front = r.abs() < 0.5;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = widget.selected.contains(book.aid);

    final box = Matrix4.identity()
      ..setEntry(3, 2, persp)
      ..multiply(Matrix4.translationValues(pose.x, pose.dy, pose.z))
      ..rotateZ(pose.rotZ)
      ..rotateX(effTiltX)
      ..rotateY(pose.rotY);

    // 避开接近 0°/90° 的极窄亚像素边缘，消除 3D 翻出首帧的细黑条闪烁
    final showSpine = math.cos(pose.rotY) > 0.035;
    final showCover = math.sin(pose.rotY) > 0.04;
    final badge = pose.o > 0.65 ? badgeFor(book) : null;

    Widget? spineFace;
    if (showSpine) {
      final spineM = box.clone()..multiply(Matrix4.translationValues(0, 0, -_d / 2));
      spineFace = Transform(
        alignment: Alignment.center,
        transform: spineM,
        child: SizedBox(
          width: _ws,
          height: _h,
          child: _BookSpine(
            body: spineBodyFor(book),
            shade: pose.spineShade,
            selected: selected,
            lifted: lift > 0.05,
            standingFactor: (1.0 - pose.o).clamp(0.0, 1.0),
          ),
        ),
      );
    }

    Widget? coverFace;
    if (showCover) {
      final coverM = box.clone()
        ..multiply(Matrix4.translationValues(_ws / 2, 0, 0))
        ..rotateY(-math.pi / 2);
      // 投影仅在书真正抽出面对读者后（o > 0.4）柔和浮现，避免侧转途中投影被透视压扁闪黑
      final sT = ((pose.o - 0.4) / 0.6).clamp(0.0, 1.0);
      final shadowFactor = sT * sT * (3.0 - 2.0 * sT);
      Widget cover = Consumer(
        builder: (context, ref, _) {
          ref.watch(volumeChangeForProvider(book.aid));
          return _SpineCoverFace(
            aid: book.aid,
            url: widget.coverOf(book),
            decodeSize: Size(_d, _h),
            shade: pose.coverShade,
            selected: selected,
            shadowAlpha: (dark ? 0.52 : 0.34) * shadowFactor,
          );
        },
      );
      if (front) {
        cover = HeroMode(
          enabled: widget.heroEnabled,
          child: Hero(tag: 'vols:${book.aid}', flightShuttleBuilder: volumeHeroShuttle, child: cover),
        );
      }
      coverFace = Transform(
        alignment: Alignment.center,
        transform: coverM,
        child: SizedBox(
          width: _d,
          height: _h,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              cover,
              if (badge != null) Positioned(top: 8, right: 8, child: badge),
            ],
          ),
        ),
      );
    }

    return KeyedSubtree(
      key: ValueKey('spine-book-${book.aid}'),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (pose.o < 0.5) ...[?coverFace, ?spineFace] else ...[?spineFace, ?coverFace],
        ],
      ),
    );
  }

  Widget _info(LibBook book, int cur, double textScale, double width) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = widget.books.length;
    final selecting = widget.selected.isNotEmpty;
    final selected = widget.selected.contains(book.aid);
    final action = widget.actionOf(book);
    final showArrows = width >= 640 && n > 1;
    final subtitle = widget.subtitleOf(book);
    // 不对按钮套 AnimatedSwitcher(key: aid)，避免快滑或拖滑块时高频重挂按钮的 Semantics / Focus 节点
    final Widget button = selecting
        ? ShelfActionButton(
            active: selected,
            onPressed: () => widget.onToggleSelect(book),
            icon: selected ? Icons.check_circle_outline : Icons.radio_button_unchecked,
            label: selected ? '已选中' : '选中',
          )
        : ShelfActionButton(
            onPressed: () => action.cid == null ? widget.onOpen(book) : widget.onRead(book, action.cid!),
            icon: action.cid == null ? Icons.auto_stories_outlined : Icons.play_arrow_rounded,
            label: action.label,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Center(
              child: n > 1
                  ? ShelfPageIndicator(keyPrefix: 'shelf-spine', index: cur, count: n, onPick: (i) => _pc?.jumpToPage(i), onTapDot: _go)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (showArrows)
                IconButton(
                  key: const ValueKey('shelf-spine-prev'),
                  tooltip: hz(context, '上一本'),
                  color: scheme.onSurface.withValues(alpha: 0.56),
                  disabledColor: scheme.onSurface.withValues(alpha: 0.18),
                  onPressed: cur > 0 ? () => _go(cur - 1) : null,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                )
              else
                const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    SizedBox(
                      height: 26 * textScale,
                      child: MaskedRollSwitcher(
                        direction: _dir,
                        semanticLabel: book.shown,
                        child: Text(
                          book.shown,
                          key: ValueKey(book.aid),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: 0.2, height: 1.28),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 18 * textScale,
                      child: MaskedRollSwitcher(
                        direction: _dir,
                        semanticLabel: subtitle,
                        child: Text(
                          subtitle,
                          key: ValueKey(book.aid),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (showArrows)
                IconButton(
                  key: const ValueKey('shelf-spine-next'),
                  tooltip: hz(context, '下一本'),
                  color: scheme.onSurface.withValues(alpha: 0.56),
                  disabledColor: scheme.onSurface.withValues(alpha: 0.18),
                  onPressed: cur < n - 1 ? () => _go(cur + 1) : null,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 40 * textScale,
            child: Center(child: button),
          ),
        ],
      ),
    );
  }
}

/// 书脊模式专用的正面封面：不透明暖纸背板 + 独立 RepaintBoundary 模糊阴影与静态封面 + 外层动态压暗遮罩，杜绝 3D 翻转途中每帧重绘模糊与闪黑影。
class _SpineCoverFace extends StatelessWidget {
  const _SpineCoverFace({
    required this.aid,
    required this.url,
    required this.shade,
    required this.selected,
    required this.shadowAlpha,
    this.decodeSize,
  });

  final String aid;
  final String url;
  final double shade;
  final bool selected;
  final double shadowAlpha;
  final Size? decodeSize;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(3));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final backing = _spinePalette(aid, url.isEmpty ? null : savedCoverColor(url), dark).bg;
    final baseShadow = dark ? 0.52 : 0.34;
    final shadowOpacity = (shadowAlpha / baseShadow).clamp(0.0, 1.0);
    final shadowBox = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: baseShadow),
              blurRadius: 28,
              spreadRadius: -6,
              offset: const Offset(0, 18),
            ),
          ],
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (shadowOpacity >= 0.995)
          shadowBox
        else if (shadowOpacity > 0.01)
          Opacity(opacity: shadowOpacity, child: shadowBox),
        RepaintBoundary(
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 不透明背板放在 ClipRRect 内且 CoverImage 关掉内部圆角与浅白底衬，彻底消除四角漏黑点与裁剪底边漏白
                ColoredBox(color: backing),
                CoverImage(url, decodeSize: decodeSize, borderRadius: 0, backgroundColor: backing),
                // 封面左侧极淡的书脊装订压痕，和转过去的书脊自然衔接
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0.08), Colors.transparent],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (shade > 0.005)
          DecoratedBox(
            decoration: BoxDecoration(borderRadius: radius, color: Colors.black.withValues(alpha: shade)),
          ),
        IgnorePointer(
          child: AnimatedContainer(
            duration: AppMotion.dur(context, AppMotion.fast),
            curve: AppMotion.curve,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: selected ? primary : primary.withValues(alpha: 0), width: 3),
            ),
          ),
        ),
      ],
    );
  }
}

/// 实体印刷文库书脊色板：深邃浓郁的复古油墨色系（钴蓝、朱红、松绿、炭墨、酒红、赭褐、普鲁士蓝、墨青）。
const _bunkoRichColors = [
  Color(0xFF1D438A), // 钴蓝
  Color(0xFF7D2A24), // 复古朱红
  Color(0xFF1D5242), // 松林绿
  Color(0xFF232220), // 炭墨黑
  Color(0xFF6B2D46), // 梅酒红
  Color(0xFF294A5E), // 普鲁士青
  Color(0xFF5D3A24), // 赭陶褐
  Color(0xFF342D52), // 靛紫
];

/// 为每本书推导「书脊底色 + 印刷文字色 + 装饰强调色」：
/// 约 1/3 呈现暖米纸底 + 深彩字（如经典日版文库白脊），约 2/3 呈现浓郁深彩油墨底 + 暖白字，
/// 让整排书脊天然形成明暗交替、冷暖交错的实体收藏节奏。
({Color bg, Color ink, Color accent, bool isPaper}) _spinePalette(String aid, Color? extracted, bool dark) {
  final h = aid.hashCode.abs();
  final base = extracted ?? _bunkoRichColors[h % _bunkoRichColors.length];
  final hsl = HSLColor.fromColor(base);
  // 若封面几乎是纯灰（饱和度极低），借用兜底色板里的色相避免整排发灰
  final effectiveHue = hsl.saturation < 0.08 ? HSLColor.fromColor(_bunkoRichColors[h % _bunkoRichColors.length]).hue : hsl.hue;
  final isPaper = h % 3 == 1;
  if (isPaper) {
    final paperBg = dark ? const Color(0xFFDCD5C5) : const Color(0xFFEAE3D4);
    final deepInk = HSLColor.fromAHSL(1, effectiveHue, hsl.saturation.clamp(0.38, 0.72), 0.24).toColor();
    return (bg: paperBg, ink: deepInk, accent: deepInk, isPaper: true);
  }
  final richSat = hsl.saturation < 0.08 ? 0.45 : hsl.saturation.clamp(0.36, 0.68);
  final richLight = dark ? 0.24 : 0.27;
  final richBg = HSLColor.fromAHSL(1, effectiveHue, richSat, richLight).toColor();
  const warmInk = Color(0xFFF3ECE0);
  return (bg: richBg, ink: warmInk, accent: warmInk, isPaper: false);
}

/// 静态书脊印刷体（独立 RepaintBoundary，不接收每帧变化的 `shade`/`lifted`/`standingFactor`）：
/// 1. 深彩油墨脊与暖米纸脊交错；
/// 2. 顶部封面满宽出血插图 + 底部柔化渐变自然融入书脊底色；
/// 3. 中部单层 CustomPaint 竖排衬线/文楷书名；
/// 4. 底部 1px 印刷方框标 + 左右立体书盒折痕与纸边厚度感。
class _StaticSpineBody extends ConsumerWidget {
  const _StaticSpineBody({
    required this.book,
    required this.coverOf,
    required this.unreadCount,
    required this.volumeCount,
    this.spineWidth,
  });

  final LibBook book;
  final String Function(LibBook) coverOf;
  final int unreadCount;
  final int volumeCount;
  final double? spineWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(volumeChangeForProvider(book.aid));
    final url = coverOf(book);
    final saved = url.isEmpty ? null : savedCoverColor(url);
    final asyncColor = url.isEmpty ? null : ref.watch(coverColorProvider(url)).value;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pal = _spinePalette(book.aid, asyncColor ?? saved, dark);
    final scheme = Theme.of(context).colorScheme;
    final tag = book.done ? '完' : (volumeCount > 0 ? '$volumeCount卷' : '文库');
    final titleFamily = Theme.of(context).textTheme.titleLarge?.fontFamily;
    final titleFallback = Theme.of(context).textTheme.titleLarge?.fontFamilyFallback;
    final bleedDecodeSize = spineWidth != null ? Size(spineWidth!, spineWidth! / 0.78) : null;
    const radius = BorderRadius.all(Radius.circular(2.5));

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 书脊真实底色
            ColoredBox(color: pal.bg),
            // 2. 顶部满宽出血封面插图：封面底边内收 2px 并改用 pal.bg 底衬，渐变在 0.88 处即达纯色 pal.bg，根除 3D 透视下同边亚像素漏白闪烁
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AspectRatio(
                aspectRatio: 0.78,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (url.isNotEmpty)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        bottom: 2,
                        child: CoverImage(
                          url,
                          thumbnail: true,
                          lowPriority: true,
                          maxDecodeWidth: 160,
                          decodeSize: bleedDecodeSize,
                          borderRadius: 0,
                          backgroundColor: pal.bg,
                        ),
                      )
                    else
                      ColoredBox(color: pal.ink.withValues(alpha: 0.10)),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            pal.bg.withValues(alpha: 0.20),
                            pal.bg.withValues(alpha: 0.88),
                            pal.bg,
                            pal.bg,
                          ],
                          stops: const [0.0, 0.48, 0.78, 0.88, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 3. 实体纸盒曲面高光 + 左右折痕阴影 + 右侧微厚度暗边，赋予成排书脊立体感
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.white.withValues(alpha: pal.isPaper ? 0.35 : 0.18),
                      Colors.white.withValues(alpha: 0.04),
                      Colors.transparent,
                      Colors.black.withValues(alpha: pal.isPaper ? 0.08 : 0.10),
                      Colors.black.withValues(alpha: pal.isPaper ? 0.24 : 0.38),
                    ],
                    stops: const [0.0, 0.09, 0.55, 0.88, 1.0],
                  ),
                ),
              ),
            ),
            // 4. 顶部和底部的轻微纸边做旧暗角
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black.withValues(alpha: pal.isPaper ? 0.14 : 0.22), width: 0.6),
                  borderRadius: radius,
                ),
              ),
            ),
            // 5. 书脊文字与底部印章布局
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 5, 8),
              child: Column(
                children: [
                  // 为顶部出血插图留出安全高度，同时允许标题从插图羽化边缘自然接续
                  const AspectRatio(aspectRatio: 0.86, child: SizedBox.shrink()),
                  Expanded(
                    child: _VerticalSpineTitle(
                      title: book.shown,
                      color: pal.ink,
                      fontFamily: titleFamily,
                      fontFamilyFallback: titleFallback,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (unreadCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: pal.ink.withValues(alpha: 0.8), width: 0.8),
                        ),
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
                    decoration: BoxDecoration(
                      border: Border.all(color: pal.ink.withValues(alpha: 0.72), width: 0.9),
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                    child: Text(
                      tag,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(color: pal.ink, fontSize: 9.5, fontWeight: FontWeight.w700, height: 1.0, letterSpacing: 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书脊动态外层：只承载每帧变化的投影、受光压暗遮罩与选中描边，复用外层传入的静态书脊印刷体 [body]。
class _BookSpine extends StatelessWidget {
  const _BookSpine({
    required this.body,
    required this.shade,
    required this.selected,
    required this.lifted,
    required this.standingFactor,
  });

  final Widget body;
  final double shade;
  final bool selected;
  final bool lifted;
  final double standingFactor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    const radius = BorderRadius.all(Radius.circular(2.5));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: standingFactor > 0.2
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: (dark ? 0.34 : 0.16) * standingFactor * (lifted ? 1.4 : 1.0)),
                  blurRadius: lifted ? 12 : 4,
                  offset: Offset(2, lifted ? 8 : 3),
                ),
              ]
            : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          body,
          if (shade > 0.005)
            DecoratedBox(
              decoration: BoxDecoration(borderRadius: radius, color: Colors.black.withValues(alpha: shade)),
            ),
          IgnorePointer(
            child: AnimatedContainer(
              duration: AppMotion.dur(context, AppMotion.fast),
              curve: AppMotion.curve,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: selected ? primary : primary.withValues(alpha: 0), width: 2.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _verticalPunct = <String, String>{
  '（': '︵',
  '）': '︶',
  '(': '︵',
  ')': '︶',
  '「': '﹁',
  '」': '﹂',
  '『': '﹃',
  '』': '﹄',
  '《': '︽',
  '》': '︾',
  '【': '︻',
  '】': '︼',
  '—': '︱',
  '―': '︱',
  '－': '︱',
  '-': '︱',
  '～': '︴',
  '~': '︴',
  '…': '⋮',
};

/// 书脊竖排书名：单层 CustomPaint + 缓存 TextPainter 绘制，CJK 直排、竖排标点映射、连续拉丁/数字横转 90°、超出自动补 `⋮`，并支持界面繁简转换。
class _VerticalSpineTitle extends StatefulWidget {
  const _VerticalSpineTitle({required this.title, required this.color, this.fontFamily, this.fontFamilyFallback});

  final String title;
  final Color color;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  static final _asciiRun = RegExp(r'^[A-Za-z0-9._:+!?\-]+$');

  static List<String> _tokenize(String s) {
    final clean = s.trim();
    if (clean.isEmpty) return const [];
    final tokens = <String>[];
    final buf = StringBuffer();
    void flushAscii() {
      if (buf.isEmpty) return;
      tokens.add(buf.toString());
      buf.clear();
    }

    for (final rune in clean.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '\t' || ch == '\n') {
        flushAscii();
        continue;
      }
      if (rune < 128 && _asciiRun.hasMatch(ch) && !_verticalPunct.containsKey(ch)) {
        buf.write(ch);
      } else {
        flushAscii();
        tokens.add(_verticalPunct[ch] ?? ch);
      }
    }
    flushAscii();
    return tokens;
  }

  @override
  State<_VerticalSpineTitle> createState() => _VerticalSpineTitleState();
}

class _SpineGlyph {
  const _SpineGlyph(this.painter, this.rotated, this.height);

  final TextPainter painter;
  final bool rotated;
  final double height;
}

class _SpineTitleLayoutCache {
  String _title = '';
  Color _color = Colors.transparent;
  String? _fontFamily;
  List<String>? _fontFamilyFallback;
  Size _size = Size.zero;
  TextScaler _textScaler = TextScaler.noScaling;
  TextDirection _textDirection = TextDirection.ltr;
  List<_SpineGlyph> glyphs = const [];
  double totalHeight = 0;

  void ensure({
    required String title,
    required Color color,
    required String? fontFamily,
    required List<String>? fontFamilyFallback,
    required Size size,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    if (_title == title &&
        _color == color &&
        _fontFamily == fontFamily &&
        listEquals(_fontFamilyFallback, fontFamilyFallback) &&
        _size == size &&
        _textScaler == textScaler &&
        _textDirection == textDirection) {
      return;
    }
    dispose();
    _title = title;
    _color = color;
    _fontFamily = fontFamily;
    _fontFamilyFallback = fontFamilyFallback == null ? null : List<String>.of(fontFamilyFallback);
    _size = size;
    _textScaler = textScaler;
    _textDirection = textDirection;

    final availW = size.width;
    final availH = size.height;
    final tokens = _VerticalSpineTitle._tokenize(title);
    if (availW <= 0 || availH <= 0 || tokens.isEmpty) {
      glyphs = const [];
      totalHeight = 0;
      return;
    }

    // 字号饱满有力，避免书脊上密密麻麻看不清
    final fontSize = (availW * 0.44).clamp(12.5, 17.0);
    final charH = fontSize * 1.16;
    final style = TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.08,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    final latinStyle = style.copyWith(fontSize: fontSize * 0.88, letterSpacing: 0.5);
    final maxLatinLen = math.max(1.0, availH * 0.42);

    final out = <_SpineGlyph>[];
    var used = 0.0;
    var truncated = false;
    for (var i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final isLatin = tok.length > 1 || (tok.codeUnitAt(0) < 128 && _VerticalSpineTitle._asciiRun.hasMatch(tok));
      final tp = TextPainter(
        text: TextSpan(text: tok, style: isLatin ? latinStyle : style),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
        ellipsis: isLatin ? '…' : null,
      );
      if (isLatin) {
        tp.layout(maxWidth: maxLatinLen);
      } else {
        tp.layout();
      }
      final itemH = isLatin ? tp.width + 3.0 : math.max(tp.height, fontSize * 1.08);
      final remaining = i < tokens.length - 1 ? charH : 0.0;
      if (used + itemH + remaining > availH) {
        tp.dispose();
        truncated = true;
        break;
      }
      used += itemH;
      out.add(_SpineGlyph(tp, isLatin, itemH));
    }
    if (truncated && availH >= charH) {
      final ellip = TextPainter(
        text: TextSpan(text: '⋮', style: style.copyWith(color: color.withValues(alpha: 0.72))),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final itemH = math.max(ellip.height, fontSize * 1.08);
      used += itemH;
      out.add(_SpineGlyph(ellip, false, itemH));
    }
    glyphs = out;
    totalHeight = used;
  }

  void dispose() {
    for (final g in glyphs) {
      g.painter.dispose();
    }
    glyphs = const [];
    totalHeight = 0;
    _size = Size.zero;
  }
}

class _VerticalSpineTitleState extends State<_VerticalSpineTitle> {
  final _cache = _SpineTitleLayoutCache();

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = hz(context, widget.title);
    if (displayTitle.trim().isEmpty) return const SizedBox.shrink();
    return SizedBox.expand(
      child: CustomPaint(
        painter: _VerticalSpineTitlePainter(
          cache: _cache,
          title: displayTitle,
          color: widget.color,
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        ),
      ),
    );
  }
}

class _VerticalSpineTitlePainter extends CustomPainter {
  const _VerticalSpineTitlePainter({
    required this.cache,
    required this.title,
    required this.color,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.textScaler,
    required this.textDirection,
  });

  final _SpineTitleLayoutCache cache;
  final String title;
  final Color color;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final TextScaler textScaler;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    cache.ensure(
      title: title,
      color: color,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      size: size,
      textScaler: textScaler,
      textDirection: textDirection,
    );
    final glyphs = cache.glyphs;
    if (glyphs.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    var y = math.max(0.0, (size.height - cache.totalHeight) / 2);
    for (final g in glyphs) {
      final tp = g.painter;
      if (g.rotated) {
        canvas.save();
        canvas.translate(size.width / 2, y + g.height / 2);
        canvas.rotate(math.pi / 2);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      } else {
        tp.paint(canvas, Offset((size.width - tp.width) / 2, y + (g.height - tp.height) / 2));
      }
      y += g.height;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VerticalSpineTitlePainter old) =>
      old.title != title ||
      old.color != color ||
      old.fontFamily != fontFamily ||
      !listEquals(old.fontFamilyFallback, fontFamilyFallback) ||
      old.textScaler != textScaler ||
      old.textDirection != textDirection;
}
