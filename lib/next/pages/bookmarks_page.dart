import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../library.dart' show LibraryStore;
import '../motion.dart';
import '../reader/reader_page.dart' show bookmarkPage;
import '../routes.dart';
import '../stats.dart';
import '../volume_covers.dart';
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

    Future<void> deleteMark(Bookmark b) async {
      await Bookmarks.remove(b);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(this.context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('已删除书签'),
            action: SnackBarAction(
              label: hz(this.context, '撤销'),
              onPressed: () async {
                await Bookmarks.toggle(b.aid, b.book, b.cid, b.chapter, b.offset, b.excerpt);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
    }

    Widget mark(Bookmark b) => Dismissible(
      key: ValueKey('${b.aid}${b.cid}${b.offset}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => deleteMark(b),
      background: Container(
        color: scheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.delete_outline, color: scheme.onError), const SizedBox(width: 6), Text('删除', style: TextStyle(color: scheme.onError))]),
      ),
      child: InkWell(
        // 位置随路由参数传过去，不覆盖真正的阅读进度
        onTap: () => context.push(Routes.reader(b.aid, b.cid, offset: b.offset), extra: b.offset),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
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
                      return AppCrossfade(
                        duration: AppMotion.fast,
                        child: Text(text, key: ValueKey(text), style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary, fontFeatures: const [FontFeature.tabularFigures()])),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: hz(context, '删除书签'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.delete_outline, size: 18, color: scheme.onSurfaceVariant),
                    onPressed: () => deleteMark(b),
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

    final cardRadius = (theme.cardTheme.shape as RoundedRectangleBorder?)?.borderRadius ?? BorderRadius.circular(16);
    final resolvedRadius = cardRadius.resolve(Directionality.of(context));
    final topRadius = BorderRadius.only(topLeft: resolvedRadius.topLeft, topRight: resolvedRadius.topRight);
    final bottomRadius = BorderRadius.only(bottomLeft: resolvedRadius.bottomLeft, bottomRight: resolvedRadius.bottomRight);
    // 拍平书籍头 + 单条书签 + 底部提示，交由 ListView.builder 按视口懒构建，避免一次性触发全部书签页码排版
    final rows = <_BmRow>[];
    for (final e in books.entries) {
      final img = ReadingStats.info(e.key).img;
      final coverUrl = queue.bookCover(e.key, img.isNotEmpty ? img : Wenku8Parser.coverUrl(e.key));
      rows.add(_BmHeaderRow(aid: e.key, book: LibraryStore.shown(e.key, e.value.first.book), count: e.value.length, coverUrl: coverUrl));
      for (var i = 0; i < e.value.length; i++) {
        rows.add(_BmEntryRow(bookmark: e.value[i], isLast: i == e.value.length - 1));
      }
    }
    if (rows.isNotEmpty) rows.add(const _BmFooterRow());

    return Scaffold(
      appBar: AppBar(title: const Text('书签')),
      body: all.isEmpty
          ? const StatePanel(title: '还没有书签', detail: '阅读时在页面上往下拉、点底部栏的书签，或选中文字后点"加书签"。')
          : contentWidth(
              ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: rows.length,
                itemBuilder: (context, i) => switch (rows[i]) {
                  _BmHeaderRow(:final aid, :final book, :final count, :final coverUrl) => DecoratedBox(
                    decoration: BoxDecoration(color: scheme.surfaceContainerLowest, borderRadius: topRadius),
                    child: Material(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: cardRadius,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => context.push(Routes.novel(aid)),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 36,
                                height: 50,
                                child: CoverImage(coverUrl, aid: aid, thumbnail: true, decodeSize: const Size(36, 50)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(book, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                                    Text('$count 个书签', style: muted),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _BmEntryRow(:final bookmark, :final isLast) => Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 12 : 0),
                    child: Material(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: isLast ? bottomRadius : BorderRadius.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Divider(height: 0.5, thickness: 0.5, indent: 16, color: scheme.outline),
                          mark(bookmark),
                        ],
                      ),
                    ),
                  ),
                  _BmFooterRow() => Text('左滑或点删除图标可移除书签', textAlign: TextAlign.center, style: muted),
                },
              ),
            ),
    );
  }
}

sealed class _BmRow {
  const _BmRow();
}

final class _BmHeaderRow extends _BmRow {
  const _BmHeaderRow({required this.aid, required this.book, required this.count, required this.coverUrl});

  final String aid;
  final String book;
  final int count;
  final String coverUrl;
}

final class _BmEntryRow extends _BmRow {
  const _BmEntryRow({required this.bookmark, required this.isLast});

  final Bookmark bookmark;
  final bool isLast;
}

final class _BmFooterRow extends _BmRow {
  const _BmFooterRow();
}
