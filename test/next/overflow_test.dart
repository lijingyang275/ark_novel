import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/stats.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ark_overflow_test');
    Hive.init(tempDir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('阅读时长柱状图：最高的那根柱子不溢出（之前多出 2 像素）', (tester) async {
    final now = DateTime.now();
    // 今天读得最多：最高的柱子在最右边，另外几天高低不一
    // 写盘要在真实的异步里等，测试的假时钟下它永远不完成
    await tester.runAsync(() => Hive.box('session').put('stats:day', {
      ReadingStats.dayKey(now): 3600,
      ReadingStats.dayKey(now.subtract(const Duration(days: 2))): 1200,
      ReadingStats.dayKey(now.subtract(const Duration(days: 6))): 300,
    }));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: StatsPage())));
    // 页面上有转圈的加载动画，pumpAndSettle 会一直等；柱子长高的动画 300 毫秒，往后推一秒就够
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
