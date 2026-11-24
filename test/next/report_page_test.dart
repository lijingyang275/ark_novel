import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/report_page.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ark_report_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('阅读报告能正常排版（之前 stretch 在滚动区域里整页布局失败，只剩背景色）', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ReportPage(aid: '1'))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('阅读时间'), findsOneWidget);
    expect(find.text('已读天数'), findsOneWidget);
  });
}
