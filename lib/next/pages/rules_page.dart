import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../color_picker.dart';
import '../library.dart' show LibraryStore;
import '../motion.dart';
import '../reader/reader_page.dart';
import '../rules.dart';
import '../stats.dart';
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

  Future<void> _deleteAt(int index) async {
    final removed = _rules[index];
    final next = [..._rules]..removeAt(index);
    await _commit(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除规则「${removed.kind == RuleKind.replace ? removed.pattern : removed.label}」'),
          action: SnackBarAction(
            label: hz(context, '撤销'),
            onPressed: () {
              final restored = [..._rules];
              restored.insert(index.clamp(0, restored.length), removed);
              _commit(restored);
            },
          ),
        ),
      );
  }

  Widget _row(int i, ReplaceRule r) {
    final scheme = Theme.of(context).colorScheme;
    final replace = r.kind == RuleKind.replace;
    final bookTitle = r.aid.isEmpty ? '' : LibraryStore.shown(r.aid, ReadingStats.info(r.aid).title);
    final scope = r.aid.isNotEmpty ? (bookTitle.isNotEmpty && !bookTitle.startsWith('#') ? ' · 仅《$bookTitle》' : ' · 仅本书') : '';
    return Dismissible(
      key: ValueKey('${r.id}_$i'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: scheme.onError),
            const SizedBox(width: 6),
            Text('删除', style: TextStyle(color: scheme.onError)),
          ],
        ),
      ),
      onDismissed: (_) => _deleteAt(i),
      child: XTile(
        leading: replace
            ? const XLeading(icon: Icons.find_replace)
            : XLeading(color: Color(r.color), child: Text('文', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(r.color)))),
        title: replace ? r.pattern : r.label,
        subtitle: replace ? (r.replacement.isEmpty ? '删除匹配内容$scope' : '替换为「${r.replacement}」$scope') : '${r.kind == RuleKind.color ? '文字着色' : '背景高亮'}$scope${r.pattern == r.label ? '' : ' · ${r.pattern}'}',
        onTap: () => _edit(i),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: hz(context, '删除规则'),
              icon: Icon(Icons.delete_outline, size: 20, color: scheme.onSurfaceVariant),
              onPressed: () => _deleteAt(i),
            ),
            Switch(value: r.enabled, onChanged: (v) => _commit([..._rules]..[i] = r.copyWith(enabled: v))),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final replaces = [for (final (i, r) in _rules.indexed) if (r.kind == RuleKind.replace) (i, r)];
    final marks = [for (final (i, r) in _rules.indexed) if (r.kind != RuleKind.replace) (i, r)];
    return Scaffold(
      appBar: AppBar(title: const Text('正则规则'), actions: [IconButton(tooltip: hz(context, '添加规则'), icon: const Icon(Icons.add), onPressed: () => _edit(null))]),
      body: AppCrossfade(
        fill: true,
        child: _rules.isEmpty
            ? KeyedSubtree(
                key: const ValueKey('empty'),
                child: contentWidth(XEmpty(icon: Icons.find_replace, title: '还没有规则', detail: '替换：去除章节中的广告、统一用字\n着色 / 高亮：标出人名等关键词，阅读时点按可添加备注', action: '添加规则', onAction: () => _edit(null))),
              )
            : KeyedSubtree(
                key: const ValueKey('list'),
                child: contentWidth(ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    if (replaces.isNotEmpty) ...[const XGroupTitle('替换'), for (final (i, r) in replaces) _row(i, r)],
                    if (replaces.isNotEmpty && marks.isNotEmpty) const XDivider(),
                    if (marks.isNotEmpty) ...[const XGroupTitle('着色与高亮'), for (final (i, r) in marks) _row(i, r)],
                  ],
                )),
              ),
      ),
    );
  }
}

