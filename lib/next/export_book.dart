import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List, compute, kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/cat_volume.dart';
import '../models/content.dart';
import 'cache.dart';
import 'data.dart' show NovelPage;
import 'epub_codec.dart';
import 'image_cache.dart';
import 'library.dart' show LibraryStore;
import 'text.dart';
import 'volume_covers.dart';

enum ExportFormat { epub, txt }

typedef ExportResult = ({Uint8List bytes, String fileName, String mimeType, int chapterCount, int imageCount});
typedef ExportFileResult = ({String filePath, String fileName, String mimeType, int chapterCount, int imageCount});

Uint8List _encodeInIsolate(
  ({
    ExportFormat format,
    String title,
    String author,
    String description,
    Uint8List? coverBytes,
    List<EpubVolumeData> volumes,
  })
  args,
) {
  if (args.format == ExportFormat.epub) {
    return EpubBuilder.build(
      title: args.title,
      author: args.author,
      description: args.description,
      coverBytes: args.coverBytes,
      volumes: args.volumes,
    );
  }
  return TxtBuilder.build(
    title: args.title,
    author: args.author,
    description: args.description,
    volumes: args.volumes,
  );
}

Future<void> _encodeToFileInIsolate(
  ({
    ExportFormat format,
    String outputPath,
    String title,
    String author,
    String description,
    String? coverPath,
    Uint8List? coverBytes,
    List<EpubVolumeData> volumes,
  })
  args,
) {
  if (args.format == ExportFormat.epub) {
    return EpubBuilder.buildToFile(
      args.outputPath,
      title: args.title,
      author: args.author,
      description: args.description,
      coverPath: args.coverPath,
      coverBytes: args.coverBytes,
      volumes: args.volumes,
    );
  }
  return TxtBuilder.buildToFile(
    args.outputPath,
    title: args.title,
    author: args.author,
    description: args.description,
    volumes: args.volumes,
  );
}

Future<void> _copyFileStreamed(String srcPath, String destPath) async {
  final sink = File(destPath).openWrite();
  try {
    await File(srcPath).openRead().pipe(sink);
  } catch (_) {
    try {
      await sink.close();
    } catch (_) {}
    rethrow;
  }
}

