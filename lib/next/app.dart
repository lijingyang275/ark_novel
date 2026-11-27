import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_prefs.dart';
import 'cache.dart';
import 'data.dart';
import 'env.dart';
import 'hant.dart';
import 'image_cache.dart';
import 'main.dart' show enterCompactImageCache, exitCompactImageCache;
import 'meta_cache.dart';
import 'motion.dart';
import 'pages/home_shell.dart' show shellLibraryPage;
import 'progress.dart';
import 'read_state.dart';
import 'reader/reader_body.dart' show PagedBody;
import 'reader/reader_page.dart' show clearReaderBookmarkCaches;
import 'router.dart';
import 'security.dart';
import 'settings.dart';
import 'sync_merge.dart';
import 'text.dart';
import 'theme.dart';
import 'volumes.dart';

class NextApp extends ConsumerStatefulWidget {
  const NextApp({super.key});

  static int _activeReaders = 0;

  /// 记录阅读器页面活跃状态（支持多实例引用计数）：用于退后台或内存压力时判断是否可安全卸载繁简词表。
  static void markReaderActive(bool active) {
    if (active) {
      _activeReaders++;
    } else if (_activeReaders > 0) {
      _activeReaders--;
    }
  }

  /// 当前是否存在活跃的阅读器页面。
  static bool get isReaderActive => _activeReaders > 0;

  @override
  ConsumerState<NextApp> createState() => _NextAppState();
}

