import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/library_pages.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/widgets.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_chapter_test').path);
    await Hive.openBox('session');
    // 旧格式的原文：打开后照样能读，压一遍之后变成 gzip
    final old = await Hive.openLazyBox('chapters');
    await old.put('9:1', {'t': '旧的正文', 'i': <String>[]});
    final index = await Hive.openBox('chapter_index');
    await index.putAll({'migrated': true, '9:1': 4, 'pt|https://www.wenku8.net/a': 1});
    await ChapterCache.open();
  });

  test('压缩存储：新旧格式都能读，旧数据压一遍后内容不变', () async {
    final text = '轻小说正文' * 2000;
    await ChapterCache.put('1', 'a', Content(text: text, images: ['img1']));
    final raw = await Hive.lazyBox('chapters').get('1:a') as Map;
    expect(raw['z'], isNotNull);
    expect((raw['z'] as List).length, lessThan(text.length));
    expect((await ChapterCache.get('1', 'a'))!.text, text);

    expect((await ChapterCache.get('9', '1'))!.text, '旧的正文');
    await ChapterCache.compressOld();
    expect((await Hive.lazyBox('chapters').get('9:1') as Map)['t'], isNull);
    expect((await ChapterCache.get('9', '1'))!.text, '旧的正文');
  });

  test('章数：存、覆盖、删除后都对；网页备份的时间戳不算章节', () async {
    expect(ChapterCache.count('9'), 1);
    expect(ChapterCache.count('pt|https'), 0);
    await ChapterCache.put('2', 'a', Content(text: 'x', images: []));
    await ChapterCache.put('2', 'b', Content(text: 'y', images: []));
    await ChapterCache.put('2', 'b', Content(text: 'yy', images: []));
    expect(ChapterCache.count('2'), 2);
    await ChapterCache.removeChapters('2', ['a', 'zzz']);
    expect(ChapterCache.count('2'), 1);
    await ChapterCache.remove('2');
    expect(ChapterCache.count('2'), 0);
  });

  test('清除已读章节只删读过的；离线插图删书时一起清掉', () async {
    for (final c in ['a', 'b', 'c']) {
      await ChapterCache.put('3', c, Content(text: c, images: []));
    }
    await ReadState.setRead('3', ['a', 'c'], true);
    expect(await ChapterCache.clearRead(), 2);
    expect(ChapterCache.has('3', 'b'), isTrue);
    expect(ChapterCache.count('3'), 1);

    await ChapterCache.addOfflineImages('3', ['u1', 'u2']);
    expect(ChapterCache.offlineImages(), containsAll(['u1', 'u2']));
    await ChapterCache.remove('3');
    expect(ChapterCache.offlineImages(), isNot(contains('u1')));
  });

  test('已读集合：同一份数据复用，写入后跟着变；返回的是副本', () async {
    await ReadState.setRead('4', ['a'], true);
    expect(ReadState.readCount('4'), 1);
    ReadState.read('4').add('zzz');
    expect(ReadState.isRead('4', 'zzz'), isFalse);
    await Hive.box('session').put('read:4', ['a', 'b']); // 同步、导入直接写 Box
    expect(ReadState.readCount('4'), 2);
  });

  test('取正文期间删了缓存：晚到的结果不写回去', () async {
    // 整本删除
    final t1 = ChapterCache.ticket('5', 'a');
    await ChapterCache.remove('5');
    expect(await ChapterCache.put('5', 'a', Content(text: '晚到', images: []), ticket: t1), isFalse);
    expect(ChapterCache.has('5', 'a'), isFalse);

    // 只删一章：别的章照常写
    await ChapterCache.put('5', 'b', Content(text: 'b', images: []));
    final tb = ChapterCache.ticket('5', 'b'), tc = ChapterCache.ticket('5', 'c');
    await ChapterCache.removeChapters('5', ['b']);
    expect(await ChapterCache.put('5', 'b', Content(text: 'b', images: []), ticket: tb), isFalse);
    expect(await ChapterCache.put('5', 'c', Content(text: 'c', images: []), ticket: tc), isTrue);
    expect(ChapterCache.count('5'), 1);

    // 删除之后新取的凭证照常能写
    expect(await ChapterCache.put('5', 'b', Content(text: 'b', images: []), ticket: ChapterCache.ticket('5', 'b')), isTrue);
  });

  test('存坏了解压不了的章节当作没缓存，不会一直读失败', () async {
    await Hive.lazyBox('chapters').put('5:x', {'z': [1, 2, 3], 'i': <String>[]});
    expect(await ChapterCache.get('5', 'x'), isNull);
  });

  testWidgets('离线缓存列表随缓存删除立即更新，不依赖下载任务或重新进入页面', (tester) async {
    await tester.runAsync(() async {
      for (final aid in ['10', '11']) {
        await ChapterCache.put(aid, 'a', Content(text: '缓存正文', images: []));
        await ChapterCache.setMeta(aid, '测试书 $aid', 1, 'https://example.invalid/cover.jpg', 'a');
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithBuild((ref, notifier) => const SessionLoggedOut()),
          imageBytesProvider.overrideWith((ref, url) => throw StateError('本测试不加载封面')),
        ],
        child: const MaterialApp(home: CachePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试书 10'), findsOneWidget);
    expect(find.text('测试书 11'), findsOneWidget);

    await tester.runAsync(() => ChapterCache.remove('10'));
    await tester.pumpAndSettle();
    expect(find.text('测试书 10'), findsNothing);
    expect(find.text('测试书 11'), findsOneWidget);

    await tester.runAsync(() => ChapterCache.remove('11'));
    await tester.pumpAndSettle();
    expect(find.text('测试书 11'), findsNothing);
    expect(find.text('还没有缓存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
