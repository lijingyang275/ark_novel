import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
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
import '../local_books.dart';
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../session.dart';
import '../settings.dart';
import '../shelf_3d.dart';
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

enum ShelfSort {
  added('加入时间'),
  name('名称'),
  lastRead('最近阅读'),
  updated('最近更新'),
  unread('未读章数'),
  total('总章数'),
  random('随机'),
  custom('自定义');

  const ShelfSort(this.label);

  final String label;
}

/// 书架的排序、筛选、显示方式，记在本地。筛选是三态：0 不限 1 必须满足 2 必须不满足（Mihon 那样）。
class ShelfOptions {
  const ShelfOptions({this.sort = ShelfSort.added, this.reverse = false, this.display = 3, this.unread = 0, this.started = 0, this.cached = 0, this.bookmarked = 0, this.completed = 0});

  final ShelfSort sort;

  /// 排序方向反过来（每种排序都有自己默认的方向）
  final bool reverse;

  /// 0 网格 1 紧凑网格 2 列表 3 卷册（一本书画成一摞卷） 4 立体
  final int display;

  /// 筛选：有未读 / 已开始读 / 有缓存 / 有书签 / 已完结
  final int unread;
  final int started;
  final int cached;
  final int bookmarked;
  final int completed;

  bool get filtering => unread + started + cached + bookmarked + completed > 0;

  ShelfOptions copyWith({ShelfSort? sort, bool? reverse, int? display, int? unread, int? started, int? cached, int? bookmarked, int? completed}) => ShelfOptions(
    sort: sort ?? this.sort,
    reverse: reverse ?? this.reverse,
    display: display ?? this.display,
    unread: unread ?? this.unread,
    started: started ?? this.started,
    cached: cached ?? this.cached,
    bookmarked: bookmarked ?? this.bookmarked,
    completed: completed ?? this.completed,
  );

  Map<String, Object> toMap() => {'sort': sort.index, 'reverse': reverse, 'display': display, 'unread': unread, 'started': started, 'cached': cached, 'bookmarked': bookmarked, 'completed': completed};

  static ShelfOptions fromMap(Map m) => ShelfOptions(
    sort: ShelfSort.values[((m['sort'] as int?) ?? 0).clamp(0, ShelfSort.values.length - 1)],
    reverse: (m['reverse'] as bool?) ?? false,
    display: (m['display'] as int?) ?? 3,
    unread: (m['unread'] as int?) ?? 0,
    started: (m['started'] as int?) ?? 0,
    cached: (m['cached'] as int?) ?? 0,
    bookmarked: (m['bookmarked'] as int?) ?? 0,
    completed: (m['completed'] as int?) ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is ShelfOptions &&
      other.sort == sort &&
      other.reverse == reverse &&
      other.display == display &&
      other.unread == unread &&
      other.started == started &&
      other.cached == cached &&
      other.bookmarked == bookmarked &&
      other.completed == completed;

  @override
  int get hashCode => Object.hash(sort, reverse, display, unread, started, cached, bookmarked, completed);
}

class _OptionsController extends Notifier<ShelfOptions> {
  Box get _box => Hive.box('session');

  @override
  ShelfOptions build() {
    final saved = _box.get('shelfOpts');
    if (saved is Map) return ShelfOptions.fromMap(saved);
    // 旧版本分开存的：排序、显示方式、三个开关筛选
    final f = ((_box.get('shelfFilter') as List?) ?? const []).cast<String>();
    final sort = (_box.get('shelfSort') as int?) ?? 0;
    return ShelfOptions(
      sort: ShelfSort.values[sort.clamp(0, ShelfSort.values.length - 1)],
      display: (_box.get('shelfDisplay') as int?) ?? 3,
      unread: f.contains('unread') ? 1 : 0,
      cached: f.contains('cached') ? 1 : 0,
      completed: f.contains('done') ? 1 : 0,
    );
  }

  void set(ShelfOptions v) {
    _box.putAll({'shelfOpts': v.toMap(), 'sync:prefsTs': DateTime.now().millisecondsSinceEpoch});
    state = v;
  }
}

/// 这个标签页用的筛选 / 排序 / 显示：开了"每个标签单独设置"就用它自己存的，没存过用全局的。
ShelfOptions shelfOptionsFor(ShelfOptions base, String tabId) {
  if (!AppPrefs.read(P.perCat, false)) return base;
  final m = AppPrefs.read<Object?>('shelf.tab.$tabId', null);
  return m is Map ? ShelfOptions.fromMap(m) : base;
}

/// 卷册模式封面右边留给后面几卷封面边的宽度（最多 3 张，每张错开 5）
const _edges = 15.0;

final shelfOptionsProvider = NotifierProvider<_OptionsController, ShelfOptions>(_OptionsController.new);

class _QueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String v) => state = v;
}

