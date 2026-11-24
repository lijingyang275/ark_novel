import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List, compute, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/wenku8/wenku8_parser.dart' show Wenku8NovelDetail;
import '../models/cat_chapter.dart';
import '../models/cat_volume.dart';
import '../models/content.dart';
import 'app_prefs.dart';
import 'data.dart' show NovelPage;
import 'epub_codec.dart';
import 'files.dart';
import 'image_cache.dart' show splitCrop;
import 'library.dart';
import 'pages/categories_page.dart';
import 'stats.dart';
import 'text.dart';
import 'updates.dart';
import 'volumes.dart';

const String kLocalAidPrefix = 'local:';
const String kLocalImgPrefix = 'localimg://';

/// 判断书号是否为本机导入的本地书籍。
bool isLocalAid(String aid) => aid.startsWith(kLocalAidPrefix);

/// 判断图片地址是否为本地书内嵌图片（`localimg://`）或本机文件路径。
bool isLocalImageUrl(String rawUrl) {
  final url = splitCrop(rawUrl).url;
  return url.startsWith(kLocalImgPrefix) || url.startsWith('file://') || (url.startsWith('/') && !url.startsWith('//'));
}

bool _isSafeFileName(String name) =>
    name.isNotEmpty && name != '.' && name != '..' && !name.contains('/') && !name.contains('\\') && !name.contains('\x00');

bool _isSafeBookId(String id) => id.isNotEmpty && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

/// 解析 `localimg://<aid>/<fileName>`（不调用 `Uri.parse`，避免 `local:` 中的冒号被误当成端口号）。
({String aid, String fileName})? parseLocalImageUrl(String rawUrl) {
  final url = splitCrop(rawUrl).url;
  if (!url.startsWith(kLocalImgPrefix)) return null;
  final rest = url.substring(kLocalImgPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash >= rest.length - 1) return null;
  final aid = rest.substring(0, slash);
  final fileName = rest.substring(slash + 1);
  if (!isLocalAid(aid) || !_isSafeFileName(fileName)) return null;
  return (aid: aid, fileName: fileName);
}

/// 当本机不存在该本地书籍的文件时抛出（例如书架条目通过 WebDAV / 备份同步自另一台设备）。
class LocalBookMissingException implements Exception {
  const LocalBookMissingException([this.message = '该本地书籍的文件不在此设备上，请在本机重新导入']);

  final String message;

  @override
  String toString() => message;
}

class LocalBookMeta {
  const LocalBookMeta({
    required this.aid,
    required this.format,
    required this.title,
    required this.author,
    required this.introduce,
    required this.importedAt,
    required this.coverFile,
    required this.catalogue,
    required this.chapterChars,
    required this.chapterImages,
  });

  final String aid;

  /// `'epub'` 或 `'txt'`
  final String format;
  final String title;
  final String author;
  final String introduce;
  final int importedAt;
  final String coverFile;
  final List<CatVolume> catalogue;
  final Map<String, int> chapterChars;
  final Map<String, List<String>> chapterImages;

  String get formatLabel => format.toLowerCase() == 'epub' ? '本地 EPUB' : '本地 TXT';

  String get coverUrl => coverFile.isEmpty ? '' : '$kLocalImgPrefix$aid/$coverFile';

  int get totalChapters => catalogue.fold(0, (sum, v) => sum + v.chapters.length);

