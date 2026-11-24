import 'package:flutter/foundation.dart' show compute;
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
    final variantCodes = <int, int>{
      for (final e in variants.entries)
        if (e.key.length == 1 && e.value.length == 1) e.key.codeUnitAt(0): e.value.codeUnitAt(0),
    };
    String toTw(String s) {
      List<int>? units;
      for (var i = 0; i < s.length; i++) {
        final cu = s.codeUnitAt(i);
        final mapped = variantCodes[cu];
        if (mapped != null && mapped != cu) {
          units ??= s.codeUnits.toList();
          units[i] = mapped;
        }
      }
      return units == null ? s : String.fromCharCodes(units);
    }

    final rawChars = <String, String>{};
    _read(chars, rawChars);
    _read(phrases, _phrases);
    rawChars.forEach((k, v) {
      if (k.length == 1 && v.length == 1) {
        final cu = v.codeUnitAt(0);
        _chars[k.codeUnitAt(0)] = variantCodes[cu] ?? cu;
      }
    });
    _phrases.updateAll((_, v) => toTw(v));
    variantCodes.forEach((k, v) => _chars.putIfAbsent(k, () => v)); // 原文本来就是繁体的「爲」也换成「為」
    fixed.forEach((k, v) => k.length > 1 ? _phrases[k] = toTw(v) : null);

    // 按首字分桶记录实际存在的词长（降序），避免对每个首字都从全局最大词长 12 倒序切片。
    final lenSets = <int, Set<int>>{};
    for (final k in _phrases.keys) {
      if (k.length < 2) continue;
      (lenSets[k.codeUnitAt(0)] ??= <int>{}).add(k.length);
    }
    lenSets.forEach((cu, set) {
      final list = set.toList()..sort((a, b) => b.compareTo(a));
      _lensByStart[cu] = list;
    });
    for (final k in _post.keys) {
      if (k.isNotEmpty) _postTriggers.add(k.codeUnitAt(0));
    }
  }

  final _chars = <int, int>{};
  final _phrases = <String, String>{};
  final _lensByStart = <int, List<int>>{};
  final _post = <String, String>{};
  final _postTriggers = <int>{};

  static Future<Hant>? _loading;

  /// 在后台 Isolate 解析词表（原生端走 `Isolate.run`，Web 端自动同步执行），避免主线程冷卡顿。
  static Future<Hant> parseAsync(String chars, String phrases, [String tw = '', String fixes = '']) =>
      compute(_parseHantTask, (chars, phrases, tw, fixes));

  /// 第一次用到时才加载词表（约 1 MB），之后复用。
  static Future<Hant> load() => _loading ??= () async {
    try {
      final [chars, phrases, tw, fixes] = await Future.wait([
        rootBundle.loadString('assets/opencc/STCharacters.txt'),
        rootBundle.loadString('assets/opencc/STPhrases.txt'),
        rootBundle.loadString('assets/opencc/TWVariants.txt'),
        rootBundle.loadString('assets/opencc/ArkFixes.txt'),
      ]);
      return loaded = await parseAsync(chars, phrases, tw, fixes);
    } catch (_) {
      _loading = null;
      rethrow;
    }
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

  final _shortCache = <String, String>{};

  String convert(String text) {
    if (text.isEmpty) return text;
    if (text.length <= 80) {
      final hit = _shortCache[text];
      if (hit != null) return hit;
    }
    final out = StringBuffer();
    final hasPost = _postTriggers.isNotEmpty;
    var maybePost = false;
    var i = 0;
    final len = text.length;
    while (i < len) {
      final cu = text.codeUnitAt(i);
      final lens = _lensByStart[cu];
      if (lens != null) {
        final rem = len - i;
        String? hit;
        for (final n in lens) {
          if (n > rem) continue;
          final v = _phrases[text.substring(i, i + n)];
          if (v != null) {
            hit = v;
            break;
          }
        }
        if (hit != null) {
          out.write(hit);
          if (hasPost && !maybePost) {
            for (var j = 0; j < hit.length; j++) {
              if (_postTriggers.contains(hit.codeUnitAt(j))) {
                maybePost = true;
                break;
              }
            }
          }
          i += hit.length;
          continue;
        }
      }
      final outCu = _chars[cu] ?? cu;
      out.writeCharCode(outCu);
      if (hasPost && !maybePost && _postTriggers.contains(outCu)) maybePost = true;
      i++;
    }
    var s = out.toString();
    if (maybePost) {
      _post.forEach((k, v) {
        if (s.contains(k)) s = s.replaceAll(k, v);
      });
    }
    if (len <= 80) {
      if (_shortCache.length >= 512) _shortCache.remove(_shortCache.keys.first);
      _shortCache[text] = s;
    }
    return s;
  }
}

Hant _parseHantTask((String, String, String, String) args) => Hant.parse(args.$1, args.$2, args.$3, args.$4);
