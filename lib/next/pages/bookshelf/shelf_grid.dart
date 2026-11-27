part of '../bookshelf_page.dart';

class _Shelf extends ConsumerStatefulWidget {
  const _Shelf({super.key, required this.catId, required this.activeTab, required this.topInset, required this.resumeEnabled});

  /// 分类 id：空串是"默认"（全部的书），[_ongoingTab] / [_doneTab] 按是否完结分，其余是自己建的分类
  final String catId;
  final ValueListenable<String> activeTab;
  final ValueListenable<double> topInset;
  final bool resumeEnabled;

  @override
  ConsumerState<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends ConsumerState<_Shelf> {
  final _selected = <String>{};
  static final _selecting = <String>{}; // 哪几个标签页正在多选
  final _focus = FocusNode(debugLabel: 'shelf-select');
  bool _markingRead = false;

  // 缓存 _arrange() 结果，避免多选、徽章切换等无关重建重复全量筛选排序
  (Map<String, LibBook>, ShelfOptions, String, String, bool, int, int)? _arrangeKey;
  List<LibBook> _arrangedBooks = const [];
  int _arrangeEpoch = 0;
  bool _arrangeDirty = false;
  bool _lastHasSelected = false;
  List<LibBook>? _lastWarmedBooks;

  // 3D / 书脊模式焦点书号持久化防抖（400ms），避免快滑每划过一本就写 Hive
  Timer? _focusSaveTimer;
  String? _pendingFocusAid;

  // 滚动方向前方预解码状态（主封面缩略图提前解码进 Flutter ImageCache）
  int _layoutCols = 1;
  double _layoutRowExtent = 0;
  double _layoutTopPadding = 0;
  Size _layoutCoverSize = Size.zero;
  final _precachedUrls = <String>{};
  (bool, int, int)? _lastPrecacheSpan;
  DateTime _lastPrecacheAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    widget.activeTab.addListener(_onActiveTabChanged);
  }

  @override
  void didUpdateWidget(_Shelf old) {
    super.didUpdateWidget(old);
    if (old.activeTab != widget.activeTab) {
      old.activeTab.removeListener(_onActiveTabChanged);
      widget.activeTab.addListener(_onActiveTabChanged);
    }
    if (old.catId != widget.catId) {
      _flushFocusAid(old.catId);
    }
  }

  void _onActiveTabChanged() {
    if (widget.activeTab.value == widget.catId && _arrangeDirty && mounted) {
      setState(() => _arrangeDirty = false);
    }
  }

  void _saveFocusAid(String aid) {
    _pendingFocusAid = aid;
    _focusSaveTimer?.cancel();
    _focusSaveTimer = Timer(const Duration(milliseconds: 400), _flushFocusAid);
  }

  void _flushFocusAid([String? catId]) {
    _focusSaveTimer?.cancel();
    _focusSaveTimer = null;
    final aid = _pendingFocusAid;
    if (aid == null) return;
    _pendingFocusAid = null;
    if (Hive.isBoxOpen('session')) {
      Hive.box('session').put('shelf3d:${catId ?? widget.catId}', aid);
    }
  }

  List<LibBook> _getArranged(LibraryState lib, ShelfOptions o, String query, bool updateRunning, int seed) {
    final k = _arrangeKey;
    if (k != null &&
        identical(k.$1, lib.books) &&
        k.$2 == o &&
        k.$3 == query &&
        k.$4 == widget.catId &&
        k.$5 == updateRunning &&
        k.$6 == seed &&
        k.$7 == _arrangeEpoch) {
      return _arrangedBooks;
    }
    // 后台非活跃保活 Tab 已有缓存结果时延迟到切回可见再重排，避免切标签或搜索时多页同时全量排序
    if (k != null && widget.activeTab.value != widget.catId) {
      _arrangeDirty = true;
      return _arrangedBooks;
    }
    _arrangeDirty = false;
    final list = _arrange(shelfBooksIn(lib, widget.catId), o, query, widget.catId);
    _arrangeKey = (lib.books, o, query, widget.catId, updateRunning, seed, _arrangeEpoch);
    _arrangedBooks = list;
    return list;
  }

  void _syncLayoutMetrics({required int cols, required double rowExtent, required double topPadding, required Size coverSize}) {
    if ((_layoutCoverSize.width - coverSize.width).abs() > 4 || (_layoutCoverSize.height - coverSize.height).abs() > 4) {
      _precachedUrls.clear();
      _lastPrecacheSpan = null;
    }
    _layoutCols = cols;
    _layoutRowExtent = rowExtent;
    _layoutTopPadding = topPadding;
    _layoutCoverSize = coverSize;
  }

