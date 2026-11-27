import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/pages/library_pages.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/widgets.dart';

class _FakeApi implements Api {
  _FakeApi(this.handler, {this.cancellableHandler});
  final Future<Content> Function(String aid, String cid) handler;
  final Future<Content> Function(String aid, String cid, CancelToken? cancelToken)? cancellableHandler;

  @override
  Future<Content> chapter(String aid, String cid) => handler(aid, cid);

  @override
  Future<Content> fetchChapter(String aid, String cid, {CancelToken? cancelToken}) =>
      cancellableHandler != null ? cancellableHandler!(aid, cid, cancelToken) : handler(aid, cid);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImages implements ImageStore {
  int inflight = 0;
  int maxConcurrent = 0;
  final loaded = <String>[];

  @override
  Future<Uint8List> load(String rawUrl) async {
    inflight++;
    if (inflight > maxConcurrent) maxConcurrent = inflight;
    loaded.add(rawUrl);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    inflight--;
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('ark_chapter_test');
    Hive.init(tmp.path);
    await Hive.openBox('session');
    // 旧格式的原文：打开后照样能读，压一遍之后变成 gzip
    final old = await Hive.openLazyBox('chapters');
    await old.put('9:1', {'t': '旧的正文', 'i': <String>[]});
    final index = await Hive.openBox('chapter_index');
    await index.putAll({'migrated': true, '9:1': 4, 'pt|https://www.wenku8.net/a': 1});
    await ChapterCache.open();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
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

  test('DownloadController 多书串行排队下载、章节插图并发加载、错误走 friendlyError', () async {
    final events = <String>[];
    final images = _FakeImages();
    final api = _FakeApi((aid, cid) async {
      events.add('start:$aid:$cid');
      if (aid == 'errBook') throw const Wenku8HttpException(429);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      events.add('end:$aid:$cid');
      return Content(text: '正文$aid$cid', images: aid == 'bookA' ? ['u1', 'u2', 'u3', 'u4'] : const []);
    });
    final c = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        imageStoreProvider.overrideWithValue(images),
      ],
    );
    addTearDown(c.dispose);

    final ctrl = c.read(downloadProvider.notifier);
    await Future.wait([
      ctrl.start('bookA', 'A', [CatChapter(title: '1', cid: 'c1')]),
      ctrl.start('bookB', 'B', [CatChapter(title: '1', cid: 'c1')]),
      ctrl.start('errBook', 'E', [CatChapter(title: '1', cid: 'c1')]),
    ]);

    // 严格串行：bookA 结束后才开始 bookB，bookB 结束后才开始 errBook
    expect(events, ['start:bookA:c1', 'end:bookA:c1', 'start:bookB:c1', 'end:bookB:c1', 'start:errBook:c1']);
    // 章节内插图按小并发（3 并发）批量加载
    expect(images.loaded, ['u1', 'u2', 'u3', 'u4']);
    expect(images.maxConcurrent, 3);
    // 错误文案通过 friendlyError 转换
    expect(c.read(downloadProvider)['errBook']?.error, '请求太频繁了（HTTP 429），请等一会儿再试');
  });

  test('图片魔数校验拒绝无效字节，识别 JPEG/PNG/GIF/WebP', () {
    expect(isValidImageBytes([0xFF, 0xD8, 0xFF, 0xE0]), isTrue); // JPEG
    expect(isValidImageBytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), isTrue); // PNG
    expect(isValidImageBytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), isTrue); // GIF89a
    expect(isValidImageBytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]), isTrue); // WebP
    expect(isValidImageBytes('{"error":"blocked"}'.codeUnits), isFalse);
    expect(isValidImageBytes([0x00, 0x01, 0x02]), isFalse);
  });

  test('ImageStore 按 URL 粒度超分通知器支持局部刷新、全局模式切换通知与自动释放', () {
    final c = ProviderContainer();
    final store = c.read(imageStoreProvider);
    final a = store.srNotifierFor('https://img.example/a.jpg#crop=0,0,1,1');
    final b = store.srNotifierFor('https://img.example/b.jpg');
    expect(identical(a, store.srNotifierFor('http://img.example/a.jpg')), isTrue);
    expect(a.value, 0);
    expect(b.value, 0);

    // 全局模式切换（notifySrModeChanged）同步刷新所有已订阅 URL
    store.notifySrModeChanged();
    expect(a.value, 1);
    expect(b.value, 1);

    // Provider 销毁时触发 store.dispose 不抛错
    c.dispose();
  });

  test('ChapterCache 异步刷新 totalBytes、O(1) metaOf、putBatch 批量写入与 pt| 事件过滤', () async {
    await ChapterCache.putBatch('batchBook', {
      'c1': (length: 5, images: const <String>[], gzipped: null, text: '第一章正文'),
      'c2': (length: 5, images: const <String>[], gzipped: null, text: '第二章正文'),
    });
    expect(ChapterCache.count('batchBook'), 2);
    expect((await ChapterCache.get('batchBook', 'c1'))?.text, '第一章正文');
    expect((await ChapterCache.get('batchBook', 'c2'))?.text, '第二章正文');

    await ChapterCache.setMeta('batchBook', '批量测试书', 2, 'https://img.example/b.jpg', 'c1');
    expect(ChapterCache.metaOf('batchBook'), ('批量测试书', 2, 'https://img.example/b.jpg', 'c1'));
    expect(ChapterCache.metaOf('not_exists'), isNull);

    final refreshed = await ChapterCache.refreshTotalBytes();
    expect(refreshed, greaterThan(0));
    expect(ChapterCache.totalBytes(), refreshed);
    expect(ChapterCache.bytesOf('batchBook'), greaterThan(0));

    // chapterCacheChangesProvider 过滤掉 pt| 网页备份时间戳事件
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final events = <Object?>[];
    final sub = c.listen(chapterCacheChangesProvider, (_, next) {
      next.whenData((e) => events.add(e.key));
    });
    await PageStore.put('https://www.wenku8.net/book/filter_test.htm', '<html>ok</html>');
    await ChapterCache.put('batchBook', 'c3', Content(text: '第三章', images: const []));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(events, isNot(contains('pt|https://www.wenku8.net/book/filter_test.htm')));
    expect(events, contains('batchBook:c3'));
    sub.close();
  });

  test('DownloadController.cancel 立即触发在途请求的 CancelToken', () async {
    final started = Completer<void>();
    var cancelled = false;
    final api = _FakeApi(
      (_, _) async => Content(text: '', images: const []),
      cancellableHandler: (aid, cid, cancelToken) async {
        started.complete();
        await cancelToken!.whenCancel;
        cancelled = true;
        throw cancelToken.cancelError!;
      },
    );
    final c = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        imageStoreProvider.overrideWithValue(_FakeImages()),
      ],
    );
    addTearDown(c.dispose);

    final ctrl = c.read(downloadProvider.notifier);
    final running = ctrl.start('cancelBook', 'Cancel', [CatChapter(title: '1', cid: 'c1')]);
    await started.future;
    ctrl.cancel('cancelBook');
    await running;
    expect(cancelled, isTrue);
    expect(c.read(downloadProvider)['cancelBook']?.running, isFalse);
    expect(c.read(downloadProvider)['cancelBook']?.error, isNull);
  });
}
