import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

/// 单章编解码数据（供 EPUB / TXT 生成与解析共用）。
class EpubChapterData {
  const EpubChapterData({required this.title, required this.text, this.images = const []});

  final String title;
  final String text;
  final List<({String name, Uint8List bytes})> images;
}

/// 单卷编解码数据（卷标题 + 章节列表）。
class EpubVolumeData {
  const EpubVolumeData({required this.title, required this.chapters});

  final String title;
  final List<EpubChapterData> chapters;
}

/// EPUB / TXT 解析后的完整书籍结构。
class ParsedBook {
  const ParsedBook({
    required this.title,
    required this.author,
    required this.description,
    this.coverBytes,
    this.coverExt,
    required this.volumes,
  });

  final String title;
  final String author;
  final String description;
  final Uint8List? coverBytes;
  final String? coverExt;
  final List<EpubVolumeData> volumes;
}

/// 根据图片魔数（或文件名后缀兜底）判断 MIME 类型和扩展名。
({String mime, String ext}) detectImageFormat(Uint8List bytes, [String? name]) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return (mime: 'image/jpeg', ext: '.jpg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return (mime: 'image/png', ext: '.png');
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return (mime: 'image/gif', ext: '.gif');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return (mime: 'image/webp', ext: '.webp');
  }
  if (bytes.length >= 4 && bytes[0] == 0x3C) {
    final head = latin1.decode(bytes.take(256).toList(), allowInvalid: true).toLowerCase();
    if (head.contains('<svg')) return (mime: 'image/svg+xml', ext: '.svg');
  }
  final ext = name == null ? '' : p.posix.extension(name).toLowerCase();
  return switch (ext) {
    '.png' => (mime: 'image/png', ext: '.png'),
    '.gif' => (mime: 'image/gif', ext: '.gif'),
    '.webp' => (mime: 'image/webp', ext: '.webp'),
    '.svg' => (mime: 'image/svg+xml', ext: '.svg'),
    _ => (mime: 'image/jpeg', ext: '.jpg'),
  };
}

