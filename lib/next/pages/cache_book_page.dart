import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../cache.dart';
import '../export_book.dart';
import '../library.dart' show LibraryStore;
import '../motion.dart';
import '../routes.dart';
import '../widgets.dart';
import 'novel_page.dart';
import '../text.dart';

/// 单本书的缓存管理：按卷列出章节，标出已缓存的，可选中若干章下载或删除。
class CacheBookPage extends ConsumerStatefulWidget {
  const CacheBookPage({super.key, required this.aid});

  final String aid;

  @override
  ConsumerState<CacheBookPage> createState() => _CacheBookPageState();
}

class _CacheBookPageState extends ConsumerState<CacheBookPage> {
  final _picked = <String>{};
  final _expanded = <String>{};
  bool _expandedInit = false;
  List<CatVolume>? _cachedCatalogue;
  List<CatChapter> _cachedAll = const [];

  List<CatChapter> _allOf(List<CatVolume> catalogue) {
    if (identical(_cachedCatalogue, catalogue)) return _cachedAll;
    _cachedCatalogue = catalogue;
    _cachedAll = [for (final v in catalogue) ...v.chapters];
    if (!_expandedInit && catalogue.length == 1) {
      _expanded.add(catalogue.first.title);
      _expandedInit = true;
    }
    return _cachedAll;
  }

  @override
  void didUpdateWidget(CacheBookPage old) {
    super.didUpdateWidget(old);
    if (old.aid != widget.aid) {
      _picked.clear();
      _expanded.clear();
      _expandedInit = false;
      _cachedCatalogue = null;
      _cachedAll = const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final novel = ref.watch(novelProvider(widget.aid));
    final task = ref.watch(downloadProvider.select((m) => m[widget.aid]));
    final data = novel.value;
    final canExport = data != null && ExportBook.availableCount(widget.aid, data.catalogue) > 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: [
          if (canExport)
            TextButton.icon(
              onPressed: () => showExportBookDialog(context, ref, aid: widget.aid, novel: data, selectedCids: _picked.isEmpty ? null : {..._picked}),
              icon: const Icon(Icons.ios_share_outlined, size: 18),
              label: Text(_picked.isEmpty ? '导出' : '导出选中'),
            ),
        ],
      ),
      body: contentWidth(
        novel.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => StatePanel(title: '加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(novelProvider(widget.aid))),
          data: (data) {
            final all = _allOf(data.catalogue);
            final cached = ChapterCache.count(widget.aid);
            final running = task?.running ?? false;
            final theme = Theme.of(context);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(width: 54, height: 72, child: CoverImage(data.detail.imgUrl, aid: widget.aid, thumbnail: true, decodeSize: const Size(54, 72))),
                          const SizedBox(width: 12),
                          Expanded(child: Text(LibraryStore.shown(widget.aid, data.detail.title), style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      AppProgressBar(value: all.isEmpty ? 0 : cached / all.length, minHeight: 4, borderRadius: 2),
                      const SizedBox(height: 6),
                      Text('已缓存 $cached/${all.length} 章 · ${ChapterCache.sizeLabel(widget.aid)}${running ? ' · 下载中' : ''}${task?.error != null ? ' · ${task!.error}' : ''}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                    ],
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      for (final v in data.catalogue) ...[
                        SliverToBoxAdapter(
                          child: ListTile(
                            onTap: () => setState(() => _expanded.contains(v.title) ? _expanded.remove(v.title) : _expanded.add(v.title)),
                            title: Text(v.title),
                            subtitle: Text('${v.chapters.where((c) => ChapterCache.has(widget.aid, c.cid)).length}/${v.chapters.length} 章已缓存'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () => setState(() {
                                    final ids = v.chapters.map((c) => c.cid);
                                    ids.every(_picked.contains) ? _picked.removeAll(ids) : _picked.addAll(ids);
                                  }),
                                  child: const Text('选卷'),
                                ),
                                AnimatedRotation(
                                  turns: _expanded.contains(v.title) ? 0.5 : 0.0,
                                  duration: AppMotion.dur(context, AppMotion.fast),
                                  curve: AppMotion.snappy,
                                  child: Icon(Icons.expand_more, size: 20, color: theme.colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_expanded.contains(v.title))
                          SliverList.builder(
                            itemCount: v.chapters.length,
                            itemBuilder: (context, i) {
                              final c = v.chapters[i];
                              return ListTile(
                                dense: true,
                                leading: Checkbox(value: _picked.contains(c.cid), onChanged: (_) => setState(() => _picked.contains(c.cid) ? _picked.remove(c.cid) : _picked.add(c.cid))),
                                title: Text(c.title),
                                trailing: ChapterCache.has(widget.aid, c.cid) ? const Icon(Icons.download_for_offline_outlined, size: 18) : null,
                                onTap: () => context.push(Routes.reader(widget.aid, c.cid)),
                              );
                            },
                          ),
                      ],
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        TextButton(onPressed: () => setState(() => _picked.length == all.length ? _picked.clear() : _picked.addAll(all.map((c) => c.cid))), child: Text(_picked.length == all.length ? '取消全选' : '全选')),
                        const Spacer(),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: _picked.isEmpty
                              ? null
                              : () async {
                                  await ChapterCache.removeChapters(widget.aid, _picked);
                                  setState(_picked.clear);
                                },
                          child: const Text('删除选中'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: running
                              ? () => ref.read(downloadProvider.notifier).cancel(widget.aid)
                              : (_picked.isEmpty ? null : () => ref.read(downloadProvider.notifier).start(widget.aid, data.detail.title, all.where((c) => _picked.contains(c.cid)).toList(), total: all.length, img: data.detail.imgUrl, firstCid: all.first.cid)),
                          child: Text(running ? '暂停' : '下载选中'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
