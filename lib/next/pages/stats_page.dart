import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../app_prefs.dart';
import '../cache.dart';
import '../history.dart';
import '../local_books.dart';
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../stats.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Vol, Volumes, volumeChangesProvider;
import '../widgets.dart';
import '../text.dart';

String _duration(int seconds) => ReadingStats.formatDuration(seconds);

/// 连续阅读天数：从今天往前数（今天还没读就从昨天开始数）
int readingStreak(Map<String, int> perDay, DateTime now) {
  var d = DateTime(now.year, now.month, now.day);
  if ((perDay[ReadingStats.dayKey(d)] ?? 0) == 0) d = DateTime(d.year, d.month, d.day - 1);
  var n = 0;
  while ((perDay[ReadingStats.dayKey(d)] ?? 0) > 0) {
    n++;
    d = DateTime(d.year, d.month, d.day - 1);
  }
  return n;
}

/// 读一章平均多少秒：只算读了一分钟以上的章（翻一下就过去的不算），不到两章算不准返回 null。
/// [chapters] 是每章各天的秒数（见 [ReadingStats.chapterSeconds]）。
int? secondsPerChapter(Iterable<Map<String, int>> chapters) {
  final totals = chapters.map((d) => d.values.fold(0, (a, b) => a + b)).where((s) => s >= 60).toList();
  return totals.length < 2 ? null : totals.fold(0, (a, b) => a + b) ~/ totals.length;
}

/// 每分钟读多少字：[samples] 是 (章节字数, 读这章用的秒数)，同样只算一分钟以上的，不到三章返回 null。
int? charsPerMinute(Iterable<(int, int)> samples) {
  final ok = samples.where((e) => e.$2 >= 60).toList();
  if (ok.length < 3) return null;
  return ok.fold(0, (a, e) => a + e.$1) * 60 ~/ ok.fold(0, (a, e) => a + e.$2);
}

/// 阅读目标完成度：[target] <= 0 或 [current] <= 0 返回 0%；未达标时向下取整至 0~99%，达标后为 100% 且 [reached] 为 true。
({double ratio, int percent, bool reached}) readingGoalProgress(int current, int target) {
  if (target <= 0 || current <= 0) return (ratio: 0.0, percent: 0, reached: false);
  final reached = current >= target;
  final ratio = (current / target).clamp(0.0, 1.0);
  final percent = reached ? 100 : (current * 100 ~/ target).clamp(0, 99);
  return (ratio: ratio, percent: percent, reached: reached);
}

/// 在读的一本：读到的那卷第几卷、读了几章 / 共几章，按读这本书的速度估计读完这卷还要多少秒（数据不够为 null）
typedef _Reading = ({String aid, String title, String img, String cid, int vol, int read, int total, int? eta});

/// 统计页昂贵聚合结果的记忆化快照：点击柱状图或热力图单日格子时直接复用，不再全表重算。
class _StatsSnapshot {
  const _StatsSnapshot({
    required this.perDay,
    required this.perBook,
    required this.chapters,
    required this.total,
    required this.today,
    required this.weekSum,
    required this.streak,
    required this.top,
    required this.topMeta,
    required this.reading,
    required this.doneYearCount,
    required this.perMonth,
    required this.maxMonth,
    required this.speed,
    required this.dayToBooks,
  });

  final Map<String, int> perDay;
  final Map<String, int> perBook;
  final int chapters;
  final int total;
  final int today;
  final int weekSum;
  final int streak;
  final List<MapEntry<String, int>> top;
  final Map<String, ({String title, String img, int days, int readCount})> topMeta;
  final List<_Reading> reading;
  final int doneYearCount;
  final List<int> perMonth;
  final int maxMonth;
  final int? speed;

  /// 日期（`yyyy-MM-dd`）→ {aid → 秒}，单次扫描生成，供柱状图与热力图按日 O(1) 查询。
  final Map<String, Map<String, int>> dayToBooks;