/// 剥离 XML 1.0 非法控制字符并转义特殊实体。
String _xmlEscape(String input) {
  final cleaned = input.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  return cleaned
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _isoUtcNow() {
  final now = DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
}

/// 标准 EPUB 3（向下兼容 EPUB 2 NCX）生成器。
class EpubBuilder {
  EpubBuilder._();

  static const _styleCss = '''
body {
  margin: 1em;
  line-height: 1.8;
  font-family: "Noto Serif SC", "Songti SC", "STSong", serif;
}
h1, h2 {
  text-align: center;
  font-weight: bold;
  margin: 1.2em 0 1em;
  line-height: 1.4;
}
p {
  text-indent: 2em;
  margin: 0.45em 0;
}
.illus {
  text-align: center;
  text-indent: 0;
  margin: 1em 0;
}
img {
  max-width: 100%;
  height: auto;
  display: block;
  margin: 0.5em auto;
}
.cover {
  text-align: center;
  margin: 0;
  padding: 0;
}
.cover img {
  max-width: 100%;
  max-height: 100%;
}
''';

  static const _containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  static Uint8List build({
    required String title,
    String author = '',
    String description = '',
    Uint8List? coverBytes,
    required List<EpubVolumeData> volumes,
    String language = 'zh-CN',
    String? identifier,
    void Function(int done, int total)? onProgress,
  }) {
    final safeTitle = title.trim().isEmpty ? '未命名书籍' : title.trim();
    final safeAuthor = author.trim();
    final safeDesc = description.trim();
    final bookId = identifier ?? 'urn:uuid:ark-novel-${DateTime.now().millisecondsSinceEpoch}';

    final archive = Archive();

    // 1. mimetype 必须放在 zip 第一个条目且绝不压缩（EPUB OCF 规范要求）
    final mimetypeBytes = ascii.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes));

    // 2. META-INF/container.xml
    archive.addFile(ArchiveFile.string('META-INF/container.xml', _containerXml));

    // 3. OEBPS/style.css
    archive.addFile(ArchiveFile.string('OEBPS/style.css', _styleCss));

    final manifestItems = <String>[
      '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
      '    <item id="style" href="style.css" media-type="text/css"/>',
    ];
    final spineItems = <String>[];

    // 4. 封面（若有）
    final hasCover = coverBytes != null && coverBytes.isNotEmpty;
    String? coverHref;
    if (hasCover) {
      final fmt = detectImageFormat(coverBytes);
      coverHref = 'images/cover${fmt.ext}';
      archive.addFile(ArchiveFile.bytes('OEBPS/$coverHref', coverBytes));
      manifestItems.add('    <item id="cover-image" href="$coverHref" media-type="${fmt.mime}" properties="cover-image"/>');
      manifestItems.add('    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>');
      spineItems.add('    <itemref idref="cover"/>');
      final coverXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${_xmlEscape(language)}">
<head>
  <meta charset="UTF-8"/>
  <title>${_xmlEscape(safeTitle)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body class="cover">
  <div class="cover"><img src="$coverHref" alt="${_xmlEscape(safeTitle)}"/></div>
</body>
</html>
''';
      archive.addFile(ArchiveFile.string('OEBPS/cover.xhtml', coverXhtml));
    }

    // 5. 章节 XHTML 与插图
    final nonEmptyVols = [
      for (final v in volumes)
        if (v.chapters.isNotEmpty) v,
    ];
    final totalChapters = nonEmptyVols.fold<int>(0, (s, v) => s + v.chapters.length);
    final tocVolumes = <({String title, List<({String title, String href})> chapters})>[];

    var chIndex = 0;
    for (final vol in nonEmptyVols) {
      final volTitle = vol.title.trim().isEmpty ? '正文' : vol.title.trim();
      final volChapters = <({String title, String href})>[];
      for (final ch in vol.chapters) {
        chIndex++;
        final chNum = chIndex.toString().padLeft(4, '0');
        final chId = 'ch_$chNum';
        final chHref = '$chId.xhtml';
        final chTitle = ch.title.trim().isEmpty ? '第 $chIndex 章' : ch.title.trim();

        final bodyBuf = StringBuffer()..writeln('  <h2>${_xmlEscape(chTitle)}</h2>');
        for (final rawLine in ch.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
          final line = rawLine.replaceFirst(RegExp(r'^[\s\u3000]+'), '').trimRight();
          if (line.isEmpty) continue;
          bodyBuf.writeln('  <p>${_xmlEscape(line)}</p>');
        }

        var imgIndex = 0;
        for (final img in ch.images) {
          if (img.bytes.isEmpty) continue;
          imgIndex++;
          final fmt = detectImageFormat(img.bytes, img.name);
          final imgId = 'img_${chNum}_${imgIndex.toString().padLeft(3, '0')}';
          final imgHref = 'images/$imgId${fmt.ext}';
          archive.addFile(ArchiveFile.bytes('OEBPS/$imgHref', img.bytes));
          manifestItems.add('    <item id="$imgId" href="$imgHref" media-type="${fmt.mime}"/>');
          bodyBuf.writeln('  <div class="illus"><img src="$imgHref" alt=""/></div>');
        }

        final chXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${_xmlEscape(language)}">
<head>
  <meta charset="UTF-8"/>
  <title>${_xmlEscape(chTitle)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
${bodyBuf.toString()}</body>
</html>
''';
        archive.addFile(ArchiveFile.string('OEBPS/$chHref', chXhtml));
        manifestItems.add('    <item id="$chId" href="$chHref" media-type="application/xhtml+xml"/>');
        spineItems.add('    <itemref idref="$chId"/>');
        volChapters.add((title: chTitle, href: chHref));
        onProgress?.call(chIndex, totalChapters);
      }
      tocVolumes.add((title: volTitle, chapters: volChapters));
    }

    // 6. OEBPS/nav.xhtml（EPUB 3 两级目录：卷 → 章）
    final navBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!DOCTYPE html>')
      ..writeln('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="${_xmlEscape(language)}">')
      ..writeln('<head>')
      ..writeln('  <meta charset="UTF-8"/>')
      ..writeln('  <title>目录</title>')
      ..writeln('  <link rel="stylesheet" type="text/css" href="style.css"/>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('  <nav epub:type="toc" id="toc">')
      ..writeln('    <h1>目录</h1>')
      ..writeln('    <ol>');
    for (final v in tocVolumes) {
      final firstHref = v.chapters.first.href;
      navBuf.writeln('      <li>');
      navBuf.writeln('        <a href="$firstHref">${_xmlEscape(v.title)}</a>');
      navBuf.writeln('        <ol>');
      for (final c in v.chapters) {
        navBuf.writeln('          <li><a href="${c.href}">${_xmlEscape(c.title)}</a></li>');
      }
      navBuf.writeln('        </ol>');
      navBuf.writeln('      </li>');
    }
    navBuf
      ..writeln('    </ol>')
      ..writeln('  </nav>')
      ..writeln('</body>')
      ..writeln('</html>');
    archive.addFile(ArchiveFile.string('OEBPS/nav.xhtml', navBuf.toString()));

    // 7. OEBPS/toc.ncx（EPUB 2 兼容两级目录）
    final ncxBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">')
      ..writeln('  <head>')
      ..writeln('    <meta name="dtb:uid" content="${_xmlEscape(bookId)}"/>')
      ..writeln('    <meta name="dtb:depth" content="2"/>')
      ..writeln('    <meta name="dtb:totalPageCount" content="0"/>')
      ..writeln('    <meta name="dtb:maxPageNumber" content="0"/>')
      ..writeln('  </head>')
      ..writeln('  <docTitle><text>${_xmlEscape(safeTitle)}</text></docTitle>')
      ..writeln('  <navMap>');
    var playOrder = 0;
    for (var vi = 0; vi < tocVolumes.length; vi++) {
      final v = tocVolumes[vi];
      playOrder++;
      ncxBuf
        ..writeln('    <navPoint id="vol_${vi + 1}" playOrder="$playOrder">')
        ..writeln('      <navLabel><text>${_xmlEscape(v.title)}</text></navLabel>')
        ..writeln('      <content src="${v.chapters.first.href}"/>');
      for (var ci = 0; ci < v.chapters.length; ci++) {
        final c = v.chapters[ci];
        playOrder++;
        ncxBuf
          ..writeln('      <navPoint id="ch_${vi + 1}_${ci + 1}" playOrder="$playOrder">')
          ..writeln('        <navLabel><text>${_xmlEscape(c.title)}</text></navLabel>')
          ..writeln('        <content src="${c.href}"/>')
          ..writeln('      </navPoint>');
      }
      ncxBuf.writeln('    </navPoint>');
    }
    ncxBuf
      ..writeln('  </navMap>')
      ..writeln('</ncx>');
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', ncxBuf.toString()));

    // 8. OEBPS/content.opf
    final opfBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">')
      ..writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">')
      ..writeln('    <dc:identifier id="bookid">${_xmlEscape(bookId)}</dc:identifier>')
      ..writeln('    <dc:title>${_xmlEscape(safeTitle)}</dc:title>');
    if (safeAuthor.isNotEmpty) {
      opfBuf.writeln('    <dc:creator>${_xmlEscape(safeAuthor)}</dc:creator>');
    }
    opfBuf.writeln('    <dc:language>${_xmlEscape(language)}</dc:language>');
    if (safeDesc.isNotEmpty) {
      opfBuf.writeln('    <dc:description>${_xmlEscape(safeDesc)}</dc:description>');
    }
    opfBuf.writeln('    <meta property="dcterms:modified">${_isoUtcNow()}</meta>');
    if (hasCover) {
      opfBuf.writeln('    <meta name="cover" content="cover-image"/>');
    }
    opfBuf
      ..writeln('  </metadata>')
      ..writeln('  <manifest>');
    for (final item in manifestItems) {
      opfBuf.writeln(item);
    }
    opfBuf
      ..writeln('  </manifest>')
      ..writeln('  <spine toc="ncx">');
    for (final item in spineItems) {
      opfBuf.writeln(item);
    }
    opfBuf.writeln('  </spine>');
    if (hasCover) {
      opfBuf
        ..writeln('  <guide>')
        ..writeln('    <reference type="cover" title="封面" href="cover.xhtml"/>')
        ..writeln('  </guide>');
    }
    opfBuf.writeln('</package>');
    archive.addFile(ArchiveFile.string('OEBPS/content.opf', opfBuf.toString()));

    return ZipEncoder().encodeBytes(archive);
  }
}

/// 排版干净的 UTF-8 TXT 生成器。
class TxtBuilder {
  TxtBuilder._();

