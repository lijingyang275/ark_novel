import 'dart:typed_data' show Int32List;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'sync.dart';

/// 替换：改写文字；高亮：底色 + 可写备注；变色：只改字的颜色（比如给不同人物分色），不带备注。
enum RuleKind { replace, highlight, color }

/// 高亮规则可选的颜色（ARGB）。
const ruleColors = [
  0xFFE53935, 0xFFF4511E, 0xFFF9A825, 0xFF43A047, 0xFF00897B, 0xFF1E88E5, 0xFF5E35B1, 0xFFD81B60, // 原来的 8 个，顺序别动（默认高亮色取第 3 个）
  0xFFFF7043, 0xFFFB8C00, 0xFFFDD835, 0xFFC0CA33, 0xFF7CB342, 0xFF26A69A, 0xFF00ACC1, 0xFF039BE5,
  0xFF3949AB, 0xFF8E24AA, 0xFFAB47BC, 0xFFEC407A, 0xFF8D6E63, 0xFF78909C, 0xFF757575, 0xFF212121,
];

/// 一条正则规则：
/// - 替换：章节正文显示前套用，用来去广告、统一用字
/// - 高亮：给匹配到的文字加底色，点一下可以写备注
/// - 变色：只把匹配到的文字（比如人物名）染上颜色
class ReplaceRule {
  const ReplaceRule({required this.pattern, required this.replacement, this.enabled = true, this.kind = RuleKind.replace, this.color = 0xFFE53935, this.name = '', this.id = '', this.aid = ''});

  final String pattern;
  final String replacement;
  final bool enabled;
  final RuleKind kind;
  final int color;

  /// 高亮规则的名字（比如人物名），备注按它归档；留空时用匹配式
  final String name;

  /// 稳定的编号，备注靠它找到规则
  final String id;

  /// 只对这本书生效的书号；留空表示所有书。阅读器里选中文字做的高亮只属于当前这本书。
  final String aid;

  String get label => name.isEmpty ? pattern : name;

  ReplaceRule copyWith({String? pattern, String? replacement, bool? enabled, RuleKind? kind, int? color, String? name, String? id, String? aid}) => ReplaceRule(
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
    kind: kind ?? this.kind,
    color: color ?? this.color,
    name: name ?? this.name,
    id: id ?? this.id,
    aid: aid ?? this.aid,
  );

  /// 正则写错时返回错误说明，正确返回 null。
  static String? validate(String pattern) {
    try {
      RegExp(pattern, multiLine: true);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }
}

/// 章节里一处高亮：`[start, end)` 是正文里的字符范围。
class Mark {
  const Mark(this.start, this.end, this.rule);

  final int start;
  final int end;
  final ReplaceRule rule;
}

class ReplaceRules {
  ReplaceRules._();

  static Box get _box => Hive.box('session');

  /// 规则变更通知（保存或同步合并后递增，供阅读器章节 provider 自动联动刷新）。
  static final changes = ValueNotifier<int>(0);

  static final _unset = Object();
  static Object? _cachedRaw = _unset;
  static List<ReplaceRule> _cachedList = const [];

  /// 只读规则列表（按 Hive 内存引用缓存，避免高频重复反序列化）。调用方切勿修改返回列表。
  static List<ReplaceRule> allView() {
    if (!Hive.isBoxOpen('session')) return const [];
    final raw = _box.get('rules');
    if (identical(raw, _cachedRaw)) return _cachedList;
    final out = <ReplaceRule>[];
    for (final (i, e) in ((raw as List?) ?? const []).cast<Map>().indexed) {
      out.add(
        ReplaceRule(
          pattern: e['p'] as String,
          replacement: e['r'] as String,
          enabled: e['e'] as bool,
          kind: RuleKind.values[(e['k'] as int?)?.clamp(0, 2) ?? 0],
          color: (e['c'] as int?) ?? ruleColors.first,
          name: (e['n'] as String?) ?? '',
          id: (e['id'] as String?) ?? 'r$i',
          aid: (e['a'] as String?) ?? '',
        ),
      );
    }
    _cachedRaw = raw;
    _cachedList = List<ReplaceRule>.unmodifiable(out);
    _matcherCache.clear();
    return _cachedList;
  }

