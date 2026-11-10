import 'package:flutter/material.dart';

import 'theme_doodle.dart';

/// 「我的」、设置、设置子页面共用的列表零件，照 X（推特）侧边栏的样子：没有卡片和边框，铺在页面底色上，
/// 线条图标、黑白灰文字，靠字号、粗细、留白和细分隔线分层；强调色只用在开关、选中这些控件上。

/// 大号导航行：线条图标 + 粗体大字（「我的」的主列表）。[big] 为 false 时是次一级的小号普通字。
class XNavRow extends StatelessWidget {
  const XNavRow({super.key, required this.icon, required this.title, this.onTap, this.trailing, this.big = true, this.color});

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool big;
  final Color? color; // 比如「退出登录」用红色

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: big ? 12 : 10),
        child: Row(
          children: [
            Icon(icon, size: big ? 24 : 22, color: fg),
            SizedBox(width: big ? 18 : 16),
            Expanded(
              child: Text(title, style: TextStyle(fontSize: big ? 18 : 15.5, fontWeight: big ? FontWeight.w700 : FontWeight.w400, color: fg)),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 设置首页那种两行的导航：线条图标 + 粗体标题 + 灰色说明
class XEntry extends StatelessWidget {
  const XEntry({super.key, required this.icon, required this.title, this.subtitle, this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 23, color: scheme.onSurface),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                  if (subtitle != null) ...[const SizedBox(height: 1), Text(subtitle!, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一组设置的组名：粗体大字
class XGroupTitle extends StatelessWidget {
  const XGroupTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
    child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface)),
  );
}

/// 组和组之间的细线
class XDivider extends StatelessWidget {
  const XDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Divider(height: 0.5, thickness: 0.5, indent: 20, endIndent: 20, color: Theme.of(context).colorScheme.outline),
  );
}

/// 一段灰色说明（放在组下面）
class XNote extends StatelessWidget {
  const XNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
    child: Text(text, style: TextStyle(fontSize: 13, height: 1.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );
}

/// 一项设置：标题 + 灰色说明，右边放控件或当前值
class XTile extends StatelessWidget {
  const XTile({super.key, required this.title, this.subtitle, this.leading, this.trailing, this.onTap, this.danger = false, this.help});

  final String title;
  final String? subtitle;

  /// 详细说明：标题后面一个小问号，点了才弹出来，平时界面不占地方
  final String? help;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        // 带开关、带箭头、只有文字的行一样高
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(title, style: TextStyle(fontSize: 15.5, color: danger ? scheme.error : scheme.onSurface))),
                      if (help != null)
                        InkResponse(
                          radius: 16,
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(title: Text(title), content: Text(help!), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))]),
                          ),
                          child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.help_outline, size: 16, color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
                  if (subtitle != null) ...[const SizedBox(height: 3), Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant))],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
        ),
      ),
    );
  }
}

/// 开关：点整行都能切换
class XSwitch extends StatelessWidget {
  const XSwitch({super.key, required this.title, this.subtitle, required this.value, required this.onChanged, this.help});

  final String title;
  final String? subtitle;
  final String? help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => XTile(title: title, subtitle: subtitle, help: help, onTap: () => onChanged(!value), trailing: Switch(value: value, onChanged: onChanged));
}

/// 右边写当前值，点开从底部弹出选项
class XChoice<T> extends StatelessWidget {
  const XChoice({super.key, required this.title, this.subtitle, required this.value, required this.options, required this.onChanged});

  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return XTile(
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(options[value] ?? '', style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant)),
          Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
        ],
      ),
      onTap: () async {
        final v = await pickOption<T>(context, title, value, options);
        if (v != null) onChanged(v);
      },
    );
  }
}

/// 底部弹出的单选列表，选中的那项后面打勾
Future<T?> pickOption<T>(BuildContext context, String title, T current, Map<T, String> options) => showModalBottomSheet<T>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            for (final e in options.entries)
              InkWell(
                onTap: () => Navigator.pop(context, e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(child: Text(e.value, style: TextStyle(fontSize: 16, fontWeight: e.key == current ? FontWeight.w700 : null))),
                      if (e.key == current) Icon(Icons.check, color: scheme.primary),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  },
);

