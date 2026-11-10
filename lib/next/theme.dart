import 'package:flutter/material.dart';

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

/// 配色方案：强调色 + 浅色 / 深色各一套底色，整个界面（背景、卡片、边框、导航）都跟着换。
class AppPalette {
  const AppPalette(this.name, this.accentLight, this.accentDark, {required this.bgLight, required this.cardLight, required this.lineLight, required this.bgDark, required this.cardDark, required this.lineDark, this.art, this.secondary, this.scene = false});

  final String name;

  /// 角色主题的图片前缀（assets/theme/`art`_0..3.webp 导航图标，以及横幅、空状态等插画，见 theme_doodle.dart）；普通配色为 null
  final String? art;

  /// 角色主题的第二强调色（装饰、渐变用）
  final Color? secondary;

  /// 插画主题（遗迹·晴空）：书架和「我的」顶部插画、手画导航图标、旗形角标、方一点的圆角、文楷标题
  final bool scene;
  final Color accentLight, accentDark;
  final Color bgLight, cardLight, lineLight;
  final Color bgDark, cardDark, lineDark;

  Color accent(bool dark) => dark ? accentDark : accentLight;
  Color bg(bool dark) => dark ? bgDark : bgLight;
  Color card(bool dark) => dark ? cardDark : cardLight;
  Color line(bool dark) => dark ? lineDark : lineLight;
}

