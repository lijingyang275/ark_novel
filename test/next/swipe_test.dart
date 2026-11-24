import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/swipe.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ark_swipe_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  tearDownAll(() async {
    // testWidgets 内触发的 Hive 写入落在 fake-async zone，Hive.close() 可能阻塞；直接清理临时目录即可
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Widget row(String cid) => ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ChapterSwipe(aid: '1', book: '书', cid: cid, title: '第一章', child: const ListTile(title: Text('第一章'))),
          ],
        ),
      ),
    ),
  );

  testWidgets('右滑过线松手标为已读，行弹回原位', (tester) async {
    await tester.pumpWidget(row('a'));
    await tester.drag(find.text('第一章'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(ReadState.isRead('1', 'a'), isTrue);
    expect(tester.getTopLeft(find.byType(ListTile)).dx, 0);
  });

  testWidgets('没拖过触发线不执行', (tester) async {
    await tester.pumpWidget(row('b'));
    await tester.drag(find.text('第一章'), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(ReadState.isRead('1', 'b'), isFalse);
  });

  testWidgets('拖开时显示动作，过线后橡皮筋最多拖到半行', (tester) async {
    await tester.pumpWidget(row('c'));
    final gesture = await tester.startGesture(tester.getCenter(find.text('第一章')));
    await gesture.moveBy(const Offset(20, 0)); // 越过拖动判定
    await gesture.moveBy(const Offset(700, 0));
    await tester.pump();
    expect(find.byIcon(Icons.done_all), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ListTile)).dx, lessThanOrEqualTo(800 * 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.done_all), findsNothing);
  });

  testWidgets('左滑过线加书签', (tester) async {
    await tester.pumpWidget(row('d'));
    await tester.drag(find.text('第一章'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(Bookmarks.has('1', 'd', 0), isTrue);
  });
}
