import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../cache.dart';
import '../history.dart';
import '../progress.dart';
import '../library.dart';
import '../routes.dart';
import '../theme_doodle.dart';
import '../volume_covers.dart';
import '../volumes.dart' show volumeChangesProvider;
import '../widgets.dart';
import 'updates_page.dart';
import '../text.dart';

/// 阅读历史：按日期分组，显示读到哪一章和时间，点一下接着读。
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  Future<void> _restoreOne(HistoryEntry e, Object? prevTomb) async {
    final box = Hive.box('session');
    final tomb = Map<String, dynamic>.from((box.get('sync:tomb') as Map?) ?? const {});
    if (prevTomb == null) {
      tomb.remove('h:${e.aid}');
    } else {
      tomb['h:${e.aid}'] = prevTomb;
    }
    await box.put('sync:tomb', tomb);
    final rest = ((box.get('history2') as List?) ?? const []).cast<Map>().where((m) => m['aid'] != e.aid).toList();
    rest.add({'aid': e.aid, 'title': e.title, 'img': e.img, 'cid': e.cid, 'chapter': e.chapter, 'time': e.time.millisecondsSinceEpoch});
    rest.sort((a, b) => (b['time'] as int).compareTo(a['time'] as int));
    await box.put('history2', rest.take(300).toList());
  }

  Future<void> _deleteOne(HistoryEntry e) async {
    final prevTomb = (Hive.box('session').get('sync:tomb') as Map?)?['h:${e.aid}'];
    await ReadingHistory.remove(e.aid);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除《${LibraryStore.shown(e.aid, e.title)}》的历史记录'),
          action: SnackBarAction(
            label: hz(context, '撤销'),
            onPressed: () async {
              await _restoreOne(e, prevTomb);
              if (mounted) setState(() {});
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    ref.watch(volumeChangesProvider);
    final covers = ref.read(volumeCoverQueueProvider);
    final items = ReadingHistory.all();
    final rows = <_HistoryRow>[];
    String? day;
    for (final e in items) {
      final label = dayLabel(e.time);
      if (label != day) {
        day = label;
        rows.add(_HistoryDayRow(label));
      }
      rows.add(_HistoryEntryRow(e));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读历史'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('清空阅读历史？'),
                    content: const Text('仅清除最近阅读历史列表，不影响阅读进度、书架和阅读时长统计。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
                    ],
                  ),
                );
                if (ok == true) {
                  await ReadingHistory.clear();
                  if (mounted) setState(() {});
                }
              },
              child: const Text('清空'),
            ),
        ],
      ),
      body: contentWidth(
        items.isEmpty
            ? const StatePanel(title: '还没有阅读记录')
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, i) => switch (rows[i]) {
                  _HistoryDayRow(:final label) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary))),
                  _HistoryEntryRow(entry: final e) => Dismissible(
                    key: ValueKey(e.aid),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: scheme.error,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline, color: scheme.onError),
                          const SizedBox(width: 6),
                          Text('删除', style: TextStyle(color: scheme.onError)),
                        ],
                      ),
                    ),
                    onDismissed: (_) => _deleteOne(e),
                    child: ListTile(
                      leading: SizedBox(width: 40, height: 54, child: CoverImage(covers.bookCover(e.aid, e.img), aid: e.aid, thumbnail: true, decodeSize: const Size(40, 54))),
                      title: Text(LibraryStore.shown(e.aid, e.title), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${e.chapter} · ${hhmm(e.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.info_outline, size: 20), tooltip: hz(context, '详情'), onPressed: () => context.push(Routes.novel(e.aid))),
                          IconButton(icon: const Icon(Icons.close, size: 18), tooltip: hz(context, '删除记录'), onPressed: () => _deleteOne(e)),
                        ],
                      ),
                      onTap: () => context.push(Routes.reader(e.aid, e.cid)),
                    ),
                  ),
                },
              ),
      ),
    );
  }
}

sealed class _HistoryRow {
  const _HistoryRow();
}

final class _HistoryDayRow extends _HistoryRow {
  const _HistoryDayRow(this.label);

  final String label;
}

final class _HistoryEntryRow extends _HistoryRow {
  const _HistoryEntryRow(this.entry);

  final HistoryEntry entry;
}