  /// 返回可变副本，兼容调用方原地增删改。
  static List<ReplaceRule> all() => List<ReplaceRule>.of(allView());

  /// 保存时顺带给改过的规则打上修改时间，删掉的规则记墓碑，同步靠它们决定谁新谁旧。
  static Future<void> save(List<ReplaceRule> rules) async {
    final old = {
      for (final e in ((_box.get('rules') as List?) ?? const []).cast<Map>())
        if (e['id'] != null) e['id'] as String: e,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <Map<String, Object>>[];
    for (final (i, r) in rules.indexed) {
      final id = r.id.isEmpty ? 'r${DateTime.now().microsecondsSinceEpoch}$i' : r.id;
      final o = old[id];
      final same = o != null && o['p'] == r.pattern && o['r'] == r.replacement && o['e'] == r.enabled && o['k'] == r.kind.index && o['c'] == r.color && o['n'] == r.name && o['a'] == r.aid;
      out.add({'p': r.pattern, 'r': r.replacement, 'e': r.enabled, 'k': r.kind.index, 'c': r.color, 'n': r.name, 'a': r.aid, 'id': id, 'ts': same ? (o['ts'] as int?) ?? 0 : now});
    }
    final kept = {for (final e in out) e['id']};
    await Sync.tombstone([for (final id in old.keys) if (!kept.contains(id)) 'r:$id']);
    await _box.put('rules', out);
    _cachedRaw = _unset;
    _cachedList = const [];
    _matcherCache.clear();
    changes.value++;
  }

  /// 外部（如同步合并）写入 `rules` 后调用：清缓存并通知下游刷新。
  static void notifyChanged() {
    _cachedRaw = _unset;
    _cachedList = const [];
    _matcherCache.clear();
    changes.value++;
  }

  static final _backref = RegExp(r'\$(\d)');
  static final _compiled = <String, RegExp>{};
  static final _matcherCache = <String, _MarkMatcher>{};

  static RegExp _regex(String pattern) {
    final hit = _compiled.remove(pattern);
    if (hit != null) return _compiled[pattern] = hit;
    if (_compiled.length >= 256) _compiled.remove(_compiled.keys.first);
    return _compiled[pattern] = RegExp(pattern, multiLine: true);
  }

  /// 依次套用启用的替换规则；替换串里可用 `$1` 引用分组。无效的规则直接跳过。
  static String apply(String text, [List<ReplaceRule>? rules]) {
    var out = text;
    for (final r in rules ?? allView()) {
      if (!r.enabled || r.kind != RuleKind.replace || r.pattern.isEmpty) continue;
      try {
        final re = _regex(r.pattern);
        if (!r.replacement.contains('\$')) {
          out = out.replaceAll(re, r.replacement);
        } else {
          out = out.replaceAllMapped(
            re,
            (m) => r.replacement.replaceAllMapped(_backref, (g) {
              final idx = int.parse(g[1]!);
              if (idx == 0) return m[0] ?? '';
              if (idx <= m.groupCount) return m.group(idx) ?? '';
              return g[0]!;
            }),
          );
        }
      } catch (_) {}
    }
    return out;
  }

  /// 在 [text] 里找出所有高亮：先写的规则优先，重叠的后者让位；结果按位置排序、互不重叠。
  static List<Mark> marks(String text, [List<ReplaceRule>? rules, String aid = '']) {
    if (text.isEmpty) return const [];
    final list = rules ?? allView();
    if (list.isEmpty) return const [];
    final _MarkMatcher matcher;
    if (rules == null || identical(rules, _cachedList)) {
      final hit = _matcherCache.remove(aid);
      if (hit != null) {
        matcher = _matcherCache[aid] = hit;
      } else {
        if (_matcherCache.length >= 16) _matcherCache.remove(_matcherCache.keys.first);
        matcher = _matcherCache[aid] = _MarkMatcher.compile(list, aid);
      }
    } else {
      matcher = _MarkMatcher.compile(list, aid);
    }
    return matcher.match(text);
  }
}

class _TrieHit {
  const _TrieHit(this.ruleIdx, this.altIdx, this.len);

