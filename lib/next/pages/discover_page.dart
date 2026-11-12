import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/recommend_block.dart';
import '../app_prefs.dart';
import '../catalog.dart';
import '../data.dart';
import '../library.dart';
import '../router.dart';
import '../widgets.dart';
import '../text.dart';

/// 发现：推荐 / 排行 / 分类 / 完结。
class DiscoverPage extends ConsumerWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('发现'),
          actions: [IconButton(icon: const Icon(Icons.search), tooltip: hz(context, '搜索'), onPressed: () => context.push(Routes.search))],
          bottom: const TabBar(tabs: [Tab(child: Text('推荐')), Tab(child: Text('排行')), Tab(child: Text('分类')), Tab(child: Text('完结'))]),
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

class _RecommendTabState extends ConsumerState<_RecommendTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(_recommendProvider.future),
      child: ref
          .watch(_recommendProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => StatePanel(title: '加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(_recommendProvider)),
            data: (blocks) => ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final block in blocks) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(block.title, style: theme.textTheme.titleLarge),
                  ),
                  // 一个分区通常 6 本：手机上 3 列排两排，宽屏放得下就 6 列一排
                  LayoutBuilder(
                    builder: (context, c) => GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: gridColumns(c.maxWidth) >= 6 ? 6 : 3, mainAxisSpacing: 16, crossAxisSpacing: 14, childAspectRatio: 0.52),
                      itemCount: block.list.length,
                      itemBuilder: (_, i) => NovelCard(title: block.list[i].title, aid: block.list[i].aid, imageUrl: block.list[i].imageUrl),
                    ),
                  ),
                ],
              ],
            ),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 8 : 12, vertical: small ? 3 : 6),
        decoration: BoxDecoration(color: selected ? scheme.primary.withValues(alpha: 0.12) : null, borderRadius: BorderRadius.circular(999)),
        child: Text(
          text,
          maxLines: 1,
          style: TextStyle(fontSize: small ? 12 : 14, height: 1.3, color: selected ? scheme.primary : scheme.onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
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
    final box = _selected.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final to = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0.5).offset.clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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

/// 「隐藏书架里的书」开关：排行和分类共用一个设置
Widget _hideShelfChip(BuildContext context, WidgetRef ref) {
  final on = AppPrefs.read(P.hideShelved, false);
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
  ref.watch(appPrefsProvider);
  if (!AppPrefs.read(P.hideShelved, false)) return null;
  final books = ref.watch(libraryProvider).books;
  return books.containsKey;
}

class _RankingTab extends ConsumerStatefulWidget {
  const _RankingTab();

  @override
  ConsumerState<_RankingTab> createState() => _RankingTabState();
}

class _RankingTabState extends ConsumerState<_RankingTab> with AutomaticKeepAliveClientMixin {
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
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final api = ref.watch(apiProvider);
    final param = rankParam(_kind, _period);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _Chips(options: [for (final k in rankKinds) k.$2], value: _kind, label: (k) => rankKinds.firstWhere((e) => e.$2 == k).$1, trailing: _hideShelfChip(context, ref), onChanged: (k) => _set(kind: k)),
        // 日 / 周 / 月 / 总：一个小分段，只有点击、推荐有
        if (rankPeriodic.contains(_kind))
          Align(
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
        Expanded(
          child: PagedNovelGrid(key: ValueKey(param), hide: _hideShelved(ref), fetch: (page) => api.ranking(param, page)),
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

  /// 全部标签：盖住标签那排往下展开，每行 5 个，多了在里面滑
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
            constraints: const BoxConstraints(maxHeight: 200),
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 5,
              childAspectRatio: 2.1,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              children: [for (final t in categoryTags) Center(child: _Pill(t, selected: t == _tag, onTap: () => _pick(t)))],
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final api = ref.watch(apiProvider);
    return Stack(
      children: [
        Column(
          children: [
            _Chips(
              options: categoryTags,
              value: _tag,
              label: (e) => e,
              onChanged: _pick,
              trailing: _sideIcon(tooltip: hz(context, '全部标签'), icon: const Icon(Icons.expand_more), onPressed: () => setState(() => _open = true)),
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
              child: PagedNovelGrid(key: ValueKey((_tag, _sort)), hide: _hideShelved(ref), fetch: (page) => api.category(_tag, _sort.$2, page)),
            ),
          ],
        ),
        // 点面板外面收起
        if (_open) Positioned.fill(child: GestureDetector(onTap: () => setState(() => _open = false), child: const ColoredBox(color: Colors.black12))),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: AnimatedSize(duration: const Duration(milliseconds: 180), curve: Curves.easeOut, alignment: Alignment.topCenter, child: _open ? _panel() : const SizedBox(width: double.infinity)),
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

/// 和其他标签一样留着：左右切回来不用重新加载
class _CompletedTabState extends ConsumerState<_CompletedTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PagedNovelGrid(fetch: ref.watch(apiProvider).completed);
  }
}
