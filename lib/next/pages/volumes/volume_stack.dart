part of '../volumes_page.dart';

/// 书架上一叠书露出后面几卷的边：卷数越多露得越多（0~3 条）
int stackEdges(int count) => count <= 1 ? 0 : (count <= 4 ? 1 : (count <= 9 ? 2 : 3));

/// 叠在第一卷后面的第 k 卷（k ≥ 1，0 是第一卷自己）：以封面中心缩小一点、往右错开露出一条边、越往后越暗。
/// 书架上的一叠和轮播打开时往右抽出的起点都用它，飞到位时两边对得上。
({double dx, double scale, double dim}) stackPose(int k, double width) {
  final s = 1 - 0.04 * k;
  return (dx: width * ((1 - s) / 2 + 0.026 * k), scale: s, dim: k <= 1 ? 0.0 : 0.12 * (k - 1));
}

/// 书架卷册模式的一叠书：第一卷的封面压着后面几卷（右边露出一条条真封面的边）。按自身比例错开，飞的时候整叠一起放大。
/// 主封面高优走缩略图，后置露边低优 + 限制 120px 解码，且高速甩动期间延迟加载只画纯色占位。
class VolumeStack extends StatelessWidget {
  const VolumeStack({super.key, required this.cover, this.behind = const [], this.aid, this.decodeSize});

  final String cover;

  /// 后面几卷的封面，近的在前
  final List<String> behind;
  final String? aid;

  /// 外层已算好的逻辑封面尺寸：直传给 [CoverImage] 省掉嵌套 [LayoutBuilder]
  final Size? decodeSize;

  @override
  Widget build(BuildContext context) {
    Widget frontSheet() => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 4, offset: const Offset(1.5, 0))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CoverImage(cover, aid: aid, thumbnail: true, decodeSize: decodeSize),
      ),
    );
    // 后置露边只露 ~5px 窄边：去掉重阴影改用轻量描边保留层次感，高速甩动期间先纯色占位、停稳再低优加载
    Widget behindSheet(String url, double dim) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black.withValues(alpha: 0.22), width: 0.7),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _DeferredBehindCover(url: url, decodeSize: decodeSize),
            if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
          ],
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none, // 后面几卷的边在封面右边、自己的范围外面
      children: [
        for (var k = behind.length; k >= 1; k--)
          () {
            // stackPose(k, 1.0).dx 恰好是相对宽度的平移比例，用 FractionalTranslation 省掉 LayoutBuilder 且 Hero 飞行时自动缩放
            final p = stackPose(k, 1.0);
            return FractionalTranslation(
              translation: Offset(p.dx, 0),
              child: Transform.scale(scale: p.scale, child: behindSheet(behind[k - 1], p.dim)),
            );
          }(),
        frontSheet(),
      ],
    );
  }
}

/// 卷册后置露边封面：高速甩动时跳过解码与网络请求，先以封面主色纯色占位，减速或停稳后再低优加载 120px 缩略图。
class _DeferredBehindCover extends ConsumerStatefulWidget {
  const _DeferredBehindCover({required this.url, this.decodeSize});

  final String url;
  final Size? decodeSize;

  @override
  ConsumerState<_DeferredBehindCover> createState() => _DeferredBehindCoverState();
}

class _DeferredBehindCoverState extends ConsumerState<_DeferredBehindCover> {
  bool _activated = false;
  ValueNotifier<bool>? _scrolling;

  void _onScrollingChanged() {
    if (!mounted || _activated) return;
    if (_scrolling?.value == false || !Scrollable.recommendDeferredLoadingForContext(context)) {
      _detach();
      setState(() => _activated = true);
    }
  }

  void _attach(ScrollableState? scrollable) {
    final notifier = scrollable?.position.isScrollingNotifier;
    if (identical(_scrolling, notifier)) return;
    _detach();
    _scrolling = notifier;
    _scrolling?.addListener(_onScrollingChanged);
  }

  void _detach() {
    _scrolling?.removeListener(_onScrollingChanged);
    _scrolling = null;
  }

  @override
  void didUpdateWidget(_DeferredBehindCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url && Scrollable.recommendDeferredLoadingForContext(context)) {
      _activated = false;
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  Color? _placeholderColor() {
    if (!Hive.isBoxOpen('session')) return null;
    return savedCoverColor(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.read(imageStoreProvider);
    bool memHit = false;
    if (widget.url.isNotEmpty) {
      try {
        memHit = store.peekThumb(widget.url) != null;
      } on Object {
        memHit = store.peek(widget.url) != null;
      }
    }
    if (_activated || memHit || !Scrollable.recommendDeferredLoadingForContext(context)) {
      _activated = true;
      _detach();
      return CoverImage(widget.url, thumbnail: true, lowPriority: true, maxDecodeWidth: 120, decodeSize: widget.decodeSize);
    }
    _attach(Scrollable.maybeOf(context));
    return ColoredBox(color: _placeholderColor() ?? Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}

/// 书架封面和轮播最前面那卷之间飞的时候：书架那叠垫底（整叠一起放大），轮播那张跟着动画淡入（返回时淡出），
/// 停在的卷不是第一卷时封面在飞行中自然换过去。
Widget volumeHeroShuttle(BuildContext context, Animation<double> animation, HeroFlightDirection direction, BuildContext from, BuildContext to) {
  final (shelf, carousel) = direction == HeroFlightDirection.push ? (from, to) : (to, from);
  // 飞行时在 Overlay 里，没有 Material 的话「在读」标签会带上默认的黄色双下划线
  return Material(
    type: MaterialType.transparency,
    child: Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none, // 书架那叠后面几卷的边在范围外面
      children: [
        (shelf.widget as Hero).child,
        FadeTransition(opacity: animation, child: (carousel.widget as Hero).child),
      ],
    ),
  );
}

/// 打开这一卷从哪章读：进度在这卷就接着读，不然从第一章没读过的正文开始，全读过就从头。
String startCid(String aid, Vol v) {
  final p = ReadingProgress.of(aid);
  if (p != null && v.cids.contains(p.cid)) return p.cid;
  final read = ReadState.readView(aid);
  return v.textCids.where((c) => !read.contains(c)).firstOrNull ?? v.cids.first;
}

/// 正在读第几卷：阅读进度所在的那卷；那卷已经读完（比如手动标了读完）就往后找第一卷没读完的。
/// 没读过、或者从那卷往后全读完了为 -1。
int readingVolume(String aid) {
  final p = ReadingProgress.of(aid);
  final i = p == null ? -1 : Volumes.indexOf(aid, p.cid);
  if (i < 0) return -1;
  final vols = Volumes.of(aid);
  final done = Volumes.done(aid);
  for (var j = i; j < vols.length; j++) {
    if (!done.containsKey(vols[j].title)) return j;
  }
  return -1;
}
