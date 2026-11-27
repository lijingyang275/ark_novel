part of '../reader_body.dart';

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
    this.paragraphSpacing = 0,
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
    this.userHighlights = const [],
    this.onHighlightTap,
    this.follow,
    this.nav,
    required this.hasSelection,
    this.tapZone = 0,
    this.tapInvert = 0,
    this.onPullDown,
    this.marked,
    this.onUserInteract,
    this.showHeader = false,
    this.imageColorFilter,
  });

  final int tapZone;
  final int tapInvert;

  /// 在章首继续往下拉：加 / 取消书签；[marked] 是当前位置有没有书签
  final VoidCallback? onPullDown;
  final bool Function()? marked;
  final VoidCallback? onUserInteract;
  final bool showHeader;
  final ColorFilter? imageColorFilter;
  final Chapter chapter;
  final SpanOf spanOf;
  final InlineSpan Function(int from, int to, (int, int)? hl)? spanOfHighlight;
  final ValueListenable<(int, int)?>? highlight;
  final TextStyle style;
  final double margin;
  final double paragraphSpacing;
  final List<HighlightEntry> userHighlights;
  final void Function(HighlightEntry)? onHighlightTap;

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
  final _mountedBlocks = <int, ({int start, int end, GlobalKey key})>{};
  List<(int, int)> _blocks = const [];
  String? _blocksText;
  double? _blocksSpacing;
  DateTime _lastAutoReport = DateTime.fromMillisecondsSinceEpoch(0);
  int _restoreToken = 0;

  void _syncBlocks() {
    final text = widget.chapter.text;
    if (identical(_blocksText, text) && _blocksSpacing == widget.paragraphSpacing) return;
    _blocksText = text;
    _blocksSpacing = widget.paragraphSpacing;
    if (text.trim().isEmpty) {
      _blocks = const [];
      return;
    }
    final paras = splitParagraphRanges(text, 0, text.length);
    if (widget.paragraphSpacing > 0) {
      _blocks = paras;
      return;
    }
    // 紧排模式按自然段边界每 ~600 字（最多 8 段）合并为一个惰性块，兼顾虚拟化与 RenderParagraph 数量
    final grouped = <(int, int)>[];
    var i = 0;
    while (i < paras.length) {
      final start = paras[i].$1;
      var end = paras[i].$2;
      var count = 1;
      i++;
      while (i < paras.length && count < 8 && (paras[i].$2 - start) <= 600) {
        end = paras[i].$2;
        count++;
        i++;
      }
      grouped.add((start, end));
    }
    _blocks = grouped;
  }

  void _onBlockMount(int index, int start, int end, GlobalKey key) {
    _mountedBlocks[index] = (start: start, end: end, key: key);
  }

  void _onBlockUnmount(int index, GlobalKey key) {
    final cur = _mountedBlocks[index];
    if (cur != null && identical(cur.key, key)) _mountedBlocks.remove(index);
  }

  double? _mountedContentYForOffset(int offset) {
    if (_blocks.isEmpty || !_controller.hasClients) return null;
    final scrollRo = context.findRenderObject();
    if (scrollRo is! RenderBox) return null;
    final target = offset.clamp(0, widget.chapter.text.length);
    final scrollTopGlobal = scrollRo.localToGlobal(Offset.zero).dy;
    final pixels = _controller.position.pixels;

    for (final entry in _mountedBlocks.values) {
      // 字符偏移正好落在块末换行符时也归属该块末尾
      if (target >= entry.start && target <= entry.end + 1) {
        final ro = entry.key.currentContext?.findRenderObject();
        if (ro is! RenderParagraph) continue;
        final localOff = (target - entry.start).clamp(0, entry.end - entry.start);
        final dy = ro.getOffsetForCaret(TextPosition(offset: localOff), Rect.zero).dy;
        return pixels + (ro.localToGlobal(Offset.zero).dy - scrollTopGlobal) + dy;
      }
    }
    return null;
  }

  void _jumpToOffset(int offset, {bool animate = false, int hopsLeft = 3, int? token}) {
    if (!mounted || !_controller.hasClients) return;
    final tok = token ?? ++_restoreToken;
    final pos = _controller.position;
    final max = pos.maxScrollExtent;
    final target = offset.clamp(0, widget.chapter.text.length);

    final exactY = _mountedContentYForOffset(target);
    if (exactY != null) {
      final to = (animate ? exactY - 80 : exactY).clamp(0.0, max);
      if (animate) {
        if (exactY < pos.pixels || exactY > pos.pixels + pos.viewportDimension - 120) {
          if (AppMotion.reduce(context)) {
            _controller.jumpTo(to);
          } else {
            _controller.animateTo(to, duration: AppMotion.standard, curve: AppMotion.decelerate);
          }
        }
      } else {
        _controller.jumpTo(to);
      }
      return;
    }

    if (hopsLeft <= 0 || max <= 0 || widget.chapter.text.isEmpty) return;
    final frac = (target / widget.chapter.text.length).clamp(0.0, 1.0);
    final double guess;
    if (hopsLeft == 3) {
      guess = (frac * max).clamp(0.0, max);
    } else {
      // 已挂载块在目标前/后时，按当前视口步长继续逼近目标块
      var minStart = widget.chapter.text.length;
      var maxEnd = 0;
      for (final e in _mountedBlocks.values) {
        if (e.start < minStart) minStart = e.start;
        if (e.end > maxEnd) maxEnd = e.end;
      }
      final step = math.max(pos.viewportDimension * 0.8, 240.0);
      guess = target < minStart ? (pos.pixels - step).clamp(0.0, max) : (pos.pixels + step).clamp(0.0, max);
    }
    _controller.jumpTo(guess);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && tok == _restoreToken) {
        _jumpToOffset(target, animate: animate, hopsLeft: hopsLeft - 1, token: tok);
      }
    });
  }

  void _followOffset(int f) {
    if (!mounted || !_controller.hasClients) return;
    final y = _mountedContentYForOffset(f);
    if (y != null) {
      final view = _controller.position;
      if (y < view.pixels || y > view.pixels + view.viewportDimension - 120) {
        final to = (y - 80).clamp(0.0, view.maxScrollExtent);
        if (AppMotion.reduce(context)) {
          _controller.jumpTo(to);
        } else {
          _controller.animateTo(to, duration: AppMotion.standard, curve: AppMotion.decelerate);
        }
      }
      return;
    }
    _jumpToOffset(f, animate: true);
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
    _restoreToken++;
    widget.highlight?.removeListener(_onHighlight);
    _mountedBlocks.clear();
    _controller.dispose();
    super.dispose();
  }

  void _nudge(double dy) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final to = (p.pixels + dy).clamp(0.0, p.maxScrollExtent);
    if (AppMotion.reduce(context)) {
      _controller.jumpTo(to);
    } else {
      _controller.animateTo(to, duration: AppMotion.fast, curve: AppMotion.decelerate);
    }
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
    if (off >= kToEnd) {
      final tok = ++_restoreToken;
      _controller.jumpTo(max);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients || tok != _restoreToken) return;
        final nextMax = _controller.position.maxScrollExtent;
        if ((nextMax - _controller.position.pixels).abs() > 1) {
          _controller.jumpTo(nextMax);
        }
        widget.onOffset(_charAtTop());
      });
      return;
    }
    if (off > 0 && widget.chapter.text.trim().isEmpty && widget.chapter.images.isNotEmpty && max > 0) {
      final idx = (off - 1).clamp(0, widget.chapter.images.length - 1);
      _controller.jumpTo((idx / widget.chapter.images.length * max).clamp(0.0, max));
    } else if (off > 0) {
      _jumpToOffset(off);
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
    if (_mountedBlocks.isEmpty) return 0;
    final scrollRo = context.findRenderObject();
    if (scrollRo is! RenderBox) return 0;
    final top = scrollRo.localToGlobal(Offset.zero).dy;
    final indices = _mountedBlocks.keys.toList()..sort();
    for (final idx in indices) {
      final entry = _mountedBlocks[idx]!;
      final ro = entry.key.currentContext?.findRenderObject();
      if (ro is! RenderParagraph) continue;
      final pTop = ro.localToGlobal(Offset.zero).dy;
      if (pTop + ro.size.height < top) continue;
      final y = top - pTop;
      return y <= 0 ? entry.start : entry.start + ro.getPositionForOffset(Offset(0, y)).offset;
    }
    return _mountedBlocks[indices.last]!.end;
  }

  int? _hitOffset(Offset global) {
    for (final entry in _mountedBlocks.values) {
      final hit = _hitOffsetInKey(entry.key, entry.start, global);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chapter;
    _syncBlocks();
    final hasText = c.text.trim().isNotEmpty;
    final mediaSize = MediaQuery.sizeOf(context);
    final width = mediaSize.width - widget.margin * 2;
    final imgDecodeSize = Size(math.max(1.0, width), math.max(1.0, mediaSize.height));
    final head = hasText ? PaginateCache.headingHeightCached(widget.title, widget.style, width) : 0.0;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final padTop = viewPadding.top + (widget.showHeader ? 36 : 24);
    final bottomPad = viewPadding.bottom + 48; // 底部留出页脚的高度，别挡字
    final strut = readerStrut(widget.style);
    final spacing = widget.paragraphSpacing;
    final textBottomPad = c.images.isEmpty && widget.onNext == null ? bottomPad : 0.0;

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
          final idx = _hitOffset(global);
          if (idx != null) {
            final m = _markAtOffset(c, idx);
            if (m != null) {
              widget.onMark(m);
              return false;
            }
            final h = _highlightAtOffset(widget.userHighlights, idx);
            if (h != null && widget.onHighlightTap != null) {
              widget.onHighlightTap!(h);
              return false;
            }
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
          top: viewPadding.top,
          child: widget.wrap(
            CustomScrollView(
              controller: _controller,
              slivers: [
                if (head > 0)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(widget.margin, padTop, widget.margin, hasText ? 0 : textBottomPad),
                    sliver: SliverToBoxAdapter(
                      child: chapterHeading(widget.title, widget.style, width, height: head, accent: widget.headingAccent),
                    ),
                  )
                else
                  SliverToBoxAdapter(child: SizedBox(height: padTop)),
                if (hasText && _blocks.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(widget.margin, 0, widget.margin, textBottomPad),
                    sliver: SliverList.builder(
                      itemCount: _blocks.length,
                      itemBuilder: (context, idx) {
                        final (start, end) = _blocks[idx];
                        final gap = spacing > 0 && idx + 1 < _blocks.length ? spacing : 0.0;
                        return _ScrollTextBlock(
                          index: idx,
                          start: start,
                          end: end,
                          bottomSpacing: gap,
                          strut: strut,
                          spanOf: widget.spanOf,
                          spanOfHighlight: widget.spanOfHighlight,
                          highlight: widget.highlight,
                          onMount: _onBlockMount,
                          onUnmount: _onBlockUnmount,
                        );
                      },
                    ),
                  ),
                if (c.images.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(widget.margin, 0, widget.margin, widget.onNext == null ? bottomPad : 0),
                    sliver: SliverList.builder(
                      itemCount: c.images.length,
                      itemBuilder: (context, idx) => Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _readerImageWidget(
                          c.images[idx],
                          widget.style.color,
                          gallery: c.images,
                          index: idx,
                          decodeSize: imgDecodeSize,
                          colorFilter: widget.imageColorFilter,
                        ),
                      ),
                    ),
                  ),
                if (widget.onNext != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(widget.margin, 32, widget.margin, bottomPad),
                    sliver: SliverToBoxAdapter(
                      child: OutlinedButton(onPressed: widget.onNext, child: Text(widget.nextLabel)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 滚屏正文单个惰性虚拟化块：仅在挂载时登记命中检测索引，并独立订阅区间内的朗读高亮更新（只重建受影响的 1~2 块）。
class _ScrollTextBlock extends StatefulWidget {
  const _ScrollTextBlock({
    required this.index,
    required this.start,
    required this.end,
    required this.bottomSpacing,
    required this.strut,
    required this.spanOf,
    required this.spanOfHighlight,
    required this.highlight,
    required this.onMount,
    required this.onUnmount,
  });

  final int index;
  final int start;
  final int end;
  final double bottomSpacing;
  final StrutStyle strut;
  final SpanOf spanOf;
  final InlineSpan Function(int from, int to, (int, int)? hl)? spanOfHighlight;
  final ValueListenable<(int, int)?>? highlight;
  final void Function(int index, int start, int end, GlobalKey key) onMount;
  final void Function(int index, GlobalKey key) onUnmount;

  @override
  State<_ScrollTextBlock> createState() => _ScrollTextBlockState();
}

class _ScrollTextBlockState extends State<_ScrollTextBlock> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.onMount(widget.index, widget.start, widget.end, _key);
  }

  @override
  void didUpdateWidget(_ScrollTextBlock old) {
    super.didUpdateWidget(old);
    if (widget.index != old.index) {
      old.onUnmount(old.index, _key);
      widget.onMount(widget.index, widget.start, widget.end, _key);
    } else if (widget.start != old.start || widget.end != old.end) {
      widget.onMount(widget.index, widget.start, widget.end, _key);
    }
  }

  @override
  void dispose() {
    widget.onUnmount(widget.index, _key);
    super.dispose();
  }

  Widget _buildRich((int, int)? hl) {
    final span = widget.spanOfHighlight != null ? widget.spanOfHighlight!(widget.start, widget.end, hl) : widget.spanOf(widget.start, widget.end);
    final rich = material.Text.rich(span, key: _key, textScaler: TextScaler.noScaling, strutStyle: widget.strut);
    if (widget.bottomSpacing <= 0) return rich;
    return Padding(padding: EdgeInsets.only(bottom: widget.bottomSpacing), child: rich);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.highlight != null && widget.spanOfHighlight != null) {
      return _ScopedHighlightBuilder(
        highlight: widget.highlight!,
        start: widget.start,
        end: widget.end,
        builder: (_, hl) => _buildRich(hl),
      );
    }
    return _buildRich(null);
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
  final _pull = ValueNotifier<double>(0); // 手指拉下的距离（原始值）
  int _springGen = 0;
  bool _marked = false; // 仅在下拉起手读取一次，禁止拖动每帧反序列化书签库
  late final _back = AnimationController.unbounded(vsync: this);
  late final _motion = Listenable.merge([_pull, _back]);

  @override
  void dispose() {
    _pull.dispose();
    _back.dispose();
    super.dispose();
  }

  /// 页面实际下移的距离：越往下越拉不动；松手后由临界阻尼弹簧无过冲回位
  double get _shown {
    if (_back.isAnimating) return math.max(0.0, _back.value);
    final pull = _pull.value;
    return pull <= 0 ? 0 : _max * (1 - math.exp(-pull / _max));
  }

  void _update(double v) {
    _springGen++;
    if (_back.isAnimating) _back.stop();
    final prev = _pull.value;
    final next = v.clamp(0.0, _max * 3);
    if (prev <= 0 && next > 0) {
      _marked = widget.marked?.call() ?? false;
    }
    final was = prev >= _threshold;
    _pull.value = next;
    if (!was && next >= _threshold) HapticFeedback.mediumImpact();
  }

  void _release() {
    final cur = _pull.value;
    if (cur <= 0) return;
    if (cur >= _threshold) widget.onPull?.call();
    final start = _shown;
    _pull.value = 0;
    final gen = ++_springGen;
    if (AppMotion.reduce(context) || start <= 0.5) {
      _back.value = 0;
      return;
    }
    _back.animateWith(SpringSimulation(AppMotion.smoothSpring, start, 0, 0, tolerance: AppMotion.pixelTolerance)).then((_) {
      if (mounted && gen == _springGen && _back.value != 0) _back.value = 0;
    });
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _update(_pull.value - n.overscroll);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // iOS 回弹式滚动：顶部越界是负的 pixels；正常往下滚就收回
      n.metrics.pixels < 0 ? _update(-n.metrics.pixels) : (_pull.value > 0 ? _update(_pull.value - (n.scrollDelta ?? 0)) : null);
    } else if (n is ScrollEndNotification) {
      _release();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPull == null) return widget.child;
    final accent = Theme.of(context).colorScheme.primary;
    final body = AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final shown = _shown;
        final pull = _pull.value;
        final ready = pull >= _threshold;
        final progress = (pull / _threshold).clamp(0.0, 1.0);
        return Stack(
          children: [
            Transform.translate(offset: Offset(0, shown), child: child),
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
                          child: AppIconSwap(
                            duration: AppMotion.instant,
                            child: Icon(
                              ready ? (_marked ? Icons.bookmark_remove : Icons.bookmark_added) : (_marked ? Icons.bookmark : Icons.bookmark_add_outlined),
                              key: ValueKey((ready, _marked)),
                              size: 26,
                              color: ready ? accent : widget.color.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedDefaultTextStyle(
                          duration: AppMotion.dur(context, AppMotion.instant),
                          curve: AppMotion.curve,
                          style: TextStyle(fontSize: 13, color: ready ? accent : widget.color.withValues(alpha: 0.55), fontWeight: ready ? FontWeight.w600 : FontWeight.w400),
                          child: Text(ready ? (_marked ? '松手取消书签' : '松手添加书签') : (_marked ? '下拉取消书签' : '下拉添加书签')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    return widget.drag
        ? GestureDetector(
            supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}, // 鼠标拖动留给选字，触控板双指留给翻页
            onVerticalDragUpdate: (d) => _update(_pull.value + d.delta.dy),
            onVerticalDragEnd: (_) => _release(),
            onVerticalDragCancel: _release,
            child: body,
          )
        : NotificationListener<ScrollNotification>(onNotification: _onScroll, child: body);
  }
}

