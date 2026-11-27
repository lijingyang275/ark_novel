import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show RenderAbstractViewport, ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/recommend_block.dart';
import '../app_prefs.dart';
import '../catalog.dart';
import '../data.dart';
import '../env.dart';
import '../library.dart';
import '../motion.dart';
import '../routes.dart';
import '../session.dart';
import '../widgets.dart';
import '../text.dart';

/// 发现：推荐 / 排行 / 题材 / 完结。
class DiscoverPage extends ConsumerWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const tabs = [Tab(child: Text('推荐')), Tab(child: Text('排行')), Tab(child: Text('题材')), Tab(child: Text('完结'))];
    final search = IconButton(icon: Icon(Icons.search, size: isDesktop ? 20 : null), tooltip: hz(context, '搜索'), onPressed: () => context.push(Routes.search));
    // 桌面宽屏：标题和分区标签合成一行，和书架、更新页的顶栏一样高；标签用圆角选中块，不拉满整个宽度
    final singleRow = isDesktop && MediaQuery.sizeOf(context).width >= 720;
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: singleRow
            ? AppBar(
                titleSpacing: 20,
                title: Row(
                  children: [
                    const Text('发现'),
                    const SizedBox(width: 18),
                    Flexible(
                      child: TabBar(
                        tabs: tabs,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        dividerHeight: 0,
                        // 不要按下 / 悬停的整块高亮：它比圆角选中块大一圈，点的时候像残影
                        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                        splashFactory: NoSplash.splashFactory,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                        labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        unselectedLabelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                        labelColor: scheme.onSurface,
                        unselectedLabelColor: scheme.onSurfaceVariant,
                        indicatorSize: TabBarIndicatorSize.tab,
                        indicator: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
                        indicatorPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ],
                ),
                actions: [search, const SizedBox(width: 8)],
                bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Divider(height: 1, color: scheme.outline.withValues(alpha: 0.6))),
              )
            : AppBar(
                title: const Text('发现'),
                actions: [search],
                bottom: const TabBar(tabs: tabs),
              ),
        body: const TabBarView(children: [_RecommendTab(), _RankingTab(), _CategoryTab(), _CompletedTab()]),
      ),
    );
  }
}

// 不自动释放：离开发现页再回来、左右切标签都不用重新联网，下拉才刷新
final _recommendProvider = FutureProvider<List<RecommendBlock>>((ref) => ref.watch(apiProvider).recommend());

class _RecommendTab extends ConsumerStatefulWidget {
  const _RecommendTab();

  @override
  ConsumerState<_RecommendTab> createState() => _RecommendTabState();
}

class _RecommendTabState extends ConsumerState<_RecommendTab> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(_recommendProvider.future),
      child: AppCrossfade(
        fill: true,
        duration: AppMotion.fast,
        child: ref
            .watch(_recommendProvider)
            .when(
              loading: () => const _RecommendSkeleton(key: ValueKey('rec-loading')),
              error: (e, _) => StatePanel(key: const ValueKey('rec-error'), title: '加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(_recommendProvider)),
              data: (blocks) => blocks.isEmpty
                  ? StatePanel(key: const ValueKey('rec-empty'), title: '暂无推荐内容', detail: '请稍后重试或检查网络连接', onRetry: () => ref.invalidate(_recommendProvider))
                  : LayoutBuilder(
                      key: const ValueKey('rec-data'),
                      builder: (context, c) {
                        final cols = gridColumns(c.maxWidth) >= 6 ? 6 : 3;
                        final itemW = ((c.maxWidth - 32 - 14 * (cols - 1)) / cols).clamp(1.0, double.infinity);
                        final coverSize = Size(itemW, itemW * 4 / 3);
                        final delegate = SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 16, crossAxisSpacing: 14, childAspectRatio: 0.52);
                        return CustomScrollView(
                          key: const PageStorageKey('discover:recommend'),
                          scrollCacheExtent: const ScrollCacheExtent.viewport(0.4),
                          slivers: [
                            for (final block in blocks) ...[
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                                sliver: SliverToBoxAdapter(child: Text(block.title, style: theme.textTheme.titleLarge)),
                              ),
                              // 一个分区通常 6 本：手机上 3 列排两排，宽屏放得下就 6 列一排
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                sliver: SliverGrid.builder(
                                  gridDelegate: delegate,
                                  itemCount: block.list.length,
                                  itemBuilder: (_, i) => NovelCard(title: block.list[i].title, aid: block.list[i].aid, imageUrl: block.list[i].imageUrl, decodeSize: coverSize),
                                ),
                              ),
                            ],
                            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
                          ],
                        );
                      },
                    ),
            ),
      ),
    );
  }
}