Future<void> _deleteQuietly(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

/// 导出已缓存书籍为 EPUB 或 TXT。
class ExportBook {
  ExportBook._();

  /// 返回该书当前可供导出的已缓存章节数。
  static int availableCount(String aid, List<CatVolume> catalogue, {Set<String>? onlyCids}) {
    var count = 0;
    for (final v in catalogue) {
      for (final c in v.chapters) {
        if (onlyCids != null && !onlyCids.contains(c.cid)) continue;
        if (ChapterCache.has(aid, c.cid)) count++;
      }
    }
    return count;
  }

  static String sanitizeFileName(String raw, {String fallback = 'book'}) {
    var clean = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_').trim();
    clean = clean.replaceAll(RegExp(r'\.+$'), '').trim();
    if (clean.isEmpty) return fallback;
    return clean.length > 80 ? clean.substring(0, 80).trim() : clean;
  }

  /// 与 [ImageStore] 保持一致的规范 URL 磁盘文件名计算（双 32 位 FNV-1a）。
  static String _imageCacheFileName(String normUrl) {
    final bytes = utf8.encode(normUrl);
    String hash(int seed) {
      var h = seed;
      for (final b in bytes) {
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
      }
      return h.toRadixString(16).padLeft(8, '0');
    }

    return hash(0x811c9dc5) + hash(0x9747b28c);
  }

  static String _normImageUrl(String rawUrl) => splitCrop(rawUrl).url.replaceFirst('http://', 'https://');

  /// 优先返回本机已缓存图片的磁盘路径（零字节读入主线程内存、不触发联网）；
  /// 仅当磁盘无文件且内存 LRU 命中或测试桩覆写 `cached` 时回退内存字节。
  static Future<({String? path, Uint8List? bytes})?> _resolveCachedImage(
    ImageStore imageStore,
    Directory? imgCacheDir,
    String rawUrl,
  ) async {
    if (rawUrl.isEmpty) return null;
    final norm = _normImageUrl(rawUrl);
    if (!kIsWeb && imgCacheDir != null) {
      final file = File(p.join(imgCacheDir.path, _imageCacheFileName(norm)));
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file && stat.size > 0) {
        return (path: file.path, bytes: null);
      }
    }
    final mem = imageStore.peek(norm);
    if (mem != null && mem.isNotEmpty) {
      return (path: null, bytes: mem);
    }
    if (imageStore.runtimeType != ImageStore) {
      final fallback = await imageStore.cached(rawUrl);
      if (fallback != null && fallback.isNotEmpty) {
        return (path: null, bytes: fallback);
      }
    }
    return null;
  }

  /// 原生端流式导出：主 Isolate 仅收集章节正文与本地图片磁盘路径，
  /// 在后台 Isolate 中通过 `ZipFileEncoder` / 流式文件写入直接输出到目标路径（默认临时目录），避免百兆级 OOM。
  static Future<ExportFileResult> buildToFile({
    required String aid,
    required NovelPage novel,
    required ExportFormat format,
    required ImageStore imageStore,
    String? outputPath,
    String? coverUrl,
    Set<String>? onlyCids,
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final shownTitle = LibraryStore.shown(aid, novel.detail.title);
    final total = availableCount(aid, novel.catalogue, onlyCids: onlyCids);
    if (total == 0) {
      throw const FormatException('所选范围内没有可导出的已缓存章节');
    }

    onProgress?.call('正在准备封面…', 0);
    final Directory? imgCacheDir = (!kIsWeb && format == ExportFormat.epub)
        ? Directory(p.join((await getApplicationSupportDirectory()).path, 'imgcache'))
        : null;

    String? coverPath;
    Uint8List? coverBytes;
    if (format == ExportFormat.epub) {
      for (final candidate in [?coverUrl, novel.detail.imgUrl]) {
        if (candidate.isEmpty) continue;
        final resolved = await _resolveCachedImage(imageStore, imgCacheDir, candidate);
        if (resolved != null) {
          coverPath = resolved.path;
          coverBytes = resolved.bytes;
          break;
        }
      }
    }

    final volumes = <EpubVolumeData>[];
    var collected = 0;
    var imageCount = 0;
    final progressClock = Stopwatch()..start();
    var lastProgressMs = -100;

    for (final v in novel.catalogue) {
      final chList = <EpubChapterData>[];
      for (final c in v.chapters) {
        if (onlyCids != null && !onlyCids.contains(c.cid)) continue;
        if (!ChapterCache.has(aid, c.cid)) continue;
        final Content? content = await ChapterCache.get(aid, c.cid);
        if (content == null) continue;

        final imageFiles = <EpubImageFile>[];
        if (format == ExportFormat.epub && content.images.isNotEmpty) {
          for (var i = 0; i < content.images.length; i++) {
            final url = content.images[i];
            final resolved = await _resolveCachedImage(imageStore, imgCacheDir, url);
            if (resolved != null) {
              imageFiles.add(EpubImageFile(name: 'img_$i', path: resolved.path, bytes: resolved.bytes));
              imageCount++;
            }
          }
        }

        chList.add(EpubChapterData(title: c.title, text: content.text, imageFiles: imageFiles));
        collected++;
        final nowMs = progressClock.elapsedMilliseconds;
        if (collected == 1 || collected == total || nowMs - lastProgressMs >= 100) {
          lastProgressMs = nowMs;
          onProgress?.call('正在收集章节 $collected / $total…', (collected / total) * 0.75);
        }
      }
      if (chList.isNotEmpty) {
        volumes.add(EpubVolumeData(title: v.title, chapters: chList));
      }
    }

    if (volumes.isEmpty) {
      throw const FormatException('未能读取到已缓存章节内容');
    }

    final ext = format == ExportFormat.epub ? 'epub' : 'txt';
    final mime = format == ExportFormat.epub ? 'application/epub+zip' : 'text/plain';
    final fileName = '${sanitizeFileName(shownTitle)}.$ext';
    final targetPath = outputPath ?? p.join((await getTemporaryDirectory()).path, fileName);

    onProgress?.call(format == ExportFormat.epub ? '正在打包 EPUB 文件…' : '正在生成 TXT 文件…', 0.85);
    await compute(
      _encodeToFileInIsolate,
      (
        format: format,
        outputPath: targetPath,
        title: shownTitle,
        author: novel.detail.author == '未知作者' ? '' : novel.detail.author,
        description: novel.detail.introduce,
        coverPath: coverPath,
        coverBytes: coverBytes,
        volumes: volumes,
      ),
    );
    onProgress?.call('正在准备导出…', 1.0);

    return (
      filePath: targetPath,
      fileName: fileName,
      mimeType: mime,
      chapterCount: collected,
      imageCount: imageCount,
    );
  }

  /// 收集已缓存章节与本地图片，在独立 isolate 中编码生成 EPUB / TXT 字节（原生端复用流式文件生成避免内存峰值）。
  static Future<ExportResult> buildBytes({
    required String aid,
    required NovelPage novel,
    required ExportFormat format,
    required ImageStore imageStore,
    String? coverUrl,
    Set<String>? onlyCids,
    void Function(String stage, double? progress)? onProgress,
  }) async {
    if (!kIsWeb) {
      final ext = format == ExportFormat.epub ? 'epub' : 'txt';
      final tmpPath = p.join(Directory.systemTemp.path, 'ark_export_${DateTime.now().microsecondsSinceEpoch}.$ext');
      try {
        final built = await buildToFile(
          aid: aid,
          novel: novel,
          format: format,
          imageStore: imageStore,
          outputPath: tmpPath,
          coverUrl: coverUrl,
          onlyCids: onlyCids,
          onProgress: onProgress,
        );
        final bytes = await File(built.filePath).readAsBytes();
        return (
          bytes: bytes,
          fileName: built.fileName,
          mimeType: built.mimeType,
          chapterCount: built.chapterCount,
          imageCount: built.imageCount,
        );
      } finally {
        await _deleteQuietly(tmpPath);
      }
    }

    final shownTitle = LibraryStore.shown(aid, novel.detail.title);
    final total = availableCount(aid, novel.catalogue, onlyCids: onlyCids);
    if (total == 0) {
      throw const FormatException('所选范围内没有可导出的已缓存章节');
    }

    onProgress?.call('正在准备封面…', 0);
    Uint8List? coverBytes;
    if (format == ExportFormat.epub) {
      for (final candidate in [?coverUrl, novel.detail.imgUrl]) {
        if (candidate.isEmpty) continue;
        final b = await imageStore.cached(candidate);
        if (b != null && b.isNotEmpty) {
          coverBytes = b;
          break;
        }
      }
    }

    final volumes = <EpubVolumeData>[];
    var collected = 0;
    var imageCount = 0;
    final progressClock = Stopwatch()..start();
    var lastProgressMs = -100;

    for (final v in novel.catalogue) {
      final chList = <EpubChapterData>[];
      for (final c in v.chapters) {
        if (onlyCids != null && !onlyCids.contains(c.cid)) continue;
        if (!ChapterCache.has(aid, c.cid)) continue;
        final Content? content = await ChapterCache.get(aid, c.cid);
        if (content == null) continue;

        final images = <({String name, Uint8List bytes})>[];
        if (format == ExportFormat.epub && content.images.isNotEmpty) {
          for (var i = 0; i < content.images.length; i++) {
            final url = content.images[i];
            final b = await imageStore.cached(url);
            if (b != null && b.isNotEmpty) {
              images.add((name: 'img_$i', bytes: b));
              imageCount++;
            }
          }
        }

        chList.add(EpubChapterData(title: c.title, text: content.text, images: images));
        collected++;
        final nowMs = progressClock.elapsedMilliseconds;
        if (collected == 1 || collected == total || nowMs - lastProgressMs >= 100) {
          lastProgressMs = nowMs;
          onProgress?.call('正在收集章节 $collected / $total…', (collected / total) * 0.75);
        }
      }
      if (chList.isNotEmpty) {
        volumes.add(EpubVolumeData(title: v.title, chapters: chList));
      }
    }

    if (volumes.isEmpty) {
      throw const FormatException('未能读取到已缓存章节内容');
    }

    onProgress?.call(format == ExportFormat.epub ? '正在打包 EPUB 文件…' : '正在生成 TXT 文件…', 0.85);
    final bytes = await compute(
      _encodeInIsolate,
      (
        format: format,
        title: shownTitle,
        author: novel.detail.author == '未知作者' ? '' : novel.detail.author,
        description: novel.detail.introduce,
        coverBytes: coverBytes,
        volumes: volumes,
      ),
    );
    onProgress?.call('正在准备导出…', 1.0);

    final ext = format == ExportFormat.epub ? 'epub' : 'txt';
    final mime = format == ExportFormat.epub ? 'application/epub+zip' : 'text/plain';
    return (
      bytes: bytes,
      fileName: '${sanitizeFileName(shownTitle)}.$ext',
      mimeType: mime,
      chapterCount: collected,
      imageCount: imageCount,
    );
  }
}

/// 弹出导出配置对话框（格式 + 范围），异步构建并保存/分享文件。
Future<void> showExportBookDialog(
  BuildContext context,
  WidgetRef ref, {
  required String aid,
  required NovelPage novel,
  Set<String>? selectedCids,
}) async {
  if (kIsWeb) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网页预览不支持导出文件')));
    return;
  }

  final totalCached = ExportBook.availableCount(aid, novel.catalogue);
  if (totalCached == 0) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有已缓存章节，请先缓存后再导出')));
    return;
  }

  final selectedCached = selectedCids == null || selectedCids.isEmpty ? 0 : ExportBook.availableCount(aid, novel.catalogue, onlyCids: selectedCids);
  final volCachedCounts = [for (final v in novel.catalogue) ExportBook.availableCount(aid, [v])];
  final exportableVols = [
    for (var i = 0; i < novel.catalogue.length; i++)
      if (volCachedCounts[i] > 0) (index: i, vol: novel.catalogue[i], count: volCachedCounts[i]),
  ];

  var format = ExportFormat.epub;
  // scope: 0 = 全部已缓存, 1 = 仅已选章节, 2 = 按卷选择
  var scope = selectedCached > 0 ? 1 : 0;
  final pickedVols = <int>{for (final v in exportableVols) v.index};

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        final canConfirm = scope != 2 || pickedVols.isNotEmpty;
        return AlertDialog(
          title: const Text('导出书籍'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('导出格式', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<ExportFormat>(
                    segments: const [
                      ButtonSegment(value: ExportFormat.epub, icon: Icon(Icons.menu_book_outlined, size: 18), label: Text('EPUB')),
                      ButtonSegment(value: ExportFormat.txt, icon: Icon(Icons.description_outlined, size: 18), label: Text('TXT')),
                    ],
                    selected: {format},
                    onSelectionChanged: (s) => setState(() => format = s.first),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    format == ExportFormat.epub ? '包含封面、卷/章两级目录与本地已缓存插图' : '纯文本 UTF-8，按卷和章节整齐排版',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Text('导出范围', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  RadioGroup<int>(
                    groupValue: scope,
                    onChanged: (v) {
                      if (v != null) setState(() => scope = v);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (selectedCached > 0)
                          RadioListTile<int>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: 1,
                            title: Text('已选中的已缓存章节（$selectedCached 章）'),
                          ),
                        RadioListTile<int>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: 0,
                          title: Text('全部已缓存章节（$totalCached 章）'),
                        ),
                        if (exportableVols.length > 1)
                          RadioListTile<int>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: 2,
                            title: Text('按卷选择（已选 ${pickedVols.length}/${exportableVols.length} 卷）'),
                          ),
                      ],
                    ),
                  ),
                  if (scope == 2 && exportableVols.length > 1)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: math.min(200.0, exportableVols.length * 64.0)),
                      child: ListView.builder(
                        itemCount: exportableVols.length,
                        itemBuilder: (_, idx) {
                          final v = exportableVols[idx];
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 12),
                            controlAffinity: ListTileControlAffinity.leading,
                            value: pickedVols.contains(v.index),
                            onChanged: (checked) => setState(() => checked == true ? pickedVols.add(v.index) : pickedVols.remove(v.index)),
                            title: Text(v.vol.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${v.count} 章'),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: canConfirm ? () => Navigator.pop(ctx, true) : null, child: const Text('开始导出')),
          ],
        );
      },
    ),
  );
  if (confirmed != true || !context.mounted) return;

  Set<String>? targetCids;
  if (scope == 1 && selectedCids != null) {
    targetCids = selectedCids;
  } else if (scope == 2) {
    targetCids = {
      for (final idx in pickedVols)
        for (final c in novel.catalogue[idx].chapters) c.cid,
    };
  }

  final progress = ValueNotifier<({String stage, double? value})>((stage: '正在准备导出…', value: null));
  final rootNav = Navigator.of(context, rootNavigator: true);
  Route<void>? dialogRoute;
  var dialogOpen = true;
  final dialogFuture = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogRoute = ModalRoute.of(ctx);
      return PopScope(
        canPop: false,
        child: ValueListenableBuilder<({String stage, double? value})>(
          valueListenable: progress,
          builder: (ctx, p, _) => AlertDialog(
            title: Text(format == ExportFormat.epub ? '正在生成 EPUB' : '正在生成 TXT'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: p.value),
                const SizedBox(height: 12),
                Text(p.stage),
              ],
            ),
          ),
        ),
      );
    },
  );
  unawaited(
    dialogFuture.whenComplete(() {
      dialogOpen = false;
      progress.dispose();
    }),
  );

  ExportFileResult? built;
  Object? error;
  try {
    final cover = ref.read(volumeCoverQueueProvider).bookCover(aid, novel.detail.imgUrl);
    built = await ExportBook.buildToFile(
      aid: aid,
      novel: novel,
      format: format,
      imageStore: ref.read(imageStoreProvider),
      coverUrl: cover,
      onlyCids: targetCids,
      onProgress: (stage, value) {
        if (dialogOpen) progress.value = (stage: stage, value: value);
      },
    );
  } catch (e) {
    error = e;
  } finally {
    if (dialogOpen) {
      final route = dialogRoute;
      if (route != null) {
        if (route.isActive) {
          if (route.isCurrent) {
            rootNav.pop();
          } else {
            rootNav.removeRoute(route);
          }
        }
      } else if (rootNav.mounted) {
        rootNav.pop();
      }
    }
  }

  if (!context.mounted) {
    if (built != null) unawaited(_deleteQuietly(built.filePath));
    return;
  }
  if (error != null || built == null) {
    final detail = error is FormatException ? error.message : '$error';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$detail')));
    return;
  }

  try {
    final desktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
    if (desktop) {
      Uri? uri;
      var dialogSucceeded = false;
      try {
        uri = await FilePicker.saveFile(
          dialogTitle: hz(context, '另存为'),
          fileName: built.fileName,
          bytes: Uint8List(0),
          mimeType: built.mimeType,
          type: FileType.custom,
          allowedExtensions: [format == ExportFormat.epub ? 'epub' : 'txt'],
        );
        dialogSucceeded = true;
      } catch (_) {
        // 桌面端另存为对话框拉起失败时回退到系统分享
      }
      if (dialogSucceeded) {
        if (uri == null) {
          await _deleteQuietly(built.filePath);
          return; // 用户取消保存
        }
        if (uri.scheme == 'file') {
          final destPath = uri.toFilePath();
          if (p.canonicalize(destPath) != p.canonicalize(built.filePath)) {
            await _copyFileStreamed(built.filePath, destPath);
            await _deleteQuietly(built.filePath);
          }
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出 ${built.chapterCount} 章到 $destPath')));
          return;
        }
        await _deleteQuietly(built.filePath);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出 ${built.chapterCount} 章到 $uri')));
        return;
      }
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(built.filePath, mimeType: built.mimeType)], title: built.fileName));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存或分享文件失败：$e')));
    }
  }
}
