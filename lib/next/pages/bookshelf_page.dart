import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show RenderProxyBox, ScrollCacheExtent;
import 'package:flutter/services.dart' show HapticFeedback, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../models/common/wenku8_node.dart';
import '../app_prefs.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../cover_color.dart';
import '../data.dart';
import '../env.dart';
import '../history.dart';
import '../image_cache.dart';
import '../library.dart';
import '../motion.dart';
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../session.dart';
import '../settings.dart';
import '../shelf_3d.dart';
import '../shelf_spine.dart';
import '../shelf_tabs.dart';
import '../theme.dart';
import '../theme_doodle.dart';
import '../theme_squire.dart';
import '../updates.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Volumes, volumeChangeForProvider;
import '../widgets.dart';
import '../x_list.dart';
import 'categories_page.dart';
import 'cover_picker_page.dart';
import 'volumes_page.dart';
import '../text.dart';

part 'bookshelf/shelf_options.dart';
part 'bookshelf/resume_bar.dart';
part 'bookshelf/shelf_grid.dart';

/// 书架：本地书库，分类是本地的（Mihon 那样），网站书架只在下拉刷新、打开 App 时同步一次。
/// 长按多选后可批量设置分类、移出书架。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

/// 手动下拉刷新期间由 [_ShelfState._refresh] 合并展示 [LibraryStore.syncNotice]，避免重复弹出两条提示。
bool _handlingRefreshNotice = false;

