import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
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
    final phraseMap = <String, String>{};
    _read(chars, rawChars);
    _read(phrases, phraseMap);
    rawChars.forEach((k, v) {
      if (k.length == 1 && v.length == 1) {
        final cu = v.codeUnitAt(0);
        _chars[k.codeUnitAt(0)] = variantCodes[cu] ?? cu;
      }
    });
    phraseMap.updateAll((_, v) => toTw(v));
    variantCodes.forEach((k, v) => _chars.putIfAbsent(k, () => v)); // 原文本来就是繁体的「爲」也换成「為」
    fixed.forEach((k, v) => k.length > 1 ? phraseMap[k] = toTw(v) : null);

    // 将词组表（长度 >= 2）构建为紧凑扁平数组前缀树（CSR Trie），匹配期按 UTF-16 codeUnit 步进，0 次 substring 分配。
    final keys = [
      for (final k in phraseMap.keys)
        if (k.length >= 2) k,
    ]..sort();
    final nodeParent = <int>[-1];
    final nodeChar = <int>[0];
    final lastChild = <int>[-1];
    final childCount = <int>[0];
    final valOff = <int>[-1];
    final valLen = <int>[0];
    final valBuf = StringBuffer();

    for (final k in keys) {
      var u = 0;
      for (var idx = 0; idx < k.length; idx++) {
        final cu = k.codeUnitAt(idx);
        final lc = lastChild[u];
        if (lc != -1 && nodeChar[lc] == cu) {
          u = lc;
        } else {
          final v = nodeChar.length;
          nodeParent.add(u);
          nodeChar.add(cu);
          lastChild.add(-1);
          childCount.add(0);
          valOff.add(-1);
          valLen.add(0);
          lastChild[u] = v;
          childCount[u]++;
          u = v;
        }
      }
      final val = phraseMap[k]!;
      valOff[u] = valBuf.length;
      valLen[u] = val.length;
      valBuf.write(val);
    }

    final nodeCount = nodeChar.length;
    _nodeStart = Int32List(nodeCount + 1);
    var totalEdges = 0;
    for (var i = 0; i < nodeCount; i++) {
      _nodeStart[i] = totalEdges;
      totalEdges += childCount[i];
    }
    _nodeStart[nodeCount] = totalEdges;
    _edgeChar = Uint16List(totalEdges);
    _edgeChild = Int32List(totalEdges);
    final cursor = Int32List.fromList(_nodeStart);
    for (var v = 1; v < nodeCount; v++) {
      final parent = nodeParent[v];
      final cu = nodeChar[v];
      final pos = cursor[parent]++;
      _edgeChar[pos] = cu;
      _edgeChild[pos] = v;
      if (parent == 0) _rootChildren[cu] = v;
    }
    _nodeValOff = Int32List.fromList(valOff);
    _nodeValLen = Uint16List.fromList(valLen);
    _valBuf = valBuf.toString();

    for (final k in _post.keys) {
      if (k.isNotEmpty) _postTriggers.add(k.codeUnitAt(0));
    }
  }

  final _chars = <int, int>{};
  final _rootChildren = <int, int>{};
  late final Int32List _nodeStart;
  late final Uint16List _edgeChar;
  late final Int32List _edgeChild;
  late final Int32List _nodeValOff;
  late final Uint16List _nodeValLen;
  late final String _valBuf;
  final _post = <String, String>{};
  final _postTriggers = <int>{};

  static const _assets = [
    'assets/opencc/STCharacters.txt',
    'assets/opencc/STPhrases.txt.gz',
    'assets/opencc/TWVariants.txt',
    'assets/opencc/ArkFixes.txt',
  ];

  static Future<Hant>? _loading;
  static int _loadGen = 0;

  /// 在后台 Isolate 解析词表（原生端走 `Isolate.run`，Web 端自动同步执行），避免主线程冷卡顿。
  static Future<Hant> parseAsync(String chars, String phrases, [String tw = '', String fixes = '']) =>
      compute(_parseHantTask, (chars, phrases, tw, fixes));

  /// 在后台 Isolate 内解压 GZip 词组表并构建紧凑 Trie（兼容原生与 Web）。
  static Future<Hant> parseAsyncGz(String chars, Uint8List phrasesGz, [String tw = '', String fixes = '']) =>
      compute(_parseHantGzTask, (chars, phrasesGz, tw, fixes));

  /// 第一次用到时才加载词表（压缩后约 300 KB），绝不在 `rootBundle` 字符串缓存留残留，之后复用。
  static Future<Hant> load() => _loading ??= () async {
    final gen = ++_loadGen;
    try {
      final results = await Future.wait<Object>([
        rootBundle.loadString('assets/opencc/STCharacters.txt', cache: false),
        rootBundle.load('assets/opencc/STPhrases.txt.gz'),
        rootBundle.loadString('assets/opencc/TWVariants.txt', cache: false),
        rootBundle.loadString('assets/opencc/ArkFixes.txt', cache: false),
      ]);
      final chars = results[0] as String;
      final phrasesData = results[1] as ByteData;
      final phrasesGz = phrasesData.buffer.asUint8List(phrasesData.offsetInBytes, phrasesData.lengthInBytes);
      final tw = results[2] as String;
      final fixes = results[3] as String;
      final h = await parseAsyncGz(chars, phrasesGz, tw, fixes);
      if (gen == _loadGen) loaded = h;
      return h;
    } catch (_) {
      if (gen == _loadGen) _loading = null;
      rethrow;
    }
  }();

  /// 当界面繁体关闭且无活跃阅读器，或收到系统内存压力告警时卸载词表，同时清理 `rootBundle` 缓存。
  static void unload() {
    _loadGen++;
    loaded = null;
    _loading = null;
    for (final asset in _assets) {
      rootBundle.evict(asset);
    }
  }

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

  static const _maxCacheTextLen = 2000;
  static const _maxCacheChars = 64 * 1024;
  static const _maxCacheEntries = 1024;

  final _shortCache = <String, String>{};
  int _cacheChars = 0;

  @visibleForTesting
  int get cacheLength => _shortCache.length;

  @visibleForTesting
  int get cacheChars => _cacheChars;

  @visibleForTesting
  List<String> get cacheKeysForTest => _shortCache.keys.toList(growable: false);

  void _putCache(String key, String value) {
    final prev = _shortCache.remove(key);
    if (prev != null) _cacheChars -= key.length;
    _shortCache[key] = value;
    _cacheChars += key.length;
    while (_shortCache.length > _maxCacheEntries || _cacheChars > _maxCacheChars) {
      final oldest = _shortCache.keys.first;
      _shortCache.remove(oldest);
      _cacheChars -= oldest.length;
    }
  }

  int _findChild(int node, int target) {
    var lo = _nodeStart[node];
    final hi = _nodeStart[node + 1];
    if (hi - lo <= 8) {
      for (var i = lo; i < hi; i++) {
        final c = _edgeChar[i];
        if (c == target) return _edgeChild[i];
        if (c > target) return -1;
      }
      return -1;
    }
    var r = hi - 1;
    while (lo <= r) {
      final mid = (lo + r) >>> 1;
      final c = _edgeChar[mid];
      if (c == target) return _edgeChild[mid];
      if (c < target) {
        lo = mid + 1;
      } else {
        r = mid - 1;
      }
    }
    return -1;
  }

  String convert(String text) {
    if (text.isEmpty) return text;
    final len = text.length;
    if (len <= _maxCacheTextLen) {
      final hit = _shortCache.remove(text);
      if (hit != null) {
        _shortCache[text] = hit;
        return hit;
      }
    }
    StringBuffer? out;
    final hasPost = _postTriggers.isNotEmpty;
    var maybePost = false;
    var i = 0;
    while (i < len) {
      final cu = text.codeUnitAt(i);
      var node = _rootChildren[cu];
      if (node != null && i + 1 < len) {
        var bestOff = -1;
        var bestLen = 0;
        var j = i + 1;
        while (j < len) {
          final next = _findChild(node!, text.codeUnitAt(j));
          if (next < 0) break;
          node = next;
          final off = _nodeValOff[node];
          if (off >= 0) {
            bestOff = off;
            bestLen = _nodeValLen[node];
          }
          j++;
        }
        if (bestOff >= 0) {
          if (out == null) {
            out = StringBuffer();
            for (var p = 0; p < i; p++) {
              out.writeCharCode(text.codeUnitAt(p));
            }
          }
          for (var k = 0; k < bestLen; k++) {
            final vcu = _valBuf.codeUnitAt(bestOff + k);
            out.writeCharCode(vcu);
            if (hasPost && !maybePost && _postTriggers.contains(vcu)) maybePost = true;
          }
          i += bestLen;
          continue;
        }
      }
      final outCu = _chars[cu] ?? cu;
      if (out != null) {
        out.writeCharCode(outCu);
      } else if (outCu != cu) {
        out = StringBuffer();
        for (var p = 0; p < i; p++) {
          out.writeCharCode(text.codeUnitAt(p));
        }
        out.writeCharCode(outCu);
      }
      if (hasPost && !maybePost && _postTriggers.contains(outCu)) maybePost = true;
      i++;
    }
    var s = out == null ? text : out.toString();
    if (maybePost) {
      _post.forEach((k, v) {
        if (s.contains(k)) s = s.replaceAll(k, v);
      });
    }
    if (len <= _maxCacheTextLen) {
      _putCache(text, s);
    }
    return s;
  }
}

Hant _parseHantTask((String, String, String, String) args) => Hant.parse(args.$1, args.$2, args.$3, args.$4);

Hant _parseHantGzTask((String, Uint8List, String, String) args) {
  final phrases = utf8.decode(GZipDecoder().decodeBytes(args.$2));
  return Hant.parse(args.$1, phrases, args.$3, args.$4);
}