  /// 监听书架垂直滑动方向，在前进方向前方约 1 屏对主封面主动预解码（带节流与去重）。
  bool _onShelfScrollPrecache(ScrollNotification n) {
    if (isWebPreview || n.metrics.axis != Axis.vertical || n is! ScrollUpdateNotification || n.metrics.outOfRange) return false;
    final dy = n.scrollDelta ?? 0;
    if (dy == 0 || _layoutRowExtent <= 0 || _layoutCols <= 0 || _layoutCoverSize.isEmpty || _arrangedBooks.isEmpty) return false;
    final now = DateTime.now();
    if (now.difference(_lastPrecacheAt) < const Duration(milliseconds: 80)) return false;

    final viewport = n.metrics.viewportDimension;
    if (viewport <= 0) return false;
    final pixels = n.metrics.pixels;
    final forward = dy > 0;
    final aheadStartPx = forward ? pixels + viewport * 0.6 : math.max(0.0, pixels - viewport * 1.1);
    final aheadEndPx = forward ? pixels + viewport * 1.3 : math.max(0.0, pixels - viewport * 0.1);
    final totalRows = (_arrangedBooks.length + _layoutCols - 1) ~/ _layoutCols;
    if (totalRows <= 0) return false;
    final startRow = (((aheadStartPx - _layoutTopPadding) / _layoutRowExtent).floor()).clamp(0, totalRows - 1);
    final endRow = (((aheadEndPx - _layoutTopPadding) / _layoutRowExtent).ceil()).clamp(0, totalRows - 1);
    if (endRow < startRow) return false;

    final span = (forward, startRow, endRow);
    if (_lastPrecacheSpan == span) return false;
    _lastPrecacheSpan = span;
    _lastPrecacheAt = now;

    final startIdx = (startRow * _layoutCols).clamp(0, _arrangedBooks.length - 1);
    final endIdx = math.min(_arrangedBooks.length - 1, (endRow + 1) * _layoutCols - 1);
    if (_precachedUrls.length > 300) _precachedUrls.clear();

    var queued = 0;
    if (forward) {
      for (var i = startIdx; i <= endIdx && queued < 12; i++) {
        final url = _cover(_arrangedBooks[i]);
        if (url.isNotEmpty && _precachedUrls.add(url)) {
          queued++;
          NetImage.precache(context, url, _layoutCoverSize, thumbnail: true, lowPriority: true).ignore();
        }
      }
    } else {
      for (var i = endIdx; i >= startIdx && queued < 12; i--) {
        final url = _cover(_arrangedBooks[i]);
        if (url.isNotEmpty && _precachedUrls.add(url)) {
          queued++;
          NetImage.precache(context, url, _layoutCoverSize, thumbnail: true, lowPriority: true).ignore();
        }
      }
    }
    return false;
  }

  void _syncSelecting() {
    _selected.isEmpty ? _selecting.remove(widget.catId) : _selecting.add(widget.catId);
    shelfSelecting.value = _selecting.isNotEmpty;
  }

  @override
  void dispose() {
    widget.activeTab.removeListener(_onActiveTabChanged);
    _flushFocusAid();
    _focus.dispose();
    _selecting.remove(widget.catId);
    Future.microtask(() => shelfSelecting.value = _selecting.isNotEmpty);
    super.dispose();
  }

