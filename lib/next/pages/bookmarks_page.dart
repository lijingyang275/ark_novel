import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../library.dart' show LibraryStore;
import '../reader/reader_page.dart' show bookmarkPage;
import '../router.dart';
import '../stats.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'updates_page.dart';
import '../text.dart';

/// 所有书签，按书分组：每本书一张卡片，顶上是封面和书名，下面每条书签是章节、第几页、那一段原文和时间。
/// 点一下回到书签那一页，左滑删除。
class BookmarksPage extends ConsumerStatefulWidget {
  const BookmarksPage({super.key});

  @override
  ConsumerState<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends ConsumerState<BookmarksPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final queue = ref.read(volumeCoverQueueProvider);
    final all = Bookmarks.all();
    final books = <String, List<Bookmark>>{};
    for (final b in all) {
      books.putIfAbsent(b.aid, () => []).add(b);
    }
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    Widget mark(Bookmark b) => Dismissible(
      key: ValueKey('${b.aid}${b.cid}${b.offset}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) async {
        await Bookmarks.remove(b);
        setState(() {});
      },
      background: Container(
        color: scheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.delete_outline, color: Colors.white), SizedBox(width: 6), Text('删除', style: TextStyle(color: Colors.white))]),
      ),
      child: InkWell(
        // 位置随路由传过去，不覆盖真正的阅读进度
        onTap: () => context.push(Routes.reader(b.aid, b.cid), extra: b.offset),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bookmark, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(b.chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall)),
                  FutureBuilder(
                    future: bookmarkPage(ref, context, b.aid, b.cid, b.chapter, b.offset),
                    builder: (_, snap) {
                      final len = ChapterCache.length(b.aid, b.cid);
                      final text = switch (snap.data) {
                        (final p, final n) => '第 $p / $n 页',
                        _ => len == null || len == 0 ? '' : '本章 ${(b.offset * 100 ~/ len).clamp(0, 100)}%',
                      };
                      return Text(text, style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary));
                    },
                  ),
                ],
              ),
              if (b.excerpt.isNotEmpty) ...[
                const SizedBox(height: 8),
                // 书签那一页开头的原文，左边一道主题色竖线
                Container(
                  padding: const EdgeInsets.only(left: 10),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 3))),
                  child: Text(b.excerpt, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                ),
              ],
              const SizedBox(height: 6),
              Text('${dayLabel(b.time)} ${hhmm(b.time)}', style: muted),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('书签')),
      body: all.isEmpty
          ? const StatePanel(title: '还没有书签', detail: '阅读时在页面上往下拉、点底部栏的书签，或选中文字后点"加书签"。')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                for (final e in books.entries) ...[
                  Material(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          onTap: () => context.push(Routes.novel(e.key)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 36,
                                  height: 50,
                                  child: CoverImage(() {
                                    final img = ReadingStats.info(e.key).img;
                                    return queue.bookCover(e.key, img.isNotEmpty ? img : Wenku8Parser.coverUrl(e.key));
                                  }()),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(LibraryStore.shown(e.key, e.value.first.book), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                                      Text('${e.value.length} 个书签', style: muted),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        for (final b in e.value) ...[Divider(height: 0.5, thickness: 0.5, indent: 16, color: scheme.outline), mark(b)],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text('左滑删除书签', textAlign: TextAlign.center, style: muted),
              ],
            ),
    );
  }
}