final shelfQueryProvider = NotifierProvider<_QueryController, String>(_QueryController.new);

/// 三态筛选：0 不限，1 必须满足，2 必须不满足
bool _tri(int state, bool Function() test) => state == 0 || test() == (state == 1);

bool _started(String aid) => ReadingProgress.of(aid) != null || ReadState.readCount(aid) > 0;

/// 未读章数：上次检查更新时记下的总章数减去读过的章数；若某卷正文已全读完而仅跳过了插图章，不把插图章算进残留未读。
int _unread(String aid) {
  final total = UpdateStore.known(aid);
  if (total == 0) return 0;
  final read = ReadState.readView(aid);
  final vols = Volumes.of(aid);
  final skippedIllus = vols.isEmpty
      ? 0
      : vols.where((v) => v.illus != null && v.textCids.isNotEmpty && v.textCids.every(read.contains) && !read.contains(v.illus)).length;
  return (total - read.length - skippedIllus).clamp(0, total);
}

List<LibBook> _arrange(Iterable<LibBook> list, ShelfOptions o, String query, String catId) {
  final q = query.toLowerCase();
  final markedAids = o.bookmarked == 0 ? const <String>{} : Bookmarks.bookmarkedAids();
  final out = list
      .where((b) => q.isEmpty || b.shown.toLowerCase().contains(q) || b.title.toLowerCase().contains(q))
      .where((b) => _tri(o.unread, () => _unread(b.aid) > 0) && _tri(o.started, () => _started(b.aid)) && _tri(o.cached, () => isLocalAid(b.aid) || ChapterCache.count(b.aid) > 0) && _tri(o.bookmarked, () => markedAids.contains(b.aid)) && _tri(o.completed, () => b.done))
      .toList();
  switch (o.sort) {
    case ShelfSort.added:
      out.sort((a, b) => b.added.compareTo(a.added));
    case ShelfSort.name:
      out.sort((a, b) => a.shown.compareTo(b.shown));
    case ShelfSort.lastRead:
      final last = {for (final b in out) b.aid: ReadingProgress.lastRead(b.aid)};
      out.sort((a, b) => last[b.aid]!.compareTo(last[a.aid]!));
    case ShelfSort.updated:
      final upd = {for (final b in out) b.aid: UpdateStore.updatedAt(b.aid)};
      out.sort((a, b) => upd[b.aid]!.compareTo(upd[a.aid]!));
    case ShelfSort.unread:
      final unr = {for (final b in out) b.aid: _unread(b.aid)};
      out.sort((a, b) => unr[b.aid]!.compareTo(unr[a.aid]!));
    case ShelfSort.total:
      final tot = {for (final b in out) b.aid: UpdateStore.known(b.aid)};
      out.sort((a, b) => tot[b.aid]!.compareTo(tot[a.aid]!));
    case ShelfSort.random:
      final seed = AppPrefs.read('shelf.seed', 1);
      out.sort((a, b) => Object.hash(a.aid, seed).compareTo(Object.hash(b.aid, seed)));
    case ShelfSort.custom:
      final order = ((Hive.box('session').get('shelfOrder:lib:$catId') as List?) ?? const []).cast<String>();
      final ranks = {for (final (i, id) in order.indexed) id: i};
      out.sort((a, b) => (ranks[a.aid] ?? order.length).compareTo(ranks[b.aid] ?? order.length));
  }
  return o.reverse ? out.reversed.toList() : out;
}

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

  void _setSearching(bool v) {
    _searching = v;
    // 晚一拍改通知器：同一次返回键里，外层 PopScope 不管先后都读到旧值
    Future.microtask(() => shelfSearching.value = _searching);
  }

  TabController? _tc;
  List<String> _ids = [];
  String _shown = ''; // 标签栏上次滚到的标签
  final _activeTab = ValueNotifier<String>(''); // 当前激活的标签 id，用来关掉后台保活标签页的重复 Hero
  final _keys = <String, GlobalKey>{};
  final _stripKey = GlobalKey();
  int _measureRetries = 0;
  final _tabScroll = ScrollController();

  Box get _box => Hive.box('session');

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
    shelfSearching.value = false;
    _resumeHidden.dispose();
    _resumeHeight.dispose();
    _activeTab.dispose();
    _tc?.dispose();
    _tabScroll.dispose();
    super.dispose();
  }

  /// 第 i 个标签里文字那一段在标签栏里的位置（左边、宽度）；还没排好版时返回 null
  (double, double)? _labelRect(List<LibCategory> tabs, int i) {
    final strip = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    final box = _keys[tabs[i].id]?.currentContext?.findRenderObject() as RenderBox?;
    if (strip == null || box == null || !box.attached || !box.hasSize) return null;
    final left = box.localToGlobal(Offset.zero, ancestor: strip).dx;
    return (left + 14, box.size.width - 28); // 去掉左右内边距，下划线和字一样宽
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
      _measureRetries = 0; // 标签变了（比如新建了分类）要重新量下划线的位置
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
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), alignment: 0.5);
  }

  /// 标签栏：点一下切换，长按拖动调整顺序
  PreferredSizeWidget _tabStrip(List<LibCategory> tabs, TabController tc, LibraryState lib, {required bool counts, required bool perCat}) {
    final query = ref.watch(shelfQueryProvider);
    final opts = ref.watch(shelfOptionsProvider);
    if (perCat && query.isNotEmpty) {
      for (final c in tabs) {
        ref.watch(appPrefProvider('shelf.tab.${c.id}'));
      }
    }
    // 搜索时每个标签显示找到几本（和标签里列出来的一样，也算上筛选）
    // 在动画外面算好：下面的 AnimatedBuilder 滑动时每帧都重建，每帧对每个标签筛选、排序一遍会掉帧
    final labels = {
      for (final c in tabs)
        c.id: query.isNotEmpty
            ? '${c.name} ${_arrange(shelfBooksIn(lib, c.id), shelfOptionsFor(opts, c.id), query, c.id).length}'
            : (counts ? '${c.name} ${shelfBooksIn(lib, c.id).length}' : c.name),
    };
    final theme = Theme.of(context);
    return PreferredSize(
      preferredSize: const Size.fromHeight(44),
      // 横向的滚动列表要有确定的高度，不然 AppBar 里量不出来、整条顶栏画不出
      child: SizedBox(
        height: 44,
        // 下划线和字色跟着滑动的进度走（和发现页的系统标签栏一样），不是切换完才跳过去
        child: AnimatedBuilder(
          animation: Listenable.merge([tc.animation!, _tabScroll]),
          builder: (context, _) {
            final at = tc.animation!.value.clamp(0.0, tabs.length - 1.0);
            final lo = at.floor(), hi = at.ceil();
            // 标签滑出屏幕时量不到（列表只排眼前的），就先用另一头的位置
            final ra = _labelRect(tabs, lo), rb = _labelRect(tabs, hi);
            final a = ra ?? rb, b = rb ?? ra;
            final t = at - lo;
            // 第一次进来时标签还没排好版：下一帧再画一次（最多重试几次，免得一直重建）
            if (a == null && _measureRetries++ < 3) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
            return Stack(
              key: _stripKey,
              children: [
                ReorderableListView.builder(
                  scrollController: _tabScroll,
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: tabs.length,
                  proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
                  onReorderItem: (from, to) {
                    final ids = [for (final c in tabs) c.id];
                    ids.insert(to, ids.removeAt(from));
                    // 隐藏的标签留在原位，可见的按新顺序填回它们占的位置
                    final all = [for (final c in allShelfTabs(lib.cats)) c.id];
                    var k = 0;
                    final ordered = [for (final id in all) ids.contains(id) ? ids[k++] : id];
                    _box.put('shelfTabOrder', ordered);
                    final catMap = {for (final c in lib.cats) c.id: c};
                    ref.read(libraryProvider.notifier).reorderCategories([for (final id in ordered) if (catMap[id] != null) catMap[id]!]);
                    setState(() {});
                  },
                  itemBuilder: (context, i) {
                    final c = tabs[i];
                    final near = (1 - (at - i).abs()).clamp(0.0, 1.0); // 1 = 正在这个标签
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(c.id),
                      index: i,
                      child: InkWell(
                        onTap: () => tc.animateTo(i),
                        child: Container(
                          key: _keys.putIfAbsent(c.id, GlobalKey.new),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            labels[c.id]!,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color.lerp(theme.colorScheme.onSurfaceVariant, theme.colorScheme.primary, near)),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (a != null && b != null)
                  Positioned(
                    left: a.$1 + (b.$1 - a.$1) * t,
                    width: a.$2 + (b.$2 - a.$2) * t,
                    bottom: 0,
                    height: 3,
                    child: IgnorePointer(
                      child: DecoratedBox(decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: const BorderRadius.vertical(top: Radius.circular(3)))),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

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
    context.push(o.display == 3 || o.display == 4 ? Routes.volumes(b.aid) : Routes.novel(b.aid));
  }

  /// 只检查当前标签里的书的更新
  void _checkTab() {
    final aids = shelfBooksIn(ref.read(libraryProvider), _curTab).map((b) => b.aid).where((a) => !isLocalAid(a)).toSet();
    if (aids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前分类没有可检查更新的在线书籍')));
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
    final tabCounts = ref.watch(appPref(P.tabCounts, false));
    final showResumeBar = ref.watch(appPref(P.resumeBar, true));
    final tabs = shelfTabs(lib.cats, hidden: hidden);
    final tc = _controller([for (final c in tabs) c.id]);
    if (perCat) ref.watch(appPrefProvider('shelf.tab.$_curTab'));
    final o = shelfOptionsFor(ref.watch(shelfOptionsProvider), _curTab);
    final scene = appPalettes[ref.watch(paletteProvider)].scene;
    final sceneMotion = scene ? ref.watch(appPref(P.sceneMotion, true)) : false;
    // 插画主题：顶栏加高，标题和按钮压在插画的天空上，下面的分类标签仍在页面底色上
    final appBar = AppBar(
      foregroundColor: scene ? RuinsColors.of(context).ink : null,
      flexibleSpace: scene ? Column(children: [Expanded(child: RuinsScene(animate: sceneMotion, horizon: 0.86, ceiling: 0.5)), const SizedBox(height: 44)]) : null,
      title: _searching
          ? TextField(
              autofocus: true,
              decoration: const InputDecoration(hint: Text('在书架中搜索', maxLines: 1, overflow: TextOverflow.ellipsis), border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
              onChanged: ref.read(shelfQueryProvider.notifier).set,
            )
          : Text('书架 · ${lib.books.length}'),
      actions: [
        IconButton(
          tooltip: hz(context, _searching ? '关闭搜索' : '搜索书架'),
          icon: Icon(_searching ? Icons.close : Icons.search),
          onPressed: () {
            setState(() => _setSearching(!_searching));
            if (!_searching) ref.read(shelfQueryProvider.notifier).set('');
          },
        ),
        IconButton(tooltip: hz(context, '筛选、排序、显示'), icon: Icon(Icons.filter_list, color: o.filtering ? Theme.of(context).colorScheme.primary : null), onPressed: _showOptions),
        PopupMenuButton<String>(
          tooltip: hz(context, '更多'),
          onSelected: (v) async {
            if (v == 'random') {
              _openRandom();
            } else if (v == 'check') {
              _checkTab();
            } else if (v == 'import_local') {
              await importLocalBooksFlow(context, ref);
            } else if (v == 'sync_shelf') {
              final err = await ref.read(libraryProvider.notifier).sync(force: true);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(err == null ? '已和网站书架同步，书架共 ${ref.read(libraryProvider).books.length} 本' : '同步网站书架失败：$err')),
              );
              if (err == null && !isWebPreview) ref.read(volumeCoverQueueProvider).prefetchAll(ref.read(libraryProvider).books.keys).ignore();
              ref.read(updateProvider.notifier).refresh();
            } else {
              context.push(v);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'import_local', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.file_open_outlined), title: Text('导入本地书籍（EPUB / TXT）'))),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'random', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.casino_outlined), title: Text('随机打开一本'))),
            PopupMenuItem(value: 'check', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.refresh), title: Text('检查「$_curTabName」的更新'))),
            if (ref.read(sessionProvider) is SessionLoggedIn)
              const PopupMenuItem(value: 'sync_shelf', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.cloud_sync_outlined), title: Text('同步网站书架'))),
            const PopupMenuDivider(),
            const PopupMenuItem(value: Routes.categories, child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.label_outline), title: Text('分类管理'))),
          ],
        ),
      ],
      bottom: scene
          ? PreferredSize(preferredSize: const Size.fromHeight(44 + 64), child: Column(children: [const SizedBox(height: 64), _tabStrip(tabs, tc, lib, counts: tabCounts, perCat: perCat)]))
          : _tabStrip(tabs, tc, lib, counts: tabCounts, perCat: perCat),
    );
    return CallbackShortcuts(
      bindings: {
        if (_searching)
          const SingleActivator(LogicalKeyboardKey.escape): () {
            setState(() => _setSearching(false));
            ref.read(shelfQueryProvider.notifier).set('');
          },
      },
      child: PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _setSearching(false));
        ref.read(shelfQueryProvider.notifier).set('');
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
                        resumeEnabled: !_searching && showResumeBar,
                      ),
                  ],
                ),
              ),
            ),
            if (!_searching && showResumeBar)
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