  final int ruleIdx;
  final int altIdx;
  final int len;
}

class _TrieNode {
  final children = <int, _TrieNode>{};
  List<_TrieHit>? hits;
}

class _MarkMatcher {
  const _MarkMatcher._({
    required this.root,
    required this.literalRules,
    required this.literalPrios,
    required this.literalSeqs,
    required this.regexRules,
  });

  static final _emptyRoot = _TrieNode();
  static final empty = _MarkMatcher._(
    root: _emptyRoot,
    literalRules: const [],
    literalPrios: const [],
    literalSeqs: const [],
    regexRules: const [],
  );

  final _TrieNode root;
  final List<ReplaceRule> literalRules;
  final List<int> literalPrios;
  final List<int> literalSeqs;
  final List<({ReplaceRule rule, int prio, int seq})> regexRules;

  /// 将仅含纯字面量及 `|` 分支的正则模式（如人物词典生成的 `RegExp.escape` 拼接模式）拆为字面量列表；
  /// 含任意正则语法、非字面量转义或空分支时返回 null，回退到标准正则执行。
  static List<String>? parseLiteralAlternatives(String pattern) {
    final out = <String>[];
    final buf = StringBuffer();
    final len = pattern.length;
    for (var i = 0; i < len; i++) {
      final cu = pattern.codeUnitAt(i);
      if (cu == 0x5C) {
        if (i + 1 >= len) return null;
        final next = pattern.codeUnitAt(++i);
        switch (next) {
          case 0x5E || 0x24 || 0x5C || 0x2E || 0x2A || 0x2B || 0x3F || 0x28 || 0x29 || 0x5B || 0x5D || 0x7B || 0x7D || 0x7C || 0x2F || 0x2D:
            buf.writeCharCode(next);
          default:
            return null;
        }
      } else if (cu == 0x7C) {
        if (buf.isEmpty) return null;
        out.add(buf.toString());
        buf.clear();
      } else {
        switch (cu) {
          case 0x5E || 0x24 || 0x2E || 0x2A || 0x2B || 0x3F || 0x28 || 0x29 || 0x5B || 0x5D || 0x7B || 0x7D:
            return null;
          default:
            buf.writeCharCode(cu);
        }
      }
    }
    if (buf.isEmpty) return null;
    out.add(buf.toString());
    return out;
  }

  factory _MarkMatcher.compile(List<ReplaceRule> list, String aid) {
    final order = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      order[list[i].id] = i;
    }
    final root = _TrieNode();
    final literalRules = <ReplaceRule>[];
    final literalPrios = <int>[];
    final literalSeqs = <int>[];
    final regexRules = <({ReplaceRule rule, int prio, int seq})>[];

    for (var i = 0; i < list.length; i++) {
      final r = list[i];
      if (!r.enabled || r.kind == RuleKind.replace || r.pattern.isEmpty || (r.aid.isNotEmpty && r.aid != aid)) continue;
      final prio = order[r.id] ?? 0;
      final alts = parseLiteralAlternatives(r.pattern);
      if (alts != null) {
        final rIdx = literalRules.length;
        literalRules.add(r);
        literalPrios.add(prio);
        literalSeqs.add(i);
        for (var altIdx = 0; altIdx < alts.length; altIdx++) {
          final alt = alts[altIdx];
          var node = root;
          for (var c = 0; c < alt.length; c++) {
            final cu = alt.codeUnitAt(c);
            node = node.children[cu] ??= _TrieNode();
          }
          final hits = node.hits ??= <_TrieHit>[];
          var dup = false;
          for (var k = 0; k < hits.length; k++) {
            if (hits[k].ruleIdx == rIdx) {
              dup = true;
              break;
            }
          }
          if (!dup) hits.add(_TrieHit(rIdx, altIdx, alt.length));
        }
      } else {
        regexRules.add((rule: r, prio: prio, seq: i));
      }
    }
    if (literalRules.isEmpty && regexRules.isEmpty) return empty;
    return _MarkMatcher._(
      root: root,
      literalRules: literalRules,
      literalPrios: literalPrios,
      literalSeqs: literalSeqs,
      regexRules: regexRules,
    );
  }