/// 离线缓存：每本书一个进度条，点进去按章节管理；这里可以整本删除。
class CachePage extends ConsumerWidget {
  const CachePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadProvider);
    ref.watch(chapterCacheChangesProvider);
    ref.watch(volumeChangesProvider); // 卷封面取到了就换上
    final books = ChapterCache.books().entries.toList();
    final offlineBytes = books.fold<int>(0, (sum, e) => sum + ChapterCache.bytesOf(e.key));
    final autoCachedBooks = ChapterCache.cachedBooks().where((aid) => !ChapterCache.offline(aid)).length;
    final art = CharacterArt.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(books.isEmpty ? '离线缓存' : '离线缓存 · ${sizeText(offlineBytes)}'),
        actions: [
          TextButton(onPressed: () => context.push(Routes.storage), child: const Text('存储空间')),
        ],
      ),
      body: contentWidth(
        books.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  if (art != null)
                    Padding(padding: const EdgeInsets.only(top: 24, bottom: 12), child: Image.asset(art.empty, height: 140))
                  else
                    const SizedBox(height: 64),
                  Text('还没有缓存', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    autoCachedBooks > 0
                        ? '在书籍详情页点「缓存全本」后书籍会列在这里。\n当前另有 $autoCachedBooks 本阅读时自动缓存的章节（共 ${ChapterCache.totalLabel()}），可在「存储空间」按书清理。'
                        : '在书籍详情页点「缓存全本」或勾选章节下载后，断网也能完整阅读正文和插图。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  if (autoCachedBooks > 0) ...[
                    const SizedBox(height: 20),
                    Center(child: OutlinedButton(onPressed: () => context.push(Routes.storage), child: const Text('管理阅读自动缓存'))),
                  ],
                ],
              )
            : ListView(
                children: [
                  if (autoCachedBooks > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        '另有 $autoCachedBooks 本阅读自动缓存章节，点右上角「存储空间」可一并查看清理',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  for (final b in books)
                    Builder(
                      builder: (context) {
                        final t = tasks[b.key];
                        final done = t?.done ?? ChapterCache.count(b.key);
                        final total = b.value.$2;
                        return ListTile(
                          // 和书架一样的封面（第一卷的高清封面）；以前导入时没记下封面地址的按书号拼
                          leading: SizedBox(width: 44, height: 59, child: CoverImage(ref.read(volumeCoverQueueProvider).bookCover(b.key, b.value.$3.isNotEmpty ? b.value.$3 : Wenku8Parser.coverUrl(b.key)), aid: b.key, thumbnail: true, decodeSize: const Size(44, 59))),
                          title: Text(LibraryStore.shown(b.key, b.value.$1)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                              const SizedBox(height: 4),
                              Text('$done/$total 章 · ${ChapterCache.sizeLabel(b.key)}${t?.running ?? false ? ' · 下载中' : ''}'),
                            ],
                          ),
                          onTap: () {
                            // 点进去直接阅读：有进度从进度处接着读，否则从第一章
                            final cid = ReadingProgress.of(b.key)?.cid ?? b.value.$4;
                            context.push(cid.isEmpty ? Routes.cacheBook(b.key) : Routes.reader(b.key, cid));
                          },
                          onLongPress: () => context.push(Routes.cacheBook(b.key)),
                          trailing: (t?.running ?? false)
                              ? IconButton(icon: const Icon(Icons.pause_circle_outline), tooltip: hz(context, '暂停下载'), onPressed: () => ref.read(downloadProvider.notifier).cancel(b.key))
                              : PopupMenuButton<String>(
                                  onSelected: (v) async {
                                    if (v == 'manage') {
                                      context.push(Routes.cacheBook(b.key));
                                    } else {
                                      final title = LibraryStore.shown(b.key, b.value.$1);
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('删除离线缓存？'),
                                          content: Text('将删除《$title》已下载的整本离线缓存（${ChapterCache.sizeLabel(b.key)}），不影响书架和阅读进度。'),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      // 先停掉这本书的下载，再删；不重建整个下载管理器，别的书的下载不受影响
                                      ref.read(downloadProvider.notifier).forget(b.key);
                                      await ChapterCache.remove(b.key);
                                    }
                                  },
                                  itemBuilder: (_) => const [PopupMenuItem(value: 'manage', child: Text('管理章节')), PopupMenuItem(value: 'delete', child: Text('删除缓存'))],
                                ),
                        );
                      },
                    ),
                ],
              ),
      ),
    );
  }
}
