import 'dart:io';

import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/pages/storage_page.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/x_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _Images implements ImageStore {
  bool measured = false;

  @override
  Future<int> diskBytes() async {
    measured = true;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ark_storage_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> addBook(String aid, int chapters) async {
    for (var i = 0; i < chapters; i++) {
      await ChapterCache.put(aid, '$i', Content(text: '缓存正文', images: []));
    }
    await ChapterCache.setMeta(aid, '测试书 $aid', chapters, '', '0');
  }

  Future<void> settleSizes(WidgetTester tester, _Images images) async {
    final watch = Stopwatch()..start();
    while (!images.measured && watch.elapsed < const Duration(seconds: 5)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(images.measured, isTrue, reason: '占用测量应完成');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester, _Images images) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [imageStoreProvider.overrideWithValue(images)],
        child: const MaterialApp(home: StoragePage()),
      ),
    );
    await settleSizes(tester, images);
  }

  Future<void> confirm(WidgetTester tester, VoidCallback callback, String title, _Images images) async {
    images.measured = false;
    late Future<void> operation;
    // 执行实际按钮回调并保留 Future，让 Hive IO 在真实异步区完成，而不是卡在 fake async 中。
    await tester.runAsync(() async {
      operation = (callback as Future<void> Function())();
    });
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => operation);
    expect(tester.takeException(), isNull);
    await settleSizes(tester, images);
  }

  IconButton deleteButton(WidgetTester tester, String aid) => tester.widget<IconButton>(
    find.descendant(
      of: find.byWidgetPredicate((w) => w is XTile && w.title == '测试书 $aid'),
      matching: find.byType(IconButton),
    ),
  );

  testWidgets('存储空间删除单本后立即移除条目，其他书保留，删完最后一本隐藏章节缓存组', (tester) async {
    await tester.runAsync(() async {
      await addBook('20', 1);
      await addBook('21', 1);
    });
    final images = _Images();
    await mount(tester, images);
    expect(find.text('测试书 20'), findsOneWidget);
    expect(find.text('测试书 21'), findsOneWidget);

    await confirm(tester, deleteButton(tester, '20').onPressed!, '删除这本书的缓存？', images);
    expect(ChapterCache.count('20'), 0);
    expect(ChapterCache.has('20', '0'), isFalse);
    expect(find.text('测试书 20'), findsNothing);
    expect(find.text('测试书 21'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);

    await confirm(tester, deleteButton(tester, '21').onPressed!, '删除这本书的缓存？', images);
    expect(find.text('测试书 21'), findsNothing);
    expect(find.text('章节缓存'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('存储空间清除已读章节后立即更新章数和条目，不删除未读章节', (tester) async {
    await tester.runAsync(() async {
      await addBook('22', 1);
      await addBook('23', 2);
      await ReadState.setRead('22', ['0'], true);
      await ReadState.setRead('23', ['0'], true);
    });
    final images = _Images();
    await mount(tester, images);
    final button = tester.widget<TextButton>(find.widgetWithText(TextButton, '清除已读章节'));
    await confirm(tester, button.onPressed!, '清除已读章节？', images);

    expect(find.text('测试书 22'), findsNothing);
    expect(find.text('测试书 23'), findsOneWidget);
    final row = tester.widget<XTile>(find.byWidgetPredicate((w) => w is XTile && w.title == '测试书 23'));
    expect(row.subtitle, startsWith('1 章 · '));
    expect(ChapterCache.has('23', '0'), isFalse);
    expect(ChapterCache.has('23', '1'), isTrue);
    expect(find.text('已清除 2 章'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
