import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_prefs.dart';
import 'hant.dart';
import 'router.dart';
import 'security.dart';
import 'settings.dart';
import 'text.dart';
import 'theme.dart';

class NextApp extends ConsumerWidget {
  const NextApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appPrefsProvider);
    final hant = AppPrefs.read(P.uiHant, false) ? ref.watch(_hantProvider).value : null;
    return MaterialApp.router(
      title: 'Ark Novel',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, appPalettes[ref.watch(paletteProvider)]),
      darkTheme: buildAppTheme(Brightness.dark, appPalettes[ref.watch(paletteProvider)], AppPrefs.read(P.pureBlack, true)),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      scrollBehavior: const _MouseDragBehavior(),
      builder: (context, child) {
        Widget w = UiHant(hant: hant, child: AppGuard(child: child ?? const SizedBox.shrink()));
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
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
  }
}

final _hantProvider = FutureProvider((ref) => Hant.load());

/// 桌面端默认不能用鼠标拖动滚动，卷轮播、横向标签这些只能拖的地方就动不了。
class _MouseDragBehavior extends MaterialScrollBehavior {
  const _MouseDragBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}