/// 滑块：标题和当前值一行，滑块在下面
class XSlider extends StatelessWidget {
  const XSlider({super.key, required this.title, required this.label, required this.slider});

  final String title;
  final String label;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(
        children: [
          Row(children: [Expanded(child: Text(title, style: TextStyle(fontSize: 15.5, color: scheme.onSurface))), Text(label, style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant))]),
          // 左右只留出半个圆点的宽度（拖到两头时圆点不出界），去掉刻度点
          SliderTheme(
            data: SliderTheme.of(context).copyWith(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10), tickMarkShape: SliderTickMarkShape.noTickMark),
            child: slider,
          ),
        ],
      ),
    );
  }
}

/// 选项不超过 3 个的：标题下面一排分段按钮
class XSegments<T> extends StatelessWidget {
  const XSegments({super.key, this.title, this.subtitle, required this.value, required this.options, required this.onChanged});

  final String? title; // 组名已经说清楚时可以不写
  final String? subtitle;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[Text(title!, style: TextStyle(fontSize: 15.5, color: scheme.onSurface)), const SizedBox(height: 8)],
          SizedBox(
            width: double.infinity,
            child: _buttons(scheme),
          ),
          if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))],
        ],
      ),
    );
  }

  Widget _buttons(ColorScheme scheme) => SegmentedButton<T>(
    showSelectedIcon: false,
    // 选中用主题色淡底（默认取第二强调色，角色主题下会和主色撞色）
    style: SegmentedButton.styleFrom(
      selectedBackgroundColor: scheme.primary.withValues(alpha: 0.14),
      selectedForegroundColor: scheme.primary,
      side: BorderSide(color: scheme.outline),
      visualDensity: VisualDensity.compact,
    ),
    segments: [for (final e in options.entries) ButtonSegment(value: e.key, label: Text(e.value))],
    selected: {value},
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

/// 一组小标签单选：标题在上，标签可以换行；[extra] 放在最后（比如「选择字体文件…」）
class XChips<T> extends StatelessWidget {
  const XChips({super.key, this.title, required this.value, required this.options, required this.onChanged, this.extra = const []});

  final String? title;
  final T? value; // null 时一个都不选中
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[Text(title!, style: TextStyle(fontSize: 15.5, color: scheme.onSurface)), const SizedBox(height: 8)],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in options.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: e.key == value,
                  showCheckmark: false,
                  selectedColor: scheme.primary.withValues(alpha: 0.14),
                  labelStyle: TextStyle(color: e.key == value ? scheme.primary : scheme.onSurface, fontWeight: e.key == value ? FontWeight.w600 : null),
                  side: BorderSide(color: e.key == value ? scheme.primary.withValues(alpha: 0.5) : scheme.outline),
                  onSelected: (_) => onChanged(e.key),
                ),
              ...extra,
            ],
          ),
        ],
      ),
    );
  }
}

/// 列表空着时的占位：主题色淡底圆里一个图标，下面标题、说明，可选一个按钮
class XEmpty extends StatelessWidget {
  const XEmpty({super.key, required this.icon, required this.title, this.detail, this.action, this.onAction});

  final IconData icon;
  final String title;
  final String? detail;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final art = CharacterArt.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (art != null)
              Image.asset(art.empty, width: 132, height: 132)
            else
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: Icon(icon, size: 34, color: scheme.primary),
              ),
            const SizedBox(height: 16),
            Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: scheme.onSurface)),
            if (detail != null) ...[const SizedBox(height: 6), Text(detail!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.6, color: scheme.onSurfaceVariant))],
            if (action != null) ...[const SizedBox(height: 20), FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: onAction, icon: const Icon(Icons.add), label: Text(action!))],
          ],
        ),
      ),
    );
  }
}

/// 列表行前面的小方块图标（二级页面的条目用）
class XLeading extends StatelessWidget {
  const XLeading({super.key, this.icon, this.color, this.child});

  final IconData? icon;
  final Color? color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
      alignment: Alignment.center,
      child: child ?? Icon(icon, size: 20, color: c),
    );
  }
}
