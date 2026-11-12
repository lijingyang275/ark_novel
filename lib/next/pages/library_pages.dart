import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../cache.dart';
import '../history.dart';
import '../progress.dart';
import '../library.dart';
import '../router.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'updates_page.dart';
import '../text.dart';

/// 阅读历史：按日期分组，显示读到哪一章和时间，点一下接着读。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ReadingHistory.all();
    final rows = <Widget>[];
    String? day;
    for (final e in items) {
      final label = dayLabel(e.time);
      if (label != day) {
        day = label;
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary))));
      }
      rows.add(
        Dismissible(
          key: ValueKey(e.aid),
          direction: DismissDirection.endToStart,
          background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_outline)),
          onDismissed: (_) async {
            await ReadingHistory.remove(e.aid);
            setState(() {});
          },
          child: ListTile(
            leading: SizedBox(width: 40, height: 54, child: CoverImage(e.img)),
            title: Text(LibraryStore.shown(e.aid, e.title), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${e.chapter} · ${hhmm(e.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(icon: const Icon(Icons.info_outline), tooltip: hz(context, '详情'), onPressed: () => context.push(Routes.novel(e.aid))),
            onTap: () => context.push(Routes.reader(e.aid, e.cid)),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读历史'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                await ReadingHistory.clear();
                setState(() {});
              },
              child: const Text('清空'),
            ),
        ],
      ),
      body: items.isEmpty ? const StatePanel(title: '还没有阅读记录') : ListView(children: rows),
    );
  }
}

/// 离线缓存：每本书一个进度条，点进去按章节管理；这里可以整本删除。
class CachePage extends ConsumerWidget {
  const CachePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadProvider);
    ref.watch(volumeChangesProvider); // 卷封面取到了就换上
    final books = ChapterCache.books().entries.toList();
    return Scaffold(
      appBar: AppBar(title: Text('离线缓存 · 共 ${ChapterCache.totalLabel()}')),
      body: books.isEmpty
          ? const StatePanel(title: '还没有缓存', detail: '在书籍详情页点"缓存"，可以整本或只缓存选中的章节。读过的章节也会自动存下来（占用见上方）。')
          : ListView(
              children: [
                for (final b in books)
                  Builder(
                    builder: (context) {
                      final t = tasks[b.key];
                      final done = t?.done ?? ChapterCache.count(b.key);
                      final total = b.value.$2;
                      return ListTile(
                        // 和书架一样的封面（第一卷的高清封面）；以前导入时没记下封面地址的按书号拼
                        leading: SizedBox(width: 44, height: 59, child: CoverImage(ref.read(volumeCoverQueueProvider).bookCover(b.key, b.value.$3.isNotEmpty ? b.value.$3 : Wenku8Parser.coverUrl(b.key)))),
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
                            ? IconButton(icon: const Icon(Icons.pause_circle_outline), onPressed: () => ref.read(downloadProvider.notifier).cancel(b.key))
                            : PopupMenuButton<String>(
                                onSelected: (v) async {
                                  if (v == 'manage') {
                                    context.push(Routes.cacheBook(b.key));
                                  } else {
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
    );
  }
}
