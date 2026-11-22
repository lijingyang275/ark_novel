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

  static List<ReplaceRule> all() {
    final out = <ReplaceRule>[];
    for (final (i, e) in ((_box.get('rules') as List?) ?? const []).cast<Map>().indexed) {
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
    return out;
  }

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
  }

  static final _backref = RegExp(r'\$(\d)');
  static final _compiled = <String, RegExp>{};

  static RegExp _regex(String pattern) {
    final hit = _compiled[pattern];
    if (hit != null) return hit;
    if (_compiled.length >= 256) _compiled.remove(_compiled.keys.first);
    return _compiled[pattern] = RegExp(pattern, multiLine: true);
  }

  /// 依次套用启用的替换规则；替换串里可用 `$1` 引用分组。无效的规则直接跳过。
  static String apply(String text, [List<ReplaceRule>? rules]) {
    var out = text;
    for (final r in rules ?? all()) {
      if (!r.enabled || r.kind != RuleKind.replace || r.pattern.isEmpty) continue;
      try {
        out = out.replaceAllMapped(
          _regex(r.pattern),
          (m) => r.replacement.replaceAllMapped(_backref, (g) {
            final idx = int.parse(g[1]!);
            if (idx == 0) return m[0] ?? '';
            if (idx <= m.groupCount) return m.group(idx) ?? '';
            return g[0]!;
          }),
        );
      } catch (_) {}
    }
    return out;
  }

  /// 在 [text] 里找出所有高亮：先写的规则优先，重叠的后者让位；结果按位置排序、互不重叠。
  static List<Mark> marks(String text, [List<ReplaceRule>? rules, String aid = '']) {
    final list = rules ?? all();
    final found = <Mark>[];
    for (final r in list) {
      if (!r.enabled || r.kind == RuleKind.replace || r.pattern.isEmpty || (r.aid.isNotEmpty && r.aid != aid)) continue;
      try {
        for (final m in _regex(r.pattern).allMatches(text)) {
          if (m.end > m.start) found.add(Mark(m.start, m.end, r));
        }
      } catch (_) {}
    }
    final order = {for (final (i, r) in list.indexed) r.id: i};
    found.sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : (order[a.rule.id] ?? 0).compareTo(order[b.rule.id] ?? 0);
    });
    final out = <Mark>[];
    var end = 0;
    for (final m in found) {
      if (m.start >= end) {
        out.add(m);
        end = m.end;
      }
    }
    return out;
  }
}

/// 高亮人物的备注：每本书一份，按规则编号存。
class RuleNotes {
  RuleNotes._();

  static Box get _box => Hive.box('session');

  static Map<String, String> of(String aid) => ((_box.get('notes:$aid') as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String));

  static String get(String aid, String ruleId) => of(aid)[ruleId] ?? '';

  static Future<void> set(String aid, String ruleId, String text) {
    final map = of(aid);
    text.trim().isEmpty ? map.remove(ruleId) : map[ruleId] = text;
    return _box.put('notes:$aid', map);
  }
}
