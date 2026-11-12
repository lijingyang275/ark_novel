import 'package:flutter/material.dart' hide Text;

import 'app_prefs.dart';
import 'rules.dart';
import 'text.dart';

/// 变色 / 高亮选颜色：一排预设色、最近自定义过的颜色，点「调色盘」展开自己调（色相、饱和度、亮度、十六进制），
/// 上面的预览按正文里真实的样子画——变色只染字，高亮带一层淡底色。
class ColorPickerField extends StatefulWidget {
  const ColorPickerField({super.key, required this.color, required this.onChanged, this.sample = '润奈', this.highlight = false});

  final int color;
  final ValueChanged<int> onChanged;

  /// 预览里显示的文字（一般是选中的字）
  final String sample;

  /// 预览按高亮（带底色）画，否则按变色（只染字）
  final bool highlight;

  @override
  State<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends State<ColorPickerField> {
  static const _recentKey = 'colors.recent';
  bool _open = false;
  late final _hex = TextEditingController(text: _hexOf(widget.color));
  late HSVColor _hsv = HSVColor.fromColor(Color(widget.color));

  static String _hexOf(int c) => (c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  List<int> get _recent => AppPrefs.readList(_recentKey).map(int.tryParse).whereType<int>().toList();

  void _pick(int c, {bool remember = false}) {
    if (remember) {
      final rest = _recent.where((e) => e != c && !ruleColors.contains(e));
      if (!ruleColors.contains(c)) AppPrefs.write(_recentKey, [c, ...rest].take(8).map((e) => '$e').toList());
    }
    widget.onChanged(c);
  }

  /// 滑块 / 输入框改了颜色：同步另外两个，预览马上变
  void _setHsv(HSVColor v, {bool fromHex = false}) {
    setState(() => _hsv = v);
    final c = v.toColor().toARGB32();
    if (!fromHex) _hex.text = _hexOf(c);
    widget.onChanged(c);
  }

  Widget _swatch(int c, {double size = 28}) {
    final selected = widget.color == c;
    return GestureDetector(
      onTap: () {
        _pick(c);
        setState(() {
          _hsv = HSVColor.fromColor(Color(c));
          _hex.text = _hexOf(c);
        });
      },
      child: Container(width: size, height: size, decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(width: selected ? 3 : 0, color: Theme.of(context).colorScheme.onSurface))),
    );
  }

  /// 带渐变底色的滑块（让人看得出往哪边拖是什么颜色）
  Widget _slider(String label, double value, double max, List<Color> track, ValueChanged<double> onChanged) {
    final cur = _hsv.toColor();
    return Row(
      children: [
        SizedBox(width: 48, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: track))),
              SizedBox(
                height: 30,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 10,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: cur,
                    overlayColor: cur.withValues(alpha: 0.2),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(value: value.clamp(0, max), max: max, onChanged: onChanged),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(widget.color);
    final theme = Theme.of(context);
    final recent = _recent;
    final hues = [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()];
    final base = TextStyle(fontSize: 18, color: theme.colorScheme.onSurface);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 预览：前后各一段普通文字，中间是染色的样子
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
          child: Text.rich(
            TextSpan(
              style: base,
              children: [
                const TextSpan(text: '「'),
                TextSpan(text: widget.sample.isEmpty ? '示例' : widget.sample, style: TextStyle(color: color, backgroundColor: widget.highlight ? color.withValues(alpha: 0.13) : null)),
                const TextSpan(text: '，好久不见。」'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final c in ruleColors) _swatch(c)]),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('最近用过', style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final c in recent) _swatch(c, size: 24)]),
        ],
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less : Icons.palette_outlined, size: 18),
          label: Text(_open ? '收起调色盘' : '调色盘'),
        ),
        if (_open) ...[
          _slider('色相', _hsv.hue, 360, hues, (v) => _setHsv(_hsv.withHue(v))),
          _slider('饱和度', _hsv.saturation, 1, [HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(), HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor()], (v) => _setHsv(_hsv.withSaturation(v))),
          _slider('亮度', _hsv.value, 1, [Colors.black, HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor()], (v) => _setHsv(_hsv.withValue(v))),
          Row(
            children: [
              SizedBox(width: 48, child: Text('色值', style: theme.textTheme.bodySmall)),
              SizedBox(
                width: 112,
                child: TextField(
                  controller: _hex,
                  maxLength: 6,
                  style: const TextStyle(fontSize: 15),
                  decoration: const InputDecoration(prefixText: '#', counterText: '', isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 8)),
                  onChanged: (t) {
                    final v = int.tryParse(t, radix: 16);
                    if (t.length == 6 && v != null) _setHsv(HSVColor.fromColor(Color(0xFF000000 | v)), fromHex: true);
                  },
                ),
              ),
              const Spacer(),
              // 调好了点这个，记进"最近用过"
              TextButton(onPressed: () => setState(() => _pick(widget.color, remember: true)), child: const Text('存为常用')),
            ],
          ),
        ],
      ],
    );
  }
}