  String get importDateLabel {
    final d = DateTime.fromMillisecondsSinceEpoch(importedAt);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  NovelPage toNovelPage() => NovelPage(
    Wenku8NovelDetail(
      title: title,
      author: author.isEmpty ? '未知作者' : author,
      status: formatLabel,
      lastUpdate: importDateLabel,
      imgUrl: coverUrl,
      introduce: introduce,
      tags: [formatLabel],
      heat: null,
      trending: null,
      isAnimated: false,
    ),
    catalogue,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'aid': aid,
    'format': format,
    'title': title,
    'author': author,
    'introduce': introduce,
    'importedAt': importedAt,
    'cover': coverFile,
    'volumes': [
      for (final v in catalogue)
        {
          'title': v.title,
          'chapters': [
            for (final c in v.chapters)
              {
                'cid': c.cid,
                'title': c.title,
                'chars': chapterChars[c.cid] ?? 0,
                if ((chapterImages[c.cid] ?? const []).isNotEmpty) 'images': chapterImages[c.cid],
              },
          ],
        },
    ],
  };

  static LocalBookMeta fromJson(Map<String, dynamic> map) {
    final aid = map['aid'] as String;
    final catalogue = <CatVolume>[];
    final chapterChars = <String, int>{};
    final chapterImages = <String, List<String>>{};
    for (final rawVol in (map['volumes'] as List? ?? const []).cast<Map>()) {
      final chapters = <CatChapter>[];
      for (final rawCh in (rawVol['chapters'] as List? ?? const []).cast<Map>()) {
        final cid = rawCh['cid'] as String;
        final title = (rawCh['title'] as String?) ?? cid;
        chapters.add(CatChapter(title: title, cid: cid));
        chapterChars[cid] = (rawCh['chars'] as num?)?.toInt() ?? 0;
        final imgs = ((rawCh['images'] as List?) ?? const []).cast<String>();
        if (imgs.isNotEmpty) chapterImages[cid] = List<String>.unmodifiable(imgs);
      }
      catalogue.add(CatVolume(title: (rawVol['title'] as String?) ?? '正文', chapters: chapters));
    }
    return LocalBookMeta(
      aid: aid,
      format: (map['format'] as String?) ?? 'txt',
      title: (map['title'] as String?) ?? '未命名书籍',
      author: (map['author'] as String?) ?? '',
      introduce: (map['introduce'] as String?) ?? '',
      importedAt: (map['importedAt'] as num?)?.toInt() ?? 0,
      coverFile: (map['cover'] as String?) ?? '',
      catalogue: catalogue,
      chapterChars: chapterChars,
      chapterImages: chapterImages,
    );
  }
}

ParsedBook _parseInIsolate(({Uint8List bytes, String format, String fallbackTitle}) args) =>
    args.format == 'epub' ? EpubParser.parseBytes(args.bytes, fallbackTitle: args.fallbackTitle) : TxtParser.parseBytes(args.bytes, fallbackTitle: args.fallbackTitle);

/// 本地导入书籍存储管理：独立存放在 `ApplicationSupport/local_books/<id>/`，
/// 与 `ChapterCache`、`imgcache`、默认备份和 WebDAV 完全隔离。
class LocalBooks {
  LocalBooks._();

  static final _metaCache = <String, LocalBookMeta>{};
  static final _rand = math.Random();

  /// 测试可注入自定义根目录，避免依赖 `path_provider` 平台通道。
  @visibleForTesting
  static Future<Directory> Function()? rootProvider;

  static Future<Directory> _rootDir() async {
    if (rootProvider != null) {
      final dir = await rootProvider!();
      return dir.create(recursive: true);
    }
    return Directory(p.join((await getApplicationSupportDirectory()).path, 'local_books')).create(recursive: true);
  }

  static String _bookId(String aid) {
    if (!isLocalAid(aid)) throw ArgumentError.value(aid, 'aid', 'not a local aid');
    final id = aid.substring(kLocalAidPrefix.length);
    if (!_isSafeBookId(id)) throw ArgumentError.value(aid, 'aid', 'invalid local book id');
    return id;
  }

  static Future<Directory> _bookDir(String aid) async => Directory(p.join((await _rootDir()).path, _bookId(aid)));

  static String generateAid() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final suffix = _rand.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '$kLocalAidPrefix${now}_$suffix';
  }

  static void clearMemoryCache() => _metaCache.clear();

  /// 从磁盘文件路径导入 `.epub` 或 `.txt`。
  static Future<LocalBookMeta> importFile(String filePath, {String? fileName}) async {
    final file = File(filePath);
    if (!await file.exists()) throw const FormatException('找不到选中的文件');
    final bytes = await file.readAsBytes();
    return importBytes(bytes, fileName: fileName ?? p.basename(filePath));
  }