/// 书架顶上的「继续阅读」：最近读的一本，点了直接进阅读器（返回回到书架）；关掉后，读到别的书时再出现。
/// 像音乐 App 的"正在播放"：底色取封面的色调，封面、书名、读到的章节，右边一个大的继续按钮。
/// 往下滑书架时以纯 GPU 位移与透明度叠加收起（[hidden]），不改下方 TabBarView 高度避免整屏连续 relayout；设置里可以整个关掉。
class _ResumeBar extends ConsumerWidget {
  const _ResumeBar({required this.hidden, required this.onHeight});

  final ValueListenable<bool> hidden;
  final ValueChanged<double> onHeight;

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.month} 月 ${t.day} 日';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder(
    valueListenable: Hive.box('session').listenable(keys: ['history2', 'resumeClosed']),
    builder: (context, box, _) {
      final h = ReadingHistory.all().firstOrNull;
      if (h == null || box.get('resumeClosed') == h.aid) {
        onHeight(0);
        return const SizedBox.shrink();
      }
      // 用 Consumer 包一层：_bar 里的 ref.watch 要在一次 build 里执行，换了书（封面变了）旧的订阅才会被清掉
      final card = _MeasureHeight(
        onHeight: onHeight,
        child: RepaintBoundary(child: Consumer(builder: (context, ref, _) => _bar(context, ref, box, h))),
      );
      return ValueListenableBuilder<bool>(
        valueListenable: hidden,
        builder: (context, isHidden, _) => TweenAnimationBuilder<double>(
          tween: Tween<double>(end: isHidden ? 0.0 : 1.0),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeInOutCubic,
          child: card,
          builder: (context, t, child) => ClipRect(
            child: IgnorePointer(
              ignoring: isHidden || t < 0.05,
              child: FractionalTranslation(
                translation: Offset(0, -(1 - t)),
                child: Opacity(opacity: Curves.easeIn.transform(t), child: child),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _bar(BuildContext context, WidgetRef ref, Box box, HistoryEntry h) {
    ref.watch(volumeChangeForProvider(h.aid)); // 仅订阅当前书的高清封面变化
    final cover = ref.read(volumeCoverQueueProvider).bookCover(h.aid, h.img);
    final tint = ref.watch(coverColorProvider(cover)).value ?? savedCoverColor(cover) ?? kNeutralCoverColor;
    final theme = Theme.of(context);
    final radius = appPalettes[ref.watch(paletteProvider)].scene ? 6.0 : 16.0;
    void open() => context.push(Routes.reader(h.aid, h.cid));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: tint),
        duration: const Duration(milliseconds: 400),
        builder: (context, color, child) => Material(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
        child: InkWell(
          onTap: open,
          onLongPress: () => context.push(Routes.novel(h.aid)),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 42, 14),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 64,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 3))]),
                      clipBehavior: Clip.antiAlias,
                      child: CoverImage(cover, aid: h.aid, thumbnail: true, decodeSize: const Size(46, 64)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('继续阅读 · ${_ago(h.time)}', style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60, letterSpacing: 0.5)),
                          const SizedBox(height: 2),
                          Text(LibraryStore.shown(h.aid, h.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(h.chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filled(
                      tooltip: hz(context, '继续阅读'),
                      style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87, fixedSize: const Size(44, 44)),
                      icon: const Icon(Icons.play_arrow_rounded, size: 26),
                      onPressed: open,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: hz(context, '关闭'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: Colors.white60,
                  icon: const Icon(Icons.close),
                  onPressed: () => box.put('resumeClosed', h.aid),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书架的筛选 / 排序 / 显示面板（Mihon 那样分三页）：筛选一行一项、点整行在 不限 → 满足 → 不满足 之间切，
/// 排序一行一项、再点当前的反过来，显示用设置页同款的分段按钮和开关。
class _OptionsSheet extends ConsumerStatefulWidget {
  const _OptionsSheet({required this.tabId});

  final String tabId;

  @override
  ConsumerState<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends ConsumerState<_OptionsSheet> with SingleTickerProviderStateMixin {
  static int _lastPage = 0; // 下次打开还停在上次那页
  late final TabController _tabs = TabController(length: 3, vsync: this, initialIndex: _lastPage)..addListener(() => _lastPage = _tabs.index);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _set(ShelfOptions v) => AppPrefs.read(P.perCat, false)
      ? ref.read(appPrefsProvider.notifier).set('shelf.tab.${widget.tabId}', v.toMap())
      : ref.read(shelfOptionsProvider.notifier).set(v);

  /// 三态筛选的一行：空框不限，勾满足，叉不满足
  Widget _tri(String label, int v, ShelfOptions Function(int) apply) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (v) {
      1 => (Icons.check_box, scheme.primary),
      2 => (Icons.disabled_by_default, scheme.error),
      _ => (Icons.check_box_outline_blank, scheme.onSurfaceVariant),
    };
    return InkWell(
      onTap: () => _set(apply((v + 1) % 3)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: TextStyle(fontSize: 15.5, color: scheme.onSurface))),
            if (v == 2) Text('不满足', style: TextStyle(fontSize: 13, color: scheme.error)),
          ],
        ),
      ),
    );
  }

  Widget _filters(ShelfOptions o) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _tri('有未读', o.unread, (v) => o.copyWith(unread: v)),
        _tri('已开始读', o.started, (v) => o.copyWith(started: v)),
        _tri('有缓存', o.cached, (v) => o.copyWith(cached: v)),
        _tri('有书签', o.bookmarked, (v) => o.copyWith(bookmarked: v)),
        _tri('已完结', o.completed, (v) => o.copyWith(completed: v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text('点一下切换：满足 → 不满足 → 不限', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
              if (o.filtering) TextButton(onPressed: () => _set(o.copyWith(unread: 0, started: 0, cached: 0, bookmarked: 0, completed: 0)), child: const Text('清除筛选')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sorts(ShelfOptions o) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        for (final s in ShelfSort.values)
          InkWell(
            // 再点一次当前的排序：方向反过来；随机再点一次换一批
            onTap: () {
              if (s == ShelfSort.random) ref.read(appPrefsProvider.notifier).set('shelf.seed', DateTime.now().millisecondsSinceEpoch & 0xFFFF);
              final switchingToCustom = s == ShelfSort.custom && o.sort != ShelfSort.custom && o.display != 2;
              _set(o.sort == s ? o.copyWith(reverse: !o.reverse) : o.copyWith(sort: s, reverse: false));
              if (switchingToCustom) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('自定义排序将自动以列表展示，可拖动右侧把手调整顺序')));
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.label,
                          style: TextStyle(fontSize: 15.5, color: o.sort == s ? scheme.primary : scheme.onSurface, fontWeight: o.sort == s ? FontWeight.w600 : null),
                        ),
                        if (s == ShelfSort.custom)
                          Text('自动切换为列表以便拖动排序', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (o.sort == s)
                    Icon(
                      switch (s) {
                        ShelfSort.random => Icons.shuffle,
                        ShelfSort.custom => Icons.check,
                        _ => o.reverse ? Icons.arrow_upward : Icons.arrow_downward,
                      },
                      size: 20,
                      color: scheme.primary,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _display(ShelfOptions o, {required String colsKey, required int cols, required bool unreadBadge, required bool cacheBadge, required bool resumeBar}) {
    final prefs = ref.read(appPrefsProvider.notifier);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        XChips<int>(title: '显示方式', value: o.display, options: const {0: '网格', 1: '紧凑', 2: '列表', 3: '卷册', 4: '立体'}, onChanged: (v) => _set(o.copyWith(display: v))),
        // 就是设置里的书架列数（竖屏、横屏分开记），这里放常用的几种；设置里选了别的也列出来
        if (o.display != 2 && o.display != 4)
          XSegments<int>(
            title: '每行几本',
            value: cols,
            options: {0: '自动', 3: '3 本', 4: '4 本', if (cols != 0 && cols != 3 && cols != 4) cols: '$cols 本'},
            onChanged: (v) => prefs.set(colsKey, v),
          ),
        const SizedBox(height: 4),
        XSwitch(title: '未读章数角标', value: unreadBadge, onChanged: (v) => prefs.set(P.unreadBadge, v)),
        XSwitch(title: '已缓存章数角标', value: cacheBadge, onChanged: (v) => prefs.set(P.cacheBadge, v)),
        XSwitch(title: '继续阅读条', value: resumeBar, onChanged: (v) => prefs.set(P.resumeBar, v)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final perCat = ref.watch(appPref(P.perCat, false));
    if (perCat) ref.watch(appPrefProvider('shelf.tab.${widget.tabId}'));
    final colsKey = MediaQuery.orientationOf(context) == Orientation.landscape ? P.colsLandscape : P.colsPortrait;
    final cols = ref.watch(appPref(colsKey, 0));
    final unreadBadge = ref.watch(appPref(P.unreadBadge, true));
    final cacheBadge = ref.watch(appPref(P.cacheBadge, false));
    final resumeBar = ref.watch(appPref(P.resumeBar, true));
    final o = shelfOptionsFor(ref.watch(shelfOptionsProvider), widget.tabId);
    final scheme = Theme.of(context).colorScheme;
    final tabName = allShelfTabs(ref.read(libraryProvider).cats).firstWhere((c) => c.id == widget.tabId, orElse: () => const LibCategory('', '默认')).name;
    // 固定高度：切换三页时面板不跳；最多占屏幕六成
    final height = math.min(MediaQuery.sizeOf(context).height * 0.6, 520.0);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            if (perCat)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('只对「$tabName」生效', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
            TabBar(
              controller: _tabs,
              tabs: [
                // 有筛选时标签旁边一个小圆点，换到别的页也知道筛着
                Tab(child: Badge(smallSize: 6, isLabelVisible: o.filtering, backgroundColor: scheme.primary, offset: const Offset(8, -2), child: const Text('筛选'))),
                const Tab(child: Text('排序')),
                const Tab(child: Text('显示')),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_filters(o), _sorts(o), _display(o, colsKey: colsKey, cols: cols, unreadBadge: unreadBadge, cacheBadge: cacheBadge, resumeBar: resumeBar)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

class _ShelfState extends ConsumerState<_Shelf> with AutomaticKeepAliveClientMixin {
  final _selected = <String>{};
  static final _selecting = <String>{}; // 哪几个标签页正在多选
  final _focus = FocusNode(debugLabel: 'shelf-select');
  bool _markingRead = false;

  // 缓存 _arrange() 结果，避免多选、徽章切换等无关重建重复全量筛选排序
  (Map<String, LibBook>, ShelfOptions, String, String, bool, int, int)? _arrangeKey;
  List<LibBook> _arrangedBooks = const [];
  int _arrangeEpoch = 0;
  List<LibBook>? _lastWarmedBooks;

  // 滚动方向前方预解码状态（主封面缩略图提前解码进 Flutter ImageCache）
  int _layoutCols = 1;
  double _layoutRowExtent = 0;
  double _layoutTopPadding = 0;
  Size _layoutCoverSize = Size.zero;
  final _precachedUrls = <String>{};
  (bool, int, int)? _lastPrecacheSpan;
  DateTime _lastPrecacheAt = DateTime(0);

  @override
  bool get wantKeepAlive => true;

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

  /// 监听书架垂直滑动方向，在前进方向前方约 1.5~2 屏对主封面主动预解码（带节流与去重）。
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
    final aheadStartPx = forward ? pixels + viewport * 0.6 : math.max(0.0, pixels - viewport * 1.8);
    final aheadEndPx = forward ? pixels + viewport * 2.4 : math.max(0.0, pixels - viewport * 0.1);
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
      for (var i = startIdx; i <= endIdx && queued < 24; i++) {
        final url = _cover(_arrangedBooks[i]);
        if (url.isNotEmpty && _precachedUrls.add(url)) {
          queued++;
          NetImage.precache(context, url, _layoutCoverSize, thumbnail: true, lowPriority: true).ignore();
        }
      }
    } else {
      for (var i = endIdx; i >= startIdx && queued < 24; i--) {
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
    ref.read(updateProvider.notifier).refresh();
  }

  Future<void> _setCats() async {
    final lib = ref.read(libraryProvider);
    if (lib.cats.isEmpty) {
      context.push(Routes.categories);
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
    if (isLocalAid(_selected.first)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('本地书籍暂不支持在线换封面')));
      return;
    }
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
    final aids = [for (final aid in _selected) if (!isLocalAid(aid)) aid];
    if (aids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('本地书籍无需缓存下载')));
      setState(_selected.clear);
      return;
    }
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
          final n = isLocalAid(aid) ? await LocalBooks.loadNovel(aid) : await api.novel(aid);
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
    final localAids = [for (final a in aids) if (isLocalAid(a)) a];
    if (localAids.isNotEmpty) {
      final res = await confirmRemoveLocalBooks(context, totalCount: aids.length, localCount: localAids.length);
      if (!res.confirmed || !mounted) return;
      await ref.read(libraryProvider.notifier).remove(aids);
      if (res.deleteFiles) {
        for (final a in localAids) {
          await LocalBooks.delete(a);
        }
      }
      if (mounted) setState(_selected.clear);
      return;
    }
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
    super.build(context);
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
    final loggedIn = ref.watch(sessionProvider) is SessionLoggedIn;
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
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => importLocalBooksFlow(context, ref),
                icon: const Icon(Icons.file_open_outlined, size: 18),
                label: const Text('导入本地书籍'),
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
        return ListView.builder(padding: EdgeInsets.fromLTRB(0, inset, 0, 24), itemCount: books.length, itemBuilder: (context, i) => _listTile(books[i]));
      }
      if (o.display == 4) {
        // 正好一屏高；外面套一层能滚的，下拉同步照常可用
        return LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: c.maxHeight,
              child: Padding(
                padding: EdgeInsets.only(top: inset),
                child: ValueListenableBuilder<String>(
                  valueListenable: widget.activeTab,
                  builder: (context, tab, _) => Shelf3DView(
                    books: books,
                    // 每个标签记住上次停在哪本，只存在本机（不进备份、不同步）
                    initialAid: Hive.box('session').get('shelf3d:${widget.catId}') as String?,
                    onFocusChanged: (aid) => Hive.box('session').put('shelf3d:${widget.catId}', aid),
                    selected: _selected,
                    heroEnabled: tab == widget.catId,
                    coverOf: _cover,
                    badgeOf: _badge,
                    subtitleOf: _shelf3dLine,
                    actionOf: _shelf3dAction,
                    onOpen: (b) => _openAndRefresh(Routes.volumes(b.aid)),
                    onRead: (b, cid) => _openAndRefresh(Routes.reader(b.aid, cid)),
                    onToggleSelect: (b) => _toggle(b.aid),
                  ),
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
              scrollCacheExtent: const ScrollCacheExtent.viewport(1), // 上下各多备一屏，快速滑动时封面也已经解码好
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
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSelecting();
    });
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
                      child: RefreshIndicator(edgeOffset: inset, onRefresh: _refresh, child: buildBody(inset)),
                    );
                  },
                ),
              ),
              if (_selected.isNotEmpty)
                Material(
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
                              if (_markingRead) ...[
                                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                const SizedBox(width: 8),
                              ],
                              Expanded(child: Text(_markingRead ? '正在标为已读…' : '${_selected.length} 本', maxLines: 1, softWrap: false, overflow: TextOverflow.fade)),
                            ],
                          ),
                        ),
                        // 和 Mihon 一样只放图标（长按看名字），文字按钮一行放不下
                        IconButton(tooltip: hz(context, '全选'), icon: const Icon(Icons.select_all), onPressed: () => setState(() => _selected.addAll(books.map((b) => b.aid)))),
                        if (_selected.length == 1) IconButton(tooltip: hz(context, '改名'), icon: const Icon(Icons.drive_file_rename_outline), onPressed: _rename),
                        if (_selected.length == 1) IconButton(tooltip: hz(context, '封面'), icon: const Icon(Icons.image_outlined), onPressed: _pickCover),
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

  void _openAndRefresh(String route) {
    context.push(route).then((_) {
      if (mounted) setState(() => _arrangeEpoch++);
    });
  }

  void _tap(LibBook b) => _selected.isEmpty ? _openAndRefresh(Routes.novel(b.aid)) : _toggle(b.aid);

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
      onPressed: () => _openAndRefresh(Routes.reader(b.aid, p.cid)),
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
    return MouseRegion(
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
            if (badge != null) Positioned(top: 6, right: 6, child: badge),
            if (resume != null) Positioned(right: 0, bottom: 0, child: resume),
          ],
        ),
      ),
    );
  }

  /// 卷册：第一卷封面在最前，右边露出后面几卷真封面的一窄条边（卷越多条数越多，单卷没有），书名和读到第几卷在封面下面。
  Widget _stackTile(LibBook b, {required Size coverSize}) {
    final badge = _badge(b);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _selected.isEmpty ? _openAndRefresh(Routes.volumes(b.aid)) : _toggle(b.aid),
        onLongPress: () => _toggle(b.aid),
        onSecondaryTap: () => _toggle(b.aid),
        child: _ShelfStackTile(book: b, catId: widget.catId, activeTab: widget.activeTab, badge: badge, coverSize: coverSize),
      ),
    );
  }

  Widget _listTile(LibBook b) {
    final p = ReadingProgress.of(b.aid);
    final n = _unread(b.aid);
    final cached = ChapterCache.count(b.aid);
    return GestureDetector(
      onSecondaryTap: () => _toggle(b.aid),
      child: ListTile(
        selected: _selected.contains(b.aid),
        leading: SizedBox(width: 40, height: 54, child: _ShelfBookCover(aid: b.aid, fallbackImg: b.img, decodeSize: const Size(40, 54))),
        title: Text(b.shown, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([if (n > 0) '未读 $n 章', if (cached > 0) '已缓存 $cached 章', if (b.done) '已完结', if (p == null) '还没读'].join(' · ')),
        trailing: _selected.contains(b.aid) ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary) : _resume(b),
        onTap: () => _tap(b),
        onLongPress: () => _toggle(b.aid),
      ),
    );
  }

  /// 自定义排序：列表形式，拖动右侧把手调整，每个分类单独记顺序。
  Widget _reorderable(List<LibBook> books, {required bool autoSwitched, required double topPadding}) => ReorderableListView.builder(
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
