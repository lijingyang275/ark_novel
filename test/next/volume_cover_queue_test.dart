import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/bangumi.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/volumes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// 假接口：取插图章节一律失败，记下取了几次
class _FailingApi implements Api {
  int calls = 0;

  @override
  Future<Content> chapter(String aid, String cid) async {
    calls++;
    throw Exception('network');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ToggleApi implements Api {
  bool fail = true;
  int calls = 0;
  Completer<void>? blocker;

  @override
  Future<Content> chapter(String aid, String cid) async {
    calls++;
    if (blocker != null) await blocker!.future;
    if (fail) throw Exception('blocked');
    return Content(text: '', images: ['https://pic.wenku8.com/$aid/1.jpg']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBangumi implements BangumiCovers {
  int calls = 0;
  final Map<String, BgmSeries> seriesMap;
  _FakeBangumi(this.seriesMap);

  @override
  Future<BgmSeries?> series(String aid) async {
    calls++;
    return seriesMap[aid];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageStore implements ImageStore {
  static final _png1x1 = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  @override
  Future<Uint8List> load(String rawUrl) async => _png1x1;

  @override
  void allowAutoSr(String url) {}

  @override
  Future<void> remove(Iterable<String> urls) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('封面队列：连着失败 3 本就停，不把整个书架请求一遍', () async {
    final dir = await Directory.systemTemp.createTemp('vqueue');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox('session');
    addTearDown(Hive.close);
    await ChapterCache.open();
    final aids = [for (var i = 0; i < 6; i++) '$i'];
    for (final aid in aids) {
      await box.put('vols:$aid', [
        {'t': '第一卷', 'c': ['c$aid'], 'i': 'i$aid'},
      ]);
    }
    final api = _FailingApi();
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);

    await c.read(volumeCoverQueueProvider).prefetchAll(aids);

    expect(api.calls, 3);
  });

  test('文库失败时临时用 Bangumi 封面兜底且不落库，恢复并重刷后换回原站封面且过程不闪烁', () async {
    final dir = await Directory.systemTemp.createTemp('vqueue_bgm_recover');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox('session');
    addTearDown(Hive.close);
    await ChapterCache.open();

    await box.put('lib:books', {
      '1': {'aid': '1', 'title': '测试轻小说', 'img': 'https://img.wenku8.com/1.jpg'},
    });
    await box.put('vols:1', [
      {'t': '第一卷', 'c': ['c1'], 'i': 'i1'},
    ]);

    final api = _ToggleApi();
    final bgm = _FakeBangumi({
      '1': (id: 101, name: '测试轻小说', vols: [(name: '测试轻小说 (1)', img: 'https://lain.bgm.tv/pic/cover/l/1.jpg')], extras: const []),
    });
    final c = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        bangumiProvider.overrideWithValue(bgm),
        imageStoreProvider.overrideWithValue(_FakeImageStore()),
      ],
    );
    addTearDown(c.dispose);

    final queue = c.read(volumeCoverQueueProvider);
    await queue.prefetchAll(['1']);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 临时兜底不写入持久化 vcover2，且 bookCover/get 返回 Bangumi 封面
    expect(Volumes.cover('1', '第一卷'), isNull);
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://lain.bgm.tv/pic/cover/l/1.jpg');

    // 网络恢复，开始重新预取：在原站取到之前继续展示 Bangumi 封面不回退成站点小图
    api.fail = false;
    api.blocker = Completer<void>();
    final refresh = queue.prefetchAll(['1']);
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://lain.bgm.tv/pic/cover/l/1.jpg');

    api.blocker!.complete();
    await refresh;

    // 原站成功后写入持久化记录，并切回原站高清封面
    expect(Volumes.cover('1', '第一卷'), 'https://pic.wenku8.com/1/1.jpg');
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://pic.wenku8.com/1/1.jpg');
  });

  test('连着失败 3 本熔断后，剩余书架书直接走 Bangumi 临时兜底', () async {
    final dir = await Directory.systemTemp.createTemp('vqueue_breaker');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox('session');
    addTearDown(Hive.close);
    await ChapterCache.open();

    final aids = [for (var i = 0; i < 5; i++) '$i'];
    await box.put('lib:books', {
      for (final aid in aids) aid: {'aid': aid, 'title': '书$aid', 'img': 'https://img.wenku8.com/$aid.jpg'},
    });
    for (final aid in aids) {
      await box.put('vols:$aid', [
        {'t': '第一卷', 'c': ['c$aid'], 'i': 'i$aid'},
      ]);
    }
    final api = _FailingApi();
    final bgm = _FakeBangumi({
      for (final aid in aids) aid: (id: int.parse(aid) + 1, name: '书$aid', vols: [(name: '书$aid (1)', img: 'https://lain.bgm.tv/$aid.jpg')], extras: const []),
    });
    final c = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        bangumiProvider.overrideWithValue(bgm),
        imageStoreProvider.overrideWithValue(_FakeImageStore()),
      ],
    );
    addTearDown(c.dispose);

    final queue = c.read(volumeCoverQueueProvider);
    await queue.prefetchAll(aids);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.calls, 3);
    expect(queue.bookCover('4', 'https://img.wenku8.com/4.jpg'), 'https://lain.bgm.tv/4.jpg');
    expect(Volumes.cover('4', '第一卷'), isNull);
  });

  test('已有持久化文库封面但下载失败时，reportCoverFailed 临时切到 Bangumi，重刷清空失败记录重试原站', () async {
    final dir = await Directory.systemTemp.createTemp('vqueue_report');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    final box = await Hive.openBox('session');
    addTearDown(Hive.close);
    await ChapterCache.open();

    await box.put('lib:books', {
      '1': {'aid': '1', 'title': '测试轻小说', 'img': 'https://img.wenku8.com/1.jpg'},
    });
    await box.put('vols:1', [
      {'t': '第一卷', 'c': ['c1'], 'i': 'i1'},
    ]);
    await Volumes.setCover('1', '第一卷', 'https://pic.wenku8.com/1/1.jpg');

    final bgm = _FakeBangumi({
      '1': (id: 101, name: '测试轻小说', vols: [(name: '测试轻小说 (1)', img: 'https://lain.bgm.tv/pic/cover/l/1.jpg')], extras: const []),
    });
    final c = ProviderContainer(
      overrides: [
        bangumiProvider.overrideWithValue(bgm),
        imageStoreProvider.overrideWithValue(_FakeImageStore()),
      ],
    );
    addTearDown(c.dispose);

    final queue = c.read(volumeCoverQueueProvider);
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://pic.wenku8.com/1/1.jpg');

    queue.reportCoverFailed('1', 'https://pic.wenku8.com/1/1.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://lain.bgm.tv/pic/cover/l/1.jpg');

    await queue.prefetchAll(['1']);
    expect(queue.bookCover('1', 'https://img.wenku8.com/1.jpg'), 'https://pic.wenku8.com/1/1.jpg');
  });
}