const appPalettes = [
  AppPalette('陶土', AppColors.terracotta, AppColors.terracottaLight, bgLight: AppColors.cream, cardLight: AppColors.creamDeep, lineLight: AppColors.line, bgDark: AppColors.night, cardDark: AppColors.nightRaised, lineDark: AppColors.lineDark),
  AppPalette('靛蓝', Color(0xFF3D5A9B), Color(0xFF8FA8E0), bgLight: Color(0xFFF4F6FB), cardLight: Color(0xFFE5EAF5), lineLight: Color(0xFFD3DAEA), bgDark: Color(0xFF181C27), cardDark: Color(0xFF242A3A), lineDark: Color(0xFF353C52)),
  AppPalette('森绿', Color(0xFF4A7C59), Color(0xFF8DBB9A), bgLight: Color(0xFFF4F7F2), cardLight: Color(0xFFE4ECDF), lineLight: Color(0xFFD1DDCB), bgDark: Color(0xFF171D18), cardDark: Color(0xFF232B25), lineDark: Color(0xFF34402F)),
  AppPalette('玫瑰', Color(0xFFB04A6B), Color(0xFFE08CA5), bgLight: Color(0xFFFBF5F6), cardLight: Color(0xFFF3E3E7), lineLight: Color(0xFFE8D0D6), bgDark: Color(0xFF211A1D), cardDark: Color(0xFF30262A), lineDark: Color(0xFF463539)),
  AppPalette('琥珀', Color(0xFFB07A1E), Color(0xFFE2B45E), bgLight: Color(0xFFFAF6EC), cardLight: Color(0xFFF1E8D2), lineLight: Color(0xFFE3D6B5), bgDark: Color(0xFF1F1B12), cardDark: Color(0xFF2D271A), lineDark: Color(0xFF43392A)),
  AppPalette('杏菜·汽水', Color(0xFF2F6FD6), Color(0xFF6FA8F0), // 强调色取发色（蓝）
      bgLight: Color(0xFFF2F9FE), cardLight: Color(0xFFDDEFFA), lineLight: Color(0xFFC5E0F2), bgDark: Color(0xFF121A33), cardDark: Color(0xFF1C2848), lineDark: Color(0xFF2D3C66), art: 'anna', secondary: Color(0xFFF4935E)),
  AppPalette('知花·草莓牛奶', Color(0xFFB0303F), Color(0xFFE8707C), // 发色（酒红）
      bgLight: Color(0xFFFDF1F3), cardLight: Color(0xFFF8DCE2), lineLight: Color(0xFFEFC6CF), bgDark: Color(0xFF241619), cardDark: Color(0xFF33212A), lineDark: Color(0xFF4A3038), art: 'chika', secondary: Color(0xFF29A9E0)),
  AppPalette('天爱星·薄荷会长', Color(0xFF2D3D6E), Color(0xFF8FA3D8), // 发色（深藏青）
      bgLight: Color(0xFFF1F8F2), cardLight: Color(0xFFDDEBDF), lineLight: Color(0xFFC8DDCB), bgDark: Color(0xFF141C26), cardDark: Color(0xFF1F2A38), lineDark: Color(0xFF31405A), art: 'amane', secondary: Color(0xFFEE6C9A)),
  AppPalette('石墨', Color(0xFF4B4A47), Color(0xFFC2C0B6), bgLight: Color(0xFFF3F3F2), cardLight: Color(0xFFE6E6E4), lineLight: Color(0xFFD5D5D2), bgDark: Color(0xFF121212), cardDark: Color(0xFF1E1E1E), lineDark: Color(0xFF333333)),
  // 放在最后：配色按序号存，插在中间会让已经选了后面配色的人换掉
  AppPalette('遗迹·晴空', Color(0xFFA8452F), Color(0xFFE08A68), // 石柱的赭红；第二强调色是旗子的芥末黄
      bgLight: Color(0xFFF6F0E5), cardLight: Color(0xFFDDEBE6), lineLight: Color(0xFFDCD0BD), bgDark: Color(0xFF13222A), cardDark: Color(0xFF1C313B), lineDark: Color(0xFF2E4752), secondary: Color(0xFFD9A03F), scene: true),
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

/// [pureBlack]：深色时底色用纯黑（AMOLED 屏黑色像素不发光），卡片和边框也压到接近黑。
ThemeData buildAppTheme(Brightness brightness, [AppPalette palette = const AppPalette('陶土', AppColors.terracotta, AppColors.terracottaLight, bgLight: AppColors.cream, cardLight: AppColors.creamDeep, lineLight: AppColors.line, bgDark: AppColors.night, cardDark: AppColors.nightRaised, lineDark: AppColors.lineDark), bool pureBlack = false]) {
  final dark = brightness == Brightness.dark;
  final black = dark && pureBlack;
  final bg = black ? Colors.black : palette.bg(dark);
  final card = black ? const Color(0xFF111111) : palette.card(dark);
  final line = black ? const Color(0xFF262626) : palette.line(dark);
  final raised = dark ? card : Colors.white;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent(dark),
    onPrimary: dark && (palette.name == '石墨' || palette.scene) ? Colors.black : Colors.white,
    secondary: palette.secondary ?? (dark ? AppColors.paperSoft : AppColors.inkSoft),
    onSecondary: dark ? AppColors.night : AppColors.cream,
    error: const Color(0xFFB3261E),
    onError: Colors.white,
    surface: bg,
    onSurface: dark ? AppColors.paper : AppColors.ink,
    onSurfaceVariant: dark ? AppColors.paperSoft : AppColors.inkSoft,
    surfaceContainerLowest: raised,
    surfaceContainerLow: card,
    surfaceContainer: card,
    surfaceContainerHigh: card,
    outline: line,
    outlineVariant: line,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: scheme.surface);
  // 插画主题：标题换文楷、字距拉开一点，圆角收小，像切过的石块
  final serif = palette.scene ? base.textTheme.apply(fontFamily: 'LXGWWenKai', fontFamilyFallback: kSerifFallback) : base.textTheme.apply(fontFamilyFallback: kSerifFallback);
  final spacing = palette.scene ? 1.5 : null;
  final r = palette.scene ? 5.0 : 12.0;

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
      centerTitle: false,
      titleTextStyle: serif.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500, letterSpacing: spacing),
    ),
    cardTheme: CardThemeData(
      color: raised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(palette.scene ? 6 : 16),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
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
      backgroundColor: scheme.surface,
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
    dialogTheme: palette.scene ? DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))) : null,
    bottomSheetTheme: palette.scene ? const BottomSheetThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12)))) : null,
    chipTheme: palette.scene ? ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r))) : null,
    segmentedButtonTheme: palette.scene ? SegmentedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(r))))) : null,
    extensions: [?characterArtOf(palette)],
  );
}
