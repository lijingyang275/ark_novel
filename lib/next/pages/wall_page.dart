import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../env.dart';
import '../motion.dart';
import '../routes.dart';
import '../stats.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Vol, Volumes, volumeChangeForProvider, volumeMetaChangesProvider;
import '../widgets.dart';
import '../text.dart';

/// 书籍墙：读完的每一卷（参考豆瓣的年度记录），按年份分组，每年顶部是数量和每月柱状图。点一卷进它的阅读报告。
/// 整页只在已读完卷列表（`vdone:*` / `vols:*`）实际变化时重建；单本书后台抓到封面或改评分只刷新该书的 [_VolumeTile]。
class WallPage extends ConsumerStatefulWidget {
  const WallPage({super.key});

  @override
  ConsumerState<WallPage> createState() => _WallPageState();
}

class _WallPageState extends ConsumerState<WallPage> {
  Map<String, Map<String, int>> _doneRefs = const {};
  Map<String, List<Vol>> _volRefs = const {};
  List<(String, int, Vol, int)> _all = const [];
  Map<int, List<(String, int, Vol, int)>> _years = const {};
  Map<String, ({String title, String author, String img})> _infos = const {};

  @override
  void initState() {
    super.initState();
    _rebuildData();
  }

  (Map<String, Map<String, int>>, Map<String, List<Vol>>) _snapshotDoneRefs() {
    if (!Hive.isBoxOpen('session')) return (const {}, const {});
    final box = Hive.box('session');
    final done = <String, Map<String, int>>{};
    final vols = <String, List<Vol>>{};
    for (final k in box.keys) {
      if (k is String && k.startsWith('vdone:')) {
        final aid = k.substring(6);
        done[aid] = Volumes.done(aid);
        vols[aid] = Volumes.of(aid);
      }
    }
    return (done, vols);
  }

  bool _sameRefs(Map<String, Map<String, int>> nextDone, Map<String, List<Vol>> nextVols) {
    if (nextDone.length != _doneRefs.length || nextVols.length != _volRefs.length) return false;
    for (final e in nextDone.entries) {
      if (!identical(_doneRefs[e.key], e.value)) return false;
      if (!identical(_volRefs[e.key], nextVols[e.key])) return false;
    }
    return true;
  }

  void _rebuildData() {
    final (doneRefs, volRefs) = _snapshotDoneRefs();
    _doneRefs = doneRefs;
    _volRefs = volRefs;
    final all = Volumes.allDone();
    final years = <int, List<(String, int, Vol, int)>>{};
    final infos = <String, ({String title, String author, String img})>{};
    for (final e in all) {
      years.putIfAbsent(DateTime.fromMillisecondsSinceEpoch(e.$4).year, () => []).add(e);
      infos.putIfAbsent(e.$1, () => ReadingStats.info(e.$1));
    }
    _all = all;
    _years = years;
    _infos = infos;
  }

  @override
  Widget build(BuildContext context) {
    // 仅订阅卷完读/结构变更，避免后台单张封面下载触发整墙检查与重建
    ref.listen<int>(volumeMetaChangesProvider, (_, _) {
      final (nextDone, nextVols) = _snapshotDoneRefs();
      if (!_sameRefs(nextDone, nextVols) && mounted) {
        setState(_rebuildData);
      }
    });
    final theme = Theme.of(context);
    final all = _all;
    final years = _years;
    final infos = _infos;

    return Scaffold(
      appBar: AppBar(title: const Text('书籍墙')),
      body: all.isEmpty
          ? const StatePanel(title: '还没有读完的卷', detail: '一卷的正文章节全部读完后会出现在这里。也可以在书籍详情页的目录里，点卷名旁边的圆圈标记读完。')
          : contentWidth(
              CustomScrollView(
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.8),
                slivers: [
                  for (final MapEntry(key: year, value: list) in years.entries) ...[
                    SliverToBoxAdapter(child: _YearHeader(year: year, list: list)),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverLayoutBuilder(
                        builder: (context, c) {
                          final cols = (c.crossAxisExtent / 180).floor().clamp(2, 5);
                          final tileW = (c.crossAxisExtent - 12 * (cols - 1)) / cols;
                          final tileSize = Size(tileW, tileW / 0.66);
                          return SliverGrid.builder(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.66),
                            itemCount: list.length,
                            itemBuilder: (context, i) => _VolumeTile(entry: list[i], info: infos[list[i].$1]!, decodeSize: tileSize),
                          );
                        },
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var m = 0; m < 12; m++)
                          Expanded(
                            child: Semantics(
                              label: '${m + 1}月读完 ${perMonth[m]} 卷',
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  SizedBox(
                                    height: 46,
                                    child: Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 2),
                                        height: 44 * perMonth[m] / most + 2,
                                        decoration: BoxDecoration(color: perMonth[m] == 0 ? theme.colorScheme.outlineVariant : theme.colorScheme.primary, borderRadius: BorderRadius.circular(2)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text('${m + 1}', maxLines: 1, softWrap: false, style: theme.textTheme.labelSmall?.copyWith(fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
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
    );
  }
}

/// 一卷：卷封面，底部渐变上压卷名、书名、读完日期和星级。
class _VolumeTile extends ConsumerWidget {
  const _VolumeTile({required this.entry, required this.info, required this.decodeSize});

  final (String, int, Vol, int) entry;
  final ({String title, String author, String img}) info;
  final Size decodeSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (aid, index, v, at) = entry;
    // 按书号细粒度订阅卷封面与评分变化，单张封面下载完成只刷新对应项
    ref.watch(volumeChangeForProvider(aid));
    final cover = ref.read(volumeCoverQueueProvider).volCover(aid, v, info.img);
    final stars = Volumes.rating(aid, v.title);
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    return AppPressScale(
      scale: 0.968,
      hoverScale: isDesktop ? 1.015 : 1.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.push(Routes.report(aid, vol: index)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(cover, thumbnail: true, decodeSize: decodeSize),
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
      ),
    );
  }
}
