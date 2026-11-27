import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:ark_novel/next/epub_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _samplePng() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Uint8List _sampleJpeg() => Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
  0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

void main() {
  group('EpubBuilder', () {
    test('生成的 EPUB 首项为未压缩 mimetype，且完整包含元数据/封面/两级目录/正文与插图', () {
      final cover = _samplePng();
      final illus1 = _sampleJpeg();
      final illus2 = _samplePng();

      final epubBytes = EpubBuilder.build(
        title: '星与海的彼端 <特别版> & "测试"',
        author: '森见测试',
        description: '第一行简介。\n包含 <XML> & 特殊符号。',
        coverBytes: cover,
        volumes: [
          EpubVolumeData(
            title: '第一卷 启程',
            chapters: [
              EpubChapterData(
                title: '第一章 黎明',
                text: '　　清晨的风吹过海面。\n　　少年拾起了<贝壳> & 地图。',
                images: [(name: 'pic1.jpg', bytes: illus1)],
              ),
              const EpubChapterData(
                title: '第二章 港口',
                text: '远处的汽笛拉响。\n旅途正式开始。',
              ),
            ],
          ),
          EpubVolumeData(
            title: '第二卷 远航',
            chapters: [
              EpubChapterData(
                title: '第三章 风暴',
                text: '雨点砸在甲板上。',
                images: [(name: 'pic2.png', bytes: illus2)],
              ),
            ],
          ),
        ],
      );

      // 1. 原始 ZIP 本地头校验：首项必须是未压缩的 mimetype
      expect(epubBytes[0], 0x50); // 'P'
      expect(epubBytes[1], 0x4B); // 'K'
      expect(epubBytes[2], 0x03);
      expect(epubBytes[3], 0x04);
      final compressionMethod = epubBytes[8] | (epubBytes[9] << 8);
      expect(compressionMethod, 0, reason: 'mimetype 压缩方法必须为 0 (STORE)');
      final nameLen = epubBytes[26] | (epubBytes[27] << 8);
      final extraLen = epubBytes[28] | (epubBytes[29] << 8);
      final firstName = ascii.decode(epubBytes.sublist(30, 30 + nameLen));
      expect(firstName, 'mimetype');
      final mimePayload = ascii.decode(epubBytes.sublist(30 + nameLen + extraLen, 30 + nameLen + extraLen + 20));
      expect(mimePayload, 'application/epub+zip');

      // 2. Archive 内容与 XML 转义校验
      final archive = ZipDecoder().decodeBytes(epubBytes);
      expect(archive.files.first.name, 'mimetype');
      expect(archive.files.first.compression, CompressionType.none);
      final byName = {for (final f in archive.files) f.name: f};
      expect(
        byName.keys,
        containsAll([
          'mimetype',
          'META-INF/container.xml',
          'OEBPS/content.opf',
          'OEBPS/toc.ncx',
          'OEBPS/nav.xhtml',
          'OEBPS/style.css',
          'OEBPS/cover.xhtml',
          'OEBPS/images/cover.png',
          'OEBPS/ch_0001.xhtml',
          'OEBPS/ch_0002.xhtml',
          'OEBPS/ch_0003.xhtml',
          'OEBPS/images/img_0001_001.jpg',
          'OEBPS/images/img_0003_001.png',
        ]),
      );

      String textOf(String path) => utf8.decode(byName[path]!.content as List<int>);
      final opf = textOf('OEBPS/content.opf');
      expect(opf, contains('星与海的彼端 &lt;特别版&gt; &amp; &quot;测试&quot;'));
      expect(opf, contains('<dc:creator>森见测试</dc:creator>'));
      expect(opf, contains('包含 &lt;XML&gt; &amp; 特殊符号。'));
      expect(opf, contains('properties="cover-image"'));

      final nav = textOf('OEBPS/nav.xhtml');
      expect(nav, contains('第一卷 启程'));
      expect(nav, contains('第一章 黎明'));
      expect(nav, contains('第二卷 远航'));

      final ch1 = textOf('OEBPS/ch_0001.xhtml');
      expect(ch1, contains('<p>清晨的风吹过海面。</p>'));
      expect(ch1, contains('<p>少年拾起了&lt;贝壳&gt; &amp; 地图。</p>'));
      expect(ch1, contains('images/img_0001_001.jpg'));

      expect(Uint8List.fromList(byName['OEBPS/images/cover.png']!.content as List<int>), equals(cover));
      expect(Uint8List.fromList(byName['OEBPS/images/img_0001_001.jpg']!.content as List<int>), equals(illus1));
      expect(Uint8List.fromList(byName['OEBPS/images/img_0003_001.png']!.content as List<int>), equals(illus2));
    });

    test('buildToFile 流式生成合法 EPUB（首项未压缩 mimetype、磁盘插图与章节全部完整可读、无残余临时文件）', () async {
      final tmp = Directory.systemTemp.createTempSync('ark_epub_stream_test_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final cover = _samplePng();
      final illus1 = _sampleJpeg();
      final illus2 = _samplePng();
      final svgBytes = Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>'));

      final coverFile = File(p.join(tmp.path, 'cover_cached'))..writeAsBytesSync(cover);
      final illus1File = File(p.join(tmp.path, 'illus1_cached'))..writeAsBytesSync(illus1);
      final svgFile = File(p.join(tmp.path, 'illus3_svg'))..writeAsBytesSync(svgBytes);
      final emptyFile = File(p.join(tmp.path, 'empty_file'))..writeAsBytesSync(const []);
      final missingPath = p.join(tmp.path, 'does_not_exist');
      final outPath = p.join(tmp.path, 'out', 'book.epub');

      final progressEvents = <(int, int)>[];
      await EpubBuilder.buildToFile(
        outPath,
        title: '流式测试录 <v2> & "EPUB"',
        author: '流式作者',
        description: '第一行简介。\n<描述>',
        coverPath: coverFile.path,
        volumes: [
          EpubVolumeData(
            title: '第一卷 启程',
            chapters: [
              EpubChapterData(
                title: '第一章 黎明',
                text: '　　清晨的风吹过海面。\n　　少年拾起了<贝壳> & 地图。',
                imageFiles: [
                  EpubImageFile(name: 'img_0', path: illus1File.path),
                  EpubImageFile(name: 'img_1', path: missingPath),
                  EpubImageFile(name: 'img_2', path: emptyFile.path),
                  EpubImageFile(name: 'img_3', path: svgFile.path),
                ],
              ),
              const EpubChapterData(
                title: '第二章 港口',
                text: '远处的汽笛拉响。',
              ),
            ],
          ),
          EpubVolumeData(
            title: '第二卷 远航',
            chapters: [
              EpubChapterData(
                title: '第三章 风暴',
                text: '雨点砸在甲板上。',
                imageFiles: [EpubImageFile(name: 'img_0', bytes: illus2)],
              ),
            ],
          ),
        ],
        onProgress: (done, total) => progressEvents.add((done, total)),
      );

      final outFile = File(outPath);
      expect(outFile.existsSync(), isTrue);
      // 确认无残余 .tmp 文件
      final siblings = outFile.parent.listSync().map((e) => p.basename(e.path)).toList();
      expect(siblings, ['book.epub']);
      expect(progressEvents, [(1, 3), (2, 3), (3, 3)]);

      // 1. 原始 ZIP 本地头字节校验：首项必须是未压缩 STORE (method=0)、无 data descriptor 的 mimetype
      final epubBytes = outFile.readAsBytesSync();
      expect(epubBytes[0], 0x50); // 'P'
      expect(epubBytes[1], 0x4B); // 'K'
      expect(epubBytes[2], 0x03);
      expect(epubBytes[3], 0x04);
      final flags = epubBytes[6] | (epubBytes[7] << 8);
      expect(flags & 0x08, 0, reason: 'mimetype 绝不能带 data descriptor 标志');
      final compressionMethod = epubBytes[8] | (epubBytes[9] << 8);
      expect(compressionMethod, 0, reason: 'mimetype 压缩方法必须为 0 (STORE)');
      final nameLen = epubBytes[26] | (epubBytes[27] << 8);
      final extraLen = epubBytes[28] | (epubBytes[29] << 8);
      expect(extraLen, 0, reason: 'mimetype 本地头不应含 extra field');
      expect(ascii.decode(epubBytes.sublist(30, 30 + nameLen)), 'mimetype');
      expect(ascii.decode(epubBytes.sublist(30 + nameLen, 30 + nameLen + 20)), 'application/epub+zip');

      // 2. 同时验证内存解码与流式解码均完整可读
      for (final mode in ['bytes', 'stream']) {
        final Archive archive;
        InputFileStream? inputStream;
        if (mode == 'bytes') {
          archive = ZipDecoder().decodeBytes(epubBytes);
        } else {
          inputStream = InputFileStream(outPath);
          archive = ZipDecoder().decodeStream(inputStream);
        }
        try {
          expect(archive.files.first.name, 'mimetype');
          expect(archive.files.first.compression, CompressionType.none);
          final byName = {for (final f in archive.files) f.name: f};
          expect(
            byName.keys,
            containsAll([
              'mimetype',
              'META-INF/container.xml',
              'OEBPS/content.opf',
              'OEBPS/toc.ncx',
              'OEBPS/nav.xhtml',
              'OEBPS/style.css',
              'OEBPS/cover.xhtml',
              'OEBPS/images/cover.png',
              'OEBPS/ch_0001.xhtml',
              'OEBPS/ch_0002.xhtml',
              'OEBPS/ch_0003.xhtml',
              'OEBPS/images/img_0001_001.jpg',
              'OEBPS/images/img_0001_002.svg',
              'OEBPS/images/img_0003_001.png',
            ]),
          );

          String textOf(String path) => utf8.decode(byName[path]!.content as List<int>);
          final opf = textOf('OEBPS/content.opf');
          expect(opf, contains('流式测试录 &lt;v2&gt; &amp; &quot;EPUB&quot;'));
          expect(opf, contains('<dc:creator>流式作者</dc:creator>'));
          expect(opf, contains('properties="cover-image"'));

          final ch1 = textOf('OEBPS/ch_0001.xhtml');
          expect(ch1, contains('<p>清晨的风吹过海面。</p>'));
          expect(ch1, contains('<p>少年拾起了&lt;贝壳&gt; &amp; 地图。</p>'));
          expect(ch1, contains('images/img_0001_001.jpg'));
          expect(ch1, contains('images/img_0001_002.svg'));

          expect(Uint8List.fromList(byName['OEBPS/images/cover.png']!.content as List<int>), equals(cover));
          expect(Uint8List.fromList(byName['OEBPS/images/img_0001_001.jpg']!.content as List<int>), equals(illus1));
          expect(Uint8List.fromList(byName['OEBPS/images/img_0001_002.svg']!.content as List<int>), equals(svgBytes));
          expect(Uint8List.fromList(byName['OEBPS/images/img_0003_001.png']!.content as List<int>), equals(illus2));
        } finally {
          await inputStream?.close();
        }
      }
    });
  });

  group('TxtBuilder', () {
    test('生成排版规范的 UTF-8 文本，保留标题/作者/简介/卷章结构与全角缩进', () {
      final bytes = TxtBuilder.build(
        title: '双语测试录',
        author: '作者B',
        description: '这是简介内容',
        volumes: const [
          EpubVolumeData(
            title: '第一卷 起始',
            chapters: [
              EpubChapterData(title: '第一章 黎明', text: '　　第一段话。\n第二段话。'),
            ],
          ),
        ],
      );
      final text = utf8.decode(bytes);
      expect(text, contains('双语测试录'));
      expect(text, contains('作者：作者B'));
      expect(text, contains('简介：\n这是简介内容'));
      expect(text, contains('第一卷 起始'));
      expect(text, contains('第一章 黎明'));
      expect(text, contains('　　第一段话。\n　　第二段话。'));
    });

    test('buildToFile 流式输出与内存版 build 字节完全一致', () async {
      final tmp = Directory.systemTemp.createTempSync('ark_txt_stream_test_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      const vols = [
        EpubVolumeData(
          title: '第一卷 起始',
          chapters: [
            EpubChapterData(title: '第一章 黎明', text: '　　第一段话。\r\n第二段话。'),
          ],
        ),
      ];
      final memBytes = TxtBuilder.build(title: '双语测试录', author: '作者B', description: '简介', volumes: vols);
      final outPath = p.join(tmp.path, 'book.txt');
      await TxtBuilder.buildToFile(outPath, title: '双语测试录', author: '作者B', description: '简介', volumes: vols);
      expect(File(outPath).readAsBytesSync(), equals(memBytes));
    });
  });

  group('detectImageFormat', () {
    test('按魔数识别 JPEG / PNG / GIF / WebP，未知字节回退扩展名', () {
      expect(detectImageFormat(_samplePng()).ext, '.png');
      expect(detectImageFormat(_sampleJpeg()).ext, '.jpg');
      expect(detectImageFormat(Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])).ext, '.gif');
      expect(detectImageFormat(Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])).ext, '.webp');
      expect(detectImageFormat(Uint8List.fromList([1, 2, 3]), 'a.webp').ext, '.webp');
    });

    test('detectImageFormatFromFile 仅读文件头识别格式，缺失或空文件返回 null', () {
      final tmp = Directory.systemTemp.createTempSync('ark_img_fmt_test_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final png = File(p.join(tmp.path, 'no_ext_png'))..writeAsBytesSync(_samplePng());
      final jpg = File(p.join(tmp.path, 'no_ext_jpg'))..writeAsBytesSync(_sampleJpeg());
      final empty = File(p.join(tmp.path, 'empty'))..writeAsBytesSync(const []);
      final missing = File(p.join(tmp.path, 'missing'));

      expect(detectImageFormatFromFile(png)?.ext, '.png');
      expect(detectImageFormatFromFile(jpg)?.ext, '.jpg');
      expect(detectImageFormatFromFile(empty), isNull);
      expect(detectImageFormatFromFile(missing), isNull);
    });
  });
}
