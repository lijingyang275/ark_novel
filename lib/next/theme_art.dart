import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'theme_squire.dart';

/// 角色主题和插画主题的美术：底部导航的 Q 版图标（其余插画见 theme_doodle.dart）。普通配色没有这些，返回 null 走默认图标。
class ThemeArt {
  const ThemeArt._();

  static Widget? navIcon(AppPalette palette, int index, {required bool selected}) {
    if (palette.scene) return RuinsNavIcon(index, selected: selected);
    final art = palette.art;
    if (art == null) return null;
    return _ArtNavIcon(asset: 'assets/theme/${art}_$index.webp', selected: selected);
  }
}

class _ArtNavIcon extends StatelessWidget {
  const _ArtNavIcon({required this.asset, required this.selected});

  final String asset;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final d = AppMotion.dur(context, AppMotion.fast);
    final px = (32 * 1.14 * MediaQuery.devicePixelRatioOf(context)).ceil();
    return AnimatedScale(
      scale: selected ? 1.14 : 0.92,
      duration: d,
      curve: AppMotion.snappy,
      child: AnimatedOpacity(
        opacity: selected ? 1 : 0.65,
        duration: d,
        curve: AppMotion.curve,
        child: Image.asset(asset, width: 32, height: 32, cacheWidth: px, cacheHeight: px),
      ),
    );
  }
}
