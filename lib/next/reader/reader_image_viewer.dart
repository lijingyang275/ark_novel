import 'package:flutter/material.dart' hide Text;
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../env.dart';
import '../image_cache.dart';
import '../main.dart' show evictInactiveImageCache;
import '../motion.dart';
import '../text.dart';
import '../widgets.dart';

class _ViewerCurveAnimatable extends Animatable<double> {
  const _ViewerCurveAnimatable(this.animation, {required this.curve, required this.reverseCurve});

  final Animation<double> animation;
  final Curve curve;
  final Curve reverseCurve;

  @override
  double transform(double t) {
    if (t == 0.0 || t == 1.0) return t;
    final reversing = animation.status == AnimationStatus.reverse || animation.status == AnimationStatus.dismissed;
    return reversing ? reverseCurve.flipped.transform(t) : curve.transform(t);
  }
}

/// 打开阅读器插图全屏查看器：支持多图左右切换、双击定点缩放、双指缩放、单击显隐工具栏、未放大时下滑关闭。
Future<void> showReaderImageViewer(BuildContext context, {required List<String> urls, int initialIndex = 0}) {
  if (urls.isEmpty) return Future.value();
  final safeIndex = initialIndex.clamp(0, urls.length - 1);
  final reduce = AppMotion.reduce(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: hz(context, '关闭'),
    barrierColor: Colors.transparent,
    transitionDuration: reduce ? Duration.zero : AppMotion.standard,
    pageBuilder: (ctx, _, _) => _ReaderImageViewer(urls: urls, initialIndex: safeIndex),
    transitionBuilder: (_, anim, _, child) {
      if (reduce) return FadeTransition(opacity: anim, child: child);
      final curved = anim.drive(_ViewerCurveAnimatable(anim, curve: AppMotion.decelerate, reverseCurve: AppMotion.exit));
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: curved.drive(Tween<double>(begin: 0.95, end: 1.0)), child: child),
      );
    },
  );
}

class _ReaderImageViewer extends ConsumerStatefulWidget {
  const _ReaderImageViewer({required this.urls, required this.initialIndex});

  final List<String> urls;
  final int initialIndex;

  @override
  ConsumerState<_ReaderImageViewer> createState() => _ReaderImageViewerState();
}

class _ReaderImageViewerState extends ConsumerState<_ReaderImageViewer> with SingleTickerProviderStateMixin {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late final AnimationController _dismissAnim = AnimationController.unbounded(vsync: this);
  late int _index = widget.initialIndex;
  bool _chrome = true;
  bool _zoomed = false;
  double _dragY = 0;
  int _dragGen = 0;

