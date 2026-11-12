import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import '../cache.dart';
import '../image_cache.dart';
import '../router.dart';
import '../stats.dart';
import '../x_list.dart';
import '../text.dart';

/// 存储空间：各部分占多少、每本书的章节缓存多大；可以一键清掉读过的章节。网页预览不进这页。
class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});

  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  late Future<List<(String, int)>> _sizes = _measure();

  /// Hive 的数据文件都在同一个目录：正文、网页备份单列，其余算"其他数据"
  Future<List<(String, int)>> _measure() async {
    var text = 0, pages = 0, other = 0;
    await for (final f in File(Hive.box('session').path!).parent.list()) {
      if (f is! File || !f.path.endsWith('.hive')) continue;
      final n = await f.length();
      switch (p.basename(f.path)) {
        case 'chapters.hive':
          text += n;
        case 'pages.hive':
          pages += n;
        default:
          other += n;
      }
    }
    final images = await ref.read(imageStoreProvider).diskBytes();
    return [('章节正文', text), ('图片', images), ('网页备份', pages), ('其他数据', other)];
  }

  void _refresh() => setState(() => _sizes = _measure());

  Future<bool> _ask(String title, String content) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除'))],
        ),
      ) ==
      true;

  Future<void> _clearRead() async {
    if (!await _ask('清除已读章节？', '所有书里读过的章节都会删掉，包括离线缓存的书；再读时重新下载。')) return;
    final n = await ChapterCache.clearRead();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已清除 $n 章')));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final books = ChapterCache.cachedBooks().toList()..sort((a, b) => ChapterCache.bytesOf(b).compareTo(ChapterCache.bytesOf(a)));
    return Scaffold(
      appBar: AppBar(title: const Text('存储空间'), actions: [TextButton(onPressed: books.isEmpty ? null : _clearRead, child: const Text('清除已读章节'))]),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const XGroupTitle('占用'),
          FutureBuilder<List<(String, int)>>(
            future: _sizes,
            builder: (context, snap) => Column(
              children: [
                for (final (name, n) in snap.data ?? const <(String, int)>[]) XTile(title: name, trailing: Text(sizeText(n), style: TextStyle(color: scheme.onSurfaceVariant))),
                if (!snap.hasData) const XTile(title: '正在计算…'),
              ],
            ),
          ),
          if (books.isNotEmpty) ...[
            const XDivider(),
            const XGroupTitle('章节缓存'),
            for (final aid in books)
              XTile(
                title: ReadingStats.info(aid).title,
                subtitle: '${ChapterCache.count(aid)} 章 · ${ChapterCache.sizeLabel(aid)}',
                onTap: () => context.push(Routes.cacheBook(aid)).then((_) => mounted ? _refresh() : null),
                trailing: IconButton(
                  tooltip: hz(context, '删除缓存'),
                  icon: Icon(Icons.delete_outline, color: scheme.onSurfaceVariant),
                  onPressed: () async {
                    if (!await _ask('删除这本书的缓存？', '再读时重新下载。')) return;
                    if (!mounted) return;
                    ref.read(downloadProvider.notifier).forget(aid); // 正在下载的先停掉
                    await ChapterCache.remove(aid);
                    if (mounted) _refresh();
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}
