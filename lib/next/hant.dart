import 'package:flutter/services.dart';

/// 简体转繁体（台湾写法），用 OpenCC 的词表（在 assets/opencc/）：STPhrases 词组优先、最长匹配，其余按 STCharacters 逐字转换，
/// 最后按 TWVariants 换成台湾用字（爲→為、裏→裡），和 OpenCC 的 s2tw 一样。
/// ArkFixes.txt 是我们自己的修正表，修 OpenCC 在小说正文里常见的误转（比如「不是只有」转成「不是隻有」）。
///
/// 只收转换前后 UTF-16 长度不变的条目（丢掉的是少数扩展区生僻字），这样书签、阅读进度、高亮的位置在简繁之间通用。
class Hant {
  Hant.parse(String chars, String phrases, [String tw = '', String fixes = '']) {
    final variants = <String, String>{};
    final fixed = <String, String>{};
    _read(tw, variants);
    _read(fixes, fixed); // = 开头的行键比值多一个字，这里会被跳过
    _read(fixes.split('\n').where((l) => l.startsWith('=')).map((l) => l.substring(1)).join('\n'), _post);
    fixed.forEach((k, v) => k.length == 1 ? variants[k] = v : null);
    String toTw(String s) => s.split('').map((c) => variants[c] ?? c).join();
    _read(chars, _chars);
    _read(phrases, _phrases);
    _chars.updateAll((_, v) => toTw(v));
    _phrases.updateAll((_, v) => toTw(v));
    variants.forEach((k, v) => _chars.putIfAbsent(k, () => v)); // 原文本来就是繁体的「爲」也换成「為」
    fixed.forEach((k, v) => k.length > 1 ? _phrases[k] = toTw(v) : null);
    for (final k in _phrases.keys) {
      _starts.add(k.codeUnitAt(0));
      if (k.length > _maxLen) _maxLen = k.length;
    }
  }

  final _chars = <String, String>{};
  final _phrases = <String, String>{};
  final _starts = <int>{};
  final _post = <String, String>{};
  var _maxLen = 1;

  static Future<Hant>? _loading;

  /// 第一次用到时才加载词表（约 1 MB），之后复用。
  static Future<Hant> load() => _loading ??= () async {
    final chars = await rootBundle.loadString('assets/opencc/STCharacters.txt');
    final phrases = await rootBundle.loadString('assets/opencc/STPhrases.txt');
    final tw = await rootBundle.loadString('assets/opencc/TWVariants.txt');
    final fixes = await rootBundle.loadString('assets/opencc/ArkFixes.txt');
    return loaded = Hant.parse(chars, phrases, tw, fixes);
  }();

  /// 已经加载好的词表；界面在 build 里同步用它，没加载完时为 null（先显示原文）。
  static Hant? loaded;

  static void _read(String dict, Map<String, String> into) {
    for (final line in dict.split('\n')) {
      if (line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      final value = line.substring(tab + 1).trim().split(' ').first; // 一简多繁时取第一个（最常用）
      if (value.length == key.length) into[key] = value;
    }
  }

  String convert(String text) {
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (_starts.contains(text.codeUnitAt(i))) {
        String? hit;
        for (var n = _maxLen < text.length - i ? _maxLen : text.length - i; n >= 2 && hit == null; n--) {
          final v = _phrases[text.substring(i, i + n)];
          if (v != null) hit = v;
        }
        if (hit != null) {
          out.write(hit);
          i += hit.length;
          continue;
        }
      }
      final c = text[i];
      out.write(_chars[c] ?? c);
      i++;
    }
    var s = out.toString();
    _post.forEach((k, v) => s = s.replaceAll(k, v));
    return s;
  }
}