  @override
  void initState() {
    super.initState();
    _dismissAnim.addListener(() {
      if (mounted) setState(() => _dragY = _dismissAnim.value);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dismissAnim.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) => evictInactiveImageCache());
    super.dispose();
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_zoomed) return;
    _dragGen++;
    if (_dismissAnim.isAnimating) _dismissAnim.stop();
    setState(() => _dragY = (_dragY + d.delta.dy).clamp(-60.0, 420.0));
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_zoomed) return;
    final vy = d.velocity.pixelsPerSecond.dy;
    if (_dragY > 110 || (_dragY > 36 && vy > 700)) {
      Navigator.of(context).maybePop();
      return;
    }
    _springBack(vy);
  }

  void _springBack([double vy = 0]) {
    if (_dragY == 0) return;
    final gen = ++_dragGen;
    if (AppMotion.reduce(context)) {
      setState(() => _dragY = 0);
      return;
    }
    _dismissAnim.animateWith(SpringSimulation(AppMotion.smoothSpring, _dragY, 0, vy.clamp(-2400.0, 2400.0), tolerance: AppMotion.pixelTolerance)).then((_) {
      if (mounted && gen == _dragGen && _dragY != 0) setState(() => _dragY = 0);
    });
  }

  Future<void> _shareCurrent() async {
    final url = widget.urls[_index];
    try {
      final filePath = await ref.read(imageStoreProvider).path(url);
      await SharePlus.instance.share(ShareParams(files: [XFile(filePath)]));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出图片失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragY.clamp(0.0, 320.0) / 320.0).clamp(0.0, 1.0);
    final bgAlpha = (1.0 - progress * 0.72).clamp(0.25, 1.0);
    final scale = 1.0 - progress * 0.14;
    final showBar = _chrome && _dragY.abs() < 6;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
      child: Material(
        color: Colors.black.withValues(alpha: bgAlpha),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: _zoomed ? null : _onVerticalDragUpdate,
              onVerticalDragEnd: _zoomed ? null : _onVerticalDragEnd,
              onVerticalDragCancel: _zoomed ? null : _springBack,
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  scale: scale,
                  child: PageView.builder(
                    controller: _pageController,
                    physics: _zoomed ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
                    itemCount: widget.urls.length,
                    onPageChanged: (i) => setState(() {
                      _index = i;
                      _zoomed = false;
                    }),
                    itemBuilder: (_, i) => _ZoomableImagePage(
                      url: widget.urls[i],
                      onTap: () => setState(() => _chrome = !_chrome),
                      onZoomChanged: (z) {
                        if (i == _index && z != _zoomed) setState(() => _zoomed = z);
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !showBar,
                child: AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: AppMotion.dur(context, AppMotion.fast),
                  curve: AppMotion.curve,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xA6000000), Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 12, 16),
                        child: Row(
                          children: [
                            if (widget.urls.length > 1)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                                child: Text('${_index + 1} / ${widget.urls.length}', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                              ),
                            const Spacer(),
                            if (!isWebPreview)
                              IconButton.filledTonal(
                                tooltip: hz(context, '保存或分享图片'),
                                style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                                icon: const Icon(Icons.ios_share, size: 20),
                                onPressed: _shareCurrent,
                              ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: hz(context, '关闭'),
                              style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomableImagePage extends StatefulWidget {
  const _ZoomableImagePage({required this.url, required this.onTap, required this.onZoomChanged});

  final String url;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableImagePage> createState() => _ZoomableImagePageState();
}

class _ZoomableImagePageState extends State<_ZoomableImagePage> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnim = AnimationController(vsync: this, duration: AppMotion.standard);
  late final CurvedAnimation _zoomCurve = CurvedAnimation(parent: _zoomAnim, curve: AppMotion.curve);
  final _matrixTween = Matrix4Tween();
  Offset _doubleTapPos = Offset.zero;
  bool _zoomed = false;

  void _onZoomTick() {
    _transform.value = _matrixTween.evaluate(_zoomCurve);
  }

  @override
  void initState() {
    super.initState();
    _transform.addListener(_syncZoom);
    _zoomAnim.addListener(_onZoomTick);
  }

  @override
  void dispose() {
    _zoomAnim.removeListener(_onZoomTick);
    _zoomCurve.dispose();
    _transform.removeListener(_syncZoom);
    _transform.dispose();
    _zoomAnim.dispose();
    super.dispose();
  }

  void _syncZoom() {
    final z = _transform.value.getMaxScaleOnAxis() > 1.05;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged(z);
    }
  }

  void _handleDoubleTap() {
    final curScale = _transform.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (curScale > 1.05) {
      target = Matrix4.identity();
    } else {
      const s = 2.5;
      final dx = -_doubleTapPos.dx * (s - 1);
      final dy = -_doubleTapPos.dy * (s - 1);
      target = Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1);
    }
    if (AppMotion.reduce(context)) {
      _transform.value = target;
      return;
    }
    _matrixTween
      ..begin = _transform.value.clone()
      ..end = target;
    _zoomAnim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewerBox = Size(mq.size.width * 1.8, mq.size.height * 1.8);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transform,
        panEnabled: _zoomed,
        minScale: 1.0,
        maxScale: 5.0,
        child: Center(
          child: NetImage(
            widget.url,
            fit: BoxFit.contain,
            decodeSize: viewerBox,
            maxDecodeWidth: 2048,
          ),
        ),
      ),
    );
  }
}
