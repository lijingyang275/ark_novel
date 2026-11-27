part of '../reader_body.dart';

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
    this.paragraphSpacing = 0,
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
    this.userHighlights = const [],
    this.onHighlightTap,
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
    this.imageColorFilter,
    this.chromeConfig,
    this.onUserInteract,
  });

  final double paragraphSpacing;
  final List<HighlightEntry> userHighlights;
  final void Function(HighlightEntry)? onHighlightTap;

  final Widget? pageBackground;
  final Object? backgroundKey;

  /// 可选的局部插图/卷封面色彩滤镜（仅开暖色护眼时用于避免全屏 `ColorFiltered` `saveLayer`）。
  final ColorFilter? imageColorFilter;
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

  /// 内存压力告警时清空分页结果、配色与烘焙纸张纹理缓存，释放非活跃章节排版数据。
  static void clearPageCache() {
    PaginateCache.clear();
    _hlColorCache.clear();
    ReaderBackground.evictTextureCache();
  }

  @override
  State<PagedBody> createState() => _PagedBodyState();
}

class _PagedBodyState extends State<PagedBody> {
  final _curl = PageCurlController();
  final _keys = <int, GlobalKey>{};
  final _pageParaKeys = <int, List<(int, GlobalKey)>>{};
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
    } else if (AppMotion.reduce(context)) {
      _controller?.jumpToPage(p + _base);
    } else {
      _controller?.animateToPage(p + _base, duration: AppMotion.fast, curve: AppMotion.decelerate);
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
      final h = has ? PaginateCache.headingHeightCached(p.title, widget.style, size.width) : 0.0;
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
    final layoutStyle = PaginateCache.normalizeStyle(widget.style);
    return PaginateCache.paginateCached(
      text: c.text,
      style: layoutStyle,
      size: size,
      title: title,
      firstTop: head,
      paragraphSpacing: widget.paragraphSpacing,
      strut: readerStrut(layoutStyle),
    );
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

  /// 插图章：整章的图按顺序在后台低优预取；当前屏与下一屏的图及临近章末时下一章首图提前解码，翻过去直接出图。
  void _prefetch() {
    if (_imgBox.isEmpty) return;
    _precacheCovers();
    if (_page >= _units - 2) {
      final nextImgs = _next?.chapter.images;
      if (nextImgs != null && nextImgs.isNotEmpty) {
        NetImage.precache(context, nextImgs.first, _imgBox, fit: BoxFit.contain);
      }
    }
    if (_c.images.isEmpty) return;
    if (!identical(_fetched, _c)) {
      _fetched = _c;
      if (!isWebPreview) {
        try {
          ProviderScope.containerOf(context, listen: false).read(imageStoreProvider).prefetch(_c.images);
        } on Object {
          // 兼容未实现 prefetch 的轻量测试桩
        }
      }
    }
    final skip = _lead + _me.covers;
    for (var i = _page * _cols - skip; i < (_page + 2) * _cols - skip; i++) {
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

  Widget _readerImage(String url, {List<String>? gallery, int index = 0}) => _readerImageWidget(
    url,
    widget.style.color,
    gallery: gallery,
    index: index,
    decodeSize: _imgBox.isEmpty ? null : _imgBox,
    colorFilter: widget.imageColorFilter,
  );

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
    final strut = readerStrut(widget.style);
    Widget buildPageText(SpanOf spanBuilder) {
      if (widget.paragraphSpacing <= 0) {
        return material.Text.rich(spanBuilder(f.starts[i], end), key: live ? _keyFor(i) : null, textScaler: TextScaler.noScaling, strutStyle: strut);
      }
      final ranges = splitParagraphRanges(c.text, f.starts[i], end);
      List<(int, GlobalKey)>? tracked;
      if (live && identical(c, _c)) {
        final existing = _pageParaKeys[i];
        if (existing != null && existing.length == ranges.length && List.generate(ranges.length, (idx) => existing[idx].$1 == ranges[idx].$1).every((x) => x)) {
          tracked = existing;
        } else {
          tracked = _pageParaKeys[i] = [for (final r in ranges) (r.$1, GlobalKey())];
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var idx = 0; idx < ranges.length; idx++)
            Padding(
              padding: idx + 1 < ranges.length ? EdgeInsets.only(bottom: widget.paragraphSpacing) : EdgeInsets.zero,
              child: material.Text.rich(
                spanBuilder(ranges[idx].$1, ranges[idx].$2),
                key: tracked?[idx].$2,
                textScaler: TextScaler.noScaling,
                strutStyle: strut,
              ),
            ),
        ],
      );
    }
    return Stack(
      children: [
        // 页尾的换行会多出一个空行超出页面，所以不用 Column：标题单独放，正文往下让出标题的高度
        if (i == 0 && f.head > 0) Positioned(top: pad.top, left: pad.left, right: pad.right, child: chapterHeading(f.title, widget.style, _width, height: f.head, accent: widget.headingAccent)),
        Padding(
          padding: i == 0 ? pad.copyWith(top: pad.top + f.head) : pad,
          child: useLiveHighlight
              ? _ScopedHighlightBuilder(
                  highlight: widget.highlight!,
                  start: f.starts[i],
                  end: end,
                  builder: (_, hl) => buildPageText((a, b) => widget.spanOfHighlight!(a, b, hl)),
                )
              : buildPageText(f.spanOf),
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
      if (p < 0 || p >= _textPages) continue;
      final idx = widget.paragraphSpacing <= 0
          ? _hitOffsetInKey(_keyFor(p), _starts[p], global)
          : _hitOffsetInKeys(_pageParaKeys[p] ?? const [], global);
      if (idx == null) continue;
      final m = _markAtOffset(_c, idx);
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
    if (widget.animate && !AppMotion.reduce(context)) {
      _controller?.animateToPage(target + _base, duration: AppMotion.fast, curve: AppMotion.decelerate);
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
        // 同样的版面（大小、排版样式、段间距、正文）不重复分页；开关菜单栏、拖滑块、换主题/暖色这类不改字形宽高的重建不会触发全文排版
        final layoutStyle = PaginateCache.normalizeStyle(widget.style);
        final sig = Object.hash(size, cols, layoutStyle, widget.paragraphSpacing, _c.text.length, _c.text.hashCode, widget.title, widget.volumeCover != null);
        if (sig != _sig) {
          final keep = _anchor;
          _sig = sig;
          _cols = cols;
          _width = size.width;
          _head = _hasText ? PaginateCache.headingHeightCached(widget.title, widget.style, size.width) : 0;
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
          _pageParaKeys.clear();
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
            cacheKey: Object.hash(
              sig,
              widget.background,
              widget.backgroundKey,
              widget.imageColorFilter,
              widget.chromeConfig?.layoutSignature,
              widget.color,
              widget.showFooter,
              widget.headingAccent?.$1,
              _prev?.starts.length,
              _next?.starts.length,
              _c.marks.length,
              Object.hashAll(widget.userHighlights.map((h) => Object.hash(h.id, h.at, h.color))),
            ),
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