class _BookshelfPageState extends ConsumerState<BookshelfPage> with TickerProviderStateMixin {
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  void _setSearching(bool v) {
    _searching = v;
    // 晚一拍改通知器：同一次返回键里，外层 PopScope 不管先后都读到旧值
    Future.microtask(() => shelfSearching.value = _searching);
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    if (v.isEmpty) {
      ref.read(shelfQueryProvider.notifier).set('');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) ref.read(shelfQueryProvider.notifier).set(v);
    });
  }

  void _clearSearchQuery() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    ref.read(shelfQueryProvider.notifier).set('');
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    setState(() => _setSearching(false));
    ref.read(shelfQueryProvider.notifier).set('');
  }

  TabController? _tc;
  List<String> _ids = [];
  String _shown = ''; // 标签栏上次滚到的标签
  final _activeTab = ValueNotifier<String>(''); // 当前激活的标签 id，用来关掉后台保活标签页的重复 Hero
  final _keys = <String, GlobalKey>{};
  final _stripKey = GlobalKey();
  final _tabScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    LibraryStore.syncNotice.addListener(_onSyncNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSyncNotice());
  }

  void _onSyncNotice() {
    if (!mounted || _handlingRefreshNotice) return;
    final notice = LibraryStore.syncNotice.value;
    if (notice == null || notice.isEmpty) return;
    LibraryStore.syncNotice.value = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }

  @override
  void dispose() {
    LibraryStore.syncNotice.removeListener(_onSyncNotice);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    shelfSearching.value = false;
    _resumeHidden.dispose();
    _resumeHeight.dispose();
    _activeTab.dispose();
    _tc?.dispose();
    _tabScroll.dispose();
    super.dispose();
  }

  /// 标签变了（新增 / 删除 / 拖动）就换一个 TabController，停在原来的标签上。
  TabController _controller(List<String> ids) {
    if (!listEquals(ids, _ids) || _tc == null) {
      final first = _tc == null;
      final cur = first ? AppPrefs.read(P.lastTab, '') : _ids[_tc!.index.clamp(0, _ids.length - 1)];
      final old = _tc;
      _tc = TabController(length: ids.length, vsync: this, initialIndex: math.max(0, ids.indexOf(cur)));
      _ids = ids;
      _activeTab.value = _ids[_tc!.index];
      _tc!.addListener(_scrollToTab);
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      if (first) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _scrollToTab() : null); // 标签栏滚到上次的标签
    }
    return _tc!;
  }

  void _scrollToTab() {
    final tc = _tc!;
    final id = _ids[tc.index];
    _activeTab.value = id;
    if (tc.indexIsChanging) return;
    if (AppPrefs.read(P.lastTab, '') != id) AppPrefs.write(P.lastTab, id);
    if (id == _shown) return;
    _shown = id;
    // 换标签就放出「继续阅读」条：新标签可能短到滚不动，收起了就再也出不来
    _scrollAccum = 0;
    _resumeHidden.value = false;
    final ctx = _keys[id]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: AppMotion.dur(context, AppMotion.fast), curve: AppMotion.curve, alignment: 0.5);
  }

  /// 标签栏内容：抽成独立 ConsumerWidget，避免搜索词变更重建整页、RuinsScene 与 TabBarView。
  Widget _tabStripBody(
    List<LibCategory> tabs,
    TabController tc,
    LibraryState lib, {
    required bool counts,
    required bool perCat,
    double height = 42,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 8),
  }) => _ShelfTabStrip(
    tabs: tabs,
    tc: tc,
    lib: lib,
    counts: counts,
    perCat: perCat,
    height: height,
    padding: padding,
    stripKey: _stripKey,
    tabKeys: _keys,
    tabScroll: _tabScroll,
    onReordered: () => setState(() {}),
  );

  PreferredSizeWidget _tabStrip(List<LibCategory> tabs, TabController tc, LibraryState lib, {required bool counts, required bool perCat}) => PreferredSize(
    preferredSize: const Size.fromHeight(42),
    child: _tabStripBody(tabs, tc, lib, counts: counts, perCat: perCat, height: 42),
  );

  String get _curTab => _ids.isEmpty || _tc == null ? '' : _ids[_tc!.index.clamp(0, _ids.length - 1)];

  /// 筛选 / 排序 / 显示：底部弹出，不顶到状态栏，分三个标签页，内容多了在里面滑
  void _showOptions() {
    final tabId = _curTab;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _OptionsSheet(tabId: tabId),
    );
  }

  /// 在当前标签里随机打开一本
  void _openRandom() {
    final books = shelfBooksIn(ref.read(libraryProvider), _curTab).toList();
    if (books.isEmpty) return;
    final b = books[math.Random().nextInt(books.length)];
    final o = shelfOptionsFor(ref.read(shelfOptionsProvider), _curTab);
    context.push(o.display == 3 || o.display == 4 || o.display == 5 ? Routes.volumes(b.aid) : Routes.novel(b.aid));
  }

  /// 只检查当前标签里的书的更新
  void _checkTab() {
    final aids = shelfBooksIn(ref.read(libraryProvider), _curTab).map((b) => b.aid).toSet();
    if (aids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前分类没有可检查更新的书籍')));
      return;
    }
    ref.read(updateProvider.notifier).refresh(only: aids);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('正在检查 ${aids.length} 本的更新')));
  }

  String get _curTabName => allShelfTabs(ref.read(libraryProvider).cats).firstWhere((c) => c.id == _curTab, orElse: () => const LibCategory('', '默认')).name;

  /// 往下滑书架时收起「继续阅读」条，往上滑或回到顶上再出来；用累计滑动距离防抖，避免触控板微动或视口变高后回弹反复触发
  final _resumeHidden = ValueNotifier<bool>(false);
  final _resumeHeight = ValueNotifier<double>(0);
  double _scrollAccum = 0;

  void _setResumeHeight(double h) {
    if ((_resumeHeight.value - h).abs() <= 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resumeHeight.value = h;
    });
  }

  bool _onShelfScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n is! ScrollUpdateNotification) return false;
    // 顶部或底部弹性越界回弹期间忽略位移，避免 Mac 滑到底部反弹时把「继续阅读」误呼出来
    if (n.metrics.outOfRange) {
      _scrollAccum = 0;
      return false;
    }
    final dy = n.scrollDelta ?? 0;
    if (dy == 0) return false;
    // 贴近最底部时忽略向上回弹余波
    if (dy < 0 && n.metrics.maxScrollExtent > 0 && n.metrics.pixels >= n.metrics.maxScrollExtent - 32) {
      _scrollAccum = 0;
      return false;
    }
    if ((dy > 0 && _scrollAccum < 0) || (dy < 0 && _scrollAccum > 0)) _scrollAccum = 0;
    _scrollAccum += dy;
    if (!_resumeHidden.value) {
      // 可滚动余量太小时（比如宽屏一屏基本放得下），收起继续阅读条会让视口变高、滚动条直接消失，不收起
      if (dy > 0 && _scrollAccum > 36 && n.metrics.pixels > 36 && n.metrics.maxScrollExtent > 160) {
        _scrollAccum = 0;
        _resumeHidden.value = true;
      }
    } else {
      if (dy < 0 && (_scrollAccum < -28 || n.metrics.pixels <= 12)) {
        _scrollAccum = 0;
        _resumeHidden.value = false;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final hidden = ref.watch(appPrefList(P.hiddenTabs));
    final perCat = ref.watch(appPref(P.perCat, false));
    final tabCounts = ref.watch(appPref(P.tabCounts, true));
    final showResumeBar = ref.watch(appPref(P.resumeBar, false));
    final tabs = shelfTabs(lib.cats, hidden: hidden);
    final tc = _controller([for (final c in tabs) c.id]);
    if (perCat) ref.watch(appPrefProvider('shelf.tab.$_curTab'));
    final o = shelfOptionsFor(ref.watch(shelfOptionsProvider), _curTab);
    final resumeForDisplay = !_searching && showResumeBar && o.display != 4 && o.display != 5;
    final scene = appPalettes[ref.watch(paletteProvider)].scene;
    final sceneMotion = scene ? ref.watch(appPref(P.sceneMotion, true)) : false;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final singleRowHeader = wide && !scene;
    final searchField = ValueListenableBuilder<TextEditingValue>(
      valueListenable: _searchCtrl,
      builder: (context, val, _) => TextField(
        controller: _searchCtrl,
        autofocus: true,
        decoration: InputDecoration(
          hint: const Text('在书架中搜索', maxLines: 1, overflow: TextOverflow.ellipsis),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          suffixIcon: val.text.isEmpty
              ? null
              : IconButton(
                  tooltip: hz(context, '清空搜索'),
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: _clearSearchQuery,
                ),
        ),
        onChanged: _onSearchChanged,
      ),
    );
    // 插画主题：顶栏加高，标题和按钮压在插画的天空上，下面的分类标签仍在页面底色上
    // 宽屏普通主题：标签栏与右侧图标合并为单行极简顶栏，消除多余顶部空白
    final appBar = AppBar(
      toolbarHeight: singleRowHeader ? 52 : (scene ? kToolbarHeight : 48),
      titleSpacing: singleRowHeader ? 8 : null,
      foregroundColor: scene ? RuinsColors.of(context).ink : null,
      flexibleSpace: scene ? Column(children: [Expanded(child: RuinsScene(animate: sceneMotion, horizon: 0.86, ceiling: 0.5)), const SizedBox(height: 42)]) : null,
      title: AppCrossfade(
        alignment: Alignment.centerLeft,
        duration: AppMotion.fast,
        child: _searching
            ? KeyedSubtree(key: const ValueKey('shelf-search'), child: searchField)
            : (singleRowHeader
                  ? KeyedSubtree(
                      key: const ValueKey('shelf-tabs'),
                      child: _tabStripBody(tabs, tc, lib, counts: tabCounts, perCat: perCat, height: 52, padding: const EdgeInsets.symmetric(horizontal: 6)),
                    )
                  : KeyedSubtree(key: const ValueKey('shelf-title'), child: Text('书架 · ${lib.books.length}'))),
      ),
      actions: [
        IconButton(
          tooltip: hz(context, _searching ? '关闭搜索' : '搜索书架'),
          icon: AppIconSwap(
            rotate: true,
            child: Icon(_searching ? Icons.close : Icons.search, key: ValueKey(_searching), size: singleRowHeader ? 20 : 22),
          ),
          onPressed: () {
            if (_searching) {
              _closeSearch();
            } else {
              setState(() => _setSearching(true));
            }
          },
        ),
        IconButton(
          tooltip: hz(context, '筛选、排序、显示'),
          icon: AppIconSwap(
            child: Icon(Icons.filter_list, key: ValueKey(o.filtering), size: singleRowHeader ? 20 : 22, color: o.filtering ? Theme.of(context).colorScheme.primary : null),
          ),
          onPressed: _showOptions,
        ),
        PopupMenuButton<String>(
          tooltip: hz(context, '更多'),
          iconSize: singleRowHeader ? 20 : 22,
          onSelected: (v) async {
            if (v == 'random') {
              _openRandom();
            } else if (v == 'check') {
              _checkTab();
            } else if (v == 'sync_shelf') {
              final err = await ref.read(libraryProvider.notifier).sync(force: true);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(err == null ? '已和网站书架同步，书架共 ${ref.read(libraryProvider).books.length} 本' : '同步网站书架失败：$err')),
              );
              if (err == null && !isWebPreview) ref.read(volumeCoverQueueProvider).prefetchAll(ref.read(libraryProvider).books.keys).ignore();
              unawaited(ref.read(updateProvider.notifier).refresh());
            } else {
              unawaited(context.push(v));
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'random', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.casino_outlined), title: Text('随机打开一本'))),
            PopupMenuItem(value: 'check', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.refresh), title: Text('检查「$_curTabName」的更新'))),
            if (ref.read(sessionProvider) is SessionLoggedIn)
              const PopupMenuItem(value: 'sync_shelf', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.cloud_sync_outlined), title: Text('同步网站书架'))),
            const PopupMenuDivider(),
            const PopupMenuItem(value: Routes.categories, child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.label_outline), title: Text('分类管理'))),
          ],
        ),
        if (singleRowHeader) const SizedBox(width: 6),
      ],
      bottom: scene
          ? PreferredSize(preferredSize: const Size.fromHeight(42 + 64), child: Column(children: [const SizedBox(height: 64), _tabStrip(tabs, tc, lib, counts: tabCounts, perCat: perCat)]))
          : (singleRowHeader && !_searching ? null : _tabStrip(tabs, tc, lib, counts: tabCounts, perCat: perCat)),
    );
    return CallbackShortcuts(
      bindings: {
        if (_searching) const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
      },
      child: PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _closeSearch();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false, // 外层主界面已经让开了键盘，这里再让一次，书架只剩上面一小截
        appBar: appBar,
        body: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onShelfScroll,
                child: TabBarView(
                  key: ObjectKey(tc),
                  controller: tc,
                  children: [
                    for (final c in tabs)
                      _Shelf(
                        key: ValueKey(c.id),
                        catId: c.id,
                        activeTab: _activeTab,
                        topInset: _resumeHeight,
                        resumeEnabled: resumeForDisplay,
                      ),
                  ],
                ),
              ),
            ),
            if (resumeForDisplay)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _ResumeBar(hidden: _resumeHidden, onHeight: _setResumeHeight),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 纯过滤计数：替代 `_arrange(...).length`，搜索时无需构造副本或排序。
