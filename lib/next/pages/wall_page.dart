import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cover_color.dart';
import '../router.dart';
import '../stats.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../text.dart';

/// 书籍墙：读完的每一卷（参考豆瓣的年度记录），按年份分组，每年顶部是数量和每月柱状图。点一卷进它的阅读报告。
class WallPage extends ConsumerWidget {
  const WallPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(volumeChangesProvider);
    final theme = Theme.of(context);
    final all = Volumes.allDone();
    final years = <int, List<(String, int, Vol, int)>>{};
    for (final e in all) {
      years.putIfAbsent(DateTime.fromMillisecondsSinceEpoch(e.$4).year, () => []).add(e);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('书籍墙')),
      body: all.isEmpty
          ? const StatePanel(title: '还没有读完的卷', detail: '一卷的正文章节全部读完后会出现在这里。也可以在书籍详情页的目录里，点卷名旁边的圆圈标记读完。')
          : contentWidth(
              CustomScrollView(
                slivers: [
                  for (final MapEntry(key: year, value: list) in years.entries) ...[
                    SliverToBoxAdapter(child: _YearHeader(year: year, list: list)),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverLayoutBuilder(
                        builder: (context, c) => SliverGrid.builder(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: (c.crossAxisExtent / 180).floor().clamp(2, 5), mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.66),
                          itemCount: list.length,
                          itemBuilder: (context, i) => _VolumeTile(entry: list[i]),
                        ),
                      ),
                    ),
                  ],
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 32),
                      child: Center(child: Text('以前读完的卷没有记录日期，按最后一次阅读的时间算', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _YearHeader extends StatelessWidget {
  const _YearHeader({required this.year, required this.list});

  final int year;
  final List<(String, int, Vol, int)> list;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perMonth = List.filled(12, 0);
    for (final e in list) {
      perMonth[DateTime.fromMillisecondsSinceEpoch(e.$4).month - 1]++;
    }
    final most = perMonth.fold(1, (a, b) => a > b ? a : b);
    final books = list.map((e) => e.$1).toSet().length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$year', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${list.length}', style: theme.textTheme.displaySmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                      Text('读完的卷 · $books 本书', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var m = 0; m < 12; m++)
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 2),
                                    height: 44 * perMonth[m] / most + 2,
                                    decoration: BoxDecoration(color: perMonth[m] == 0 ? theme.colorScheme.outlineVariant : theme.colorScheme.primary, borderRadius: BorderRadius.circular(2)),
                                  ),
                                  const SizedBox(height: 4),
                                  Text('${m + 1}', style: theme.textTheme.labelSmall?.copyWith(fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
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
          ),
        ],
      ),
    );
  }
}

/// 一卷：卷封面，底部渐变上压卷名、书名、读完日期和星级。
class _VolumeTile extends ConsumerWidget {
  const _VolumeTile({required this.entry});

  final (String, int, Vol, int) entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (aid, index, v, at) = entry;
    final info = ReadingStats.info(aid);
    final cover = ref.read(volumeCoverQueueProvider).volCover(aid, v, info.img);
    ref.read(coverColorProvider(cover)); // 顺手把背景色算好存下，点进报告时直接用
    final stars = Volumes.rating(aid, v.title);
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => context.push(Routes.report(aid, vol: index)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CoverImage(cover),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(begin: Alignment(0, 0.1), end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, height: 1.25)),
                Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: Text('${d.month}月${d.day}日 读完', style: const TextStyle(color: Colors.white70, fontSize: 11))),
                    for (var i = 1; i <= stars; i++) const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFC53D)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
