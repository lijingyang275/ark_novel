import 'dart:async';
import 'dart:io';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/updates.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _FakeApi extends Api {
  _FakeApi(this._handler)
    : super(
        Wenku8Client(baseUrl: () => 'https://www.wenku8.net', charset: () => CharsetType.gbk, headers: const {}),
        Wenku8Urls('https://www.wenku8.net', CharsetType.gbk),
        'https://www.wenku8.net',
        'guest',
      );

  final Future<List<CatVolume>> Function(String aid, CancelToken? cancelToken) _handler;
  final List<String> requested = [];

  @override
  Future<List<CatVolume>> catalogue(String aid, {bool fresh = false, CancelToken? cancelToken}) {
    requested.add(aid);
    return _handler(aid, cancelToken);
  }
}

List<CatVolume> _cat(int count) => [
  CatVolume(
    title: '第一卷',
    chapters: [for (var i = 1; i <= count; i++) CatChapter(title: '第$i章', cid: '$i')],
  ),
];

Future<void> _seedLibrary(List<({String aid, String title, bool done, List<String> cats})> books) async {
  final box = Hive.box('session');
  final map = <String, Map>{};
  for (final b in books) {
    map[b.aid] = {
      'aid': b.aid,
      'title': b.title,
      'img': 'https://img.wenku8.com/${b.aid}.jpg',
      'cats': b.cats,
      'done': b.done,
    };
  }
  await box.put('lib:books', map);
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ark_updates_test_');
    Hive.init(tempDir.path);
    await Hive.openBox('session');
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    await Hive.box('session').clear();
  });

  test('UpdateStore.unread 直接遍历原始列表计数并尊重 lastSeen 边界', () async {
    expect(UpdateStore.unread(), 0);
    await UpdateStore.save(
      {'1': 3},
      [
        {'aid': '1', 'title': 'A', 'img': '', 'chapter': 'c1', 'cid': '1', 'time': 1000},
        {'aid': '1', 'title': 'A', 'img': '', 'chapter': 'c2', 'cid': '2', 'time': 2000},
        {'aid': '1', 'title': 'A', 'img': '', 'chapter': 'c3', 'cid': '3', 'time': 3000},
      ],
      at: {'1': 3000},
    );
    expect(UpdateStore.unread(), 3);
    await Hive.box('session').put('updates:seen', 2000);
    expect(UpdateStore.unread(), 1);
    expect(UpdateStore.updatedAt('1'), 3000);
    await UpdateStore.markSeen();
    expect(UpdateStore.unread(), 0);
  });

  test('首次检查记录基准不产生更新，二次检查发现新章节写入 feed', () async {
    await _seedLibrary([(aid: '10', title: '测试书', done: false, cats: const [])]);
    var chapterCount = 2;
    final api = _FakeApi((aid, _) async => _cat(chapterCount));
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);

    await c.read(updateProvider.notifier).refresh(force: true);
    expect(c.read(updateProvider).error, isNull);
    expect(UpdateStore.known('10'), 2);
    expect(UpdateStore.feed(), isEmpty);

    chapterCount = 4;
    await c.read(updateProvider.notifier).refresh(force: true);
    expect(c.read(updateProvider).error, isNull);
    expect(UpdateStore.known('10'), 4);
    final feed = UpdateStore.feed();
    expect(feed.length, 2);
    expect(feed.map((e) => e.cid).toSet(), {'3', '4'});
  });

  test('遇 CloudflareChallengeException / Cloudflare403Exception / 429 立即中止后续书籍', () async {
    await _seedLibrary([
      (aid: '1', title: '书1', done: false, cats: const []),
      (aid: '2', title: '书2', done: false, cats: const []),
      (aid: '3', title: '书3', done: false, cats: const []),
    ]);

    for (final err in <Object>[
      CloudflareChallengeException(requestOptions: RequestOptions(path: '/1')),
      Cloudflare403Exception(requestOptions: RequestOptions(path: '/1')),
      const Wenku8HttpException(429),
    ]) {
      final api = _FakeApi((aid, _) async => throw err);
      final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
      await c.read(updateProvider.notifier).refresh(force: true);
      final p = c.read(updateProvider);
      expect(api.requested, ['1'], reason: '应在第 1 本遇 $err 时立刻中止');
      expect(p.running, isFalse);
      expect(p.error, isNotNull);
      expect(p.errorObject, same(err));
      c.dispose();
    }
  });

  test('连续 3 次网络错误自动熔断，非连续错误会重置计数', () async {
    await _seedLibrary([
      for (var i = 1; i <= 5; i++) (aid: '$i', title: '书$i', done: false, cats: const []),
    ]);

    final apiFail = _FakeApi((aid, _) async => throw DioException.connectionTimeout(timeout: const Duration(seconds: 5), requestOptions: RequestOptions(path: '/$aid')));
    final c1 = ProviderContainer(overrides: [apiProvider.overrideWithValue(apiFail)]);
    addTearDown(c1.dispose);
    await c1.read(updateProvider.notifier).refresh(force: true);
    expect(apiFail.requested, ['1', '2', '3']);
    expect(c1.read(updateProvider).error, contains('连续多次网络错误'));

    await Hive.box('session').delete('updates:known');
    await Hive.box('session').delete('updates:check');

    // 1、2 失败，3 成功重置计数，4、5 失败 → 全部 5 本都会跑完且不触发熔断
    final apiMixed = _FakeApi((aid, _) async {
      if (aid == '3') return _cat(2);
      throw const Wenku8HttpException(502);
    });
    final c2 = ProviderContainer(overrides: [apiProvider.overrideWithValue(apiMixed)]);
    addTearDown(c2.dispose);
    await c2.read(updateProvider.notifier).refresh(force: true);
    expect(apiMixed.requested, ['1', '2', '3', '4', '5']);
    expect(c2.read(updateProvider).error, isNull);
    expect(UpdateStore.known('3'), 2);
  });

  test('cancel() 立即取消在途请求并中止剩余书籍', () async {
    await _seedLibrary([
      (aid: '1', title: '书1', done: false, cats: const []),
      (aid: '2', title: '书2', done: false, cats: const []),
      (aid: '3', title: '书3', done: false, cats: const []),
    ]);

    final started = Completer<void>();
    var tokenCancelled = false;
    final api = _FakeApi((aid, cancelToken) async {
      if (aid == '1') {
        started.complete();
        await cancelToken!.whenCancel;
        tokenCancelled = true;
        throw cancelToken.cancelError!;
      }
      return _cat(1);
    });

    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final running = c.read(updateProvider.notifier).refresh(force: true);
    await started.future;
    c.read(updateProvider.notifier).cancel();
    await running;

    expect(tokenCancelled, isTrue);
    expect(api.requested, ['1']);
    final p = c.read(updateProvider);
    expect(p.running, isFalse);
    expect(p.error, isNull);
  });

  test('refresh 进行中被 ref.invalidate(updateProvider) 时不抛 StateError', () async {
    await _seedLibrary([
      (aid: '1', title: '书1', done: false, cats: const []),
      (aid: '2', title: '书2', done: false, cats: const []),
    ]);

    final gate = Completer<void>();
    final api = _FakeApi((aid, _) async {
      await gate.future;
      return _cat(2);
    });
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);

    final running = c.read(updateProvider.notifier).refresh(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.invalidate(updateProvider);
    gate.complete();
    await running; // 若漏了 ref.mounted 检查会在此抛 StateError
    expect(c.read(updateProvider).running, isFalse);
  });

  test('过滤条件：跳过已完结、未开始阅读与分类黑白名单', () async {
    await _seedLibrary([
      (aid: 'done_book', title: '完结书', done: true, cats: const ['c1']),
      (aid: 'unread_new', title: '未开始书', done: false, cats: const ['c1']),
      (aid: 'excluded', title: '排除分类', done: false, cats: const ['c2']),
      (aid: 'target', title: '目标书', done: false, cats: const ['c1']),
    ]);
    await ReadState.mark('target', '1', 100);
    await ReadState.mark('excluded', '1', 100);
    await ReadState.mark('done_book', '1', 100);
    await AppPrefs.write(P.updSkipDone, true);
    await AppPrefs.write(P.updSkipNotStarted, true);
    await AppPrefs.write(P.updInclude, ['c1']);
    await AppPrefs.write(P.updExclude, ['c2']);

    final api = _FakeApi((aid, _) async => _cat(3));
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);

    await c.read(updateProvider.notifier).refresh(force: true);
    expect(api.requested, ['target']);
  });
}
