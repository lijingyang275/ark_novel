part of '../bookshelf_page.dart';

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

  /// 0 网格 1 紧凑网格 2 列表 3 卷册（一本书画成一摞卷） 4 立体 5 书脊（竖插书脊、当前书 3D 抽出展示封面）
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
      .where((b) => _tri(o.unread, () => _unread(b.aid) > 0) && _tri(o.started, () => _started(b.aid)) && _tri(o.cached, () => ChapterCache.count(b.aid) > 0) && _tri(o.bookmarked, () => markedAids.contains(b.aid)) && _tri(o.completed, () => b.done))
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
      onTap: () {
        HapticFeedback.selectionClick();
        _set(apply((v + 1) % 3));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            AppIconSwap(child: Icon(icon, key: ValueKey(v), color: color)),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: TextStyle(fontSize: 15.5, color: scheme.onSurface))),
            AppCollapse(
              visible: v == 2,
              axis: Axis.horizontal,
              duration: AppMotion.fast,
              child: Text('不满足', style: TextStyle(fontSize: 13, color: scheme.error)),
            ),
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
              AppCollapse(
                visible: o.filtering,
                axis: Axis.horizontal,
                duration: AppMotion.fast,
                child: TextButton(onPressed: () => _set(o.copyWith(unread: 0, started: 0, cached: 0, bookmarked: 0, completed: 0)), child: const Text('清除筛选')),
              ),
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
              HapticFeedback.selectionClick();
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
                        AnimatedDefaultTextStyle(
                          duration: AppMotion.dur(context, AppMotion.fast),
                          curve: AppMotion.curve,
                          style: TextStyle(
                            fontSize: 15.5,
                            color: o.sort == s ? scheme.primary : scheme.onSurface,
                            fontWeight: o.sort == s ? FontWeight.w600 : FontWeight.w400,
                          ),
                          child: Text(s.label),
                        ),
                        if (s == ShelfSort.custom)
                          Text('自动切换为列表以便拖动排序', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  AppReveal(
                    visible: o.sort == s,
                    offset: Offset.zero,
                    beginScale: 0.72,
                    duration: AppMotion.fast,
                    child: switch (s) {
                      ShelfSort.random => Icon(Icons.shuffle, size: 20, color: scheme.primary),
                      ShelfSort.custom => Icon(Icons.check, size: 20, color: scheme.primary),
                      _ => AnimatedRotation(
                          turns: o.reverse ? 0.5 : 0.0,
                          duration: AppMotion.dur(context, AppMotion.fast),
                          curve: AppMotion.snappy,
                          child: Icon(Icons.arrow_downward, size: 20, color: scheme.primary),
                        ),
                    },
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
        XChips<int>(title: '显示方式', value: o.display, options: const {0: '网格', 1: '紧凑', 2: '列表', 3: '卷册', 4: '立体', 5: '书脊'}, onChanged: (v) => _set(o.copyWith(display: v))),
        // 就是设置里的书架列数（竖屏、横屏分开记），这里放常用的几种；设置里选了别的也列出来
        AppCollapse(
          visible: o.display != 2 && o.display != 4 && o.display != 5,
          child: XSegments<int>(
            title: '每行几本',
            value: cols,
            options: {0: '自动', 3: '3 本', 4: '4 本', if (cols != 0 && cols != 3 && cols != 4) cols: '$cols 本'},
            onChanged: (v) => prefs.set(colsKey, v),
          ),
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
    final resumeBar = ref.watch(appPref(P.resumeBar, false));
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