  static Uint8List build({
    required String title,
    String author = '',
    String description = '',
    required List<EpubVolumeData> volumes,
    void Function(int done, int total)? onProgress,
  }) {
    final safeTitle = title.trim().isEmpty ? '未命名书籍' : title.trim();
    final safeAuthor = author.trim();
    final safeDesc = description.trim();
    final buf = StringBuffer()..writeln(safeTitle);
    if (safeAuthor.isNotEmpty) buf.writeln('作者：$safeAuthor');
    if (safeDesc.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('简介：')
        ..writeln(safeDesc);
    }

    final nonEmptyVols = [
      for (final v in volumes)
        if (v.chapters.isNotEmpty) v,
    ];
    final totalChapters = nonEmptyVols.fold<int>(0, (s, v) => s + v.chapters.length);
    var done = 0;

    for (final vol in nonEmptyVols) {
      final volTitle = vol.title.trim();
      if (volTitle.isNotEmpty && (nonEmptyVols.length > 1 || volTitle != '正文')) {
        buf
          ..writeln()
          ..writeln(volTitle);
      }
      for (final ch in vol.chapters) {
        done++;
        final chTitle = ch.title.trim();
        buf
          ..writeln()
          ..writeln(chTitle.isEmpty ? '第 $done 章' : chTitle)
          ..writeln();
        for (final rawLine in ch.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
          final line = rawLine.replaceFirst(RegExp(r'^[\s\u3000]+'), '').trimRight();
          if (line.isEmpty) continue;
          buf.writeln('　　$line');
        }
        onProgress?.call(done, totalChapters);
      }
    }
    return Uint8List.fromList(utf8.encode(buf.toString()));
  }
}

// =============================================================================
// 安全解压与轻量 XML 解析（用于 container.xml / content.opf / toc.ncx）
// =============================================================================

/// 限额内存输出流：即使恶意 zip 伪造 header 中的 size，解压时超出上限也会立刻中断，防止 zip bomb 撑爆内存。
class _BoundedOutputStream extends OutputMemoryStream {
  _BoundedOutputStream(this.maxBytes);

  final int maxBytes;

  void _check(int incoming) {
    if (length + incoming > maxBytes) {
      throw const FormatException('EPUB 内存在超大文件，已中止解析');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

class _XmlNode {
  _XmlNode(this.name, this.attrs);

  final String name;
  final Map<String, String> attrs;
  final List<_XmlNode> children = [];
  final StringBuffer _text = StringBuffer();

  String get localName {
    final i = name.indexOf(':');
    return (i >= 0 ? name.substring(i + 1) : name).toLowerCase();
  }

  String get text {
    if (children.isEmpty) return _text.toString();
    final buf = StringBuffer(_text.toString());
    for (final c in children) {
      buf.write(c.text);
    }
    return buf.toString();
  }

  String? attr(String key) {
    final lower = key.toLowerCase();
    for (final e in attrs.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  Iterable<_XmlNode> findAll(String local) sync* {
    final target = local.toLowerCase();
    for (final c in children) {
      if (c.localName == target) yield c;
      yield* c.findAll(target);
    }
  }

  _XmlNode? findFirst(String local) => findAll(local).firstOrNull;
}

String _unescapeXml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);'), (m) {
    final entity = m[1]!;
    return switch (entity) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => '\u00A0',
      _ when entity.startsWith('#x') || entity.startsWith('#X') => _safeChar(int.tryParse(entity.substring(2), radix: 16)),
      _ when entity.startsWith('#') => _safeChar(int.tryParse(entity.substring(1))),
      _ => m[0]!,
    };
  });
}

String _safeChar(int? code) {
  if (code == null || code <= 0 || code > 0x10FFFF) return '';
  if (code >= 0xD800 && code <= 0xDFFF) return '';
  return String.fromCharCode(code);
}