  /// 从字节流导入 `.epub` 或 `.txt`（解析在独立 isolate 中执行，不阻塞 UI）。
  static Future<LocalBookMeta> importBytes(Uint8List bytes, {required String fileName}) async {
    final ext = p.extension(fileName).toLowerCase();
    final format = switch (ext) {
      '.epub' => 'epub',
      '.txt' => 'txt',
      _ => throw FormatException('不支持的文件格式（仅支持 EPUB / TXT）：$fileName'),
    };
    final fallbackTitle = p.basenameWithoutExtension(fileName).trim();
    final parsed = await compute(_parseInIsolate, (bytes: bytes, format: format, fallbackTitle: fallbackTitle.isEmpty ? '未命名书籍' : fallbackTitle));
    return saveParsed(parsed, format: format);
  }

  /// 将已解析的书籍持久化到独立目录 `local_books/<id>/`。
  static Future<LocalBookMeta> saveParsed(ParsedBook book, {required String format, String? aid}) async {
    final bookAid = aid ?? generateAid();
    final dir = await _bookDir(bookAid);
    final chaptersDir = Directory(p.join(dir.path, 'chapters'));
    final imagesDir = Directory(p.join(dir.path, 'images'));
    await chaptersDir.create(recursive: true);
    await imagesDir.create(recursive: true);

    try {
      var coverFile = '';
      if (book.coverBytes != null && book.coverBytes!.isNotEmpty) {
        final fmt = detectImageFormat(book.coverBytes!, book.coverExt == null ? null : 'cover${book.coverExt}');
        coverFile = 'cover${fmt.ext}';
        await writeFileAtomic(File(p.join(dir.path, coverFile)), book.coverBytes!);
      }

      final catalogue = <CatVolume>[];
      final chapterChars = <String, int>{};
      final chapterImages = <String, List<String>>{};
      var chSeq = 0;

      for (final vol in book.volumes) {
        final chapters = <CatChapter>[];
        for (final ch in vol.chapters) {
          chSeq++;
          final cid = 'c${chSeq.toString().padLeft(4, '0')}';
          chapters.add(CatChapter(title: ch.title, cid: cid));
          chapterChars[cid] = ch.text.length;

          final compressed = gzip.encode(utf8.encode(ch.text));
          await writeFileAtomic(File(p.join(chaptersDir.path, '$cid.txt.gz')), compressed);

          if (ch.images.isNotEmpty) {
            final savedNames = <String>[];
            for (var i = 0; i < ch.images.length; i++) {
              final img = ch.images[i];
              if (img.bytes.isEmpty) continue;
              final fmt = detectImageFormat(img.bytes, img.name);
              final fileName = '${cid}_${(i + 1).toString().padLeft(3, '0')}${fmt.ext}';
              await writeFileAtomic(File(p.join(imagesDir.path, fileName)), img.bytes);
              savedNames.add(fileName);
            }
            if (savedNames.isNotEmpty) chapterImages[cid] = List<String>.unmodifiable(savedNames);
          }
        }
        if (chapters.isNotEmpty) {
          catalogue.add(CatVolume(title: vol.title, chapters: chapters));
        }
      }

      if (catalogue.isEmpty) {
        throw const FormatException('书籍中没有可导入的章节');
      }

      final meta = LocalBookMeta(
        aid: bookAid,
        format: format,
        title: book.title,
        author: book.author,
        introduce: book.description,
        importedAt: DateTime.now().millisecondsSinceEpoch,
        coverFile: coverFile,
        catalogue: catalogue,
        chapterChars: chapterChars,
        chapterImages: chapterImages,
      );
      await writeFileAtomic(File(p.join(dir.path, 'meta.json')), utf8.encode(jsonEncode(meta.toJson())));
      _metaCache[bookAid] = meta;
      return meta;
    } catch (_) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
      _metaCache.remove(bookAid);
      rethrow;
    }
  }

  static LocalBookMeta? peekMeta(String aid) => _metaCache[aid];

  /// 同步获取已加载到本地内存索引的章节字数（供书签页码与分卷统计使用）。
  static int? chapterLength(String aid, String cid) => _metaCache[aid]?.chapterChars[cid];

  static Future<LocalBookMeta?> loadMeta(String aid) async {
    if (!isLocalAid(aid)) return null;
    final hit = _metaCache[aid];
    if (hit != null) return hit;
    final dir = await _bookDir(aid);
    final file = File(p.join(dir.path, 'meta.json'));
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) return null;
    final meta = LocalBookMeta.fromJson(raw);
    _metaCache[aid] = meta;
    return meta;
  }

  static Future<bool> exists(String aid) async {
    if (!isLocalAid(aid)) return false;
    final dir = await _bookDir(aid);
    return File(p.join(dir.path, 'meta.json')).exists();
  }

  /// 读取本地书籍详情与目录；本机缺少文件时返回友好错误提示。
  static Future<NovelPage> loadNovel(String aid) async {
    final meta = await loadMeta(aid);
    if (meta == null) throw const LocalBookMissingException();
    if (Hive.isBoxOpen('session')) {
      await Volumes.saveCatalogue(aid, meta.catalogue);
      await UpdateStore.noteKnownCount(aid, meta.totalChapters);
    }
    return meta.toNovelPage();
  }

  /// 读取本地书籍单章正文与内嵌插图地址列表（`localimg://<aid>/<fileName>`）。
  static Future<Content> loadChapter(String aid, String cid) async {
    final meta = await loadMeta(aid);
    if (meta == null) throw const LocalBookMissingException();
    if (!_isSafeFileName(cid)) throw const LocalBookMissingException();
    final dir = await _bookDir(aid);
    final file = File(p.join(dir.path, 'chapters', '$cid.txt.gz'));
    if (!await file.exists()) throw const LocalBookMissingException();
    final compressed = await file.readAsBytes();
    final text = utf8.decode(gzip.decode(compressed));
    final imgFiles = meta.chapterImages[cid] ?? const <String>[];
    return Content(
      text: text,
      images: [for (final f in imgFiles) '$kLocalImgPrefix$aid/$f'],
    );
  }

  /// 解析本地图片对应的磁盘文件路径（不经 `imgcache`）。
  static Future<String?> resolveImagePath(String rawUrl) async {
    final clean = splitCrop(rawUrl).url;
    final parsed = parseLocalImageUrl(clean);
    if (parsed != null) {
      final dir = await _bookDir(parsed.aid);
      final file = parsed.fileName.startsWith('cover.')
          ? File(p.join(dir.path, parsed.fileName))
          : File(p.join(dir.path, 'images', parsed.fileName));
      return await file.exists() ? file.path : null;
    }
    if (clean.startsWith('file://')) {
      try {
        final f = File(Uri.parse(clean).toFilePath());
        return await f.exists() ? f.path : null;
      } catch (_) {
        return null;
      }
    }
    if (clean.startsWith('/') && !clean.startsWith('//')) {
      final f = File(clean);
      return await f.exists() ? f.path : null;
    }
    return null;
  }

  /// 读取本地图片二进制字节，不存在返回 null。
  static Future<Uint8List?> readImageBytes(String rawUrl) async {
    final filePath = await resolveImagePath(rawUrl);
    if (filePath == null) return null;
    final f = File(filePath);
    return await f.exists() ? await f.readAsBytes() : null;
  }

  /// 删除本地书籍在磁盘上的全部文件。
  static Future<void> delete(String aid) async {
    _metaCache.remove(aid);
    if (!isLocalAid(aid)) return;
    final dir = await _bookDir(aid);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 计算单本本地书籍占用的磁盘字节数。
  static Future<int> bytesOf(String aid) async {
    if (!isLocalAid(aid)) return 0;
    final dir = await _bookDir(aid);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// 计算全部本地书籍占用的磁盘字节数。
  static Future<int> totalBytes() async {
    final root = await _rootDir();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// 列出本机磁盘上所有本地书籍的 `aid`。
  static Future<List<String>> listLocalAids() async {
    final root = await _rootDir();
    if (!await root.exists()) return const [];
    final out = <String>[];
    await for (final entity in root.list()) {
      if (entity is Directory && await File(p.join(entity.path, 'meta.json')).exists()) {
        out.add('$kLocalAidPrefix${p.basename(entity.path)}');
      }
    }
    return out;
  }
}

/// 书架/详情页移出含本地书籍时的确认弹窗：询问是否同时删除本机导入的书籍文件。
Future<({bool confirmed, bool deleteFiles})> confirmRemoveLocalBooks(
  BuildContext context, {
  required int totalCount,
  required int localCount,
}) async {
  var deleteFiles = true;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(totalCount == 1 ? '移出这本书？' : '移出 $totalCount 本书？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              localCount == totalCount
                  ? '仅从书架移出后，阅读进度仍会保留；勾选下方选项可同时删除本机导入的书籍文件。'
                  : '在线书籍登录时会一起从网站书架移出；其中包含 $localCount 本本地导入的书籍。',
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: deleteFiles,
              onChanged: (v) => setState(() => deleteFiles = v ?? true),
              title: const Text('同时删除本地书籍文件'),
              subtitle: const Text('释放存储空间，删除后需重新导入才能阅读'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移出')),
        ],
      ),
    ),
  );
  return (confirmed: result == true, deleteFiles: result == true && deleteFiles);
}