int _countMatching(Iterable<LibBook> list, ShelfOptions o, String query) {
  final q = query.toLowerCase();
  final markedAids = o.bookmarked == 0 ? const <String>{} : Bookmarks.bookmarkedAids();
  var count = 0;
  for (final b in list) {
    if (q.isNotEmpty && !b.shown.toLowerCase().contains(q) && !b.title.toLowerCase().contains(q)) continue;
    if (!_tri(o.unread, () => _unread(b.aid) > 0)) continue;
    if (!_tri(o.started, () => _started(b.aid))) continue;
    if (!_tri(o.cached, () => ChapterCache.count(b.aid) > 0)) continue;
    if (!_tri(o.bookmarked, () => markedAids.contains(b.aid))) continue;
    if (!_tri(o.completed, () => b.done)) continue;
    count++;
  }
  return count;
}

/// 书架分类标签条：独立订阅 `shelfQueryProvider` 与 `shelfOptionsProvider`，避免搜索敲字重建 `BookshelfPage`、`RuinsScene` 与 `TabBarView`。
/// 下划线拆成独立叠层 [_ShelfTabIndicator]，滑动切换标签时不每帧重建 `ReorderableListView.builder`。
class _ShelfTabStrip extends ConsumerWidget {
  const _ShelfTabStrip({
    required this.tabs,
    required this.tc,
    required this.lib,
    required this.counts,
    required this.perCat,
    required this.height,
    required this.padding,
    required this.stripKey,
    required this.tabKeys,
    required this.tabScroll,
    required this.onReordered,
  });