/// 添加 / 编辑一条规则的对话框；返回 null 表示取消。阅读器里选中文字后也用它。
Future<ReplaceRule?> showRuleDialog(BuildContext context, {ReplaceRule? initial}) async {
  final pattern = TextEditingController(text: initial?.pattern ?? '');
  final replacement = TextEditingController(text: initial?.replacement ?? '');
  final name = TextEditingController(text: initial?.name ?? '');
  final sample = TextEditingController();
  var kind = initial?.kind ?? RuleKind.replace;
  var color = initial?.color ?? ruleColors.first;
  var bookOnly = (initial?.aid ?? '').isNotEmpty;
  String? error;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        final kindDesc = switch (kind) {
          RuleKind.replace => '替换或删除匹配的正文（如去广告、统一译名）',
          RuleKind.color => '只改变匹配文字颜色，不带背景与备注',
          RuleKind.highlight => '带淡底色标记，阅读时点按高亮文字可编写人物或伏笔备注',
        };
        String? preview;
        if (kind == RuleKind.replace && sample.text.isNotEmpty && pattern.text.isNotEmpty && ReplaceRule.validate(pattern.text) == null) {
          preview = ReplaceRules.apply(sample.text, [ReplaceRule(pattern: pattern.text, replacement: replacement.text, kind: RuleKind.replace)]);
        }
        return AlertDialog(
          title: Text(initial == null || initial.pattern.isEmpty ? '添加规则' : '编辑规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<RuleKind>(
                  segments: const [ButtonSegment(value: RuleKind.replace, label: Text('替换')), ButtonSegment(value: RuleKind.color, label: Text('着色')), ButtonSegment(value: RuleKind.highlight, label: Text('高亮'))],
                  selected: {kind},
                  onSelectionChanged: (s) => setLocal(() => kind = s.first),
                ),
                const SizedBox(height: 6),
                AppCrossfade(
                  alignment: Alignment.centerLeft,
                  child: Text(kindDesc, key: ValueKey(kind), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pattern,
                  onChanged: (_) => setLocal(() => error = null),
                  decoration: InputDecoration(label: const Text('匹配内容（正则表达式）'), errorText: error),
                ),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: AppMotion.dur(context, AppMotion.fast),
                  curve: AppMotion.curve,
                  alignment: Alignment.topCenter,
                  child: AppCrossfade(
                    alignment: Alignment.topCenter,
                    child: kind == RuleKind.replace
                        ? Column(
                            key: const ValueKey('replace-fields'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: replacement,
                                onChanged: (_) => setLocal(() {}),
                                decoration: const InputDecoration(label: Text('替换为'), helper: Text(r'留空则删除匹配内容；用 $1 引用分组')),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: sample,
                                onChanged: (_) => setLocal(() {}),
                                decoration: const InputDecoration(label: Text('测试样本文本（可选）'), hint: Text('输入一句话实时查看替换结果', maxLines: 1, overflow: TextOverflow.ellipsis)),
                              ),
                              AppCollapse(
                                visible: preview != null,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                                    child: Text('结果：${preview ?? ''}', style: Theme.of(context).textTheme.bodySmall),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Column(
                            key: ValueKey('mark-fields-$kind'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AppCollapse(
                                visible: kind == RuleKind.highlight,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: TextField(
                                    controller: name,
                                    onChanged: (_) => setLocal(() {}),
                                    decoration: const InputDecoration(label: Text('名称（可选）'), helper: Text('例如人物名，备注按名称归类')),
                                  ),
                                ),
                              ),
                              ColorPickerField(color: color, highlight: kind == RuleKind.highlight, sample: name.text.isNotEmpty ? name.text : '示例', onChanged: (c) => setLocal(() => color = c)),
                            ],
                          ),
                  ),
                ),
                if ((initial?.aid ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('仅对当前书籍生效'),
                    subtitle: const Text('取消勾选后将对所有书籍生效'),
                    value: bookOnly,
                    onChanged: (v) => setLocal(() => bookOnly = v ?? true),
                  ),
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
        );
      },
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    pattern.dispose();
    replacement.dispose();
    name.dispose();
    sample.dispose();
  });
  if (saved != true) return null;
  final base = initial ?? const ReplaceRule(pattern: '', replacement: '');
  return base.copyWith(
    pattern: pattern.text,
    replacement: kind == RuleKind.replace ? replacement.text : '',
    name: kind == RuleKind.highlight ? name.text.trim() : '',
    kind: kind,
    color: color,
    aid: bookOnly ? base.aid : '',
  );
}
