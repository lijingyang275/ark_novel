import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

Box get _box => Hive.box('session');

/// 深浅色：跟随系统 / 浅色 / 深色，记在本地。
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.values[(_box.get('themeMode') as int?) ?? 0];

  void set(ThemeMode mode) {
    _box.putAll({'themeMode': mode.index, 'sync:appearanceTs': DateTime.now().millisecondsSinceEpoch});
    state = mode;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// 配色方案编号（theme.dart 的 appPalettes）。
class PaletteController extends Notifier<int> {
  @override
  int build() => (_box.get('palette') as int?) ?? 7;

  void set(int index) {
    _box.putAll({'palette': index, 'sync:appearanceTs': DateTime.now().millisecondsSinceEpoch});
    state = index;
  }
}

final paletteProvider = NotifierProvider<PaletteController, int>(PaletteController.new);

/// 屏幕方向：0 锁竖屏（手机默认）1 自动旋转（平板默认）2 锁横屏，记在本地。
class OrientationController extends Notifier<int> {
  static int get saved => (_box.get('orientation') as int?) ?? _defaultValue;

  static int get _defaultValue {
    final view = PlatformDispatcher.instance.views.first;
    return view.physicalSize.shortestSide / view.devicePixelRatio >= 600 ? 1 : 0;
  }

  @override
  int build() => saved;

  void set(int v) {
    _box.put('orientation', v);
    state = v;
    applyOrientation(v);
  }
}

final orientationProvider = NotifierProvider<OrientationController, int>(OrientationController.new);

/// 启动时和改设置时调用。只对手机、平板有效（iPad 分屏时系统不让 App 锁方向）。
void applyOrientation(int v) => SystemChrome.setPreferredOrientations(switch (v) {
  1 => const [],
  2 => const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  _ => const [DeviceOrientation.portraitUp],
});

/// 阅读器的外观和翻页方式。
class ReaderPrefs {
  const ReaderPrefs({this.fontSize = 18, this.lineHeight = 1.8, this.letterSpacing = 0, this.paragraphSpacing = 0, this.theme = 5, this.mode = 3, this.ttsRate = 0.5, this.margin = 22, this.font = 1, this.ttsPitch = 1.0, this.ttsVoice = '', this.ttsHighlight = true, this.ttsAutoNext = true, this.dual = true, this.dim = 0, this.volumeKeys = true, this.tapZone = 0, this.tapInvert = 0, this.keepScreenOn = true, this.fullscreen = true, this.showStatus = true, this.skipRead = false, this.chapterToast = false, this.warm = 0, this.grayscale = false, this.invert = false, this.customBrightness = false, this.brightness = 0.5, this.volumeInvert = false, this.pageAnim = true, this.prefetch = 2, this.prefetchWifi = false, this.prefetchBook = false, this.hant = false, this.autoScrollSpeed = 60, this.autoTurnSeconds = 8, this.bgTexture = 0, this.bgImageOpacity = 0.35, this.headerLeft = 1, this.headerRight = 0, this.footerLeft = 3, this.footerRight = 4});

  final double fontSize;
  final double lineHeight;

  /// 字间距（-0.5 ~ 4.0 px，0 为默认）
  final double letterSpacing;

  /// 段间距（0 ~ 24 px，0 为紧邻换行）
  final double paragraphSpacing;

  /// 阅读背景：0 纸张 1 护眼 2 夜间 3 跟随应用
  final int theme;

  /// 翻页方式：0 上下滚动 1 左右滑动 2 仿真翻页 3 覆盖翻页
  final int mode;

  /// 字体：0 系统默认 1 衬线 2 自选字体文件
  final int font;

  /// 左右页边距
  final double margin;

  /// 朗读语速 0.1~1.0
  final double ttsRate;

  /// 朗读音调 0.5~2.0
  final double ttsPitch;

  /// 朗读声音（系统语音名），留空用系统默认
  final String ttsVoice;

  /// 朗读时高亮正在读的句子，并跟着翻页
  final bool ttsHighlight;

  /// 读完一章自动读下一章
  final bool ttsAutoNext;

  /// 宽屏（窗口宽度 ≥ 900）时左右翻页模式显示双页
  final bool dual;

  /// 阅读亮度遮罩的不透明度 0~0.7，0 为不遮
  final double dim;

  /// 音量键翻页（只有安卓有用）：下音量键下一页，上音量键上一页
  final bool volumeKeys;

  /// 点击分区：0 默认（翻页模式左右两边翻页，滚动模式点哪里都呼出菜单） 1 L 型 2 Kindle 式 3 边缘式 4 只呼出菜单
  final int tapZone;

  /// 点击反转：0 不反转 1 水平 2 垂直 3 两者
  final int tapInvert;

  /// 阅读时保持屏幕常亮
  final bool keepScreenOn;

  /// 阅读时隐藏状态栏（全屏）
  final bool fullscreen;

  /// 显示页脚（时间、电量、页码 / 进度）
  final bool showStatus;

  /// 翻到下一章时跳过已读的章节
  final bool skipRead;

  /// 切章时提示章节名
  final bool chapterToast;

  /// 暖色滤镜强度 0~0.5，0 为关
  final double warm;
  final bool grayscale;
  final bool invert;

  /// 自定义屏幕亮度（可以比系统亮度更亮）和它的值 0.02~1
  final bool customBrightness;
  final double brightness;

  /// 音量键方向反过来：下音量键上一页
  final bool volumeInvert;

  /// 左右滑动翻页时的动画
  final bool pageAnim;

  /// 往后预加载几章（0 不预加载），以及只在 Wi-Fi 下预加载
  final int prefetch;
  final bool prefetchWifi;

  /// 打开书后在后台把整本的正文缓存下来（不含插图）
  final bool prefetchBook;

  /// 正文以繁体显示（显示时转换，缓存的仍是简体）
  final bool hant;

  /// 自动滚屏速度（20~220 px/s）与自动翻页间隔（3~30 秒/页）
  final double autoScrollSpeed;
  final int autoTurnSeconds;

  /// 内置纸张纹理（0 无纹理、1 宣纸、2 复古纸、3 笔记纸）与自定义背景图浓度（0.05~0.85）
  final int bgTexture;
  final double bgImageOpacity;

  /// 页眉 / 页脚字段（0 留空、1 章节名、2 书名、3 时间与电量、4 页码/进度、5 本卷剩余时间、6 本卷进度）
  final int headerLeft;
  final int headerRight;
  final int footerLeft;
  final int footerRight;

  ReaderPrefs copyWith({double? fontSize, double? lineHeight, double? letterSpacing, double? paragraphSpacing, int? theme, int? mode, double? ttsRate, double? margin, int? font, double? ttsPitch, String? ttsVoice, bool? ttsHighlight, bool? ttsAutoNext, bool? dual, double? dim, bool? volumeKeys, int? tapZone, int? tapInvert, bool? keepScreenOn, bool? fullscreen, bool? showStatus, bool? skipRead, bool? chapterToast, double? warm, bool? grayscale, bool? invert, bool? customBrightness, double? brightness, bool? volumeInvert, bool? pageAnim, int? prefetch, bool? prefetchWifi, bool? prefetchBook, bool? hant, double? autoScrollSpeed, int? autoTurnSeconds, int? bgTexture, double? bgImageOpacity, int? headerLeft, int? headerRight, int? footerLeft, int? footerRight}) => ReaderPrefs(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    theme: theme ?? this.theme,
    mode: mode ?? this.mode,
    ttsRate: ttsRate ?? this.ttsRate,
    margin: margin ?? this.margin,
    font: font ?? this.font,
    ttsPitch: ttsPitch ?? this.ttsPitch,
    ttsVoice: ttsVoice ?? this.ttsVoice,
    ttsHighlight: ttsHighlight ?? this.ttsHighlight,
    ttsAutoNext: ttsAutoNext ?? this.ttsAutoNext,
    dual: dual ?? this.dual,
    dim: dim ?? this.dim,
    volumeKeys: volumeKeys ?? this.volumeKeys,
    tapZone: tapZone ?? this.tapZone,
    tapInvert: tapInvert ?? this.tapInvert,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    fullscreen: fullscreen ?? this.fullscreen,
    showStatus: showStatus ?? this.showStatus,
    skipRead: skipRead ?? this.skipRead,
    chapterToast: chapterToast ?? this.chapterToast,
    warm: warm ?? this.warm,
    grayscale: grayscale ?? this.grayscale,
    invert: invert ?? this.invert,
    customBrightness: customBrightness ?? this.customBrightness,
    brightness: brightness ?? this.brightness,
    volumeInvert: volumeInvert ?? this.volumeInvert,
    pageAnim: pageAnim ?? this.pageAnim,
    prefetch: prefetch ?? this.prefetch,
    prefetchWifi: prefetchWifi ?? this.prefetchWifi,
    prefetchBook: prefetchBook ?? this.prefetchBook,
    hant: hant ?? this.hant,
    autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
    autoTurnSeconds: autoTurnSeconds ?? this.autoTurnSeconds,
    bgTexture: bgTexture ?? this.bgTexture,
    bgImageOpacity: bgImageOpacity ?? this.bgImageOpacity,
    headerLeft: headerLeft ?? this.headerLeft,
    headerRight: headerRight ?? this.headerRight,
    footerLeft: footerLeft ?? this.footerLeft,
    footerRight: footerRight ?? this.footerRight,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderPrefs &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          letterSpacing == other.letterSpacing &&
          paragraphSpacing == other.paragraphSpacing &&
          theme == other.theme &&
          mode == other.mode &&
          ttsRate == other.ttsRate &&
          margin == other.margin &&
          font == other.font &&
          ttsPitch == other.ttsPitch &&
          ttsVoice == other.ttsVoice &&
          ttsHighlight == other.ttsHighlight &&
          ttsAutoNext == other.ttsAutoNext &&
          dual == other.dual &&
          dim == other.dim &&
          volumeKeys == other.volumeKeys &&
          tapZone == other.tapZone &&
          tapInvert == other.tapInvert &&
          keepScreenOn == other.keepScreenOn &&
          fullscreen == other.fullscreen &&
          showStatus == other.showStatus &&
          skipRead == other.skipRead &&
          chapterToast == other.chapterToast &&
          warm == other.warm &&
          grayscale == other.grayscale &&
          invert == other.invert &&
          customBrightness == other.customBrightness &&
          brightness == other.brightness &&
          volumeInvert == other.volumeInvert &&
          pageAnim == other.pageAnim &&
          prefetch == other.prefetch &&
          prefetchWifi == other.prefetchWifi &&
          prefetchBook == other.prefetchBook &&
          hant == other.hant &&
          autoScrollSpeed == other.autoScrollSpeed &&
          autoTurnSeconds == other.autoTurnSeconds &&
          bgTexture == other.bgTexture &&
          bgImageOpacity == other.bgImageOpacity &&
          headerLeft == other.headerLeft &&
          headerRight == other.headerRight &&
          footerLeft == other.footerLeft &&
          footerRight == other.footerRight;

  @override
  int get hashCode => Object.hashAll([
    fontSize, lineHeight, letterSpacing, paragraphSpacing, theme, mode, ttsRate, margin, font, ttsPitch, ttsVoice, ttsHighlight, ttsAutoNext,
    dual, dim, volumeKeys, tapZone, tapInvert, keepScreenOn, fullscreen, showStatus, skipRead, chapterToast,
    warm, grayscale, invert, customBrightness, brightness, volumeInvert, pageAnim, prefetch, prefetchWifi, prefetchBook, hant,
    autoScrollSpeed, autoTurnSeconds, bgTexture, bgImageOpacity, headerLeft, headerRight, footerLeft, footerRight,
  ]);
}

class ReaderPrefsController extends Notifier<ReaderPrefs> {
  late ReaderPrefs _persisted;

  @override
  ReaderPrefs build() {
    final loaded = ReaderPrefs(
      fontSize: (_box.get('r.fontSize') as num?)?.toDouble() ?? 18,
      lineHeight: (_box.get('r.lineHeight') as num?)?.toDouble() ?? 1.8,
      letterSpacing: ((_box.get('r.letterSpacing') as num?)?.toDouble() ?? 0).clamp(-0.5, 4.0),
      paragraphSpacing: ((_box.get('r.paragraphSpacing') as num?)?.toDouble() ?? 0).clamp(0.0, 24.0),
      theme: (_box.get('r.theme') as int?) ?? 5,
      mode: (_box.get('r.mode') as int?) ?? 3,
      ttsRate: (_box.get('r.ttsRate') as num?)?.toDouble() ?? 0.5,
      margin: (_box.get('r.margin') as num?)?.toDouble() ?? 22,
      font: (_box.get('r.font') as int?) ?? 1,
      ttsPitch: (_box.get('r.ttsPitch') as num?)?.toDouble() ?? 1.0,
      ttsVoice: (_box.get('r.ttsVoice') as String?) ?? '',
      ttsHighlight: (_box.get('r.ttsHighlight') as bool?) ?? true,
      ttsAutoNext: (_box.get('r.ttsAutoNext') as bool?) ?? true,
      dual: (_box.get('r.dual') as bool?) ?? true,
      dim: (_box.get('r.dim') as num?)?.toDouble() ?? 0,
      volumeKeys: (_box.get('r.volumeKeys') as bool?) ?? true,
      tapZone: (_box.get('r.tapZone') as int?) ?? 0,
      tapInvert: (_box.get('r.tapInvert') as int?) ?? 0,
      keepScreenOn: (_box.get('r.keepScreenOn') as bool?) ?? true,
      fullscreen: (_box.get('r.fullscreen') as bool?) ?? true,
      showStatus: (_box.get('r.showStatus') as bool?) ?? true,
      skipRead: (_box.get('r.skipRead') as bool?) ?? false,
      chapterToast: (_box.get('r.chapterToast') as bool?) ?? false,
      warm: (_box.get('r.warm') as num?)?.toDouble() ?? 0,
      grayscale: (_box.get('r.grayscale') as bool?) ?? false,
      invert: (_box.get('r.invert') as bool?) ?? false,
      customBrightness: (_box.get('r.customBrightness') as bool?) ?? false,
      brightness: (_box.get('r.brightness') as num?)?.toDouble() ?? 0.5,
      volumeInvert: (_box.get('r.volumeInvert') as bool?) ?? false,
      pageAnim: (_box.get('r.pageAnim') as bool?) ?? true,
      prefetch: (_box.get('r.prefetch') as int?) ?? 2,
      prefetchWifi: (_box.get('r.prefetchWifi') as bool?) ?? false,
      prefetchBook: (_box.get('r.prefetchBook') as bool?) ?? false,
      hant: (_box.get('r.hant') as bool?) ?? false,
      autoScrollSpeed: ((_box.get('r.autoScrollSpeed') as num?)?.toDouble() ?? 60).clamp(20, 220),
      autoTurnSeconds: ((_box.get('r.autoTurnSeconds') as int?) ?? 8).clamp(3, 30),
      bgTexture: ((_box.get('r.bgTexture') as int?) ?? 0).clamp(0, 3),
      bgImageOpacity: ((_box.get('r.bgImageOpacity') as num?)?.toDouble() ?? 0.35).clamp(0.05, 0.85),
      headerLeft: ((_box.get('r.headerLeft') as int?) ?? 1).clamp(0, 6),
      headerRight: ((_box.get('r.headerRight') as int?) ?? 0).clamp(0, 6),
      footerLeft: ((_box.get('r.footerLeft') as int?) ?? 3).clamp(0, 6),
      footerRight: ((_box.get('r.footerRight') as int?) ?? 4).clamp(0, 6),
    );
    _persisted = loaded;
    return loaded;
  }

  static Map<String, Object> _diff(ReaderPrefs prev, ReaderPrefs next) {
    final diff = <String, Object>{};
    if (prev.fontSize != next.fontSize) diff['r.fontSize'] = next.fontSize;
    if (prev.lineHeight != next.lineHeight) diff['r.lineHeight'] = next.lineHeight;
    if (prev.letterSpacing != next.letterSpacing) diff['r.letterSpacing'] = next.letterSpacing;
    if (prev.paragraphSpacing != next.paragraphSpacing) diff['r.paragraphSpacing'] = next.paragraphSpacing;
    if (prev.theme != next.theme) diff['r.theme'] = next.theme;
    if (prev.mode != next.mode) diff['r.mode'] = next.mode;
    if (prev.ttsRate != next.ttsRate) diff['r.ttsRate'] = next.ttsRate;
    if (prev.margin != next.margin) diff['r.margin'] = next.margin;
    if (prev.font != next.font) diff['r.font'] = next.font;
    if (prev.ttsPitch != next.ttsPitch) diff['r.ttsPitch'] = next.ttsPitch;
    if (prev.ttsVoice != next.ttsVoice) diff['r.ttsVoice'] = next.ttsVoice;
    if (prev.ttsHighlight != next.ttsHighlight) diff['r.ttsHighlight'] = next.ttsHighlight;
    if (prev.ttsAutoNext != next.ttsAutoNext) diff['r.ttsAutoNext'] = next.ttsAutoNext;
    if (prev.dual != next.dual) diff['r.dual'] = next.dual;
    if (prev.dim != next.dim) diff['r.dim'] = next.dim;
    if (prev.volumeKeys != next.volumeKeys) diff['r.volumeKeys'] = next.volumeKeys;
    if (prev.tapZone != next.tapZone) diff['r.tapZone'] = next.tapZone;
    if (prev.tapInvert != next.tapInvert) diff['r.tapInvert'] = next.tapInvert;
    if (prev.keepScreenOn != next.keepScreenOn) diff['r.keepScreenOn'] = next.keepScreenOn;
    if (prev.fullscreen != next.fullscreen) diff['r.fullscreen'] = next.fullscreen;
    if (prev.showStatus != next.showStatus) diff['r.showStatus'] = next.showStatus;
    if (prev.skipRead != next.skipRead) diff['r.skipRead'] = next.skipRead;
    if (prev.chapterToast != next.chapterToast) diff['r.chapterToast'] = next.chapterToast;
    if (prev.warm != next.warm) diff['r.warm'] = next.warm;
    if (prev.grayscale != next.grayscale) diff['r.grayscale'] = next.grayscale;
    if (prev.invert != next.invert) diff['r.invert'] = next.invert;
    if (prev.customBrightness != next.customBrightness) diff['r.customBrightness'] = next.customBrightness;
    if (prev.brightness != next.brightness) diff['r.brightness'] = next.brightness;
    if (prev.volumeInvert != next.volumeInvert) diff['r.volumeInvert'] = next.volumeInvert;
    if (prev.pageAnim != next.pageAnim) diff['r.pageAnim'] = next.pageAnim;
    if (prev.prefetch != next.prefetch) diff['r.prefetch'] = next.prefetch;
    if (prev.prefetchWifi != next.prefetchWifi) diff['r.prefetchWifi'] = next.prefetchWifi;
    if (prev.prefetchBook != next.prefetchBook) diff['r.prefetchBook'] = next.prefetchBook;
    if (prev.hant != next.hant) diff['r.hant'] = next.hant;
    if (prev.autoScrollSpeed != next.autoScrollSpeed) diff['r.autoScrollSpeed'] = next.autoScrollSpeed;
    if (prev.autoTurnSeconds != next.autoTurnSeconds) diff['r.autoTurnSeconds'] = next.autoTurnSeconds;
    if (prev.bgTexture != next.bgTexture) diff['r.bgTexture'] = next.bgTexture;
    if (prev.bgImageOpacity != next.bgImageOpacity) diff['r.bgImageOpacity'] = next.bgImageOpacity;
    if (prev.headerLeft != next.headerLeft) diff['r.headerLeft'] = next.headerLeft;
    if (prev.headerRight != next.headerRight) diff['r.headerRight'] = next.headerRight;
    if (prev.footerLeft != next.footerLeft) diff['r.footerLeft'] = next.footerLeft;
    if (prev.footerRight != next.footerRight) diff['r.footerRight'] = next.footerRight;
    return diff;
  }

  /// 仅更新内存状态用于滑块实时预览，不触发 Hive 写盘。
  void preview(ReaderPrefs next) {
    if (state != next) state = next;
  }

  /// 差分写入：仅将真正变化的字段与 `sync:readerTs` 写入 Hive；[persist] 为 false 时等同于 [preview]。
  void update(ReaderPrefs next, {bool persist = true}) {
    if (!persist) {
      preview(next);
      return;
    }
    final diff = _diff(_persisted, next);
    if (diff.isNotEmpty) {
      diff['sync:readerTs'] = DateTime.now().millisecondsSinceEpoch;
      _box.putAll(diff);
      _persisted = next;
    }
    if (state != next) state = next;
  }

  /// 立即提交 [next] 并差分落盘。
  void commit(ReaderPrefs next) => update(next, persist: true);

  /// 将当前内存预览态差分落盘（若与上次落盘一致则不写盘）。
  void flush() => update(state, persist: true);
}

final readerPrefsProvider = NotifierProvider<ReaderPrefsController, ReaderPrefs>(ReaderPrefsController.new);