  /// 下拉：游客检查本地书架章节更新；已登录时先无感重连（若离线），再和网站书架同步并检查更新。
  Future<void> _refresh() async {
    CoverImage.clearFailed();
    final s = ref.read(sessionProvider);
    if (s is! SessionLoggedIn) {
      if (ref.read(libraryProvider).books.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('登录后可同步网站上的云端书架')));
        return;
      }
      await ref.read(updateProvider.notifier).refresh(force: true);
      if (!mounted) return;
      final err = ref.read(updateProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err ?? '已检查本地书架章节更新（登录账号可与网站书架同步）')),
      );
      return;
    }
    if (s.offline && !s.needsVerify) {
      final reason = await ref.read(sessionProvider.notifier).restore(silent: true);
      if (!mounted) return;
      if (reason != null) {
        final onNet = ref.read(nodeProvider) == Wenku8Node.wwwWenku8Net;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(onNet ? '$reason：wenku8.net 可能被本地 DNS 拦截，可切到 wenku8.cc' : '重新连接失败：$reason'),
            action: onNet ? SnackBarAction(label: '切到 wenku8.cc', onPressed: () => ref.read(nodeProvider.notifier).set(Wenku8Node.wwwWenku8Cc)) : null,
          ),
        );
        return;
      }
    }
    _handlingRefreshNotice = true;
    LibraryStore.syncNotice.value = null;
    final String? err;
    final String? notice;
    try {
      err = await ref.read(libraryProvider.notifier).sync(force: true);
      notice = LibraryStore.syncNotice.value;
      LibraryStore.syncNotice.value = null;
    } finally {
      _handlingRefreshNotice = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err != null
              ? '同步网站书架失败：$err'
              : (notice ?? '已和网站书架同步，书架共 ${ref.read(libraryProvider).books.length} 本'),
        ),
      ),
    );
    if (err == null && !isWebPreview) ref.read(volumeCoverQueueProvider).prefetchAll(ref.read(libraryProvider).books.keys).ignore();
    unawaited(ref.read(updateProvider.notifier).refresh());
  }

  Future<void> _setCats() async {
    final lib = ref.read(libraryProvider);
    if (lib.cats.isEmpty) {
      unawaited(context.push(Routes.categories));
      return;
    }
    // 只选了一本时预先勾上它现在的分类
    final initial = _selected.length == 1 ? lib.books[_selected.first]?.cats ?? const <String>[] : const <String>[];
    final cats = await pickCategories(context, lib.cats, initial);
    if (cats == null) return;
    await ref.read(libraryProvider.notifier).setCats(_selected, cats);
    if (mounted) setState(_selected.clear);
  }

  /// 书架上的封面是第一卷的卷封面，所以换的是第一卷的
  Future<void> _pickCover() async {
    final vols = Volumes.of(_selected.first);
    if (vols.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先打开一次这本书的详情，目录加载后才能选封面')));
      return;
    }
    await pickVolumeCover(context, _selected.first, vols.first);
    if (mounted) setState(_selected.clear);
  }

  /// 改书架上显示的名字（只在本机，网站上不变），留空恢复原名
  Future<void> _rename() async {
    final b = ref.read(libraryProvider).books[_selected.first];
    if (b == null) return;
    final controller = TextEditingController(text: b.shown);
    final alts = titleAlternatives(b.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('显示名称'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 两个译名点一个就用，书名长也能看全
              for (final a in alts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(a == b.shown ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text(a),
                  onTap: () => Navigator.pop(context, a),
                ),
              TextField(
                controller: controller,
                autofocus: alts.isEmpty,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.text, // 多行显示，但回车是确定不是换行
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(hint: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定'))],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose()); // 退出动画还在用它，晚一帧再释放
    if (name == null) return;
    await ref.read(libraryProvider.notifier).rename(b.aid, name);
    if (mounted) setState(_selected.clear);
  }

  /// 选中的书整本下载离线缓存：一本下完再下一本（同时下会被网站限流），在后台跑，进度在离线缓存页看
  void _download() {
    final aids = [..._selected];
    final container = ProviderScope.containerOf(context); // 书架页关了也接着下
    () async {
      for (final aid in aids) {
        try {
          final n = await container.read(apiProvider).novel(aid);
          final all = [for (final v in n.catalogue) ...v.chapters];
          if (all.isEmpty) continue;
          await container.read(downloadProvider.notifier).start(aid, n.detail.title, all, img: n.detail.imgUrl);
        } catch (_) {} // 这本取不到目录就跳过，下一本照常
      }
    }();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('开始下载 ${aids.length} 本，进度在「离线缓存」里看')));
    setState(_selected.clear);
  }

  /// 选中的书全部章节标为已读（要取一次目录）
  Future<void> _markRead() async {
    if (_markingRead) return;
    final aids = [..._selected];
    final api = ref.read(apiProvider);
    setState(() => _markingRead = true);
    var failed = 0;
    try {
      for (final aid in aids) {
        try {
          final n = await api.novel(aid);
          await ReadState.setRead(aid, [for (final v in n.catalogue) ...v.chapters.map((c) => c.cid)], true);
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (mounted) setState(() => _markingRead = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed == 0 ? '已标为已读' : '$failed 本没取到目录，其余已标为已读')));
    setState(() {
      _arrangeEpoch++;
      _selected.clear();
    });
  }

  Future<void> _remove() async {
    final aids = [..._selected];
    final n = aids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移出 $n 本书？'),
        content: const Text('登录时会一起从网站书架移出。阅读进度和缓存不会删。'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移出'))],
      ),
    );
    if (ok != true) return;
    await ref.read(libraryProvider.notifier).remove(aids);
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final perCat = ref.watch(appPref(P.perCat, false));
    if (perCat) ref.watch(appPrefProvider('shelf.tab.${widget.catId}'));
    final o = shelfOptionsFor(ref.watch(shelfOptionsProvider), widget.catId);
    final seed = o.sort == ShelfSort.random ? ref.watch(appPref('shelf.seed', 1)) : 0;
    final colsKey = MediaQuery.orientationOf(context) == Orientation.landscape ? P.colsLandscape : P.colsPortrait;
    final customCols = ref.watch(appPref(colsKey, 0));
    ref.watch(appPref(P.unreadBadge, true));
    ref.watch(appPref(P.cacheBadge, false));
    ref.watch(appPref(P.resumeButton, true));
    final query = ref.watch(shelfQueryProvider);
    final updateRunning = ref.watch(updateProvider.select((p) => p.running)); // 检查完更新后刷新未读数（不在中间进度跳动时反复重排全表）
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    final books = _getArranged(lib, o, query, updateRunning, seed);
    if (!identical(_lastWarmedBooks, books)) {
      _lastWarmedBooks = books;
      _precachedUrls.clear();
      _lastPrecacheSpan = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || isWebPreview) return;
        // 按当前实际排序顺序预热缩略图到独立 16 MB 内存缓存
        ref.read(imageStoreProvider).warm([for (final b in books) _cover(b)], thumbnail: true);
      });
    }
    final loggedIn = ref.watch(sessionProvider.select((s) => s is SessionLoggedIn));
    final cols = customCols == 0 ? null : customCols;

    Widget buildBody(double inset) {
      if (lib.books.isEmpty) {
        return Padding(
          padding: EdgeInsets.only(top: inset),
          child: StatePanel(
            title: '书架还是空的',
            detail: loggedIn ? '可以下拉同步网站书架，或去「发现」与「搜索」找书加入书架。' : '登录轻小说文库账号可同步云端书架；不登录也可在「发现」页把喜欢的书加入本地书架。',
            icon: Icons.auto_stories_outlined,
            actions: [
              if (!loggedIn)
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => context.push(Routes.login),
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('登录文库账号'),
                )
              else
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: _refresh,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('同步网站书架'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => context.go(Routes.discover),
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: const Text('去发现页逛逛'),
              ),
            ],
          ),
        );
      }
      if (books.isEmpty) {
        final inCatEmpty = shelfBooksIn(lib, widget.catId).isEmpty;
        return Padding(
          padding: EdgeInsets.only(top: inset),
          child: StatePanel(title: inCatEmpty ? '这个分类还没有书' : (query.isEmpty ? '没有符合条件的书' : '这个分类里没有「$query」'), detail: inCatEmpty && !widget.catId.startsWith('auto:') ? '在书架长按书本，选"分类"放进来。' : null),
        );
      }
      if (o.sort == ShelfSort.custom && query.isEmpty && !o.filtering) {
        _syncLayoutMetrics(cols: 1, rowExtent: 72, topPadding: inset, coverSize: const Size(40, 54));
        return _reorderable(books, autoSwitched: o.display != 2, topPadding: inset);
      }
      if (o.display == 2) {
        _syncLayoutMetrics(cols: 1, rowExtent: 72, topPadding: inset, coverSize: const Size(40, 54));
        return ListView.builder(
          key: PageStorageKey('shelf:${widget.catId}:${o.display}'),
          padding: EdgeInsets.fromLTRB(0, inset, 0, 24),
          itemCount: books.length,
          itemBuilder: (context, i) => _listTile(books[i]),
        );
      }
      if (o.display == 4 || o.display == 5) {
        final initialFocusAid = _pendingFocusAid ?? (Hive.box('session').get('shelf3d:${widget.catId}') as String?);
        // 正好一屏高；外面套一层能滚的，下拉同步照常可用；书脊/立体模式不显示继续阅读条，顶部不留冗余 inset
        return LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: c.maxHeight,
              child: ValueListenableBuilder<String>(
                  valueListenable: widget.activeTab,
                  builder: (context, tab, _) => o.display == 5
                      ? ShelfSpineView(
                          books: books,
                          initialAid: initialFocusAid,
                          onFocusChanged: _saveFocusAid,
                          selected: _selected,
                          heroEnabled: tab == widget.catId,
                          coverOf: _cover,
                          badgeOf: _badge,
                          subtitleOf: _shelf3dLine,
                          actionOf: _shelf3dAction,
                          unreadOf: (b) => _unread(b.aid),
                          volumeCountOf: (b) => Volumes.of(b.aid).length,
                          onOpen: (b) => _openAndRefresh(Routes.volumes(b.aid), b.aid),
                          onRead: (b, cid) => _openAndRefresh(Routes.reader(b.aid, cid), b.aid),
                          onToggleSelect: (b) => _toggle(b.aid),
                        )
                      : Shelf3DView(
                          books: books,
                          // 每个标签记住上次停在哪本，只存在本机（不进备份、不同步）
                          initialAid: initialFocusAid,
                          onFocusChanged: _saveFocusAid,
                          selected: _selected,
                          heroEnabled: tab == widget.catId,
                          coverOf: _cover,
                          badgeOf: _badge,
                          subtitleOf: _shelf3dLine,
                          actionOf: _shelf3dAction,
                          onOpen: (b) => _openAndRefresh(Routes.volumes(b.aid), b.aid),
                          onRead: (b, cid) => _openAndRefresh(Routes.reader(b.aid, cid), b.aid),
                          onToggleSelect: (b) => _toggle(b.aid),
                        ),
              ),
            ),
          ),
        );
      }
      if (o.display == 3) {
        return LayoutBuilder(
          builder: (context, c) {
            final n = cols ?? (c.maxWidth / 140).floor().clamp(2, 8);
            final cellW = (c.maxWidth - 32 - 14 * (n - 1)) / n;
            final coverW = math.max(1.0, cellW - _edges);
            final coverH = coverW / kCoverAspect;
            final coverSize = Size(coverW, coverH);
            final mainExtent = coverH + 6 + 44 * textScale;
            final topPad = 12 + inset;
            _syncLayoutMetrics(cols: n, rowExtent: mainExtent + 16, topPadding: topPad, coverSize: coverSize);
            return GridView.builder(
              key: PageStorageKey('shelf:${widget.catId}:${o.display}'),
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.4), // 上下适量多备，兼顾滑动顺滑与活跃纹理数
              padding: EdgeInsets.fromLTRB(16, topPad, 16, 24),
              // 一格 = 封面（右边留出后面几卷的边）+ 下面两行字（随系统字号伸缩防溢出）
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: n, mainAxisSpacing: 16, crossAxisSpacing: 14, mainAxisExtent: mainExtent),
              itemCount: books.length,
              itemBuilder: (context, i) => _stackTile(books[i], coverSize: coverSize),
            );
          },
        );
      }
      return LayoutBuilder(
        builder: (context, c) {
          final compact = o.display == 1;
          final n = cols ?? (compact ? (c.maxWidth / 104).floor().clamp(3, 10) : gridColumns(c.maxWidth));
          final topPad = 8 + inset;
          final Size coverSize;
          final double rowExtent;
          if (compact) {
            final itemW = math.max(1.0, (c.maxWidth - 32 - 8 * (n - 1)) / n);
            final itemH = itemW / 0.72;
            coverSize = Size(itemW, itemH);
            rowExtent = itemH + 8;
          } else {
            final itemW = math.max(1.0, (c.maxWidth - 32 - 14 * (n - 1)) / n);
            final coverH = itemW * 4 / 3;
            coverSize = Size(itemW, coverH);
            rowExtent = coverH + 8 + 42 * textScale.clamp(1.0, 1.6) + 20;
          }
          _syncLayoutMetrics(cols: n, rowExtent: rowExtent, topPadding: topPad, coverSize: coverSize);
          return GridView.builder(
            key: PageStorageKey('shelf:${widget.catId}:${o.display}'),
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.4),
            padding: EdgeInsets.fromLTRB(16, topPad, 16, 24),
            gridDelegate: compact
                ? SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: n, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.72)
                : novelGridDelegate(c.maxWidth, columns: n, textScale: textScale),
            itemCount: books.length,
            itemBuilder: (context, i) => _gridTile(books[i], compact: compact, coverSize: coverSize),
          );
        },
      );
    }

    final hasSelected = _selected.isNotEmpty;
    if (hasSelected != _lastHasSelected) {
      _lastHasSelected = hasSelected;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSelecting();
      });
    }
    return CallbackShortcuts(
      bindings: {
        if (_selected.isNotEmpty) const SingleActivator(LogicalKeyboardKey.escape): () => setState(_selected.clear),
      },
      child: Focus(
        focusNode: _focus,
        child: PopScope(
          canPop: _selected.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(_selected.clear); // 返回键先退出多选
          },
          child: Column(
            children: [
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: widget.topInset,
                  builder: (context, rawInset, _) {
                    final inset = widget.resumeEnabled ? rawInset : 0.0;
                    return NotificationListener<ScrollNotification>(
                      onNotification: _onShelfScrollPrecache,
                      child: RefreshIndicator(
                        edgeOffset: inset,
                        onRefresh: _refresh,
                        child: AppCrossfade(
                          fill: true,
                          duration: AppMotion.fast,
                          child: KeyedSubtree(
                            key: ValueKey(
                              lib.books.isEmpty
                                  ? 'empty-lib'
                                  : books.isEmpty
                                  ? 'empty-cat'
                                  : (o.sort == ShelfSort.custom && query.isEmpty && !o.filtering)
                                  ? 'custom'
                                  : 'display:${o.display}',
                            ),
                            child: buildBody(inset),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              AppCollapse(
                visible: _selected.isNotEmpty,
                axisAlignment: 1.0,
                duration: AppMotion.standard,
                reverseDuration: AppMotion.fast,
                child: Material(
                  elevation: 3,
                  color: theme.colorScheme.surfaceContainer,
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        IconButton(tooltip: hz(context, '取消多选'), icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
                        Expanded(
                          child: Row(
                            children: [
                              AppCollapse(
                                visible: _markingRead,
                                axis: Axis.horizontal,
                                duration: AppMotion.fast,
                                child: const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                ),
                              ),
                              Expanded(
                                child: AppCrossfade(
                                  alignment: Alignment.centerLeft,
                                  duration: AppMotion.fast,
                                  child: Text(
                                    _markingRead ? '正在标为已读…' : '${_selected.length} 本',
                                    key: ValueKey(_markingRead ? 'marking' : 'n:${_selected.length}'),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.fade,
                                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 和 Mihon 一样只放图标（长按看名字），文字按钮一行放不下
                        IconButton(tooltip: hz(context, '全选'), icon: const Icon(Icons.select_all), onPressed: () => setState(() => _selected.addAll(books.map((b) => b.aid)))),
                        AppCollapse(
                          visible: _selected.length == 1,
                          axis: Axis.horizontal,
                          duration: AppMotion.fast,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(tooltip: hz(context, '改名'), icon: const Icon(Icons.drive_file_rename_outline), onPressed: _rename),
                              IconButton(tooltip: hz(context, '封面'), icon: const Icon(Icons.image_outlined), onPressed: _pickCover),
                            ],
                          ),
                        ),
                        IconButton(tooltip: hz(context, '分类'), icon: const Icon(Icons.label_outline), onPressed: _setCats),
                        IconButton(tooltip: hz(context, '移出书架'), icon: const Icon(Icons.delete_outline), onPressed: _remove),
                        PopupMenuButton<VoidCallback>(
                          tooltip: hz(context, '更多'),
                          onSelected: (f) => f(),
                          itemBuilder: (_) => [
                            PopupMenuItem(value: _download, child: const ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.download_outlined), title: Text('下载'))),
                            PopupMenuItem(
                              enabled: !_markingRead,
                              value: _markRead,
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: _markingRead ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.done_all),
                                title: Text(_markingRead ? '正在标为已读…' : '标为已读'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _cover(LibBook b) => ref.read(volumeCoverQueueProvider).bookCover(b.aid, b.img);

  void _toggle(String aid) {
    // 第一本长按时重一点的震动，之后点选轻一点
    _selected.isEmpty ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick();
    setState(() => _selected.contains(aid) ? _selected.remove(aid) : _selected.add(aid));
    if (_selected.isNotEmpty) _focus.requestFocus(); // 保证桌面端按 Esc 可直接退出多选
  }

  (String?, int, Set<String>, int, int, int, int, int) _bookSnapshot(String aid) => (
    ReadingProgress.of(aid)?.cid,
    ReadingProgress.lastRead(aid),
    ReadState.readView(aid),
    ChapterCache.count(aid),
    Bookmarks.bookmarkedCids(aid).length,
    UpdateStore.known(aid),
    UpdateStore.updatedAt(aid),
    Volumes.changes.value,
  );

  void _openAndRefresh(String route, String aid) {
    final before = _bookSnapshot(aid);
    context.push(route).then((_) {
      if (!mounted) return;
      final after = _bookSnapshot(aid);
      final unchanged = after.$1 == before.$1 &&
          after.$2 == before.$2 &&
          identical(after.$3, before.$3) &&
          after.$4 == before.$4 &&
          after.$5 == before.$5 &&
          after.$6 == before.$6 &&
          after.$7 == before.$7 &&
          after.$8 == before.$8;
      if (unchanged) return;
      final o = shelfOptionsFor(ref.read(shelfOptionsProvider), widget.catId);
      final affectsOrder = o.unread != 0 ||
          o.started != 0 ||
          o.cached != 0 ||
          o.bookmarked != 0 ||
          o.sort == ShelfSort.lastRead ||
          o.sort == ShelfSort.updated ||
          o.sort == ShelfSort.unread ||
          o.sort == ShelfSort.total;
      setState(() {
        if (affectsOrder) _arrangeEpoch++;
      });
    });
  }

  void _tap(LibBook b) => _selected.isEmpty ? _openAndRefresh(Routes.novel(b.aid), b.aid) : _toggle(b.aid);

  /// 立体模式下面的按钮：读过的接着读，没读过的从第一卷开始读，没有分卷信息就打开卷册页。
  /// 这是这一屏的主按钮，不受设置里封面角「继续阅读」小按钮开关的影响
  ({String label, String? cid}) _shelf3dAction(LibBook b) {
    final p = ReadingProgress.of(b.aid);
    if (p != null) return (label: '继续读', cid: p.cid);
    final vols = Volumes.of(b.aid);
    return vols.isEmpty ? (label: '打开', cid: null) : (label: '开始读', cid: startCid(b.aid, vols.first));
  }

  /// 立体模式书名下面那一行：连载状态 · 读到第几卷 · 未读几章
  String _shelf3dLine(LibBook b) {
    final vols = Volumes.of(b.aid).length;
    final at = readingVolume(b.aid);
    final n = _unread(b.aid);
    return [
      b.done ? '已完结' : '连载中',
      if (vols > 0) at >= 0 ? '读到第 ${at + 1} / $vols 卷' : '共 $vols 卷',
      if (n > 0) '未读 $n 章' else if (ReadingProgress.of(b.aid) == null) '还没读',
    ].join(' · ');
  }

  /// 封面右下角的"继续阅读"：直接回到上次读的位置（读过才有）。
  Widget? _resume(LibBook b) {
    final p = ReadingProgress.of(b.aid);
    if (p == null || _selected.isNotEmpty || !AppPrefs.read(P.resumeButton, true)) return null;
    return IconButton.filledTonal(
      tooltip: hz(context, '继续阅读'),
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      icon: const Icon(Icons.play_arrow),
      onPressed: () => _openAndRefresh(Routes.reader(b.aid, p.cid), b.aid),
    );
  }

  Widget? _badge(LibBook b) {
    if (_selected.contains(b.aid)) return Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary);
    final n = AppPrefs.read(P.unreadBadge, true) ? _unread(b.aid) : 0;
    final c = AppPrefs.read(P.cacheBadge, false) ? ChapterCache.count(b.aid) : 0;
    if (n == 0 && c == 0) return null;
    // 插画主题用燕尾小旗代替圆角标，角色主题用蜡笔描边的小圆
    final scene = appPalettes[ref.read(paletteProvider)].scene;
    final doodle = CharacterArt.of(context) != null;
    final scheme = Theme.of(context).colorScheme;
    Widget badge(String t, Color bg, Color fg, {bool plain = false}) => scene
        ? PennantBadge(t, color: bg, textColor: fg)
        : doodle
        ? DoodleBadge(t, color: bg, textColor: fg)
        : Badge(label: Text(t), backgroundColor: plain ? null : bg, textColor: plain ? null : fg);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c > 0) badge('$c', scene ? scheme.secondary : scheme.tertiaryContainer, scene ? RuinsColors.day.ink : scheme.onTertiaryContainer),
        if (c > 0 && n > 0) const SizedBox(width: 3),
        if (n > 0) badge('$n', scheme.primary, scheme.onPrimary, plain: true),
      ],
    );
  }

  Widget _gridTile(LibBook b, {required bool compact, required Size coverSize}) {
    final resume = _resume(b);
    final badge = _badge(b);
    if (!compact) {
      return GestureDetector(
        onLongPress: () => _toggle(b.aid),
        onSecondaryTap: () => _toggle(b.aid),
        child: NovelCard(
          title: b.shown,
          aid: b.aid,
          cover: _ShelfBookCover(aid: b.aid, fallbackImg: b.img, decodeSize: coverSize),
          onTap: () => _tap(b),
          badge: badge,
          action: resume,
        ),
      );
    }
    // 紧凑：书名压在封面底部的渐变上
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    return AppPressScale(
      scale: 0.968,
      hoverScale: isDesktop ? 1.014 : 1.0,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onLongPress: () => _toggle(b.aid),
          onSecondaryTap: () => _toggle(b.aid),
          onTap: () => _tap(b),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ShelfBookCover(aid: b.aid, fallbackImg: b.img, decodeSize: coverSize),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: const LinearGradient(begin: Alignment.center, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
                ),
              ),
              Positioned(left: 6, right: resume == null ? 6 : 40, bottom: 6, child: Text(b.shown, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.25))),
              Positioned(
                top: 6,
                right: 6,
                child: AppIconSwap(
                  child: badge != null ? KeyedSubtree(key: ValueKey(_selected.contains(b.aid)), child: badge) : const SizedBox.shrink(key: ValueKey('empty')),
                ),
              ),
              if (resume != null) Positioned(right: 0, bottom: 0, child: resume),
            ],
          ),
        ),
      ),
    );
  }

  /// 卷册：第一卷封面在最前，右边露出后面几卷真封面的一窄条边（卷越多条数越多，单卷没有），书名和读到第几卷在封面下面。
  Widget _stackTile(LibBook b, {required Size coverSize}) {
    final badge = _badge(b);
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    return AppPressScale(
      scale: 0.968,
      hoverScale: isDesktop ? 1.014 : 1.0,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _selected.isEmpty ? _openAndRefresh(Routes.volumes(b.aid), b.aid) : _toggle(b.aid),
          onLongPress: () => _toggle(b.aid),
          onSecondaryTap: () => _toggle(b.aid),
          child: _ShelfStackTile(book: b, catId: widget.catId, activeTab: widget.activeTab, badge: badge, coverSize: coverSize),
        ),
      ),
    );
  }

  Widget _listTile(LibBook b) {
    final p = ReadingProgress.of(b.aid);
    final n = _unread(b.aid);
    final cached = ChapterCache.count(b.aid);
    final isSelected = _selected.contains(b.aid);
    final resume = _resume(b);
    return GestureDetector(
      onSecondaryTap: () => _toggle(b.aid),
      child: ListTile(
        selected: isSelected,
        leading: SizedBox(width: 40, height: 54, child: _ShelfBookCover(aid: b.aid, fallbackImg: b.img, decodeSize: const Size(40, 54))),
        title: Text(b.shown, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([if (n > 0) '未读 $n 章', if (cached > 0) '已缓存 $cached 章', if (b.done) '已完结', if (p == null) '还没读'].join(' · ')),
        trailing: AppIconSwap(
          child: isSelected
              ? Icon(Icons.check_circle, key: const ValueKey('sel'), color: Theme.of(context).colorScheme.primary)
              : (resume != null ? KeyedSubtree(key: const ValueKey('res'), child: resume) : const SizedBox.shrink(key: ValueKey('none'))),
        ),
        onTap: () => _tap(b),
        onLongPress: () => _toggle(b.aid),
      ),
    );
  }

  /// 自定义排序：列表形式，拖动右侧把手调整，每个分类单独记顺序。
  Widget _reorderable(List<LibBook> books, {required bool autoSwitched, required double topPadding}) => ReorderableListView.builder(
    key: PageStorageKey('shelf:${widget.catId}:custom'),
    padding: EdgeInsets.fromLTRB(0, topPadding, 0, 24),
    header: autoSwitched ? const XNote('自定义排序下自动切换为列表视图，按住右侧把手可拖动调整顺序。') : null,
    itemCount: books.length,
    onReorderItem: (from, to) {
      final list = [...books];
      list.insert(to, list.removeAt(from));
      Hive.box('session').put('shelfOrder:lib:${widget.catId}', [for (final b in list) b.aid]);
      setState(() => _arrangeEpoch++);
    },
    itemBuilder: (context, i) => ListTile(
      key: ValueKey(books[i].aid),
      leading: SizedBox(width: 40, height: 54, child: _ShelfBookCover(aid: books[i].aid, fallbackImg: books[i].img, decodeSize: const Size(40, 54))),
      title: Text(books[i].shown, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
      onTap: () => context.push(Routes.novel(books[i].aid)),
    ),
  );
}

/// 书架单本封面：按 `aid` 细粒度订阅卷封面变化，后台每抓完一本封面只刷新该书卡片。
class _ShelfBookCover extends ConsumerWidget {
  const _ShelfBookCover({required this.aid, required this.fallbackImg, this.decodeSize});

  final String aid;
  final String fallbackImg;
  final Size? decodeSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(volumeChangeForProvider(aid));
    final cover = ref.read(volumeCoverQueueProvider).bookCover(aid, fallbackImg);
    return CoverImage(cover, aid: aid, thumbnail: true, decodeSize: decodeSize);
  }
}

/// 书架卷册卡片内部：按 `aid` 细粒度订阅该书卷信息与封面变更，复用外层算好的 [coverSize] 省掉嵌套 LayoutBuilder。
class _ShelfStackTile extends ConsumerWidget {
  const _ShelfStackTile({required this.book, required this.catId, required this.activeTab, required this.badge, required this.coverSize});

  final LibBook book;
  final String catId;
  final ValueListenable<String> activeTab;
  final Widget? badge;
  final Size coverSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(volumeChangeForProvider(book.aid));
    final vols = Volumes.of(book.aid);
    final at = readingVolume(book.aid);
    final doneMap = Volumes.done(book.aid);
    final allDone = vols.isNotEmpty && vols.every((v) => doneMap.containsKey(v.title));
    final queue = ref.read(volumeCoverQueueProvider);
    final cover = queue.bookCover(book.aid, book.img);
    final behind = [for (final v in vols.skip(1).take(stackEdges(vols.length))) queue.volCover(book.aid, v, book.img)];
    final theme = Theme.of(context);
    final w = coverSize.width;
    final h = coverSize.height;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: Stack(
              clipBehavior: Clip.none, // 后面几卷的边在封面右边、Stack 外面
              children: [
                // 整叠放进 Hero：点开时一起飞过去放大（只有当前标签页开启 Hero，避免保活的相邻标签撞 tag）
                SizedBox(
                  width: w,
                  height: h,
                  child: ValueListenableBuilder<String>(
                    valueListenable: activeTab,
                    builder: (context, tab, child) => HeroMode(enabled: tab == catId, child: child!),
                    child: Hero(tag: 'vols:${book.aid}', flightShuttleBuilder: volumeHeroShuttle, child: VolumeStack(cover: cover, behind: behind, aid: book.aid, decodeSize: coverSize)),
                  ),
                ),
                if (badge != null) Positioned(top: 6, right: 6, child: badge!),
                if (vols.length == 1)
                  Positioned(
                    left: 6,
                    top: h - 6 - 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                      child: const Text('单卷', style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(book.shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(
          vols.isEmpty ? '还没有分卷信息' : [if (allDone) '已读完' else if (at >= 0) '读到第 ${at + 1} 卷', '共 ${vols.length} 卷'].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 测量子节点高度并在高度变化时通知父级（用于「继续阅读条」静态留白，不随滑出动画触发）。
class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureHeight renderObject) => renderObject.onHeight = onHeight;
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (_lastHeight != h) {
      _lastHeight = h;
      onHeight(h);
    }
  }
}
