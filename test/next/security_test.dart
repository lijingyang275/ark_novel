import 'dart:async';
import 'dart:io';

import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/incognito.dart';
import 'package:ark_novel/next/security.dart';
import 'package:ark_novel/next/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory dir;
  final secureCalls = <bool>[];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = Directory.systemTemp.createTempSync('ark_security_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ark/secure'), (call) async {
      if (call.method == 'setSecure') {
        secureCalls.add((call.arguments as Map)['secure'] as bool);
      }
      return null;
    });
  });

  setUp(() async {
    await Hive.box('session').clear();
    secureCalls.clear();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ark/secure'), null);
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Widget wrap(Widget child, {ProviderContainer? container}) {
    final app = MaterialApp(theme: buildAppTheme(Brightness.light), home: child);
    return container == null ? ProviderScope(child: app) : UncontrolledProviderScope(container: container, child: app);
  }

  Future<void> writePref(WidgetTester tester, String key, Object? value) => tester.runAsync(() => AppPrefs.write(key, value));

  testWidgets('未开启应用锁：冷启动直接放行且子页面可交互', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    var authCalls = 0;
    var tapped = 0;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => true,
          onAuthenticate: (_) async {
            authCalls++;
            return true;
          },
          child: Scaffold(
            body: TextButton(onPressed: () => tapped++, child: const Text('正文按钮')),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Ark Novel 已锁定'), findsNothing);
    expect(authCalls, 0);
    await tester.tap(find.text('正文按钮'));
    expect(tapped, 1);
  });

  testWidgets('开启应用锁：冷启动锁定，验证失败保持锁定，点解锁成功后放行', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    await writePref(tester, P.lock, true);
    var allow = false;
    var authCalls = 0;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => true,
          onAuthenticate: (_) async {
            authCalls++;
            return allow;
          },
          child: const Scaffold(body: Text('已解锁内容')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 首帧自动触发一次验证，失败后仍保持锁定
    expect(authCalls, 1);
    expect(find.text('Ark Novel 已锁定'), findsOneWidget);

    // 允许通过后点击「解锁」按钮
    allow = true;
    await tester.tap(find.text('解锁'));
    await tester.pump();
    await tester.pump();

    expect(authCalls, 2);
    expect(find.text('Ark Novel 已锁定'), findsNothing);
  });

  testWidgets('设备已关闭系统锁屏时自动放行，避免永久锁死', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    await writePref(tester, P.lock, true);
    var authCalls = 0;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => false,
          onAuthenticate: (_) async {
            authCalls++;
            return false;
          },
          child: const Scaffold(body: Text('正文')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(authCalls, 0);
    expect(find.text('Ark Novel 已锁定'), findsNothing);
  });

  testWidgets('后台切换：lockAfter=0 立即锁定，恢复时保持锁定直至验证通过', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    await writePref(tester, P.lock, true);
    await writePref(tester, P.lockAfter, 0);
    var authCalls = 0;
    Completer<bool>? secondAuth;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => true,
          onAuthenticate: (_) async {
            authCalls++;
            if (authCalls == 1) return true;
            secondAuth = Completer<bool>();
            return secondAuth!.future;
          },
          child: const Scaffold(body: Text('正文')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(authCalls, 1);
    expect(find.text('Ark Novel 已锁定'), findsNothing);

    // 切到后台并回到前台：立即处于锁定状态并触发二次验证
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Ark Novel 已锁定'), findsOneWidget);
    expect(authCalls, 2);

    // 二次验证通过后解锁
    secondAuth!.complete(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Ark Novel 已锁定'), findsNothing);
  });

  testWidgets('后台超时：lockAfter=5 时短离不锁，超 5 分钟后恢复锁定并验证', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    await writePref(tester, P.lock, true);
    await writePref(tester, P.lockAfter, 5);
    var clock = DateTime(2026, 1, 1, 12, 0);
    var authCalls = 0;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          now: () => clock,
          canAuth: () async => true,
          onAuthenticate: (_) async {
            authCalls++;
            return true;
          },
          child: const Scaffold(body: Text('正文')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(authCalls, 1);

    // 离开 2 分钟：不锁、不弹验证
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('Ark Novel 已锁定'), findsNothing);
    clock = clock.add(const Duration(minutes: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(authCalls, 1);
    expect(find.text('Ark Novel 已锁定'), findsNothing);

    // 离开 5 分钟：恢复时锁定并验证
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    clock = clock.add(const Duration(minutes: 5));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(authCalls, 2);
    expect(find.text('Ark Novel 已锁定'), findsNothing);
  });

  testWidgets('验证弹窗期间的生命周期抖动不触发重入死循环', variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
    await writePref(tester, P.lock, true);
    await writePref(tester, P.lockAfter, 0);
    final pending = Completer<bool>();
    var authCalls = 0;

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => true,
          onAuthenticate: (_) {
            authCalls++;
            return pending.future;
          },
          child: const Scaffold(body: Text('正文')),
        ),
      ),
    );
    await tester.pump();
    expect(authCalls, 1);

    // 系统生物识别弹窗导致 inactive -> resumed 抖动
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(authCalls, 1);

    pending.complete(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Ark Novel 已锁定'), findsNothing);
  });

  testWidgets('防截屏策略：跟随 P.secure 与无痕模式同步并去重', variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Future<void> setPref(String key, Object? value) => tester.runAsync(() async {
      container.read(appPrefsProvider.notifier).set(key, value);
      await Hive.box('session').flush();
    });

    await tester.pumpWidget(wrap(const AppGuard(child: Scaffold(body: Text('正文'))), container: container));
    await tester.pump();
    expect(secureCalls, [false]);

    // 切到「始终开启」
    await setPref(P.secure, 1);
    await tester.pump();
    expect(secureCalls, [false, true]);

    // 无关偏好变动不重复调用通道
    await setPref(P.resumeBar, false);
    await tester.pump();
    expect(secureCalls, [false, true]);

    // 切到「仅无痕时」：当前未开无痕 -> 关闭防截屏
    await setPref(P.secure, 2);
    await tester.pump();
    expect(secureCalls, [false, true, false]);

    // 打开无痕 -> 开启防截屏；关闭无痕 -> 关闭防截屏
    await tester.runAsync(() async {
      container.read(incognitoProvider.notifier).set(true);
      await Hive.box('session').flush();
    });
    await tester.pump();
    expect(secureCalls, [false, true, false, true]);

    await tester.runAsync(() async {
      container.read(incognitoProvider.notifier).set(false);
      await Hive.box('session').flush();
    });
    await tester.pump();
    expect(secureCalls, [false, true, false, true, false]);
  });

  testWidgets('宽屏锁屏页按钮居中且宽度受限，不贴边拉伸', variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
    await writePref(tester, P.lock, true);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        AppGuard(
          canAuth: () async => true,
          onAuthenticate: (_) async => false,
          child: const Scaffold(body: Text('正文')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final rect = tester.getRect(find.byType(FilledButton));
    expect(rect.width, lessThanOrEqualTo(280));
    expect(rect.width, greaterThanOrEqualTo(200));
    expect(rect.center.dx, closeTo(640, 1));
  });
}
