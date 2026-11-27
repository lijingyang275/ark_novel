import 'package:flutter/material.dart';

import 'env.dart';
import 'motion.dart';
import 'theme_doodle.dart';

/// "Claude 风格"配色：暖米白底、陶土橙强调色、暖深灰暗色模式。
class AppColors {
  const AppColors._();

  static const terracotta = Color(0xFFC96442);
  static const terracottaLight = Color(0xFFD97757);

  // 浅色
  static const cream = Color(0xFFFAF9F5);
  static const creamDeep = Color(0xFFF0EEE6);
  static const ink = Color(0xFF141413);
  static const inkSoft = Color(0xFF5E5D59);
  static const line = Color(0xFFE3DFD3);

  // 深色
  static const night = Color(0xFF262624);
  static const nightRaised = Color(0xFF30302E);
  static const paper = Color(0xFFFAF9F5);
  static const paperSoft = Color(0xFFC2C0B6);
  static const lineDark = Color(0xFF3E3E3A);
}

/// 标题用衬线体；没有安装时依次回退到系统宋体。
const List<String> kSerifFallback = ['Noto Serif SC', 'Source Han Serif SC', 'Songti SC', 'STSong', 'serif'];

/// 配色方案：强调色 + 浅色 / 深色各一个底色，整个界面（背景、卡片、边框、导航）都跟着换。
/// 卡片、分隔线等表面色不再逐个手调，按 [SurfaceTones.of] 从底色和强调色统一推导，所有配色的层次感一致。
class AppPalette {
  const AppPalette(this.name, this.accentLight, this.accentDark, {required this.bgLight, required this.bgDark, this.art, this.secondary, this.scene = false});

  final String name;

  /// 角色主题的图片前缀（assets/theme/`art`_0..3.webp 导航图标，以及横幅、空状态等插画，见 theme_doodle.dart）；普通配色为 null
  final String? art;

  /// 角色主题的第二强调色（装饰、渐变用）
  final Color? secondary;

  /// 插画主题（遗迹·晴空）：书架和「我的」顶部插画、手画导航图标、旗形角标、方一点的圆角、文楷标题
  final bool scene;
  final Color accentLight, accentDark;
  final Color bgLight, bgDark;

  Color accent(bool dark) => dark ? accentDark : accentLight;
  Color bg(bool dark) => dark ? bgDark : bgLight;
  SurfaceTones tones(bool dark) => SurfaceTones.of(bg(dark), accent(dark), dark);
  Color card(bool dark) => tones(dark).container;
  Color line(bool dark) => tones(dark).line;
  Color get cardLight => card(false);
  Color get cardDark => card(true);
}

/// 一套表面色阶：在底色上按固定比例混入文字色，再染一点强调色。
/// 浅色时 [lowest] 是比底色更亮的“抬起”面（卡片、输入框）；深色时卡片要比底色亮才看得出，[lowest] 也取亮一档。
class SurfaceTones {
  const SurfaceTones._(this.lowest, this.low, this.container, this.high, this.highest, this.line);

  final Color lowest, low, container, high, highest, line;

  static const _inkMix = Color(0xFF1A1A18);
  static const _paperMix = Color(0xFFF2F0EA);

  static SurfaceTones of(Color bg, Color accent, bool dark) {
    final on = dark ? _paperMix : _inkMix;
    Color tone(double t) => Color.lerp(Color.lerp(bg, on, t)!, accent, dark ? 0.035 : 0.025)!;
    return dark
        ? SurfaceTones._(tone(0.07), tone(0.035), tone(0.06), tone(0.09), tone(0.13), tone(0.15))
        : SurfaceTones._(Color.lerp(bg, Colors.white, 0.7)!, tone(0.028), tone(0.048), tone(0.07), tone(0.10), tone(0.12));
  }
}