  List<Mark> match(String text) {
    final textLen = text.length;
    if (textLen == 0 || (literalRules.isEmpty && regexRules.isEmpty)) return const [];

    // 纯字面量快速路径：单遍 O(N) 前缀树扫描 + 实时非重叠裁剪，免去全量排序
    if (regexRules.isEmpty) {
      final ruleCount = literalRules.length;
      final lastEnd = Int32List(ruleCount);
      final bestAlt = Int32List(ruleCount)..fillRange(0, ruleCount, -1);
      final bestLen = Int32List(ruleCount);
      final touched = <int>[];
      final out = <Mark>[];
      final rootChildren = root.children;
      var globalEnd = 0;

      for (var pos = 0; pos < textLen; pos++) {
        var node = rootChildren[text.codeUnitAt(pos)];
        if (node == null) continue;
        var j = pos;
        while (node != null) {
          final hits = node.hits;
          if (hits != null) {
            for (var k = 0; k < hits.length; k++) {
              final h = hits[k];
              final rIdx = h.ruleIdx;
              if (pos < lastEnd[rIdx]) continue;
              final prevAlt = bestAlt[rIdx];
              if (prevAlt < 0) {
                touched.add(rIdx);
                bestAlt[rIdx] = h.altIdx;
                bestLen[rIdx] = h.len;
              } else if (h.altIdx < prevAlt) {
                bestAlt[rIdx] = h.altIdx;
                bestLen[rIdx] = h.len;
              }
            }
          }
          j++;
          if (j >= textLen) break;
          node = node.children[text.codeUnitAt(j)];
        }
        if (touched.isEmpty) continue;
        final canEmit = pos >= globalEnd;
        var winIdx = -1;
        var winPrio = 0;
        var winSeq = 0;
        var winLen = 0;
        for (var k = 0; k < touched.length; k++) {
          final rIdx = touched[k];
          final mLen = bestLen[rIdx];
          lastEnd[rIdx] = pos + mLen;
          bestAlt[rIdx] = -1;
          if (canEmit) {
            final prio = literalPrios[rIdx];
            final seq = literalSeqs[rIdx];
            if (winIdx < 0 || prio < winPrio || (prio == winPrio && seq < winSeq)) {
              winIdx = rIdx;
              winPrio = prio;
              winSeq = seq;
              winLen = mLen;
            }
          }
        }
        touched.clear();
        if (winIdx >= 0) {
          final end = pos + winLen;
          out.add(Mark(pos, end, literalRules[winIdx]));
          globalEnd = end;
        }
      }
      return out;
    }

    // 混合路径（含复杂正则规则）：字面量走单遍前缀树 + 复杂规则走正则，合并排序后按原语义去重叠
    final found = <({int start, int end, int prio, int seq, ReplaceRule rule})>[];
    if (literalRules.isNotEmpty) {
      final ruleCount = literalRules.length;
      final lastEnd = Int32List(ruleCount);
      final bestAlt = Int32List(ruleCount)..fillRange(0, ruleCount, -1);
      final bestLen = Int32List(ruleCount);
      final touched = <int>[];
      final rootChildren = root.children;

      for (var pos = 0; pos < textLen; pos++) {
        var node = rootChildren[text.codeUnitAt(pos)];
        if (node == null) continue;
        var j = pos;
        while (node != null) {
          final hits = node.hits;
          if (hits != null) {
            for (var k = 0; k < hits.length; k++) {
              final h = hits[k];
              final rIdx = h.ruleIdx;
              if (pos < lastEnd[rIdx]) continue;
              final prevAlt = bestAlt[rIdx];
              if (prevAlt < 0) {
                touched.add(rIdx);
                bestAlt[rIdx] = h.altIdx;
                bestLen[rIdx] = h.len;
              } else if (h.altIdx < prevAlt) {
                bestAlt[rIdx] = h.altIdx;
                bestLen[rIdx] = h.len;
              }
            }
          }
          j++;
          if (j >= textLen) break;
          node = node.children[text.codeUnitAt(j)];
        }
        if (touched.isEmpty) continue;
        for (var k = 0; k < touched.length; k++) {
          final rIdx = touched[k];
          final mLen = bestLen[rIdx];
          final end = pos + mLen;
          lastEnd[rIdx] = end;
          bestAlt[rIdx] = -1;
          found.add((start: pos, end: end, prio: literalPrios[rIdx], seq: literalSeqs[rIdx], rule: literalRules[rIdx]));
        }
        touched.clear();
      }
    }

    for (final entry in regexRules) {
      try {
        for (final m in ReplaceRules._regex(entry.rule.pattern).allMatches(text)) {
          if (m.end > m.start) {
            found.add((start: m.start, end: m.end, prio: entry.prio, seq: entry.seq, rule: entry.rule));
          }
        }
      } catch (_) {}
    }

    if (found.isEmpty) return const [];
    found.sort((a, b) {
      final c = a.start.compareTo(b.start);
      if (c != 0) return c;
      final p = a.prio.compareTo(b.prio);
      return p != 0 ? p : a.seq.compareTo(b.seq);
    });
    final out = <Mark>[];
    var end = 0;
    for (final m in found) {
      if (m.start >= end) {
        out.add(Mark(m.start, m.end, m.rule));
        end = m.end;
      }
    }
    return out;
  }
}

/// 替换/高亮规则变更通知 provider，供阅读器章节缓存自动联动刷新。
final replaceRulesChangesProvider = Provider<int>((ref) {
  void listener() => ref.invalidateSelf();
  ReplaceRules.changes.addListener(listener);
  ref.onDispose(() => ReplaceRules.changes.removeListener(listener));
  return ReplaceRules.changes.value;
});

/// 高亮人物的备注：每本书一份，按规则编号存。
class RuleNotes {
  RuleNotes._();

