import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../app_prefs.dart';
import '../library.dart';
import '../x_list.dart';
import 'bookshelf_page.dart';
import '../text.dart';

/// 选分类（可多选，一个都不选就是"默认"）。取消返回 null。
Future<List<String>?> pickCategories(BuildContext context, List<LibCategory> cats, List<String> initial) {
  final chosen = {...initial};
  return showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('选择分类'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 一个分类都不选就是放在"默认"；勾它会清掉其他分类
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认（不分类）'),
                value: chosen.isEmpty,
                onChanged: (v) => setState(chosen.clear),
              ),
              for (final c in cats)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name),
                  value: chosen.contains(c.id),
                  onChanged: (v) => setState(() => v! ? chosen.add(c.id) : chosen.remove(c.id)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, [for (final c in cats) if (chosen.contains(c.id)) c.id]), child: const Text('确定')),
        ],
      ),
    ),
  );
}

Future<String?> _askName(BuildContext context, String title, [String initial = '']) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hint: Text('分类名称', maxLines: 1, overflow: TextOverflow.ellipsis)), onSubmitted: (v) => Navigator.pop(context, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
      ],
    ),
  ).then((v) => v?.trim().isEmpty ?? true ? null : v!.trim());
}

/// 管理书架标签：默认、连载、完结和自己建的分类放在一起拖动排序（和书架上拖标签是同一个顺序），每个都能隐藏；
/// 自己建的还能改名、删除。分类只存在本机，不影响网站书架。
class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    ref.watch(appPrefsProvider);
    final ctl = ref.read(libraryProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final tabs = allShelfTabs(lib.cats);
    final merged = lib.cats.where(isMergedCategory).toList(); // 和连载 / 完结同名的，书并进那个标签，不单独排
    final hidden = AppPrefs.readList(P.hiddenTabs);
    Future<void> create() async {
      final name = await _askName(context, '新建分类');
      if (name != null) await ctl.addCategory(name);
    }

    void toggleHidden(LibCategory c) {
      final next = hidden.contains(c.id) ? hidden.where((e) => e != c.id).toList() : [...hidden, c.id];
      if (tabs.every((t) => next.contains(t.id))) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('至少要留一个标签显示在书架上')));
        return;
      }
      ref.read(appPrefsProvider.notifier).set(P.hiddenTabs, next);
    }

    Widget menu(LibCategory c) => PopupMenuButton<String>(
      tooltip: hz(context, '更多'),
      icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined), title: Text('重命名'))),
        PopupMenuItem(value: 'delete', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.delete_outline, color: scheme.error), title: Text('删除', style: TextStyle(color: scheme.error)))),
      ],
      onSelected: (v) async {
        if (v == 'rename') {
          final name = await _askName(context, '重命名分类', c.name);
          if (name != null) await ctl.renameCategory(c.id, name);
          return;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除「${c.name}」？'),
            content: const Text('分类中的书不会被删除，只是不再属于该分类。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(style: FilledButton.styleFrom(backgroundColor: scheme.error), onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        );
        if (ok == true) await ctl.deleteCategory(c.id);
      },
    );

    final builtIn = {'', 'auto:ongoing', 'auto:done'};
    return Scaffold(
      appBar: AppBar(title: const Text('分类管理')),
      floatingActionButton: FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: const Text('新建分类')),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        buildDefaultDragHandles: false,
        footer: Column(
          children: [
            for (final c in merged)
              XTile(
                leading: XLeading(icon: Icons.merge_type, color: scheme.onSurfaceVariant),
                title: c.name,
                subtitle: '并入「${c.name}」',
                trailing: menu(c),
              ),
          ],
        ),
        itemCount: tabs.length,
        onReorderItem: (from, to) {
          final list = [...tabs];
          list.insert(to, list.removeAt(from));
          Hive.box('session').put('shelfTabOrder', [for (final c in list) c.id]);
          // 自建分类本身的顺序（选分类时的列表）也跟着改，顺便让这一页和书架重建
          ctl.reorderCategories([...list.where((c) => !builtIn.contains(c.id)).map((c) => lib.cats.firstWhere((e) => e.id == c.id)), ...merged]);
        },
        itemBuilder: (context, i) {
          final c = tabs[i];
          final auto = builtIn.contains(c.id);
          final off = hidden.contains(c.id);
          return Material(
            key: ValueKey(c.id),
            color: Colors.transparent,
            child: Opacity(
              opacity: off ? 0.5 : 1,
              child: XTile(
                leading: XLeading(icon: auto ? Icons.auto_awesome_outlined : Icons.label_outline, color: scheme.primary),
                title: c.name,
                subtitle: '${booksInTab(lib, c.id)} 本书${auto ? ' · 自动' : ''}${off ? ' · 已隐藏' : ''}',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(tooltip: hz(context, off ? '在书架上显示' : '在书架上隐藏'), icon: Icon(off ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: scheme.onSurfaceVariant), onPressed: () => toggleHidden(c)),
                    if (auto) const SizedBox(width: 48) else menu(c), // 占住菜单的位置，眼睛图标上下对齐
                    ReorderableDragStartListener(index: i, child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.drag_indicator, color: scheme.onSurfaceVariant))),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