/// 推荐页首次加载骨架：两个分区标题条 + 封面网格占位。
class _RecommendSkeleton extends StatelessWidget {
  const _RecommendSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainer;
    Widget bar(double w, [double h = 12]) => Container(height: h, width: w, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)));
    return AppSkeletonPulse(
      child: LayoutBuilder(
        builder: (context, c) {
          final cols = gridColumns(c.maxWidth) >= 6 ? 6 : 3;
          final delegate = SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 16, crossAxisSpacing: 14, childAspectRatio: 0.52);
          return CustomScrollView(
            physics: const NeverScrollableScrollPhysics(),
            slivers: [
              for (var s = 0; s < 2; s++) ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  sliver: SliverToBoxAdapter(child: Align(alignment: Alignment.centerLeft, child: bar(110, 20))),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid.builder(
                    gridDelegate: delegate,
                    itemCount: 6,
                    itemBuilder: (_, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)), child: const SizedBox.expand())),
                        const SizedBox(height: 8),
                        bar(double.infinity),
                        const SizedBox(height: 6),
                        bar(48),
                      ],
                    ),
                  ),
                ),
              ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          );
        },
      ),
    );
  }
}

/// 筛选项：没选中的只是文字，选中的是主题色淡底的小圆角块
class _Pill extends StatelessWidget {
  const _Pill(this.text, {super.key, required this.selected, required this.onTap, this.small = false});

  final String text;
  final bool selected;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dur = AppMotion.dur(context, AppMotion.fast);
    return AppPressScale(
      scale: 0.95,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: dur,
          curve: AppMotion.curve,
          padding: EdgeInsets.symmetric(horizontal: small ? 8 : 12, vertical: small ? 3 : 6),
          decoration: BoxDecoration(color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent, borderRadius: BorderRadius.circular(999)),
          child: AnimatedDefaultTextStyle(
            duration: dur,
            curve: AppMotion.curve,
            style: TextStyle(fontSize: small ? 12 : 14, height: 1.3, color: selected ? scheme.primary : scheme.onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
            child: Text(text, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

/// 一排横向滑动的筛选项，右边可以挂一个小图标
class _Chips<T> extends StatefulWidget {
  const _Chips({required this.options, required this.value, required this.onChanged, required this.label, this.trailing});

  final List<T> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String Function(T) label;
  final Widget? trailing;

  @override
  State<_Chips<T>> createState() => _ChipsState<T>();
}

class _ChipsState<T> extends State<_Chips<T>> {
  final _selected = GlobalKey();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reveal(); // 记住的选项可能在后面
  }

  @override
  void didUpdateWidget(_Chips<T> old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _reveal();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 只滚这一排（Scrollable.ensureVisible 会连外面左右翻页的 TabBarView 一起拨动）
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box = _selected.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final to = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0.5).offset.clamp(0.0, _scroll.position.maxScrollExtent);
    if (AppMotion.reduce(context)) {
      _scroll.jumpTo(to);
    } else {
      _scroll.animateTo(to, duration: AppMotion.fast, curve: AppMotion.curve);
    }
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        // 选项不多（最多几十个），全部排出来，选中的才能滚到
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              spacing: 2,
              children: [for (final o in widget.options) _Pill(widget.label(o), key: o == widget.value ? _selected : null, selected: o == widget.value, onTap: () => widget.onChanged(o))],
            ),
          ),
        ),
        ?widget.trailing,
      ],
    ),
  );
}

