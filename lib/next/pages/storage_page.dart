import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../cache.dart';
import '../image_cache.dart';
import '../routes.dart';
import '../stats.dart';
import '../text.dart';
import '../widgets.dart';
import '../x_list.dart';

/// 存储空间：各部分占多少、每本书的章节缓存多大；可以一键清掉读过的章节。网页预览不进这页。
class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});

  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  late Future<List<(String, int)>> _sizes = _measure();

  static const _customResourceDirs = ['font', 'reader_bg', 'char_avatar', 'avatar'];

  Future<int> _dirBytes(Directory dir) async {
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) n += await entity.length();
    }
    return n;
  }

  /// Hive 的数据文件都在同一个目录：正文、网页备份单列，其余算"其他数据"；同时统计自定义资源目录。
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

    var customBytes = 0;
    try {
      final support = await getApplicationSupportDirectory();
      for (final sub in _customResourceDirs) {
        customBytes += await _dirBytes(Directory(p.join(support.path, sub)));
      }
    } catch (_) {}

    final images = await ref.read(imageStoreProvider).diskBytes();

    return [
      ('章节正文', text),
      ('图片', images),
      if (customBytes > 0) ('字体与自定义资源', customBytes),
      ('网页备份', pages),
      ('其他数据', other),
    ];
  }

  void _refresh() => setState(() {
    _sizes = _measure();
  });

  Future<bool> _ask(String title, String content) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
          ],
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
    final cachedIds = ChapterCache.cachedBooks().toList();
    final bytesByBook = {for (final aid in cachedIds) aid: ChapterCache.bytesOf(aid)};
    final books = cachedIds..sort((a, b) => bytesByBook[b]!.compareTo(bytesByBook[a]!));
    return Scaffold(
      appBar: AppBar(title: const Text('存储空间'), actions: [TextButton(onPressed: books.isEmpty ? null : _clearRead, child: const Text('清除已读章节'))]),
      body: contentWidth(
        ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const XGroupTitle('占用'),
            FutureBuilder<List<(String, int)>>(
              future: _sizes,
              builder: (context, snap) => Column(
                children: [
                  for (final (name, n) in snap.data ?? const <(String, int)>[])
                    XTile(
                      title: name,
                      subtitle: name == '网页备份' && n > 0 ? '离线兜底用的详情与目录页面，点此可清除' : null,
                      trailing: Text(sizeText(n), style: TextStyle(color: scheme.onSurfaceVariant)),
                      onTap: name == '网页备份' && n > 0
                          ? () async {
                              if (!await _ask('清除网页备份？', '清除后断网时将无法打开未缓存过的书籍详情与目录，联网后会自动重新保存。')) return;
                              await PageStore.clear();
                              if (mounted) _refresh();
                            }
                          : null,
                    ),
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
                  subtitle: '${ChapterCache.count(aid)} 章 · ${sizeText(bytesByBook[aid]!)}',
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
      ),
    );
  }
}