const appPalettes = [
  AppPalette('陶土', Color(0xFFC15F3C), Color(0xFFDE8462), bgLight: AppColors.cream, bgDark: AppColors.night),
  AppPalette('靛蓝', Color(0xFF3E5BA6), Color(0xFF9BB0E6), bgLight: Color(0xFFF6F7F9), bgDark: Color(0xFF1B1D23)),
  AppPalette('森绿', Color(0xFF3D7655), Color(0xFF93C3A2), bgLight: Color(0xFFF6F7F4), bgDark: Color(0xFF1B1E1B)),
  AppPalette('玫瑰', Color(0xFFB04868), Color(0xFFE896AE), bgLight: Color(0xFFFAF7F7), bgDark: Color(0xFF221D1F)),
  AppPalette('琥珀', Color(0xFFA26E1A), Color(0xFFE2B867), bgLight: Color(0xFFFAF8F2), bgDark: Color(0xFF211E18)),
  AppPalette('杏菜·汽水', Color(0xFF2F6CCF), Color(0xFF80B2F2), // 强调色取发色（蓝）
      bgLight: Color(0xFFF4F8FC), bgDark: Color(0xFF171C27), art: 'anna', secondary: Color(0xFFF4935E)),
  AppPalette('知花·草莓牛奶', Color(0xFFAE3646), Color(0xFFEE8693), // 发色（酒红）
      bgLight: Color(0xFFFCF6F7), bgDark: Color(0xFF241C1E), art: 'chika', secondary: Color(0xFF29A9E0)),
  AppPalette('天爱星·薄荷会长', Color(0xFF2F5577), Color(0xFF93B8D8), // 发色（藏青）往薄荷底色的青调靠一点，不再生硬
      bgLight: Color(0xFFF3F8F5), bgDark: Color(0xFF171E21), art: 'amane', secondary: Color(0xFFEE6C9A)),
  AppPalette('石墨', Color(0xFF3B3B39), Color(0xFFD4D2CC), bgLight: Color(0xFFF6F6F5), bgDark: Color(0xFF1E1E1F)),
  // 放在最后：配色按序号存，插在中间会让已经选了后面配色的人换掉
  AppPalette('遗迹·晴空', Color(0xFFA8452F), Color(0xFFE08A68), // 石柱的赭红；第二强调色是旗子的芥末黄
      bgLight: Color(0xFFF7F2E8), bgDark: Color(0xFF14232A), secondary: Color(0xFFD9A03F), scene: true),
];

/// 滑块没拖到的那段轨道：默认色在浅底上看不见，用文字色的淡影。阅读设置面板换了底色，也用这两个。
SliderThemeData appSliderTheme(ColorScheme s) => SliderThemeData(inactiveTrackColor: s.onSurface.withValues(alpha: 0.14));

/// 关着的开关：默认的边框和圆点跟着分隔线的颜色，太淡，看不出是开关。
SwitchThemeData appSwitchTheme(ColorScheme s) {
  WidgetStateProperty<Color?> off(Color c) => WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) || st.contains(WidgetState.disabled) ? null : c);
  return SwitchThemeData(
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, // 设置里整行都能点，不用开关自己撑高一圈
    thumbColor: off(s.onSurfaceVariant.withValues(alpha: 0.8)),
    trackColor: off(s.onSurface.withValues(alpha: 0.06)),
    trackOutlineColor: off(s.onSurfaceVariant.withValues(alpha: 0.38)),
  );
}

Color _onColor(Color bg, {bool preferDark = false}) {
  if (ThemeData.estimateBrightnessForColor(bg) == Brightness.light) return Colors.black;
  if (preferDark && bg.computeLuminance() > 0.25) return Colors.black;
  return Colors.white;
}