/// 右侧的小图标按钮
Widget _sideIcon({required String tooltip, required Widget icon, Widget? selectedIcon, bool? selected, required VoidCallback onPressed}) => IconButton(
  tooltip: tooltip,
  iconSize: 20,
  visualDensity: VisualDensity.compact,
  isSelected: selected,
  icon: icon,
  selectedIcon: selectedIcon,
  onPressed: onPressed,
);

/// 「隐藏书架里的书」开关：排行、分类与完结共用一个设置
Widget _hideShelfChip(BuildContext context, WidgetRef ref) {
  final on = ref.watch(appPref(P.hideShelved, false));
  return Padding(
    padding: const EdgeInsets.only(right: 6),
    child: _sideIcon(
      tooltip: hz(context, '隐藏书架里的书'),
      selected: on,
      icon: const Icon(Icons.library_add_check_outlined),
      selectedIcon: const Icon(Icons.library_add_check),
      onPressed: () {
        ref.read(appPrefsProvider.notifier).set(P.hideShelved, !on);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(on ? '显示书架里的书' : '已隐藏书架里的书'), duration: const Duration(seconds: 1)));
      },
    ),
  );
}

/// 打开了「隐藏书架里的」就返回判断函数，否则 null
bool Function(String)? _hideShelved(WidgetRef ref) {
  if (!ref.watch(appPref(P.hideShelved, false))) return null;
  final books = ref.watch(libraryProvider.select((s) => s.books));
  return books.containsKey;
}

class _RankingTab extends ConsumerStatefulWidget {
  const _RankingTab();

  @override
  ConsumerState<_RankingTab> createState() => _RankingTabState();
}

class _RankingTabState extends ConsumerState<_RankingTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // 从上次的参数（比如 weekvisit）拆出榜单和时间
  late final _saved = parseRank(AppPrefs.read(P.discoverRank, ''));
  late var _kind = _saved.$1;
  late var _period = _saved.$2;

  void _set({String? kind, String? period}) {
    setState(() {
      _kind = kind ?? _kind;
      _period = period ?? _period;
    });
    AppPrefs.write(P.discoverRank, rankParam(_kind, _period));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!isWebPreview && ref.watch(sessionProvider.select((s) => s is SessionLoggedOut))) {
      return const LoginPrompt(title: '排行榜需要登录', detail: '登录轻小说文库账号后可查看点击榜、推荐榜、收藏榜等榜单；「推荐」分区可直接浏览。');
    }
    final api = ref.watch(apiProvider);
    final node = ref.watch(nodeProvider);
    final param = rankParam(_kind, _period);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _Chips(options: [for (final k in rankKinds) k.$2], value: _kind, label: (k) => rankKinds.firstWhere((e) => e.$2 == k).$1, trailing: _hideShelfChip(context, ref), onChanged: (k) => _set(kind: k)),
        // 日 / 周 / 月 / 总：一个小分段，只有点击、推荐有
        AppCollapse(
          visible: rankPeriodic.contains(_kind),
          duration: AppMotion.fast,
          reverseDuration: AppMotion.instant,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final (label, p) in rankPeriods) _Pill(label, small: true, selected: p == _period, onTap: () => _set(period: p))],
              ),
            ),
          ),
        ),
        Expanded(
          child: PagedNovelGrid(
            key: ValueKey((node, param)),
            hide: _hideShelved(ref),
            onRefresh: api.clearListCache,
            fetchWithCancel: (page, cancelToken) => api.fetchRanking(param, page, cancelToken: cancelToken),
          ),
        ),
      ],
    );
  }
}

class _CategoryTab extends ConsumerStatefulWidget {
  const _CategoryTab();

  @override
  ConsumerState<_CategoryTab> createState() => _CategoryTabState();
}

