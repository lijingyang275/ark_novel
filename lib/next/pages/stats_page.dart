import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../cache.dart';
import '../history.dart';
import '../progress.dart';
import '../read_state.dart';
import '../router.dart';
import '../stats.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../text.dart';

String _duration(int seconds) => seconds >= 3600 ? '${seconds ~/ 3600} 小时 ${(seconds % 3600) ~/ 60} 分' : '${(seconds / 60).ceil()} 分钟';

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

/// 在读的一本：读到的那卷第几卷、读了几章 / 共几章，按读这本书的速度估计读完这卷还要多少秒（数据不够为 null）
typedef _Reading = ({String aid, String title, String img, String cid, int vol, int read, int total, int? eta});

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
  List<_Reading> _reading() {
    final out = <_Reading>[];
    final seen = <String>{};
    final pace = secondsPerChapter(ReadingStats.chapterBooks().expand((a) => ReadingStats.chapterSeconds(a).values)); // 这本书数据不够时用整体的
    for (final h in ReadingHistory.all()) {
      if (out.length >= 4) break;
      if (!seen.add(h.aid)) continue;
      final vols = Volumes.of(h.aid);
      final cid = ReadingProgress.of(h.aid)?.cid ?? h.cid;
      var vi = vols.indexWhere((v) => v.cids.contains(cid));
      if (vi < 0) continue;
      final read = ReadState.read(h.aid);
      int left(Vol v) => v.textCids.where((c) => !read.contains(c)).length;
      while (vi < vols.length && left(vols[vi]) == 0) {
        vi++;
      }
      if (vi >= vols.length) continue; // 全读完了
      final v = vols[vi];
      final per = secondsPerChapter(ReadingStats.chapterSeconds(h.aid).values) ?? pace;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    ref.watch(volumeChangesProvider);
    final queue = ref.read(volumeCoverQueueProvider);
    final now = DateTime.now();
    final perDay = ReadingStats.perDay();
    final perBook = ReadingStats.perBook();
    final total = perDay.values.fold(0, (a, b) => a + b);
    final today = perDay[ReadingStats.dayKey(now)] ?? 0;
    final weekSum = [for (var i = 0; i < 7; i++) perDay[ReadingStats.dayKey(DateTime(now.year, now.month, now.day - i))] ?? 0].fold(0, (a, b) => a + b);
    final streak = readingStreak(perDay, now);
    final top = perBook.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    String cover(String aid, String img) => queue.bookCover(aid, img.isNotEmpty ? img : Wenku8Parser.coverUrl(aid));

    Widget card(Widget child, {VoidCallback? onTap}) => Material(
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
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
    final picked = _picked != null && _picked! < bars.length ? bars[_picked!] : null;
    // 柱状图下面列出读了哪几本：点了柱子是那一天（那个月），没点是整段时间
    final from = bars.first.$4;
    final booksInRange = ReadingStats.booksOn((d) => picked != null ? d.startsWith(picked.$4) : d.compareTo(from) >= 0).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final reading = _reading();
    final doneYear = Volumes.allDone().where((e) => DateTime.fromMillisecondsSinceEpoch(e.$4).year == now.year).toList();
    final perMonth = List.filled(12, 0);
    for (final e in doneYear) {
      perMonth[DateTime.fromMillisecondsSinceEpoch(e.$4).month - 1]++;
    }
    final maxMonth = perMonth.fold(1, math.max);
    final speed = charsPerMinute([
      for (final aid in ReadingStats.chapterBooks())
        for (final e in ReadingStats.chapterSeconds(aid).entries)
          if (ReadState.isRead(aid, e.key))
            if (ChapterCache.length(aid, e.key) case final n?) (n, e.value.values.fold(0, (a, b) => a + b)),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读统计'),
        actions: [
          if (perBook.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _ManageStatsPage()));
                if (mounted) setState(() {});
              },
              child: const Text('管理'),
            ),
        ],
      ),
      body: total == 0 && ReadingStats.chapters == 0
          ? const StatePanel(title: '还没有阅读数据', detail: '读几章之后这里会出现统计。')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // 今天
                card(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('今天', style: muted),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: '${(today / 60).ceil()}', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, color: scheme.primary)),
                                  TextSpan(text: ' 分钟', style: theme.textTheme.titleMedium),
                                ],
                              ),
                            ),
                            Text('近 7 天共 ${_duration(weekSum)}', style: muted),
                          ],
                        ),
                      ),
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
                        height: chartH + 20,
                        child: Stack(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final (i, (label, sec, _, _)) in bars.indexed)
                                  Expanded(
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
                                              height: 20,
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
                              ],
                            ),
                            // 平均线
                            if (avg > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 20 + chartH * avg / maxBar,
                                child: IgnorePointer(child: Container(height: 1, color: scheme.onSurfaceVariant.withValues(alpha: 0.5))),
                              ),
                          ],
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
                                  SizedBox(width: 40, height: 56, child: CoverImage(cover(r.aid, r.img))),
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
                          Text('${doneYear.length} 卷', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.primary)),
                          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var m = 0; m < 12; m++)
                            Expanded(
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
                      _Heatmap(perDay: perDay, now: now),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  [
                    '累计 ${_duration(total)}',
                    '读过 ${perBook.length} 本',
                    '${ReadingStats.chapters} 章',
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
                      final info = ReadingStats.info(e.key);
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => context.push(Routes.report(e.key)),
                        onLongPress: () => context.push(Routes.novel(e.key)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(width: 40, height: 56, child: CoverImage(cover(e.key, info.img))),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge)),
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
                                    Text('${ReadingStats.bookDays(e.key).length} 天 · ${ReadState.read(e.key).length} 章已读', style: muted),
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
            ),
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
      body: ListView.builder(
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
    );
  }
}

/// GitHub 那样的阅读日历：一列一周（周一在上），越往右越近，颜色越深读得越久。格子数按宽度放得下多少周算。
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.perDay, required this.now});

  final Map<String, int> perDay;
  final DateTime now;

  static const _cell = 13.0, _gap = 3.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    Color colorOf(int sec) {
      final m = sec / 60;
      if (m <= 0) return scheme.onSurface.withValues(alpha: 0.06);
      return scheme.primary.withValues(alpha: m < 15 ? 0.3 : (m < 30 ? 0.5 : (m < 60 ? 0.75 : 1)));
    }

    return LayoutBuilder(
      builder: (context, c) {
        final weeks = ((c.maxWidth + _gap) / (_cell + _gap)).floor().clamp(4, 53);
        final today = DateTime(now.year, now.month, now.day);
        final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
        final start = DateTime(monday.year, monday.month, monday.day - 7 * (weeks - 1));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var w = 0; w < weeks; w++)
                  Padding(
                    padding: EdgeInsets.only(right: w < weeks - 1 ? _gap : 0),
                    child: Column(
                      children: [
                        for (var d = 0; d < 7; d++)
                          () {
                            final day = DateTime(start.year, start.month, start.day + w * 7 + d);
                            return Padding(
                              padding: EdgeInsets.only(bottom: d < 6 ? _gap : 0),
                              child: Container(
                                width: _cell,
                                height: _cell,
                                decoration: BoxDecoration(
                                  color: day.isAfter(today) ? Colors.transparent : colorOf(perDay[ReadingStats.dayKey(day)] ?? 0),
                                  borderRadius: BorderRadius.circular(3),
                                  border: day == today ? Border.all(color: scheme.primary, width: 1.2) : null,
                                ),
                              ),
                            );
                          }(),
                      ],
                    ),
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
          ],
        );
      },
    );
  }
}
