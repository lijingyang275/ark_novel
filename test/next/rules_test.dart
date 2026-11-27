import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test('按顺序套用规则，支持分组引用', () {
    final rules = [
      const ReplaceRule(pattern: r'(\d+)话', replacement: r'第$1话'),
      const ReplaceRule(pattern: '广告', replacement: ''),
    ];
    expect(ReplaceRules.apply('12话 广告正文', rules), '第12话 正文');
  });

  test('替换串里的分组引用超出捕获组数量时不报错并保留原字符串', () {
    final rules = [
      const ReplaceRule(pattern: r'(\d+)话', replacement: r'第$1话-$2'),
    ];
    expect(ReplaceRules.apply('12话', rules), r'第12话-$2');
  });

  test('停用的和写错的规则被跳过', () {
    final rules = [const ReplaceRule(pattern: 'a', replacement: 'b', enabled: false), const ReplaceRule(pattern: '(', replacement: 'x')];
    expect(ReplaceRules.apply('aaa(', rules), 'aaa(');
    expect(ReplaceRule.validate('('), isNotNull);
    expect(ReplaceRule.validate('a+'), isNull);
  });

  test('高亮规则：先写的优先，重叠的让位，结果按位置排序', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.highlight, id: 'a'),
      const ReplaceRule(pattern: '云海|林', replacement: '', kind: RuleKind.highlight, id: 'b'),
      const ReplaceRule(pattern: '广告', replacement: '', id: 'c'),
    ];
    final marks = ReplaceRules.marks('林云看见云海，广告', rules);
    expect([for (final m in marks) (m.start, m.end, m.rule.id)], [(0, 2, 'a'), (4, 6, 'b')]);
  });

  test('高亮规则不参与文字替换', () {
    final rules = [const ReplaceRule(pattern: '林云', replacement: 'X', kind: RuleKind.highlight, id: 'a')];
    expect(ReplaceRules.apply('林云', rules), '林云');
  });

  test('变色规则参与着色但不是高亮；单本书的规则只在那本书生效', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.color, id: 'a'),
      const ReplaceRule(pattern: '云海', replacement: '', kind: RuleKind.highlight, id: 'b', aid: '1'),
    ];
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '1')) (m.rule.id, m.rule.kind)], [('a', RuleKind.color), ('b', RuleKind.highlight)]);
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '2')) m.rule.id], ['a']);
    expect(ReplaceRules.apply('林云', rules), '林云');
  });

  test('ReplaceRules.allView 缓存同一引用并在 save / notifyChanged 时刷新与通知', () async {
    final dir = Directory.systemTemp.createTempSync('ark_rules_cache_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    addTearDown(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final beforeVer = ReplaceRules.changes.value;
    await ReplaceRules.save(const [ReplaceRule(pattern: '旧词', replacement: '新词', id: 'r1')]);
    expect(ReplaceRules.changes.value, beforeVer + 1);

    final v1 = ReplaceRules.allView();
    final v2 = ReplaceRules.allView();
    expect(identical(v1, v2), isTrue);
    expect(v1.single.pattern, '旧词');

    // all() 返回独立可变副本，修改不影响缓存
    final copy = ReplaceRules.all()..clear();
    expect(copy, isEmpty);
    expect(ReplaceRules.allView().length, 1);

    // 外部直接写入新列表也能自动失效缓存
    await Hive.box('session').put('rules', [
      {'p': '同步词', 'r': '替换', 'e': true, 'k': 0, 'c': 0xFFE53935, 'n': '', 'a': '', 'id': 'r2', 'ts': 1},
    ]);
    ReplaceRules.notifyChanged();
    expect(ReplaceRules.changes.value, beforeVer + 2);
    expect(ReplaceRules.allView().single.pattern, '同步词');

    // 删除 rules 键（变为 null）后 notifyChanged 必须返回空列表，不能命中旧缓存
    await Hive.box('session').delete('rules');
    ReplaceRules.notifyChanged();
    expect(ReplaceRules.allView(), isEmpty);
  });

  test('ReplaceRules.marks 字面量多模式前缀树与原逐条 RegExp 实现 100% 等价', () {
    List<(int, int, String)> referenceMarks(String text, List<ReplaceRule> list, [String aid = '']) {
      final found = <Mark>[];
      for (final r in list) {
        if (!r.enabled || r.kind == RuleKind.replace || r.pattern.isEmpty || (r.aid.isNotEmpty && r.aid != aid)) continue;
        try {
          for (final m in RegExp(r.pattern, multiLine: true).allMatches(text)) {
            if (m.end > m.start) found.add(Mark(m.start, m.end, r));
          }
        } catch (_) {}
      }
      final order = {for (final (i, r) in list.indexed) r.id: i};
      found.sort((a, b) {
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : (order[a.rule.id] ?? 0).compareTo(order[b.rule.id] ?? 0);
      });
      final out = <(int, int, String)>[];
      var end = 0;
      for (final m in found) {
        if (m.start >= end) {
          out.add((m.start, m.end, m.rule.id));
          end = m.end;
        }
      }
      return out;
    }

    List<(int, int, String)> actualMarks(String text, List<ReplaceRule> list, [String aid = '']) => [
      for (final m in ReplaceRules.marks(text, list, aid)) (m.start, m.end, m.rule.id),
    ];

    // 1. 人物词典生成的 RegExp.escape 多别名 `|` 拼接（含正则元字符转义）
    final charRules = [
      ReplaceRule(pattern: [r'小佐内由纪', r'小佐内', r'Mr. Smith', r'A+B', r'(小名)'].map(RegExp.escape).join('|'), replacement: '', kind: RuleKind.highlight, id: 'c1'),
      ReplaceRule(pattern: [r'小鸠常悟朗', r'小鸠', r'[设定]'].map(RegExp.escape).join('|'), replacement: '', kind: RuleKind.color, id: 'c2'),
      ReplaceRule(pattern: [r'由纪', r'常悟朗'].map(RegExp.escape).join('|'), replacement: '', kind: RuleKind.highlight, id: 'c3'),
    ];
    const sample1 = '小佐内由纪和小鸠常悟朗见到了Mr. Smith，提到了A+B、(小名)与[设定]；后来小佐内叫住了小鸠和由纪。';
    expect(actualMarks(sample1, charRules), equals(referenceMarks(sample1, charRules)));

    // 2. 单条规则内分支顺序语义：'林|林云' 先命中短分支 '林'，而 '林云|林' 先命中长分支 '林云'
    final altOrder1 = [const ReplaceRule(pattern: '林|林云', replacement: '', kind: RuleKind.highlight, id: 'a1')];
    final altOrder2 = [const ReplaceRule(pattern: '林云|林', replacement: '', kind: RuleKind.highlight, id: 'a2')];
    expect(actualMarks('林云', altOrder1), equals(referenceMarks('林云', altOrder1)));
    expect(actualMarks('林云', altOrder1), [(0, 1, 'a1')]);
    expect(actualMarks('林云', altOrder2), equals(referenceMarks('林云', altOrder2)));
    expect(actualMarks('林云', altOrder2), [(0, 2, 'a2')]);

    // 3. 自重叠与竞争规则：xab(r1) + aba(r2) 在 'xababa' 上不因 r2 被挡而复活 [3,6)
    final overlapRules = [
      const ReplaceRule(pattern: 'xab', replacement: '', kind: RuleKind.highlight, id: 'r1'),
      const ReplaceRule(pattern: 'aba', replacement: '', kind: RuleKind.highlight, id: 'r2'),
    ];
    expect(actualMarks('xababa', overlapRules), equals(referenceMarks('xababa', overlapRules)));
    expect(actualMarks('xababa', overlapRules), [(0, 3, 'r1')]);
    expect(actualMarks('ababa', overlapRules), equals(referenceMarks('ababa', overlapRules)));

    // 4. 混合字面量规则 + 复杂正则规则 + 禁用/跨书/非法规则
    final mixedRules = [
      const ReplaceRule(pattern: '爱丽丝|白兔', replacement: '', kind: RuleKind.highlight, id: 'm1'),
      const ReplaceRule(pattern: r'第\d+章', replacement: '', kind: RuleKind.color, id: 'm2'),
      const ReplaceRule(pattern: '爱丽丝梦游', replacement: '', kind: RuleKind.highlight, id: 'm3'),
      const ReplaceRule(pattern: '「[^」]+」', replacement: '', kind: RuleKind.highlight, id: 'm4'),
      const ReplaceRule(pattern: '(', replacement: '', kind: RuleKind.highlight, id: 'bad'),
      const ReplaceRule(pattern: '白兔', replacement: '', kind: RuleKind.highlight, id: 'otherBook', aid: '999'),
      const ReplaceRule(pattern: '梦游', replacement: '', kind: RuleKind.highlight, id: 'off', enabled: false),
      const ReplaceRule(pattern: '爱丽丝', replacement: 'X', kind: RuleKind.replace, id: 'rep'),
    ];
    const sample4 = '第12章 爱丽丝梦游仙境，白兔说：「快跟上来！」随后爱丽丝追了过去。';
    expect(actualMarks(sample4, mixedRules, '1'), equals(referenceMarks(sample4, mixedRules, '1')));

    // 5. 空串与无命中快退出
    expect(ReplaceRules.marks('', charRules), isEmpty);
    expect(ReplaceRules.marks('完全不相关的纯正文内容', charRules), isEmpty);
    expect(ReplaceRules.marks('完全不相关的纯正文内容', mixedRules, '1'), isEmpty);
  });

  test('RuleNotes 缓存 O(1) 读取、keysView 与变更失效', () async {
    final dir = Directory.systemTemp.createTempSync('ark_rule_notes_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    addTearDown(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    expect(RuleNotes.get('1', 'r1'), '');
    expect(RuleNotes.keysView('1'), isEmpty);

    await RuleNotes.set('1', 'r1', '主角设定');
    await RuleNotes.set('1', 'r2', '关键伏笔');
    expect(RuleNotes.get('1', 'r1'), '主角设定');
    expect(RuleNotes.get('1', 'r2'), '关键伏笔');
    final k1 = RuleNotes.keysView('1');
    final k2 = RuleNotes.keysView('1');
    expect(identical(k1, k2), isTrue);
    expect(k1, {'r1', 'r2'});

    // 清空单条
    await RuleNotes.set('1', 'r1', '   ');
    expect(RuleNotes.get('1', 'r1'), '');
    expect(RuleNotes.keysView('1'), {'r2'});

    // 外部写入新 Map 自动失效缓存
    await Hive.box('session').put('notes:1', {'r3': '同步备注'});
    expect(RuleNotes.get('1', 'r3'), '同步备注');
    expect(RuleNotes.keysView('1'), {'r3'});
  });
}