/// 轻量级、容错的 XML 树解析器：正确支持自闭合标签、命名空间、CDATA、注释与 DOCTYPE，
/// 避免 HTML5 解析器将 `<item .../>`、`<content .../>` 错误嵌套的问题。
_XmlNode _parseXml(String src) {
  final root = _XmlNode('#root', const {});
  final stack = <_XmlNode>[root];
  final n = src.length;
  var i = 0;

  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
  bool isNameChar(int c) => !isSpace(c) && c != 0x3E /* > */ && c != 0x2F /* / */ && c != 0x3D /* = */;

  while (i < n) {
    final lt = src.indexOf('<', i);
    if (lt < 0) {
      stack.last._text.write(_unescapeXml(src.substring(i)));
      break;
    }
    if (lt > i) {
      stack.last._text.write(_unescapeXml(src.substring(i, lt)));
    }
    i = lt;

    // 注释 <!-- ... -->
    if (src.startsWith('<!--', i)) {
      final end = src.indexOf('-->', i + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    // CDATA <![CDATA[ ... ]]>
    if (src.startsWith('<![CDATA[', i)) {
      final end = src.indexOf(']]>', i + 9);
      if (end < 0) {
        stack.last._text.write(src.substring(i + 9));
        break;
      }
      stack.last._text.write(src.substring(i + 9, end));
      i = end + 3;
      continue;
    }
    // 处理指令 <? ... ?>
    if (src.startsWith('<?', i)) {
      final end = src.indexOf('?>', i + 2);
      i = end < 0 ? n : end + 2;
      continue;
    }
    // DOCTYPE / 声明 <! ... >（含内部子集 [...]）
    if (src.startsWith('<!', i)) {
      i += 2;
      var inBracket = false;
      var quote = 0;
      while (i < n) {
        final c = src.codeUnitAt(i++);
        if (quote != 0) {
          if (c == quote) quote = 0;
        } else if (c == 0x22 || c == 0x27) {
          quote = c;
        } else if (c == 0x5B /* [ */) {
          inBracket = true;
        } else if (c == 0x5D /* ] */) {
          inBracket = false;
        } else if (c == 0x3E /* > */ && !inBracket) {
          break;
        }
      }
      continue;
    }
    // 闭合标签 </name>
    if (src.startsWith('</', i)) {
      i += 2;
      while (i < n && isSpace(src.codeUnitAt(i))) {
        i++;
      }
      final start = i;
      while (i < n && isNameChar(src.codeUnitAt(i))) {
        i++;
      }
      final closeName = src.substring(start, i).toLowerCase();
      final gt = src.indexOf('>', i);
      i = gt < 0 ? n : gt + 1;
      for (var k = stack.length - 1; k >= 1; k--) {
        if (stack[k].name.toLowerCase() == closeName) {
          stack.length = k;
          break;
        }
      }
      continue;
    }

    // 开始标签 <name attr="val" ... [/]>
    i++; // skip '<'
    while (i < n && isSpace(src.codeUnitAt(i))) {
      i++;
    }
    final nameStart = i;
    while (i < n && isNameChar(src.codeUnitAt(i))) {
      i++;
    }
    if (i == nameStart) {
      stack.last._text.write('<');
      continue;
    }
    final tagName = src.substring(nameStart, i);
    final attrs = <String, String>{};
    var selfClosing = false;

    while (i < n) {
      while (i < n && isSpace(src.codeUnitAt(i))) {
        i++;
      }
      if (i >= n) break;
      final c = src.codeUnitAt(i);
      if (c == 0x3E /* > */) {
        i++;
        break;
      }
      if (c == 0x2F /* / */) {
        selfClosing = true;
        i++;
        if (i < n && src.codeUnitAt(i) == 0x3E) i++;
        break;
      }
      final attrStart = i;
      while (i < n && isNameChar(src.codeUnitAt(i))) {
        i++;
      }
      if (i == attrStart) {
        i++;
        continue;
      }
      final attrName = src.substring(attrStart, i);
      while (i < n && isSpace(src.codeUnitAt(i))) {
        i++;
      }
      var attrVal = '';
      if (i < n && src.codeUnitAt(i) == 0x3D /* = */) {
        i++;
        while (i < n && isSpace(src.codeUnitAt(i))) {
          i++;
        }
        if (i < n && (src.codeUnitAt(i) == 0x22 || src.codeUnitAt(i) == 0x27)) {
          final q = src.codeUnitAt(i++);
          final valStart = i;
          while (i < n && src.codeUnitAt(i) != q) {
            i++;
          }
          attrVal = _unescapeXml(src.substring(valStart, i));
          if (i < n) i++;
        } else {
          final valStart = i;
          while (i < n && !isSpace(src.codeUnitAt(i)) && src.codeUnitAt(i) != 0x3E && src.codeUnitAt(i) != 0x2F) {
            i++;
          }
          attrVal = _unescapeXml(src.substring(valStart, i));
        }
      }
      attrs[attrName] = attrVal;
    }

    final node = _XmlNode(tagName, attrs);
    stack.last.children.add(node);
    if (!selfClosing) stack.add(node);
  }
  return root;
}

class _ManifestItem {
  const _ManifestItem({required this.id, required this.href, required this.path, required this.mediaType, required this.properties});

  final String id;
  final String href;
  final String path;
  final String mediaType;
  final Set<String> properties;

  bool get isImage => mediaType.startsWith('image/');
}

class _TocEntry {
  const _TocEntry({required this.title, this.path, this.children = const []});

  final String title;
  final String? path;
  final List<_TocEntry> children;
}

/// 标准 EPUB 2 / EPUB 3 解析器（含 Zip Slip 与 Zip Bomb 防护）。
class EpubParser {
  EpubParser._();

  static const int maxEntryBytes = 32 << 20; // 单文件上限 32 MB
  static const int maxTotalBytes = 256 << 20; // 解压总大小上限 256 MB
  static const int maxEntries = 10000;

  /// 严格校验并规范 zip 内路径，拒绝任何 Zip Slip 穿越或绝对路径。
  static String validateZipPath(String rawName) {
    if (rawName.contains('\x00')) throw FormatException('不安全的 EPUB 路径：$rawName');
    if (rawName.startsWith('/') || rawName.startsWith('\\') || RegExp(r'^[A-Za-z]:').hasMatch(rawName)) {
      throw FormatException('不安全的 EPUB 绝对路径：$rawName');
    }
    final normalized = rawName.replaceAll('\\', '/');
    final out = <String>[];
    for (final seg in normalized.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') throw FormatException('检测到非法路径穿越（Zip Slip）：$rawName');
      out.add(seg);
    }
    if (out.isEmpty) throw FormatException('无效的 EPUB 路径：$rawName');
    return out.join('/');
  }

  static String? _resolveRelativePath(String baseDir, String rawHref) {
    final cleaned = rawHref.split('#').first.split('?').first.trim();
    if (cleaned.isEmpty) return null;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(cleaned)) return null; // 跳过 http/data/mailto 等外部协议
    String decoded;
    try {
      decoded = Uri.decodeFull(cleaned);
    } catch (_) {
      decoded = cleaned;
    }
    if (decoded.contains('\x00')) return null;
    final combined = decoded.startsWith('/') ? decoded.substring(1) : (baseDir.isEmpty ? decoded : '$baseDir/$decoded');
    final out = <String>[];
    for (final seg in combined.replaceAll('\\', '/').split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isEmpty) return null; // 不允许越出压缩包根目录
        out.removeLast();
      } else {
        out.add(seg);
      }
    }
    return out.isEmpty ? null : out.join('/');
  }

  static ParsedBook parseBytes(Uint8List bytes, {String fallbackTitle = '未命名书籍'}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('无法解析 EPUB 文件（压缩包已损坏或格式不支持）');
    }

    if (archive.files.length > maxEntries) {
      throw const FormatException('EPUB 文件条目过多，已中止解析');
    }

    final entries = <String, ArchiveFile>{};
    final entriesLower = <String, ArchiveFile>{};
    var declaredTotal = 0;

    for (final file in archive.files) {
      if (!file.isFile) {
        // 目录条目也要做路径穿越校验
        if (file.name.isNotEmpty) {
          final trimmed = file.name.endsWith('/') || file.name.endsWith('\\') ? file.name.substring(0, file.name.length - 1) : file.name;
          if (trimmed.isNotEmpty) validateZipPath(trimmed);
        }
        continue;
      }
      final safePath = validateZipPath(file.name);
      if (file.size < 0 || file.size > maxEntryBytes) {
        throw const FormatException('EPUB 内存在超大文件，已中止解析');
      }
      declaredTotal += file.size;
      if (declaredTotal > maxTotalBytes) {
        throw const FormatException('EPUB 解压体积超出限制');
      }
      entries[safePath] = file;
      entriesLower[safePath.toLowerCase()] = file;
    }

    var extractedTotal = 0;
    final bytesCache = <String, Uint8List>{};

    ArchiveFile? findEntry(String path) => entries[path] ?? entriesLower[path.toLowerCase()];

    Uint8List? readEntryBytes(String path) {
      final key = path.toLowerCase();
      final cached = bytesCache[key];
      if (cached != null) return cached;
      final file = findEntry(path);
      if (file == null) return null;
      final remaining = maxTotalBytes - extractedTotal;
      final limit = remaining < maxEntryBytes ? remaining : maxEntryBytes;
      if (limit <= 0) throw const FormatException('EPUB 解压体积超出限制');
      final out = _BoundedOutputStream(limit);
      file.writeContent(out, freeMemory: false);
      final data = Uint8List.fromList(out.getBytes());
      extractedTotal += data.length;
      bytesCache[key] = data;
      return data;
    }

    String? readEntryText(String path) {
      final raw = readEntryBytes(path);
      if (raw == null) return null;
      return _decodeTextBytes(raw);
    }

    // 1. 解析 META-INF/container.xml 找到 OPF 路径
    String? opfPath;
    final containerText = readEntryText('META-INF/container.xml');
    if (containerText != null) {
      final containerXml = _parseXml(containerText);
      for (final rf in containerXml.findAll('rootfile')) {
        final fullPath = rf.attr('full-path')?.trim();
        if (fullPath != null && fullPath.isNotEmpty) {
          opfPath = _resolveRelativePath('', fullPath);
          if (opfPath != null) break;
        }
      }
    }
    opfPath ??= entries.keys.where((k) => k.toLowerCase().endsWith('.opf')).firstOrNull;
    if (opfPath == null) {
      throw const FormatException('无效的 EPUB 文件：缺少 OPF 索引');
    }

    final opfText = readEntryText(opfPath);
    if (opfText == null) {
      throw const FormatException('无效的 EPUB 文件：无法读取 OPF 索引');
    }
    final opfDir = p.posix.dirname(opfPath) == '.' ? '' : p.posix.dirname(opfPath);
    final opfXml = _parseXml(opfText);

    // 2. 元数据
    final metaNode = opfXml.findFirst('metadata');
    final rawTitle = metaNode?.findFirst('title')?.text.trim() ?? '';
    final title = rawTitle.isEmpty ? fallbackTitle : rawTitle;
    final authors = [
      for (final c in metaNode?.findAll('creator') ?? const <_XmlNode>[])
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    final author = authors.join(' / ');
    final rawDesc = metaNode?.findFirst('description')?.text.trim() ?? '';
    final description = RegExp(r'<(?:p|br|div|span|b|i|em|strong|a|ul|ol|li|h[1-6])\b', caseSensitive: false).hasMatch(rawDesc)
        ? (html_parser.parseFragment(rawDesc).text ?? rawDesc).trim()
        : rawDesc;

    String? metaCoverContent;
    for (final m in metaNode?.findAll('meta') ?? const <_XmlNode>[]) {
      if ((m.attr('name') ?? '').toLowerCase() == 'cover') {
        final content = m.attr('content')?.trim();
        if (content != null && content.isNotEmpty) {
          metaCoverContent = content;
          break;
        }
      }
    }

    // 3. Manifest
    final manifest = <String, _ManifestItem>{};
    final manifestByPath = <String, _ManifestItem>{};
    for (final item in opfXml.findAll('item')) {
      final id = item.attr('id')?.trim() ?? '';
      final href = item.attr('href')?.trim() ?? '';
      final mediaType = (item.attr('media-type') ?? '').trim().toLowerCase();
      final props = (item.attr('properties') ?? '').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toSet();
      final resolved = _resolveRelativePath(opfDir, href);
      if (id.isEmpty || resolved == null) continue;
      final mi = _ManifestItem(id: id, href: href, path: resolved, mediaType: mediaType, properties: props);
      manifest[id] = mi;
      manifestByPath[resolved.toLowerCase()] = mi;
    }

    // 4. Spine & Guide
    final spineNode = opfXml.findFirst('spine');
    final spineTocId = spineNode?.attr('toc')?.trim();
    final spinePaths = <String>[];
    final seenSpine = <String>{};
    for (final itemref in spineNode?.findAll('itemref') ?? const <_XmlNode>[]) {
      final idref = itemref.attr('idref')?.trim();
      if (idref == null) continue;
      final item = manifest[idref];
      if (item != null && seenSpine.add(item.path.toLowerCase())) {
        spinePaths.add(item.path);
      }
    }

    final coverPagePaths = <String>{};
    for (final ref in opfXml.findAll('reference')) {
      if ((ref.attr('type') ?? '').toLowerCase() == 'cover') {
        final resolved = _resolveRelativePath(opfDir, ref.attr('href') ?? '');
        if (resolved != null) coverPagePaths.add(resolved.toLowerCase());
      }
    }
    for (final item in manifest.values) {
      if (!item.isImage && (item.id.toLowerCase() == 'cover' || item.id.toLowerCase() == 'coverpage' || p.posix.basenameWithoutExtension(item.path).toLowerCase() == 'cover')) {
        coverPagePaths.add(item.path.toLowerCase());
      }
    }

    // 5. 封面定位
    String? coverPath;
    // (a) EPUB 3 properties="cover-image"
    for (final item in manifest.values) {
      if (item.properties.contains('cover-image')) {
        coverPath = item.path;
        break;
      }
    }
    // (b) EPUB 2 <meta name="cover" content="..."/>
    if (coverPath == null && metaCoverContent != null) {
      final byId = manifest[metaCoverContent];
      if (byId != null && byId.isImage) {
        coverPath = byId.path;
      } else {
        final byHref = _resolveRelativePath(opfDir, metaCoverContent);
        if (byHref != null && findEntry(byHref) != null) coverPath = byHref;
      }
    }
    // (c) cover.xhtml 里的第一张图
    if (coverPath == null) {
      for (final cp in coverPagePaths) {
        final xhtml = readEntryText(cp);
        if (xhtml == null) continue;
        final extracted = _extractXhtml(xhtml, xhtmlDir: p.posix.dirname(cp) == '.' ? '' : p.posix.dirname(cp), readBytes: readEntryBytes);
        if (extracted.imagePaths.isNotEmpty) {
          coverPath = extracted.imagePaths.first;
          break;
        }
      }
    }
    // (d) 文件名含 cover 的图片
    if (coverPath == null) {
      for (final item in manifest.values) {
        if (item.isImage && p.posix.basenameWithoutExtension(item.path).toLowerCase().contains('cover')) {
          coverPath = item.path;
          break;
        }
      }
      coverPath ??= entries.keys.where((k) {
        final ext = p.posix.extension(k).toLowerCase();
        return {'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(ext) && p.posix.basenameWithoutExtension(k).toLowerCase().contains('cover');
      }).firstOrNull;
    }

    Uint8List? coverBytes = coverPath == null ? null : readEntryBytes(coverPath);
    String? coverExt = coverBytes == null || coverBytes.isEmpty ? null : detectImageFormat(coverBytes, coverPath).ext;

    // 6. 目录解析（优先 EPUB 3 nav.xhtml，其次 EPUB 2 toc.ncx）
    final navItem = manifest.values.where((m) => m.properties.contains('nav')).firstOrNull;
    final ncxItem = (spineTocId != null ? manifest[spineTocId] : null) ??
        manifest.values.where((m) => m.mediaType == 'application/x-dtbncx+xml' || m.path.toLowerCase().endsWith('.ncx')).firstOrNull;

    var tocEntries = <_TocEntry>[];
    if (navItem != null) {
      final navText = readEntryText(navItem.path);
      if (navText != null) {
        final navDir = p.posix.dirname(navItem.path) == '.' ? '' : p.posix.dirname(navItem.path);
        tocEntries = _parseNavXhtml(navText, navDir);
      }
    }
    if (tocEntries.isEmpty && ncxItem != null) {
      final ncxText = readEntryText(ncxItem.path);
      if (ncxText != null) {
        final ncxDir = p.posix.dirname(ncxItem.path) == '.' ? '' : p.posix.dirname(ncxItem.path);
        tocEntries = _parseTocNcx(ncxText, ncxDir);
      }
    }

    // 7. 将 TOC 层级与 spine 顺序结合成「卷 → 章」
    final hasNestedToc = tocEntries.any((e) => e.children.isNotEmpty);
    final volumeTitles = <String>[];
    final pathMeta = <String, ({int volIndex, String title})>{};

    int ensureVolume(String name) {
      final clean = name.trim().isEmpty ? '正文' : name.trim();
      volumeTitles.add(clean);
      return volumeTitles.length - 1;
    }

    if (hasNestedToc) {
      int? looseVolIndex;
      void collectLeaves(List<_TocEntry> nodes, int volIndex) {
        for (final node in nodes) {
          final np = node.path?.toLowerCase();
          if (node.children.isEmpty) {
            if (np != null) pathMeta.putIfAbsent(np, () => (volIndex: volIndex, title: node.title));
          } else {
            final childPaths = <String>{};
            void gather(List<_TocEntry> list) {
              for (final c in list) {
                if (c.path != null) childPaths.add(c.path!.toLowerCase());
                gather(c.children);
              }
            }

            gather(node.children);
            if (np != null && !childPaths.contains(np)) {
              pathMeta.putIfAbsent(np, () => (volIndex: volIndex, title: node.title));
            }
            collectLeaves(node.children, volIndex);
          }
        }
      }

      for (final top in tocEntries) {
        if (top.children.isNotEmpty) {
          looseVolIndex = null;
          final vi = ensureVolume(top.title);
          final childPaths = <String>{};
          void gather(List<_TocEntry> list) {
            for (final c in list) {
              if (c.path != null) childPaths.add(c.path!.toLowerCase());
              gather(c.children);
            }
          }

          gather(top.children);
          final topPath = top.path?.toLowerCase();
          if (topPath != null && !childPaths.contains(topPath)) {
            pathMeta.putIfAbsent(topPath, () => (volIndex: vi, title: top.title));
          }
          collectLeaves(top.children, vi);
        } else {
          final np = top.path?.toLowerCase();
          if (np == null) continue;
          looseVolIndex ??= ensureVolume(volumeTitles.isEmpty ? '正文' : '其他');
          pathMeta.putIfAbsent(np, () => (volIndex: looseVolIndex!, title: top.title));
        }
      }
    } else if (tocEntries.isNotEmpty) {
      final vi = ensureVolume('正文');
      for (final e in tocEntries) {
        final ep = e.path?.toLowerCase();
        if (ep != null) pathMeta.putIfAbsent(ep, () => (volIndex: vi, title: e.title));
      }
    } else {
      ensureVolume('正文');
    }

    // 确定待解析的章节路径顺序：以 spine 为主，若 spine 为空则回退到 TOC 路径
    final orderedPaths = <String>[...spinePaths];
    if (orderedPaths.isEmpty) {
      void addTocPaths(List<_TocEntry> list) {
        for (final e in list) {
          if (e.path != null && seenSpine.add(e.path!.toLowerCase())) orderedPaths.add(e.path!);
          addTocPaths(e.children);
        }
      }

      addTocPaths(tocEntries);
    }

    final navLower = navItem?.path.toLowerCase();
    final volChapters = List<List<EpubChapterData>>.generate(volumeTitles.length, (_) => []);
    var currentVol = 0;
    var chapterSeq = 0;
    ({Uint8List bytes, String ext})? firstChapterImage;

    for (final path in orderedPaths) {
      final lower = path.toLowerCase();
      if (lower == navLower) continue;
      final xhtml = readEntryText(path);
      if (xhtml == null) continue;
      final dir = p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
      final meta = pathMeta[lower];
      final extracted = _extractXhtml(xhtml, xhtmlDir: dir, readBytes: readEntryBytes, knownTitle: meta?.title);

      // 纯封面页（无正文，且只有封面图）：跳过，不变成空正文首章
      if (coverPagePaths.contains(lower) && extracted.text.isEmpty) {
        if ((coverBytes == null || coverBytes.isEmpty) && extracted.images.isNotEmpty) {
          coverBytes = extracted.images.first.bytes;
          coverExt = detectImageFormat(coverBytes, extracted.images.first.name).ext;
        }
        continue;
      }

      if (extracted.text.isEmpty && extracted.images.isEmpty) continue;

      if (firstChapterImage == null && extracted.images.isNotEmpty) {
        final first = extracted.images.first;
        firstChapterImage = (bytes: first.bytes, ext: detectImageFormat(first.bytes, first.name).ext);
      }

      chapterSeq++;
      final volIdx = meta?.volIndex ?? currentVol;
      currentVol = volIdx;
      final chTitle = (meta?.title.trim().isNotEmpty ?? false)
          ? meta!.title.trim()
          : (extracted.heading.isNotEmpty ? extracted.heading : '第 $chapterSeq 章');
      volChapters[volIdx].add(EpubChapterData(title: chTitle, text: extracted.text, images: extracted.images));
    }

    // 兜底封面：若未显式声明封面，使用首张插图
    if ((coverBytes == null || coverBytes.isEmpty) && firstChapterImage != null) {
      coverBytes = firstChapterImage.bytes;
      coverExt = firstChapterImage.ext;
    }

    final resultVolumes = <EpubVolumeData>[
      for (var i = 0; i < volumeTitles.length; i++)
        if (volChapters[i].isNotEmpty) EpubVolumeData(title: volumeTitles[i], chapters: volChapters[i]),
    ];

    if (resultVolumes.isEmpty) {
      throw const FormatException('EPUB 中未解析出可阅读的章节内容');
    }

    return ParsedBook(
      title: title,
      author: author,
      description: description,
      coverBytes: coverBytes,
      coverExt: coverExt,
      volumes: resultVolumes,
    );
  }

  static List<_TocEntry> _parseNavXhtml(String xhtml, String navDir) {
    final doc = html_parser.parse(xhtml);
    dom.Element? tocNav;
    for (final nav in doc.querySelectorAll('nav')) {
      final type = (nav.attributes['epub:type'] ?? nav.attributes['role'] ?? nav.id).toLowerCase();
      if (type.contains('toc')) {
        tocNav = nav;
        break;
      }
    }
    tocNav ??= doc.querySelector('nav');
    final rootOl = tocNav?.querySelector('ol');
    if (rootOl == null) return const [];

    List<_TocEntry> parseOl(dom.Element ol) {
      final out = <_TocEntry>[];
      for (final child in ol.children) {
        if (child.localName != 'li') continue;
        dom.Element? link;
        dom.Element? labelEl;
        dom.Element? subOl;
        for (final el in child.children) {
          if (el.localName == 'a' && link == null) {
            link = el;
          } else if (el.localName == 'span' && labelEl == null) {
            labelEl = el;
          } else if (el.localName == 'ol' && subOl == null) {
            subOl = el;
          }
        }
        final label = (link?.text ?? labelEl?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
        final href = link?.attributes['href'];
        final resolved = href == null ? null : _resolveRelativePath(navDir, href);
        final children = subOl == null ? const <_TocEntry>[] : parseOl(subOl);
        if (label.isEmpty && children.isEmpty) continue;
        out.add(_TocEntry(title: label.isEmpty ? '章节' : label, path: resolved, children: children));
      }
      return out;
    }

    return parseOl(rootOl);
  }

  static List<_TocEntry> _parseTocNcx(String ncx, String ncxDir) {
    final xml = _parseXml(ncx);
    final navMap = xml.findFirst('navmap');
    if (navMap == null) return const [];

    List<_TocEntry> parsePoints(List<_XmlNode> nodes) {
      final out = <_TocEntry>[];
      for (final node in nodes) {
        if (node.localName != 'navpoint') continue;
        final label = node.findFirst('navlabel')?.findFirst('text')?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
        String? src;
        for (final c in node.children) {
          if (c.localName == 'content') {
            src = c.attr('src');
            break;
          }
        }
        final resolved = src == null ? null : _resolveRelativePath(ncxDir, src);
        final children = parsePoints(node.children);
        if (label.isEmpty && children.isEmpty) continue;
        out.add(_TocEntry(title: label.isEmpty ? '章节' : label, path: resolved, children: children));
      }
      return out;
    }

    return parsePoints(navMap.children);
  }

  static const _blockTags = {
    'p',
    'div',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'blockquote',
    'pre',
    'tr',
    'section',
    'article',
    'header',
    'footer',
    'dt',
    'dd',
    'figcaption',
    'hr',
  };

  static const _skipTags = {'script', 'style', 'noscript', 'rt', 'rp'};

  static ({String heading, String text, List<({String name, Uint8List bytes})> images, List<String> imagePaths}) _extractXhtml(
    String xhtml, {
    required String xhtmlDir,
    required Uint8List? Function(String path) readBytes,
    String? knownTitle,
  }) {
    final doc = html_parser.parse(xhtml);
    final body = doc.body ?? doc.documentElement;
    if (body == null) return (heading: '', text: '', images: const [], imagePaths: const []);

    final heading = (body.querySelector('h1, h2, h3')?.text ?? doc.querySelector('title')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

    final images = <({String name, Uint8List bytes})>[];
    final imagePaths = <String>[];
    final seenImages = <String>{};

    void addImgSrc(String? rawSrc) {
      if (rawSrc == null || rawSrc.trim().isEmpty) return;
      final resolved = _resolveRelativePath(xhtmlDir, rawSrc);
      if (resolved == null || !seenImages.add(resolved.toLowerCase())) return;
      final b = readBytes(resolved);
      if (b == null || b.isEmpty) return;
      imagePaths.add(resolved);
      images.add((name: p.posix.basename(resolved), bytes: b));
    }

    final buf = StringBuffer();
    void walk(dom.Node node) {
      if (node is dom.Text) {
        final t = node.text.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
        buf.write(t);
        return;
      }
      if (node is! dom.Element) return;
      final tag = (node.localName ?? '').toLowerCase();
      if (_skipTags.contains(tag)) return;
      if (tag == 'br') {
        buf.write('\n');
        return;
      }
      if (tag == 'img') {
        addImgSrc(node.attributes['src']);
        return;
      }
      if (tag == 'image') {
        String? svgHref;
        for (final entry in node.attributes.entries) {
          final k = entry.key.toString().toLowerCase();
          if (k == 'href' || k == 'xlink:href' || k.endsWith(':href')) {
            svgHref = entry.value;
            break;
          }
        }
        addImgSrc(svgHref);
        return;
      }
      final isBlock = _blockTags.contains(tag);
      if (isBlock) buf.write('\n');
      for (final child in node.nodes) {
        walk(child);
      }
      if (isBlock) buf.write('\n');
    }

    walk(body);

    final lines = <String>[];
    for (final raw in buf.toString().split('\n')) {
      final line = raw.replaceAll('\u00A0', ' ').trim();
      if (line.isNotEmpty) lines.add(line);
    }

    // 去掉首行与章节标题完全重复的标题行，避免阅读器顶部标题和正文第一行重复显示
    final targetTitle = (knownTitle?.trim().isNotEmpty ?? false) ? knownTitle!.trim() : heading;
    if (lines.isNotEmpty && targetTitle.isNotEmpty && lines.first == targetTitle) {
      lines.removeAt(0);
    }

    return (heading: heading, text: lines.join('\n'), images: images, imagePaths: imagePaths);
  }
}

/// 文本编码自动检测与解码（UTF-8 BOM / UTF-16 BOM / 严格 UTF-8 / GBK 兜底）。
String _decodeTextBytes(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  // UTF-8 BOM
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  // UTF-16 LE BOM
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  // UTF-16 BE BOM
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  // 严格 UTF-8 优先
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return const GbkCodec(allowInvalid: true).decode(bytes);
  }
}

/// 智能 TXT 解析器（自动编码检测 + 卷/章正则识别 + 超长/无标题自动按段落切分）。
class TxtParser {
  TxtParser._();

  static const int maxChapterChars = 25000;
  static const int _maxHeadingLength = 60;

  static final _volumePattern = RegExp(
    r'^(?:第\s*[一二三四五六七八九十百千万〇零两0-9]+\s*[卷部篇册集](?:[\s\u3000:：\-—·、].*)?|(?:Volume|Vol\.?|Book|Part)\s*\d+(?:[\s:.\-—].*)?)$',
    caseSensitive: false,
  );

  static final _chapterPattern = RegExp(
    r'^(?:第\s*[一二三四五六七八九十百千万〇零两0-9]+\s*[章回节话幕](?:[\s\u3000:：\-—·、].*)?|(?:序章|序幕|序言|楔子|引子|前言|终章|尾声|结局|后记|番外|外传|特别篇|特典|幕间|间章)(?:[\s\u3000:：\-—·、0-9一二三四五六七八九十].*)?|(?:Chapter|Ch\.?)\s*\d+(?:[\s:.\-—].*)?|(?:Prologue|Epilogue|Interlude|Afterword)(?:[\s:.\-—].*)?)$',
    caseSensitive: false,
  );

  static ParsedBook parseBytes(Uint8List bytes, {required String fallbackTitle}) {
    final decoded = _decodeTextBytes(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (decoded.trim().isEmpty) {
      throw const FormatException('TXT 文件内容为空');
    }

    final lines = decoded.split('\n');
    var author = '';
    final descLines = <String>[];

    final volumes = <({String title, List<({String title, List<String> lines})> chapters})>[];
    String? pendingVolTitle;
    ({String title, List<String> lines})? currentChapter;
    final prefaceLines = <String>[];
    var foundHeading = false;

    void ensureVolume(String volTitle) {
      volumes.add((title: volTitle, chapters: []));
    }

    void startChapter(String chTitle) {
      if (volumes.isEmpty) {
        ensureVolume(pendingVolTitle ?? '正文');
        pendingVolTitle = null;
      } else if (pendingVolTitle != null) {
        ensureVolume(pendingVolTitle!);
        pendingVolTitle = null;
      }
      final ch = (title: chTitle, lines: <String>[]);
      volumes.last.chapters.add(ch);
      currentChapter = ch;
    }

    var inDesc = false;
    for (final raw in lines) {
      final trimmed = raw.replaceFirst(RegExp(r'^[\s\u3000]+'), '').trimRight();
      if (trimmed.isEmpty) {
        if (!foundHeading) inDesc = false;
        continue;
      }

      if (trimmed.length <= _maxHeadingLength && _volumePattern.hasMatch(trimmed)) {
        foundHeading = true;
        inDesc = false;
        pendingVolTitle = trimmed;
        currentChapter = null;
        continue;
      }

      if (trimmed.length <= _maxHeadingLength && _chapterPattern.hasMatch(trimmed)) {
        foundHeading = true;
        inDesc = false;
        startChapter(trimmed);
        continue;
      }

      if (!foundHeading) {
        if (prefaceLines.length < 20) {
          final authorMatch = RegExp(r'^作者[：:]\s*(.+)$').firstMatch(trimmed);
          if (authorMatch != null && author.isEmpty) {
            author = authorMatch[1]!.trim();
            inDesc = false;
            continue;
          }
          if (trimmed == '简介：' || trimmed == '简介:') {
            inDesc = true;
            continue;
          }
          final descInline = RegExp(r'^简介[：:]\s*(.+)$').firstMatch(trimmed);
          if (descInline != null) {
            descLines.add(descInline[1]!.trim());
            inDesc = true;
            continue;
          }
          if (inDesc) {
            descLines.add(trimmed);
            continue;
          }
          // 若第一行就是书名本身，不重复当正文前言
          if (prefaceLines.isEmpty && (trimmed == fallbackTitle || trimmed == '《$fallbackTitle》')) {
            continue;
          }
        }
        prefaceLines.add(trimmed);
      } else {
        if (currentChapter == null) {
          startChapter(pendingVolTitle ?? '正文');
        }
        currentChapter!.lines.add(trimmed);
      }
    }

    // 处理前言或全书无章节标题的情况
    final resultVolumes = <EpubVolumeData>[];
    if (!foundHeading) {
      final allText = prefaceLines.join('\n').trim();
      final body = allText.isEmpty ? decoded.trim() : allText;
      final split = _splitByParagraphs(body, maxChars: maxChapterChars, baseTitle: null);
      resultVolumes.add(EpubVolumeData(title: '正文', chapters: split));
    } else {
      final prefaceText = prefaceLines.join('\n').trim();
      if (prefaceText.isNotEmpty) {
        final prefaceChapters = _splitByParagraphs(prefaceText, maxChars: maxChapterChars, baseTitle: '前言');
        if (volumes.isEmpty) {
          resultVolumes.add(EpubVolumeData(title: '正文', chapters: prefaceChapters));
        } else {
          volumes.first.chapters.insertAll(0, [for (final c in prefaceChapters) (title: c.title, lines: c.text.split('\n'))]);
        }
      }
      for (final v in volumes) {
        final chapters = <EpubChapterData>[];
        for (final ch in v.chapters) {
          final text = ch.lines.join('\n').trim();
          if (text.isEmpty) continue;
          chapters.addAll(_splitByParagraphs(text, maxChars: maxChapterChars, baseTitle: ch.title));
        }
        if (chapters.isNotEmpty) {
          resultVolumes.add(EpubVolumeData(title: v.title, chapters: chapters));
        }
      }
    }

    if (resultVolumes.isEmpty) {
      final body = decoded.trim();
      resultVolumes.add(EpubVolumeData(title: '正文', chapters: _splitByParagraphs(body, maxChars: maxChapterChars, baseTitle: null)));
    }

    return ParsedBook(
      title: fallbackTitle.trim().isEmpty ? '未命名书籍' : fallbackTitle.trim(),
      author: author,
      description: descLines.join('\n').trim(),
      volumes: resultVolumes,
    );
  }

  /// 按自然段边界切分过长章节；若单段本身超过 [maxChars]，优先在句末标点处切分。
  static List<EpubChapterData> _splitByParagraphs(String text, {required int maxChars, required String? baseTitle}) {
    if (text.length <= maxChars) {
      return [EpubChapterData(title: baseTitle ?? '正文', text: text)];
    }

    final chunks = <String>[];
    final buf = StringBuffer();

    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) chunks.add(s);
      buf.clear();
    }

    for (final rawPara in text.split('\n')) {
      final para = rawPara.trim();
      if (para.isEmpty) continue;

      if (para.length > maxChars) {
        flush();
        var start = 0;
        while (start < para.length) {
          final remaining = para.length - start;
          if (remaining <= maxChars) {
            chunks.add(para.substring(start));
            break;
          }
          var end = start + maxChars;
          // 尽量回退到最近的句末标点，避免拦腰截断句子
          final searchFrom = start + (maxChars * 0.7).floor();
          var cut = -1;
          for (var k = end - 1; k >= searchFrom; k--) {
            final ch = para[k];
            if (ch == '。' || ch == '！' || ch == '？' || ch == '.' || ch == '!' || ch == '?' || ch == '”' || ch == '」') {
              cut = k + 1;
              break;
            }
          }
          if (cut > start) end = cut;
          chunks.add(para.substring(start, end).trim());
          start = end;
        }
        continue;
      }

      if (buf.isNotEmpty && buf.length + 1 + para.length > maxChars) {
        flush();
      }
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(para);
    }
    flush();

    if (chunks.length == 1) {
      return [EpubChapterData(title: baseTitle ?? '正文', text: chunks.first)];
    }
    return [
      for (var i = 0; i < chunks.length; i++)
        EpubChapterData(
          title: baseTitle == null ? '第 ${i + 1} 章' : '$baseTitle（${i + 1}）',
          text: chunks[i],
        ),
    ];
  }
}