class _NextAppState extends ConsumerState<NextApp> with WidgetsBindingObserver {
  bool _bgCompact = false;
  (int, bool, bool)? _themeKey;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    if (_bgCompact) {
      _bgCompact = false;
      exitCompactImageCache();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _unloadHantIfIdle() {
    final uiHant = AppPrefs.read(P.uiHant, false);
    if (!uiHant && (!NextApp.isReaderActive || !ref.read(readerPrefsProvider).hant) && Hant.loaded != null) {
      Hant.unload();
    }
  }

  void _scheduleHantUnloadIfUnused() {
    Future.microtask(() {
      if (!mounted) return;
      if (!AppPrefs.read(P.uiHant, false) && !ref.read(readerPrefsProvider).hant) Hant.unload();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (!_bgCompact) {
        _bgCompact = true;
        enterCompactImageCache();
      }
      ref.read(imageStoreProvider).onMemoryPressure();
      ReadingProgress.flush().ignore();
      MetaCache.evictMemory();
      Volumes.evictMemory();
      ReadState.evictMemory();
      SyncMerge.evictMemory();
      ChapterCache.evictMemory();
      Api.evictMemory();
      if (ref.exists(apiProvider)) ref.read(apiProvider).onMemoryPressure();
      _unloadHantIfIdle();
    } else if (state == AppLifecycleState.resumed) {
      if (_bgCompact) {
        _bgCompact = false;
        exitCompactImageCache();
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    ref.read(imageStoreProvider).onMemoryPressure();
    PaintingBinding.instance.imageCache.clear();
    MetaCache.evictMemory();
    Volumes.evictMemory();
    ReadState.evictMemory();
    SyncMerge.evictMemory();
    ChapterCache.evictMemory();
    Api.evictMemory();
    if (ref.exists(apiProvider)) ref.read(apiProvider).onMemoryPressure();
    PagedBody.clearPageCache();
    clearReaderBookmarkCaches();
    _unloadHantIfIdle();
  }

  @override
  Widget build(BuildContext context) {
    final (uiHant, pureBlack) = ref.watch(appPrefsProvider.select((_) => (AppPrefs.read(P.uiHant, false), AppPrefs.read(P.pureBlack, pureBlackDefault))));
    // 用 ref.listen 替代 ref.watch，避免阅读页切繁体时触发 NextApp 整树重建和重造两套 ThemeData
    ref.listen<bool>(readerPrefsProvider.select((p) => p.hant), (_, readerHant) {
      if (!readerHant && !AppPrefs.read(P.uiHant, false) && Hant.loaded != null) {
        _scheduleHantUnloadIfUnused();
      }
    });
    if (!uiHant && Hant.loaded != null && !ref.read(readerPrefsProvider).hant) {
      _scheduleHantUnloadIfUnused();
    }
    final hant = uiHant ? ref.watch(_hantProvider).value : null;
    final router = ref.watch(routerProvider);
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    // 菜单栏、快捷键切到主标签页时，先关掉侧栏里打开的资料库页面，不然它还盖在上面
    void goMain(String route) {
      shellLibraryPage.value = null;
      router.go(route);
    }

    final desktop = !kIsWeb && (isMac || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);
    final paletteIndex = ref.watch(paletteProvider);
    final themeKey = (paletteIndex, pureBlack, desktop);
    if (_themeKey != themeKey || _lightTheme == null || _darkTheme == null) {
      _themeKey = themeKey;
      final palette = appPalettes[paletteIndex];
      _lightTheme = buildAppTheme(Brightness.light, palette);
      _darkTheme = buildAppTheme(Brightness.dark, palette, pureBlack);
    }
    final app = MaterialApp.router(
      title: 'Ark Novel',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ref.watch(themeModeProvider),
      themeAnimationDuration: AppMotion.expressive,
      themeAnimationCurve: AppMotion.curve,
      routerConfig: router,
      scrollBehavior: const _MouseDragBehavior(),
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final overlay = (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(statusBarColor: Colors.transparent);
        Widget w = AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlay,
          child: UiHant(hant: hant, child: AppGuard(child: child ?? const SizedBox.shrink())),
        );
        if (desktop) {
          w = CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              SingleActivator(LogicalKeyboardKey.keyK, meta: isMac, control: !isMac): () => router.push(Routes.search),
              SingleActivator(LogicalKeyboardKey.comma, meta: isMac, control: !isMac): () => goMain(Routes.settings),
            },
            child: w,
          );
        }
        if (isMac) {
          final mq = MediaQuery.of(context);
          final top = math.max(mq.padding.top, 28.0);
          w = MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(top: top),
              viewPadding: mq.viewPadding.copyWith(top: math.max(mq.viewPadding.top, 28.0)),
            ),
            child: w,
          );
        }
        return w;
      },
    );
    if (!isMac) return app;
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Ark Novel',
          menus: [
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about)) const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
            PlatformMenuItem(
              label: '设置…',
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              onSelected: () => goMain(Routes.settings),
            ),
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.hide)) const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit)) const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ],
        ),
        PlatformMenu(
          label: '导航',
          menus: [
            PlatformMenuItem(
              label: '搜索',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
              onSelected: () => router.push(Routes.search),
            ),
            PlatformMenuItem(
              label: '书架',
              shortcut: const SingleActivator(LogicalKeyboardKey.digit1, meta: true),
              onSelected: () => goMain(Routes.bookshelf),
            ),
            PlatformMenuItem(
              label: '发现',
              shortcut: const SingleActivator(LogicalKeyboardKey.digit2, meta: true),
              onSelected: () => goMain(Routes.discover),
            ),
            PlatformMenuItem(
              label: '更新',
              shortcut: const SingleActivator(LogicalKeyboardKey.digit3, meta: true),
              onSelected: () => goMain(Routes.updates),
            ),
            PlatformMenuItem(
              label: '我的',
              shortcut: const SingleActivator(LogicalKeyboardKey.digit4, meta: true),
              onSelected: () => goMain(Routes.profile),
            ),
          ],
        ),
      ],
      child: app,
    );
  }
}

final _hantProvider = FutureProvider.autoDispose((ref) => Hant.load());

/// 桌面端默认不能用鼠标拖动滚动，卷轮播、横向标签这些只能拖的地方就动不了。
class _MouseDragBehavior extends MaterialScrollBehavior {
  const _MouseDragBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}