  List<MapEntry<String, int>> booksMatching(bool Function(String day) inDay) {
    final agg = <String, int>{};
    for (final e in dayToBooks.entries) {
      if (!inDay(e.key)) continue;
      for (final b in e.value.entries) {
        agg[b.key] = (agg[b.key] ?? 0) + b.value;
      }
    }
    return agg.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }
}

/// 阅读统计：今天 / 连续天数；周 / 月 / 年时长（点柱子看那天读了哪几本）；在读的书还要多久读完这卷；
/// 今年每月读完几卷；阅读日历；总计和阅读速度；读得最久的书。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  int _range = 0; // 0 周、1 月、2 年
  int? _picked; // 点中的那根柱子
  int _reloadEpoch = 0;
  (int, int, String, int)? _cacheKey;
  _StatsSnapshot? _snapshot;

  void _onStatsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ReadingStats.changes.addListener(_onStatsChanged);
  }

  @override
  void dispose() {
    ReadingStats.changes.removeListener(_onStatsChanged);
    super.dispose();
  }

  /// 柱状图的数据：(标签, 秒, 点中时显示的日期, 日期前缀)。年按自然月合计，前缀是 `yyyy-MM-`，日子的前缀就是整个日期。
  List<(String, int, String, String)> _bars(Map<String, int> perDay, DateTime now) {
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    if (_range == 2) {
      return [
        for (var i = 11; i >= 0; i--)
          () {
            final m = DateTime(now.year, now.month - i);
            final prefix = '${m.year}-${m.month.toString().padLeft(2, '0')}-';
            return ('${m.month}月', perDay.entries.where((e) => e.key.startsWith(prefix)).fold(0, (a, e) => a + e.value), '${m.year} 年 ${m.month} 月', prefix);
          }(),
      ];
    }
    final n = _range == 0 ? 7 : 30;
    return [
      for (var i = n - 1; i >= 0; i--)
        () {
          final d = DateTime(now.year, now.month, now.day - i);
          final label = _range == 0 ? week[d.weekday - 1] : (i % 5 == 0 ? '${d.month}/${d.day}' : '');
          return (label, perDay[ReadingStats.dayKey(d)] ?? 0, '${d.month}月${d.day}日 周${week[d.weekday - 1]}', ReadingStats.dayKey(d));
        }(),
    ];
  }

  /// 最近读的几本还没读完的书：读到的那卷（读完了就看下一卷）还剩几章、大概还要多久
  List<_Reading> _reading(Map<String, Map<String, Map<String, int>>> chapterSecsByBook, int? pace) {
    final out = <_Reading>[];
    final seen = <String>{};
    for (final h in ReadingHistory.all()) {
      if (out.length >= 4) break;
      if (!seen.add(h.aid)) continue;
      final vols = Volumes.of(h.aid);
      final cid = ReadingProgress.of(h.aid)?.cid ?? h.cid;
      var vi = vols.indexWhere((v) => v.cids.contains(cid));
      if (vi < 0) continue;
      final read = ReadState.readView(h.aid);
      int left(Vol v) => v.textCids.where((c) => !read.contains(c)).length;
      while (vi < vols.length && left(vols[vi]) == 0) {
        vi++;
      }
      if (vi >= vols.length) continue; // 全读完了
      final v = vols[vi];
      final bookCh = chapterSecsByBook[h.aid];
      final per = (bookCh == null ? null : secondsPerChapter(bookCh.values)) ?? pace;
      final info = ReadingStats.info(h.aid);
      out.add((
        aid: h.aid,
        title: info.title,
        img: info.img.isNotEmpty ? info.img : h.img,
        cid: v.cids.contains(cid) ? cid : v.cids.first,
        vol: vi,
        read: v.textCids.length - left(v),
        total: v.textCids.length,
        eta: per == null ? null : per * left(v),
      ));
    }
    return out;
  }

  _StatsSnapshot _computeSnapshot(DateTime now, int volVersion) {
    final todayKey = ReadingStats.dayKey(now);
    final key = (ReadingStats.changes.value, volVersion, todayKey, _reloadEpoch);
    if (_snapshot != null && _cacheKey == key) return _snapshot!;

    final perDay = ReadingStats.perDay();
    final perBook = ReadingStats.perBook();
    final chapters = ReadingStats.chapters;
    final total = perDay.values.fold(0, (a, b) => a + b);
    final today = perDay[todayKey] ?? 0;
    final weekSum = [for (var i = 0; i < 7; i++) perDay[ReadingStats.dayKey(DateTime(now.year, now.month, now.day - i))] ?? 0].fold(0, (a, b) => a + b);
    final streak = readingStreak(perDay, now);
    final top = perBook.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final topMeta = <String, ({String title, String img, int days, int readCount})>{
      for (final e in top.take(10))
        e.key: () {
          final info = ReadingStats.info(e.key);
          return (title: info.title, img: info.img, days: ReadingStats.bookDays(e.key).length, readCount: ReadState.readView(e.key).length);
        }(),
    };

    // 单次扫描各书章节时长：同时支撑阅读速度、在读预计耗时、柱状图与热力图按日书单
    final chapterSecsByBook = <String, Map<String, Map<String, int>>>{};
    final dayToBooks = <String, Map<String, int>>{};
    final speedSamples = <(int, int)>[];
    for (final aid in ReadingStats.chapterBooks()) {
      final ch = ReadingStats.chapterSeconds(aid);
      chapterSecsByBook[aid] = ch;
      final readSet = ReadState.readView(aid);
      for (final ce in ch.entries) {
        var chTotal = 0;
        for (final de in ce.value.entries) {
          chTotal += de.value;
          final byBook = dayToBooks.putIfAbsent(de.key, () => {});
          byBook[aid] = (byBook[aid] ?? 0) + de.value;
        }
        if (readSet.contains(ce.key)) {
          final n = isLocalAid(aid) ? LocalBooks.chapterLength(aid, ce.key) : ChapterCache.length(aid, ce.key);
          if (n != null) speedSamples.add((n, chTotal));
        }
      }
    }
    final pace = secondsPerChapter(chapterSecsByBook.values.expand((m) => m.values));
    final reading = _reading(chapterSecsByBook, pace);
    final doneYear = Volumes.allDone().where((e) => DateTime.fromMillisecondsSinceEpoch(e.$4).year == now.year).toList();
    final perMonth = List.filled(12, 0);
    for (final e in doneYear) {
      perMonth[DateTime.fromMillisecondsSinceEpoch(e.$4).month - 1]++;
    }
    final maxMonth = perMonth.fold(1, math.max);
    final speed = charsPerMinute(speedSamples);

    _cacheKey = key;
    return _snapshot = _StatsSnapshot(
      perDay: perDay,
      perBook: perBook,
      chapters: chapters,
      total: total,
      today: today,
      weekSum: weekSum,
      streak: streak,
      top: top,
      topMeta: topMeta,
      reading: reading,
      doneYearCount: doneYear.length,
      perMonth: perMonth,
      maxMonth: maxMonth,
      speed: speed,
      dayToBooks: dayToBooks,
    );
  }

  Future<void> _pickGoal({
    required String title,
    required String unit,
    required String prefKey,
    required int current,
    required List<int> presets,
    required int maxVal,
  }) async {
    final ctrl = TextEditingController(text: current > 0 && !presets.contains(current) ? '$current' : '');
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        String? err;
        return StatefulBuilder(
          builder: (ctx, setLocal) => Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.viewInsetsOf(ctx).bottom + 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in [0, ...presets])
                      ChoiceChip(
                        label: Text(v == 0 ? '关闭目标' : '$v $unit'),
                        selected: current == v,
                        showCheckmark: false,
                        selectedColor: scheme.primary.withValues(alpha: 0.14),
                        labelStyle: TextStyle(color: current == v ? scheme.primary : scheme.onSurface, fontWeight: current == v ? FontWeight.w600 : null),
                        side: BorderSide(color: current == v ? scheme.primary.withValues(alpha: 0.5) : scheme.outline),
                        onSelected: (_) => Navigator.pop(sheetCtx, v),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          label: Text('自定义（$unit）'),
                          hintText: '1 ~ $maxVal',
                          errorText: err,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () {
                        final v = int.tryParse(ctrl.text.trim());
                        if (v == null || v < 1 || v > maxVal) {
                          setLocal(() => err = '请输入 1 ~ $maxVal');
                          return;
                        }
                        Navigator.pop(sheetCtx, v);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (picked != null && mounted) {
      ref.read(appPrefsProvider.notifier).set(prefKey, picked);
    }
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final volVersion = ref.watch(volumeChangesProvider);
    final dailyGoal = ref.watch(appPref(P.statsDailyGoal, 0));
    final yearlyVolGoal = ref.watch(appPref(P.statsYearlyVolGoal, 0));
    final queue = ref.read(volumeCoverQueueProvider);
    final now = DateTime.now();
    final snap = _computeSnapshot(now, volVersion);
    final perDay = snap.perDay;
    final perBook = snap.perBook;
    final total = snap.total;
    final today = snap.today;
    final todayMins = today <= 0 ? 0 : (today + 59) ~/ 60;
    final dailyProg = readingGoalProgress(todayMins, dailyGoal);
    final weekSum = snap.weekSum;
    final streak = snap.streak;
    final top = snap.top;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    String cover(String aid, String img) => queue.bookCover(aid, img.isNotEmpty ? img : Wenku8Parser.coverUrl(aid));

    final cardRadius = (theme.cardTheme.shape as RoundedRectangleBorder?)?.borderRadius ?? BorderRadius.circular(16);
    Widget card(Widget child, {VoidCallback? onTap}) => Material(
      color: scheme.surfaceContainerLowest,
      borderRadius: cardRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );

    final bars = _bars(perDay, now);
    final maxBar = bars.fold(1, (a, b) => b.$2 > a ? b.$2 : a);
    final nonZero = bars.where((b) => b.$2 > 0);
    final avg = nonZero.isEmpty ? 0 : nonZero.fold(0, (a, b) => a + b.$2) ~/ nonZero.length;
    const chartH = 120.0;
    final labelH = math.max(20.0, MediaQuery.textScalerOf(context).scale(16));
    final picked = _picked != null && _picked! < bars.length ? bars[_picked!] : null;
    // 柱状图下面列出读了哪几本：点了柱子是那一天（那个月），没点是整段时间
    final from = bars.first.$4;
    final booksInRange = snap.booksMatching((d) => picked != null ? d.startsWith(picked.$4) : d.compareTo(from) >= 0);

    final reading = snap.reading;
    final volGoalProg = readingGoalProgress(snap.doneYearCount, yearlyVolGoal);
    final perMonth = snap.perMonth;
    final maxMonth = snap.maxMonth;
    final speed = snap.speed;
    void editDailyGoal() => _pickGoal(
      title: '每日阅读目标',
      unit: '分钟',
      prefKey: P.statsDailyGoal,
      current: dailyGoal,
      presets: const [15, 30, 45, 60, 90, 120],
      maxVal: 1440,
    );
    void editYearlyVolGoal() => _pickGoal(
      title: '年度完卷目标',
      unit: '卷',
      prefKey: P.statsYearlyVolGoal,
      current: yearlyVolGoal,
      presets: const [12, 24, 36, 50, 100],
      maxVal: 9999,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读统计'),
        actions: [
          if (total > 0 || snap.doneYearCount > 0)
            TextButton(
              onPressed: () => context.push(Routes.yearlyReport(now.year)),
              child: const Text('年度报告'),
            ),
          if (perBook.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _ManageStatsPage()));
                if (mounted) setState(() => _reloadEpoch++);
              },
              child: const Text('管理'),
            ),
        ],
      ),
      body: total == 0 && snap.chapters == 0
          ? const StatePanel(title: '还没有阅读数据', detail: '读几章之后这里会出现统计。')
          : contentWidth(ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // 今天 + 每日目标环 + 连续天数
                card(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('今天', style: muted),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: '$todayMins', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, color: scheme.primary)),
                                  TextSpan(text: ' 分钟', style: theme.textTheme.titleMedium),
                                ],
                              ),
                            ),
                            Text('近 7 天共 ${_duration(weekSum)}', style: muted),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: hz(context, '设置每日阅读目标'),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: editDailyGoal,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 54,
                                  height: 54,
                                  child: CustomPaint(
                                    painter: _GoalRingPainter(
                                      ratio: dailyGoal > 0 ? dailyProg.ratio : 0,
                                      trackColor: scheme.primary.withValues(alpha: 0.14),
                                      fillColor: dailyProg.reached ? const Color(0xFF34C759) : scheme.primary,
                                    ),
                                    child: Center(
                                      child: dailyGoal > 0
                                          ? Text(
                                              '${dailyProg.percent}%',
                                              style: theme.textTheme.labelMedium?.copyWith(
                                                fontWeight: FontWeight.w700,
                                                color: dailyProg.reached ? const Color(0xFF34C759) : scheme.primary,
                                              ),
                                            )
                                          : Icon(Icons.flag_outlined, size: 20, color: scheme.onSurfaceVariant),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(dailyGoal > 0 ? '$todayMins/$dailyGoal 分' : '设目标', style: muted),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        children: [
                          Icon(Icons.local_fire_department_rounded, color: streak > 0 ? const Color(0xFFFF9500) : scheme.outline, size: 30),
                          Text('$streak 天', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                          Text('连续阅读', style: muted),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 年度阅读报告入口卡片
                card(
                  onTap: () => context.push(Routes.yearlyReport(now.year)),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.auto_awesome_rounded, color: scheme.primary, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${now.year} 年度阅读报告', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text('年度时长、最爱作品与读者称号，支持生成长图分享', style: muted),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 柱状图
                card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('阅读时长', style: theme.textTheme.titleMedium)),
                          SegmentedButton<int>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            segments: const [ButtonSegment(value: 0, label: Text('周')), ButtonSegment(value: 1, label: Text('月')), ButtonSegment(value: 2, label: Text('年'))],
                            selected: {_range},
                            onSelectionChanged: (v) => setState(() {
                              _range = v.first;
                              _picked = null;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 点了柱子显示那一天 / 那个月读了多久，没点时显示平均
                      Text(
                        picked != null
                            ? '${picked.$3} · ${picked.$2 == 0 ? '没读' : _duration(picked.$2)}'
                            : (avg == 0 ? '这段时间还没读' : '有阅读的${_range == 2 ? '月份' : '日子'}平均 ${_duration(avg)}'),
                        style: picked == null ? muted : theme.textTheme.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: chartH + labelH,
                        child: LayoutBuilder(
                          builder: (context, c) {
                            void pickAt(double dx) {
                              if (bars.isEmpty || c.maxWidth <= 0) return;
                              final idx = (dx / c.maxWidth * bars.length).floor().clamp(0, bars.length - 1);
                              if (_picked != idx) setState(() => _picked = idx);
                            }

                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onHorizontalDragStart: (d) => pickAt(d.localPosition.dx),
                              onHorizontalDragUpdate: (d) => pickAt(d.localPosition.dx),
                              child: Stack(
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      for (final (i, (label, sec, fullDate, _)) in bars.indexed)
                                        Expanded(
                                          child: Semantics(
                                            button: true,
                                            selected: _picked == i,
                                            label: '$fullDate，${sec == 0 ? '未阅读' : _duration(sec)}',
                                            child: MouseRegion(
                                              cursor: SystemMouseCursors.click,
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                onTap: () => setState(() => _picked = _picked == i ? null : i),
                                                child: Padding(
                                                  padding: EdgeInsets.symmetric(horizontal: _range == 1 ? 1 : 4),
                                                  child: Column(
                                                    mainAxisAlignment: MainAxisAlignment.end,
                                                    children: [
                                                      AnimatedContainer(
                                                        duration: const Duration(milliseconds: 300),
                                                        curve: Curves.easeOutCubic,
                                                        height: math.max(2, chartH * sec / maxBar), // 最高的正好顶满，不能再加，否则超出 2 像素
                                                        decoration: BoxDecoration(
                                                          color: _picked != null
                                                              ? (_picked == i ? scheme.primary : scheme.primary.withValues(alpha: 0.25))
                                                              : (sec >= avg && avg > 0 ? scheme.primary : scheme.primary.withValues(alpha: 0.45)),
                                                          borderRadius: BorderRadius.circular(_range == 1 ? 2 : 5),
                                                        ),
                                                      ),
                                                      SizedBox(
                                                        height: labelH,
                                                        child: Center(
                                                          child: Text(
                                                            label,
                                                            maxLines: 1,
                                                            softWrap: false,
                                                            overflow: TextOverflow.visible,
                                                            style: theme.textTheme.labelSmall?.copyWith(color: _picked == i ? scheme.primary : scheme.onSurfaceVariant, fontWeight: _picked == i ? FontWeight.w700 : null),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  // 平均线
                                  if (avg > 0)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: labelH + chartH * avg / maxBar,
                                      child: IgnorePointer(child: Container(height: 1, color: scheme.onSurfaceVariant.withValues(alpha: 0.5))),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      if (booksInRange.isNotEmpty) ...[
                        const Divider(height: 24),
                        for (final e in booksInRange.take(5))
                          InkWell(
                            onTap: () => context.push(Routes.report(e.key)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Expanded(child: Text(ReadingStats.info(e.key).title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  const SizedBox(width: 12),
                                  Text(_duration(e.value), style: muted),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                if (reading.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在读', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        for (final r in reading)
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => context.push(Routes.reader(r.aid, r.cid)),
                            onLongPress: () => context.push(Routes.novel(r.aid)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  SizedBox(width: 40, height: 56, child: CoverImage(cover(r.aid, r.img), thumbnail: true, decodeSize: const Size(40, 56))),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                                        const SizedBox(height: 6),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(3),
                                          child: LinearProgressIndicator(
                                            value: r.total == 0 ? 0 : r.read / r.total,
                                            minHeight: 5,
                                            color: scheme.primary,
                                            backgroundColor: scheme.primary.withValues(alpha: 0.12),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '第 ${r.vol + 1} 卷 · 还剩 ${r.total - r.read} 章${r.eta == null ? '' : ' · 约 ${_duration(r.eta!)}'}',
                                          style: muted,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // 今年每月读完几卷，点进书籍墙
                card(
                  onTap: () => context.push(Routes.wall),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('今年读完的卷', style: theme.textTheme.titleMedium)),
                          Tooltip(
                            message: hz(context, '设置年度完卷目标'),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: editYearlyVolGoal,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  yearlyVolGoal > 0 ? '目标 $yearlyVolGoal 卷' : '设目标',
                                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${snap.doneYearCount} 卷', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.primary)),
                          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                        ],
                      ),
                      if (yearlyVolGoal > 0) ...[
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: editYearlyVolGoal,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: volGoalProg.ratio,
                                  minHeight: 6,
                                  color: volGoalProg.reached ? const Color(0xFF34C759) : scheme.primary,
                                  backgroundColor: scheme.primary.withValues(alpha: 0.12),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      volGoalProg.reached ? '已达成年度目标 · ${snap.doneYearCount} / $yearlyVolGoal 卷' : '年度目标进度 ${snap.doneYearCount} / $yearlyVolGoal 卷',
                                      style: muted,
                                    ),
                                  ),
                                  Text(
                                    '${volGoalProg.percent}%',
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: volGoalProg.reached ? const Color(0xFF34C759) : scheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var m = 0; m < 12; m++)
                            Expanded(
                              child: Semantics(
                                label: '${m + 1}月读完 ${perMonth[m]} 卷',
                                child: Column(
                                  children: [
                                    Text(perMonth[m] == 0 ? '' : '${perMonth[m]}', style: theme.textTheme.labelSmall),
                                    Container(
                                      height: math.max(2, 36.0 * perMonth[m] / maxMonth),
                                      margin: const EdgeInsets.symmetric(horizontal: 4),
                                      decoration: BoxDecoration(
                                        color: m > now.month - 1 ? scheme.onSurface.withValues(alpha: 0.06) : scheme.primary.withValues(alpha: perMonth[m] == 0 ? 0.15 : 0.8),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text('${m + 1}', style: muted),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 阅读日历
                card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('阅读日历', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      _Heatmap(perDay: perDay, now: now, dayToBooks: snap.dayToBooks),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  [
                    '累计 ${_duration(total)}',
                    '读过 ${perBook.length} 本',
                    '${snap.chapters} 章',
                    if (speed != null) '约 $speed 字/分钟',
                  ].join(' · '),
                  style: muted,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Text('读得最久', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final e in top.take(10))
                  Builder(
                    builder: (context) {
                      final meta = snap.topMeta[e.key]!;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => context.push(Routes.report(e.key)),
                        onLongPress: () => context.push(Routes.novel(e.key)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(width: 40, height: 56, child: CoverImage(cover(e.key, meta.img), thumbnail: true, decodeSize: const Size(40, 56))),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: Text(meta.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge)),
                                        Text(_duration(e.value), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    // 和读得最久的那本比的长度
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(value: e.value / top.first.value, minHeight: 5, color: scheme.primary, backgroundColor: scheme.primary.withValues(alpha: 0.12)),
                                    ),
                                    const SizedBox(height: 4),
                                    Text('${meta.days} 天 · ${meta.readCount} 章已读', style: muted),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            )),
    );
  }
}

/// 管理阅读记录：所有读过的书，时长长的在前，可以一本本删掉。
class _ManageStatsPage extends StatefulWidget {
  const _ManageStatsPage();

  @override
  State<_ManageStatsPage> createState() => _ManageStatsPageState();
}

class _ManageStatsPageState extends State<_ManageStatsPage> {
  Future<void> _delete(String aid, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阅读记录'),
        content: Text('删除《$title》的阅读记录？书架和阅读进度不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ReadingStats.deleteBook(aid);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final books = ReadingStats.perBook().entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
      appBar: AppBar(title: const Text('管理记录')),
      body: contentWidth(
        ListView.builder(
          itemCount: books.length,
          itemBuilder: (context, i) {
            final e = books[i];
            final title = ReadingStats.info(e.key).title;
            return ListTile(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_duration(e.value)),
              trailing: IconButton(tooltip: hz(context, '删除'), icon: const Icon(Icons.delete_outline), onPressed: () => _delete(e.key, title)),
            );
          },
        ),
      ),
    );
  }
}

/// GitHub 那样的阅读日历：一列一周（周一在上），越往右越近，颜色越深读得越久。格子数按宽度放得下多少周算；点击格子查看单日详情。
class _Heatmap extends StatefulWidget {
  const _Heatmap({required this.perDay, required this.now, required this.dayToBooks});

  final Map<String, int> perDay;
  final DateTime now;
  final Map<String, Map<String, int>> dayToBooks;

  @override
  State<_Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<_Heatmap> {
  static const _cell = 13.0, _gap = 3.0;
  DateTime? _picked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    Color colorOf(int sec) {
      final m = sec / 60;
      if (m <= 0) return scheme.onSurface.withValues(alpha: 0.06);
      return scheme.primary.withValues(alpha: m < 15 ? 0.3 : (m < 30 ? 0.5 : (m < 60 ? 0.75 : 1)));
    }

    final picked = _picked;
    final pickedKey = picked == null ? null : ReadingStats.dayKey(picked);
    final pickedSec = pickedKey == null ? 0 : (widget.perDay[pickedKey] ?? 0);
    final pickedBooks = pickedKey == null
        ? const <MapEntry<String, int>>[]
        : ((widget.dayToBooks[pickedKey] ?? const <String, int>{}).entries.toList()..sort((a, b) => b.value.compareTo(a.value)));

    return LayoutBuilder(
      builder: (context, c) {
        final weeks = ((c.maxWidth + _gap) / (_cell + _gap)).floor().clamp(4, 53);
        final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
        final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
        final start = DateTime(monday.year, monday.month, monday.day - 7 * (weeks - 1));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var w = 0; w < weeks; w++)
                  Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        () {
                          final day = DateTime(start.year, start.month, start.day + w * 7 + d);
                          final future = day.isAfter(today);
                          final sec = future ? 0 : (widget.perDay[ReadingStats.dayKey(day)] ?? 0);
                          final isPicked = !future && picked == day;
                          final label = '${day.year}年${day.month}月${day.day}日，${sec == 0 ? '未阅读' : _duration(sec)}';
                          final box = Padding(
                            padding: EdgeInsets.only(right: w < weeks - 1 ? _gap : 0, bottom: d < 6 ? _gap : 0),
                            child: Container(
                              width: _cell,
                              height: _cell,
                              decoration: BoxDecoration(
                                color: future ? Colors.transparent : colorOf(sec),
                                borderRadius: BorderRadius.circular(3),
                                border: isPicked
                                    ? Border.all(color: scheme.onSurface, width: 1.6)
                                    : (day == today ? Border.all(color: scheme.primary, width: 1.2) : null),
                              ),
                            ),
                          );
                          if (future) return box;
                          return Semantics(
                            button: true,
                            selected: isPicked,
                            label: label,
                            child: Tooltip(
                              message: label,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _picked = _picked == day ? null : day),
                                  child: box,
                                ),
                              ),
                            ),
                          );
                        }(),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${start.month}月${start.day}日', style: small),
                const Spacer(),
                Text('少 ', style: small),
                for (final s in const [0, 600, 1200, 2400, 3600]) Container(width: 10, height: 10, margin: const EdgeInsets.only(left: 2), decoration: BoxDecoration(color: colorOf(s), borderRadius: BorderRadius.circular(2))),
                Text(' 多', style: small),
              ],
            ),
            if (picked != null) ...[
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${picked.year}年${picked.month}月${picked.day}日 · ${pickedSec == 0 ? '当天未阅读' : _duration(pickedSec)}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: hz(context, '关闭单日详情'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _picked = null),
                  ),
                ],
              ),
              for (final e in pickedBooks.take(5))
                InkWell(
                  onTap: () => context.push(Routes.report(e.key)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(ReadingStats.info(e.key).title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 12),
                        Text(_duration(e.value), style: muted),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// 每日阅读目标环形进度绘制器。
class _GoalRingPainter extends CustomPainter {
  const _GoalRingPainter({required this.ratio, required this.trackColor, required this.fillColor});

  final double ratio;
  final Color trackColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, radius, track);
    if (ratio <= 0) return;
    final arc = Paint()
      ..color = fillColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * ratio.clamp(0.0, 1.0),
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_GoalRingPainter old) => old.ratio != ratio || old.trackColor != trackColor || old.fillColor != fillColor;
}
