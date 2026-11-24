import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ark_novel/next/epub_codec.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';

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
  group('EpubBuilder & EpubParser', () {
    test('生成的 EPUB 首项为未压缩 mimetype，且完整回环解析元数据/封面/多卷/章节正文/内嵌插图', () {
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

      // Archive 层校验必备文件齐全
      final decodedArchive = ZipDecoder().decodeBytes(epubBytes);
      expect(decodedArchive.files.first.name, 'mimetype');
      expect(decodedArchive.files.first.compression, CompressionType.none);
      final names = decodedArchive.files.map((f) => f.name).toSet();
      expect(names, containsAll(['mimetype', 'META-INF/container.xml', 'OEBPS/content.opf', 'OEBPS/toc.ncx', 'OEBPS/nav.xhtml', 'OEBPS/style.css', 'OEBPS/cover.xhtml']));

      // 2. EpubParser 完整回环解析
      final parsed = EpubParser.parseBytes(epubBytes);
      expect(parsed.title, '星与海的彼端 <特别版> & "测试"');
      expect(parsed.author, '森见测试');
      expect(parsed.description, contains('包含 <XML> & 特殊符号。'));
      expect(parsed.coverBytes, equals(cover));
      expect(parsed.coverExt, '.png');
      expect(parsed.volumes.length, 2);

      expect(parsed.volumes[0].title, '第一卷 启程');
      expect(parsed.volumes[0].chapters.length, 2);
      expect(parsed.volumes[0].chapters[0].title, '第一章 黎明');
      expect(parsed.volumes[0].chapters[0].text, '清晨的风吹过海面。\n少年拾起了<贝壳> & 地图。');
      expect(parsed.volumes[0].chapters[0].images.length, 1);
      expect(parsed.volumes[0].chapters[0].images.first.bytes, equals(illus1));

      expect(parsed.volumes[0].chapters[1].title, '第二章 港口');
      expect(parsed.volumes[0].chapters[1].text, '远处的汽笛拉响。\n旅途正式开始。');
      expect(parsed.volumes[0].chapters[1].images, isEmpty);

      expect(parsed.volumes[1].title, '第二卷 远航');
      expect(parsed.volumes[1].chapters.length, 1);
      expect(parsed.volumes[1].chapters[0].title, '第三章 风暴');
      expect(parsed.volumes[1].chapters[0].text, '雨点砸在甲板上。');
      expect(parsed.volumes[1].chapters[0].images.length, 1);
      expect(parsed.volumes[1].chapters[0].images.first.bytes, equals(illus2));
    });

    test('支持仅含 EPUB 2 toc.ncx、SVG 封面/插图与自动 cover.jpg 兜底', () {
      final cover = _sampleJpeg();
      final archive = Archive()
        ..addFile(ArchiveFile.noCompress('mimetype', 20, ascii.encode('application/epub+zip')))
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'content.opf',
            '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>EPUB2 样本</dc:title>
    <dc:creator>作者甲</dc:creator>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="img_cover" href="images/cover.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'toc.ncx',
            '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="v1" playOrder="1">
      <navLabel><text>卷一</text></navLabel>
      <content src="text/ch1.xhtml"/>
      <navPoint id="p1" playOrder="2">
        <navLabel><text>序幕</text></navLabel>
        <content src="text/ch1.xhtml"/>
      </navPoint>
      <navPoint id="p2" playOrder="3">
        <navLabel><text>正篇</text></navLabel>
        <content src="text/ch2.xhtml"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'text/ch1.xhtml',
            '<html><body><style>.x{color:red}</style><script>alert(1)</script><p>第一段<br/>换行后</p><svg><image xlink:href="../images/cover.jpg"/></svg></body></html>',
          ),
        )
        ..addFile(ArchiveFile.string('text/ch2.xhtml', '<html><body><div>第二章正文</div></body></html>'))
        ..addFile(ArchiveFile.bytes('images/cover.jpg', cover));

      final parsed = EpubParser.parseBytes(ZipEncoder().encodeBytes(archive));
      expect(parsed.title, 'EPUB2 样本');
      expect(parsed.author, '作者甲');
      expect(parsed.coverBytes, equals(cover));
      expect(parsed.volumes.length, 1);
      expect(parsed.volumes.first.title, '卷一');
      expect(parsed.volumes.first.chapters.length, 2);
      expect(parsed.volumes.first.chapters[0].title, '序幕');
      expect(parsed.volumes.first.chapters[0].text, '第一段\n换行后');
      expect(parsed.volumes.first.chapters[0].images.length, 1);
      expect(parsed.volumes.first.chapters[0].images.first.bytes, equals(cover));
      expect(parsed.volumes.first.chapters[1].title, '正篇');
      expect(parsed.volumes.first.chapters[1].text, '第二章正文');
    });

    test('防 Zip Slip 安全校验：拒绝路径穿越与绝对路径', () {
      for (final maliciousPath in [
        '../evil.txt',
        'OEBPS/../../escape.xhtml',
        '/etc/passwd',
        r'..\..\windows\system32\cmd.exe',
        'C:/evil.xml',
      ]) {
        final archive = Archive()
          ..addFile(ArchiveFile.string(maliciousPath, 'evil'))
          ..addFile(ArchiveFile.string('META-INF/container.xml', '<container/>'));
        final bytes = ZipEncoder().encodeBytes(archive);
        expect(
          () => EpubParser.parseBytes(bytes),
          throwsA(isA<FormatException>()),
          reason: '应拦截危险路径 $maliciousPath',
        );
      }
    });
  });

  group('TxtBuilder & TxtParser', () {
    test('UTF-8（有/无 BOM）与 GBK 编码自动检测准确解码', () {
      const sample = '第一章 遇见\n\n你好，轻小说世界！\n第二章 分别\n\n再见。';

      // UTF-8 无 BOM
      final pUtf8 = TxtParser.parseBytes(Uint8List.fromList(utf8.encode(sample)), fallbackTitle: '测试书');
      expect(pUtf8.volumes.single.chapters.length, 2);
      expect(pUtf8.volumes.single.chapters[0].text, '你好，轻小说世界！');

      // UTF-8 带 BOM
      final utf8Bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(sample)]);
      final pBom = TxtParser.parseBytes(utf8Bom, fallbackTitle: '测试书');
      expect(pBom.volumes.single.chapters.length, 2);
      expect(pBom.volumes.single.chapters[0].title, '第一章 遇见');

      // GBK 编码
      final gbkBytes = Uint8List.fromList(const GbkCodec().encode(sample));
      final pGbk = TxtParser.parseBytes(gbkBytes, fallbackTitle: 'GBK样本');
      expect(pGbk.title, 'GBK样本');
      expect(pGbk.volumes.single.chapters.length, 2);
      expect(pGbk.volumes.single.chapters[0].title, '第一章 遇见');
      expect(pGbk.volumes.single.chapters[0].text, '你好，轻小说世界！');
      expect(pGbk.volumes.single.chapters[1].title, '第二章 分别');
    });

    test('中英文卷章正则识别与 TxtBuilder 回环', () {
      final built = TxtBuilder.build(
        title: '双语测试录',
        author: '作者乙',
        description: '一段简介。',
        volumes: const [
          EpubVolumeData(
            title: '第一卷 始动',
            chapters: [
              EpubChapterData(title: '序章', text: '序章内容。'),
              EpubChapterData(title: '第一章 觉醒', text: '第一章正文第一段。\n第二段。'),
              EpubChapterData(title: '后记', text: '感谢阅读。'),
            ],
          ),
          EpubVolumeData(
            title: 'Volume 2 Dawn',
            chapters: [
              EpubChapterData(title: 'Chapter 1 Arrival', text: 'The ship docked at dawn.'),
              EpubChapterData(title: '番外 小剧场', text: '轻松日常。'),
              EpubChapterData(title: '尾声', text: '故事落幕。'),
            ],
          ),
        ],
      );

      final parsed = TxtParser.parseBytes(built, fallbackTitle: '双语测试录');
      expect(parsed.title, '双语测试录');
      expect(parsed.author, '作者乙');
      expect(parsed.description, '一段简介。');
      expect(parsed.volumes.length, 2);
      expect(parsed.volumes[0].title, '第一卷 始动');
      expect(parsed.volumes[0].chapters.map((c) => c.title).toList(), ['序章', '第一章 觉醒', '后记']);
      expect(parsed.volumes[1].title, 'Volume 2 Dawn');
      expect(parsed.volumes[1].chapters.map((c) => c.title).toList(), ['Chapter 1 Arrival', '番外 小剧场', '尾声']);
    });

    test('无章节标题的超长文本按自然段自动切分且不丢字', () {
      final para = '这是一段用于测试超长文本自动按自然段切分的轻小说正文句子。' * 20; // 约 560 字/段
      final paragraphs = List<String>.generate(100, (i) => '段落$i：$para'); // 总计约 56000+ 字 (> 25000)
      final raw = paragraphs.join('\n');

      final parsed = TxtParser.parseBytes(Uint8List.fromList(utf8.encode(raw)), fallbackTitle: '无标题长文');
      expect(parsed.volumes.length, 1);
      final chapters = parsed.volumes.single.chapters;
      expect(chapters.length, greaterThanOrEqualTo(3));
      for (final ch in chapters) {
        expect(ch.text.length, lessThanOrEqualTo(TxtParser.maxChapterChars));
        expect(ch.title, startsWith('第 '));
      }
      final rejoined = chapters.map((c) => c.text).join('\n');
      expect(rejoined, raw);
    });
  });
}