class _CategoryTabState extends ConsumerState<_CategoryTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  var _tag = categoryTags.contains(AppPrefs.read(P.discoverTag, '')) ? AppPrefs.read(P.discoverTag, '') : categoryTags.first;
  var _sort = categorySorts.firstWhere((e) => e.$2 == AppPrefs.read(P.discoverTagSort, ''), orElse: () => categorySorts.first);
  var _open = false; // 全部标签的下拉面板

  void _pick(String t) {
    AppPrefs.write(P.discoverTag, t);
    setState(() {
      _tag = t;
      _open = false;
    });
  }

  /// 全部标签：盖住标签那排往下展开，流式换行，多了在里面滑
  Widget _panel() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 22),
                Expanded(child: Text('全部标签', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                _sideIcon(tooltip: hz(context, '收起'), icon: const Icon(Icons.expand_less), onPressed: () => setState(() => _open = false)),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final t in categoryTags) _Pill(t, selected: t == _tag, onTap: () => _pick(t))],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!isWebPreview && ref.watch(sessionProvider.select((s) => s is SessionLoggedOut))) {
      return const LoginPrompt(title: '题材筛选需要登录', detail: '登录轻小说文库账号后可按奇幻、校园、恋爱等题材标签筛选小说。');
    }
    final api = ref.watch(apiProvider);
    final node = ref.watch(nodeProvider);
    return Stack(
      children: [
        Column(
          children: [
            _Chips(
              options: categoryTags,
              value: _tag,
              label: (e) => e,
              onChanged: _pick,
              trailing: _sideIcon(
                tooltip: hz(context, '全部标签'),
                icon: AnimatedRotation(
                  turns: _open ? 0.5 : 0.0,
                  duration: AppMotion.dur(context, AppMotion.fast),
                  curve: AppMotion.snappy,
                  child: const Icon(Icons.expand_more),
                ),
                onPressed: () => setState(() => _open = !_open),
              ),
            ),
            _Chips(
              options: categorySorts,
              value: _sort,
              label: (e) => e.$1,
              trailing: _hideShelfChip(context, ref),
              onChanged: (v) {
                AppPrefs.write(P.discoverTagSort, v.$2);
                setState(() => _sort = v);
              },
            ),
            Expanded(
              child: PagedNovelGrid(
                key: ValueKey((node, _tag, _sort)),
                hide: _hideShelved(ref),
                onRefresh: api.clearListCache,
                fetchWithCancel: (page, cancelToken) => api.fetchCategory(_tag, _sort.$2, page, cancelToken: cancelToken),
              ),
            ),
          ],
        ),
        // 点面板外面收起
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_open,
            child: GestureDetector(
              onTap: () => setState(() => _open = false),
              child: AnimatedOpacity(
                opacity: _open ? 1.0 : 0.0,
                duration: AppMotion.dur(context, AppMotion.standard),
                curve: AppMotion.curve,
                child: const ColoredBox(color: Colors.black12),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: AppCollapse(visible: _open, duration: AppMotion.standard, reverseDuration: AppMotion.fast, child: _panel()),
        ),
      ],
    );
  }
}

class _CompletedTab extends ConsumerStatefulWidget {
  const _CompletedTab();

  @override
  ConsumerState<_CompletedTab> createState() => _CompletedTabState();
}

/// 保活保留已加载的分页列表与滚动位置，避免左右切换分区重复重新拉取
class _CompletedTabState extends ConsumerState<_CompletedTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!isWebPreview && ref.watch(sessionProvider.select((s) => s is SessionLoggedOut))) {
      return const LoginPrompt(title: '完结列表需要登录', detail: '登录轻小说文库账号后可浏览全部已完结小说。');
    }
    final api = ref.watch(apiProvider);
    final hideOn = ref.watch(appPref(P.hideShelved, false));
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: AppCrossfade(
                  alignment: Alignment.centerLeft,
                  duration: AppMotion.fast,
                  child: Text(
                    hideOn ? '已隐藏书架里的书' : '全部已完结小说',
                    key: ValueKey(hideOn),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              _hideShelfChip(context, ref),
            ],
          ),
        ),
        Expanded(
          child: PagedNovelGrid(
            key: ValueKey(ref.watch(nodeProvider)),
            hide: _hideShelved(ref),
            onRefresh: api.clearListCache,
            fetchWithCancel: (page, cancelToken) => api.fetchCompleted(page, cancelToken: cancelToken),
          ),
        ),
      ],
    );
  }
}
