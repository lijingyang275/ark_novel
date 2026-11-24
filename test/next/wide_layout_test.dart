import 'dart:io';

import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/bookmarks_page.dart';
import 'package:ark_novel/next/pages/library_pages.dart';
import 'package:ark_novel/next/pages/login_page.dart';
import 'package:ark_novel/next/pages/rules_page.dart';
import 'package:ark_novel/next/pages/settings_page.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/pages/storage_page.dart';
import 'package:ark_novel/next/pages/sync_page.dart';
import 'package:ark_novel/next/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 桌面窗口的最小、常见、超宽三种尺寸下，不用联网的页面都不能溢出。
void main() {
  late SessionStore store;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('ark_wide_test');
    final dir = tempDir.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir);
    store = await SessionStore.open();
    await ChapterCache.open();
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const pages = <String, Widget>{
    '书签': BookmarksPage(),
    '历史': HistoryPage(),
    '缓存': CachePage(),
    '登录': LoginPage(),
    '替换规则': RulesPage(),
    '设置': SettingsPage(),
    '统计': StatsPage(),
    '存储': StoragePage(),
    '同步': SyncPage(),
  };

  for (final size in const [Size(480, 600), Size(1280, 800), Size(2560, 1300)]) {
    for (final MapEntry(key: name, value: page) in pages.entries) {
      testWidgets('$name ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(overrides: [sessionStoreProvider.overrideWithValue(store)], child: MaterialApp(home: page)));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
