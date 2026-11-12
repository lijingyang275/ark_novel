import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../color_picker.dart';
import '../reader/reader_page.dart';
import '../rules.dart';
import '../widgets.dart';
import '../x_list.dart';
import '../text.dart';

/// 正则规则管理：替换（去广告、统一用字）和高亮（给人物名染色、点一下写备注）。改动后已打开的章节会重新生成。
class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});

  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage> {
  late List<ReplaceRule> _rules = ReplaceRules.all();

  Future<void> _commit(List<ReplaceRule> next) async {
    await ReplaceRules.save(next);
    ref.invalidate(chapterProvider);
    setState(() => _rules = ReplaceRules.all());
  }

  Future<void> _edit(int? index) async {
    final rule = await showRuleDialog(context, initial: index == null ? null : _rules[index]);
    if (rule == null) return;
    final next = [..._rules];
    final at = index;
    if (at == null) {
      next.add(rule);
    } else {
      next[at] = rule;
    }
    await _commit(next);
  }

  Widget _row(int i, ReplaceRule r) {
    final scheme = Theme.of(context).colorScheme;
    final replace = r.kind == RuleKind.replace;
    final scope = r.aid.isNotEmpty ? ' · 仅本书' : '';
    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.error.withValues(alpha: 0.12),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline, color: scheme.error),
      ),
      onDismissed: (_) => _commit([..._rules]..removeAt(i)),
      child: XTile(
        leading: replace
            ? const XLeading(icon: Icons.find_replace)
            : XLeading(color: Color(r.color), child: Text('文', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(r.color)))),
        title: replace ? r.pattern : r.label,
        subtitle: replace ? (r.replacement.isEmpty ? '删除匹配内容$scope' : '替换为「${r.replacement}」$scope') : '${r.kind == RuleKind.color ? '文字着色' : '背景高亮'}$scope${r.pattern == r.label ? '' : ' · ${r.pattern}'}',
        onTap: () => _edit(i),
        trailing: Switch(value: r.enabled, onChanged: (v) => _commit([..._rules]..[i] = r.copyWith(enabled: v))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final replaces = [for (final (i, r) in _rules.indexed) if (r.kind == RuleKind.replace) (i, r)];
    final marks = [for (final (i, r) in _rules.indexed) if (r.kind != RuleKind.replace) (i, r)];
    return Scaffold(
      appBar: AppBar(title: const Text('正则规则'), actions: [IconButton(tooltip: hz(context, '添加规则'), icon: const Icon(Icons.add), onPressed: () => _edit(null))]),
      body: _rules.isEmpty
          ? XEmpty(icon: Icons.find_replace, title: '还没有规则', detail: '替换：去除章节中的广告、统一用字\n着色 / 高亮：标出人名等关键词，阅读时点按可添加备注', action: '添加规则', onAction: () => _edit(null))
          : contentWidth(ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (replaces.isNotEmpty) ...[const XGroupTitle('替换'), for (final (i, r) in replaces) _row(i, r)],
                if (replaces.isNotEmpty && marks.isNotEmpty) const XDivider(),
                if (marks.isNotEmpty) ...[const XGroupTitle('着色与高亮'), for (final (i, r) in marks) _row(i, r)],
              ],
            )),
    );
  }
}

/// 添加 / 编辑一条规则的对话框；返回 null 表示取消。阅读器里选中文字后也用它。
Future<ReplaceRule?> showRuleDialog(BuildContext context, {ReplaceRule? initial}) async {
  final pattern = TextEditingController(text: initial?.pattern ?? '');
  final replacement = TextEditingController(text: initial?.replacement ?? '');
  final name = TextEditingController(text: initial?.name ?? '');
  var kind = initial?.kind ?? RuleKind.replace;
  var color = initial?.color ?? ruleColors.first;
  String? error;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text(initial == null || initial.pattern.isEmpty ? '添加规则' : '编辑规则'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<RuleKind>(
                segments: const [ButtonSegment(value: RuleKind.replace, label: Text('替换')), ButtonSegment(value: RuleKind.color, label: Text('着色')), ButtonSegment(value: RuleKind.highlight, label: Text('高亮'))],
                selected: {kind},
                onSelectionChanged: (s) => setLocal(() => kind = s.first),
              ),
              const SizedBox(height: 12),
              TextField(controller: pattern, decoration: InputDecoration(label: Text('匹配内容（正则表达式）'), errorText: error)),
              const SizedBox(height: 12),
              if (kind == RuleKind.replace)
                TextField(controller: replacement, decoration: const InputDecoration(label: Text('替换为'), helper: Text(r'留空则删除匹配内容；用 $1 引用分组')))
              else ...[
                if (kind == RuleKind.highlight) ...[
                  TextField(controller: name, decoration: const InputDecoration(label: Text('名称（可选）'), helper: Text('例如人物名，备注按名称归类'))),
                  const SizedBox(height: 12),
                ],
                ColorPickerField(color: color, highlight: kind == RuleKind.highlight, sample: name.text.isNotEmpty ? name.text : '示例', onChanged: (c) => setLocal(() => color = c)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final e = pattern.text.isEmpty ? '请输入正则表达式' : ReplaceRule.validate(pattern.text);
              if (e != null) {
                setLocal(() => error = e);
              } else {
                Navigator.pop(context, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (saved != true) return null;
  return (initial ?? const ReplaceRule(pattern: '', replacement: '')).copyWith(pattern: pattern.text, replacement: replacement.text, name: name.text.trim(), kind: kind, color: color);
}