  final List<LibCategory> tabs;
  final TabController tc;
  final LibraryState lib;
  final bool counts;
  final bool perCat;
  final double height;
  final EdgeInsets padding;
  final GlobalKey stripKey;
  final Map<String, GlobalKey> tabKeys;
  final ScrollController tabScroll;
  final VoidCallback onReordered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(shelfQueryProvider);
    final opts = ref.watch(shelfOptionsProvider);
    if (perCat && query.isNotEmpty) {
      for (final c in tabs) {
        ref.watch(appPrefProvider('shelf.tab.${c.id}'));
      }
    }
    final showCounts = counts || query.isNotEmpty;
    final tabNums = {
      for (final c in tabs)
        c.id: query.isNotEmpty
            ? _countMatching(shelfBooksIn(lib, c.id), shelfOptionsFor(opts, c.id), query)
            : (counts ? shelfBooksIn(lib, c.id).length : null),
    };
    final scheme = Theme.of(context).colorScheme;
    final anim = tc.animation!;

    return SizedBox(
      height: height,
      child: Stack(
        key: stripKey,
        children: [
          ReorderableListView.builder(
            scrollController: tabScroll,
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            padding: padding,
            itemCount: tabs.length,
            proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
            onReorderItem: (from, to) {
              final ids = [for (final c in tabs) c.id];
              ids.insert(to, ids.removeAt(from));
              // 隐藏的标签留在原位，可见的按新顺序填回它们占的位置
              final all = [for (final c in allShelfTabs(lib.cats)) c.id];
              final idSet = ids.toSet();
              var k = 0;
              final ordered = [for (final id in all) idSet.contains(id) ? ids[k++] : id];
              Hive.box('session').put('shelfTabOrder', ordered);
              final catMap = {for (final c in lib.cats) c.id: c};
              ref.read(libraryProvider.notifier).reorderCategories([for (final id in ordered) if (catMap[id] != null) catMap[id]!]);
              onReordered();
            },
            itemBuilder: (context, i) {
              final c = tabs[i];
              final num = tabNums[c.id];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(c.id),
                index: i,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => tc.animateTo(i),
                  child: Container(
                    key: tabKeys.putIfAbsent(c.id, GlobalKey.new),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: AnimatedBuilder(
                      animation: anim,
                      builder: (context, _) {
                        final at = anim.value.clamp(0.0, tabs.length - 1.0);
                        final near = (1 - (at - i).abs()).clamp(0.0, 1.0); // 1 = 正在这个标签
                        final labelColor = Color.lerp(scheme.onSurfaceVariant.withValues(alpha: 0.76), scheme.onSurface, near);
                        final countColor = Color.lerp(scheme.onSurfaceVariant.withValues(alpha: 0.45), scheme.primary.withValues(alpha: 0.78), near);
                        return Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: c.name,
                                style: TextStyle(fontSize: 14.5, fontWeight: near > 0.5 ? FontWeight.w600 : FontWeight.w500, color: labelColor),
                              ),
                              if (showCounts && num != null)
                                TextSpan(
                                  text: ' $num',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    color: countColor,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: _ShelfTabIndicator(
                tabs: tabs,
                tc: tc,
                tabScroll: tabScroll,
                stripKey: stripKey,
                tabKeys: tabKeys,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 独立下划线指示器叠层：只监听标签动画与横向滚动，避免每帧重建整条标签列表。
class _ShelfTabIndicator extends StatefulWidget {
  const _ShelfTabIndicator({
    required this.tabs,
    required this.tc,
    required this.tabScroll,
    required this.stripKey,
    required this.tabKeys,
    required this.color,
  });

  final List<LibCategory> tabs;
  final TabController tc;
  final ScrollController tabScroll;
  final GlobalKey stripKey;
  final Map<String, GlobalKey> tabKeys;
  final Color color;

  @override
  State<_ShelfTabIndicator> createState() => _ShelfTabIndicatorState();
}

class _ShelfTabIndicatorState extends State<_ShelfTabIndicator> {
  int _measureRetries = 0;

  @override
  void didUpdateWidget(_ShelfTabIndicator old) {
    super.didUpdateWidget(old);
    if (old.tc != widget.tc || old.tabs.length != widget.tabs.length) {
      _measureRetries = 0;
    }
  }

  (double, double)? _labelRect(int i) {
    final strip = widget.stripKey.currentContext?.findRenderObject() as RenderBox?;
    final box = widget.tabKeys[widget.tabs[i].id]?.currentContext?.findRenderObject() as RenderBox?;
    if (strip == null || box == null || !box.attached || !box.hasSize) return null;
    final left = box.localToGlobal(Offset.zero, ancestor: strip).dx;
    return (left + 14, math.max(0.0, box.size.width - 28));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([widget.tc.animation!, widget.tabScroll]),
      builder: (context, _) {
        final at = widget.tc.animation!.value.clamp(0.0, widget.tabs.length - 1.0);
        final lo = at.floor(), hi = at.ceil();
        final ra = _labelRect(lo), rb = _labelRect(hi);
        final a = ra ?? rb, b = rb ?? ra;
        final t = at - lo;
        if (a == null && _measureRetries++ < 3) {
          WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
        }
        if (a == null || b == null) return const SizedBox.shrink();
        final left = a.$1 + (b.$1 - a.$1) * t;
        final width = a.$2 + (b.$2 - a.$2) * t;
        return Align(
          alignment: Alignment.bottomLeft,
          child: Transform.translate(
            offset: Offset(left, 0),
            child: SizedBox(
              width: width,
              height: 2,
              child: DecoratedBox(decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2))),
            ),
          ),
        );
      },
    );
  }
}