/// 书架「导入本地书籍（EPUB / TXT）」交互流程：支持多选、默认分类、进度弹窗与导入结果提示。
Future<void> importLocalBooksFlow(BuildContext context, WidgetRef ref) async {
  if (kIsWeb) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网页预览不支持导入本地书籍')));
    return;
  }
  final List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(
      dialogTitle: hz(context, '选择本地 EPUB 或 TXT 书籍'),
      type: FileType.custom,
      allowedExtensions: ['epub', 'txt'],
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开文件选择器失败：$e')));
    }
    return;
  }
  if (picked.isEmpty || !context.mounted) return;

  // 按新书默认分类决定放入哪个书架分类
  final libCats = ref.read(libraryProvider).cats;
  final def = AppPrefs.read(P.defaultCat, 'ask');
  final List<String>? chosenCats;
  if (def == 'ask' || (def.isNotEmpty && !libCats.any((c) => c.id == def))) {
    chosenCats = libCats.isEmpty ? const <String>[] : await pickCategories(context, libCats, const []);
  } else {
    chosenCats = def.isEmpty ? const <String>[] : [def];
  }
  if (chosenCats == null || !context.mounted) return;

  final status = ValueNotifier<({int done, int total, String label})>((done: 0, total: picked.length, label: '准备导入…'));
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<({int done, int total, String label})>(
          valueListenable: status,
          builder: (ctx, s, _) => AlertDialog(
            title: const Text('正在导入本地书籍'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: s.total == 0 ? null : s.done / s.total),
                const SizedBox(height: 12),
                Text(s.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => dialogOpen = false),
  );

  final imported = <LocalBookMeta>[];
  final errors = <String>[];
  try {
    for (var i = 0; i < picked.length; i++) {
      final f = picked[i];
      status.value = (done: i, total: picked.length, label: '正在解析 (${i + 1}/${picked.length})：${f.name}');
      try {
        final LocalBookMeta meta;
        if (f.path != null && f.path!.isNotEmpty) {
          meta = await LocalBooks.importFile(f.path!, fileName: f.name);
        } else {
          final bytes = await f.readAsBytes();
          meta = await LocalBooks.importBytes(bytes, fileName: f.name);
        }
        await Volumes.saveCatalogue(meta.aid, meta.catalogue);
        if (meta.coverUrl.isNotEmpty && meta.catalogue.isNotEmpty) {
          await Volumes.setCover(meta.aid, meta.catalogue.first.title, meta.coverUrl);
        }
        await ReadingStats.setMeta(meta.aid, meta.title, meta.author, meta.coverUrl);
        await ref.read(libraryProvider.notifier).add(meta.aid, meta.title, meta.coverUrl, cats: chosenCats);
        await UpdateStore.noteKnownCount(meta.aid, meta.totalChapters);
        imported.add(meta);
      } catch (e) {
        final msg = e is FormatException ? e.message : '$e';
        errors.add('${f.name}：$msg');
      }
      status.value = (done: i + 1, total: picked.length, label: '已完成 ${i + 1}/${picked.length}');
    }
  } finally {
    status.dispose();
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  if (!context.mounted) return;
  final msg = errors.isEmpty
      ? (imported.length == 1 ? '已导入《${imported.first.title}》并加入书架' : '已导入 ${imported.length} 本本地书籍并加入书架')
      : (imported.isEmpty ? '导入失败：${errors.first}' : '成功导入 ${imported.length} 本，失败 ${errors.length} 本（${errors.first}）');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