  static Box get _box => Hive.box('session');

  static final _cache = <String, ({Object? raw, Map<String, String> map, Set<String> keys})>{};
  static const _emptyEntry = (raw: null, map: <String, String>{}, keys: <String>{});

  static ({Object? raw, Map<String, String> map, Set<String> keys}) _entry(String aid) {
    if (!Hive.isBoxOpen('session')) return _emptyEntry;
    final raw = _box.get('notes:$aid');
    final hit = _cache[aid];
    if (hit != null && identical(hit.raw, raw)) return hit;
    final parsed = raw is Map ? <String, String>{for (final e in raw.entries) e.key as String: e.value as String} : const <String, String>{};
    final frozen = parsed.isEmpty ? const <String, String>{} : Map<String, String>.unmodifiable(parsed);
    final keys = frozen.isEmpty ? const <String>{} : Set<String>.unmodifiable(frozen.keys);
    final entry = (raw: raw, map: frozen, keys: keys);
    if (_cache.length >= 16 && !_cache.containsKey(aid)) _cache.remove(_cache.keys.first);
    return _cache[aid] = entry;
  }

  static Map<String, String> of(String aid) => Map<String, String>.of(_entry(aid).map);

  /// 只读备注键集合（缓存复用，避免高频构建重复分配 Set）。
  static Set<String> keysView(String aid) => _entry(aid).keys;

  static String get(String aid, String ruleId) => _entry(aid).map[ruleId] ?? '';

  static Future<void> set(String aid, String ruleId, String text) async {
    final map = of(aid);
    text.trim().isEmpty ? map.remove(ruleId) : map[ruleId] = text;
    await _box.put('notes:$aid', map);
    _cache.remove(aid);
  }
}