/// [pureBlack]：深色时底色用纯黑（AMOLED 屏黑色像素不发光），卡片和边框也按同样比例从纯黑推导，压到接近黑。
ThemeData buildAppTheme(Brightness brightness, [AppPalette palette = const AppPalette('陶土', Color(0xFFC15F3C), Color(0xFFDE8462), bgLight: AppColors.cream, bgDark: AppColors.night), bool pureBlack = false]) {
  final dark = brightness == Brightness.dark;
  final black = dark && pureBlack;
  final bg = black ? Colors.black : palette.bg(dark);
  final primary = palette.accent(dark);
  final t = SurfaceTones.of(bg, primary, dark);
  final card = t.container;
  final line = t.line;
  final raised = t.lowest;
  final secondary = palette.secondary ?? (dark ? AppColors.paperSoft : AppColors.inkSoft);
  final onSurface = dark ? AppColors.paper : AppColors.ink;
  final tertiaryContainer = Color.alphaBlend((palette.secondary ?? primary).withValues(alpha: dark ? 0.22 : 0.16), card);
  final desktop = isDesktop;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: _onColor(primary, preferDark: dark),
    secondary: secondary,
    onSecondary: _onColor(secondary, preferDark: true),
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onSurface,
    error: dark ? const Color(0xFFF2B8B5) : const Color(0xFFB3261E),
    onError: dark ? const Color(0xFF601410) : Colors.white,
    surface: bg,
    onSurface: onSurface,
    onSurfaceVariant: dark ? AppColors.paperSoft : AppColors.inkSoft,
    surfaceContainerLowest: raised,
    surfaceContainerLow: t.low,
    surfaceContainer: card,
    surfaceContainerHigh: t.high,
    surfaceContainerHighest: t.highest,
    outline: line,
    outlineVariant: line,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: scheme.surface);
  // 插画主题：标题换文楷、字距拉开一点，圆角收小，像切过的石块
  final serif = palette.scene ? base.textTheme.apply(fontFamily: 'LXGWWenKai', fontFamilyFallback: kSerifFallback) : base.textTheme.apply(fontFamilyFallback: kSerifFallback);
  final spacing = palette.scene ? 1.5 : null;
  final r = palette.scene ? 5.0 : (desktop ? 9.0 : 12.0);
  // 桌面端用鼠标点，按钮不用撑到手指大小
  final buttonSize = desktop ? const Size(64, 40) : const Size(64, 48);

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displaySmall: serif.displaySmall?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5),
      headlineMedium: serif.headlineMedium?.copyWith(fontWeight: FontWeight.w500),
      headlineSmall: serif.headlineSmall?.copyWith(fontWeight: FontWeight.w500),
      titleLarge: serif.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: spacing),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: desktop ? 0 : null,
      centerTitle: false,
      // 桌面端顶栏和书架的单行顶栏一样高（52），标题用衬线大字
      toolbarHeight: desktop ? 52 : null,
      titleTextStyle: serif.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: desktop ? FontWeight.w600 : FontWeight.w500, fontSize: desktop ? 20 : null, letterSpacing: spacing),
    ),
    cardTheme: CardThemeData(
      color: raised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(palette.scene ? 6 : (desktop ? 12 : 16)),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        textStyle: TextStyle(fontSize: desktop ? 14.5 : 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(r),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // 比页面背景深一档，和上面的内容分开
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.scene ? scheme.secondary.withValues(alpha: 0.26) : scheme.primary.withValues(alpha: 0.14),
      indicatorShape: palette.scene ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)) : null,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(color: scheme.outline, thickness: 1, space: 1),
    sliderTheme: appSliderTheme(scheme),
    switchTheme: appSwitchTheme(scheme),
    popupMenuTheme: const PopupMenuThemeData(position: PopupMenuPosition.under),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: ApplePageTransitionsBuilder(),
        TargetPlatform.android: ApplePageTransitionsBuilder(),
        TargetPlatform.macOS: ApplePageTransitionsBuilder(),
        TargetPlatform.windows: ApplePageTransitionsBuilder(),
        TargetPlatform.linux: ApplePageTransitionsBuilder(),
      },
    ),
    dialogTheme: palette.scene ? DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))) : null,
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(palette.scene ? 12 : 20))),
      showDragHandle: false,
    ),
    chipTheme: palette.scene ? ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r))) : null,
    segmentedButtonTheme: palette.scene ? SegmentedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(r))))) : null,
    extensions: [?characterArtOf(palette)],
  );
}
