import 'dart:convert';
import 'dart:io';

import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/cover_color.dart';
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/meta_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ark_meta_cache_test_');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('MetaCache.open migrates bgm and ccolor keys out of session while keeping synced keys', () async {
    final session = await Hive.openBox('session');
    await session.putAll({
      'bgm:100': {'id': 1, 'name': 'Test', 'vols': const [], 'x': const [], 't': 123},
      'bgm_info:100': {'id': 1, 't': 123},
      'bgm_chars:100': {'t': 123, 'list': const []},
      'ccolor': {'https://example.com/a.jpg': 0xFF112233},
      'vcover2:100': {'第一卷': 'https://example.com/v1.jpg'},
      'lib:books': {'100': {'title': '测试'}},
    });

    final cache = await MetaCache.open();
    expect(cache, isA<LazyBox>());
    expect(await cache.get('bgm:100'), isA<Map>());
    expect(await cache.get('bgm_info:100'), isA<Map>());
    expect(await cache.get('bgm_chars:100'), isA<Map>());
    expect(await cache.get('ccolor'), isA<Map>());

    // 已从核心 session Box 迁出，但需要同步的 vcover2 与书架数据留在 session 中
    expect(session.containsKey('bgm:100'), isFalse);
    expect(session.containsKey('bgm_info:100'), isFalse);
    expect(session.containsKey('bgm_chars:100'), isFalse);
    expect(session.containsKey('ccolor'), isFalse);
    expect(session.containsKey('vcover2:100'), isTrue);
    expect(session.containsKey('lib:books'), isTrue);

    expect(savedCoverColor('https://example.com/a.jpg')?.toARGB32(), 0xFF112233);
  });

  test('MetaCache hot LRU caps at 12 entries and evictMemory preserves LazyBox disk & cover colors', () async {
    final cache = await MetaCache.open();
    await MetaCache.putCoverColors({'https://example.com/cover.jpg': 0xFFABCDEF});
    expect(savedCoverColor('https://example.com/cover.jpg')?.toARGB32(), 0xFFABCDEF);

    for (var i = 1; i <= 15; i++) {
      await cache.put('bgm_info:$i', {'id': i, 't': 1000 + i});
    }
    for (var i = 1; i <= 15; i++) {
      final m = await MetaCache.getMap('bgm_info:$i');
      expect(m?['id'], i);
    }

    // 超过 12 条后最早读取的 1..3 已从内存热点淘汰，最近 12 条（4..15）仍在热点中
    expect(MetaCache.peekMap('bgm_info:1'), isNull);
    expect(MetaCache.peekMap('bgm_info:3'), isNull);
    expect(MetaCache.peekMap('bgm_info:4')?['id'], 4);
    expect(MetaCache.peekMap('bgm_info:15')?['id'], 15);

    // 清空内存热点后，封面颜色依然同步可用，且 getMap 仍能按需从磁盘 LazyBox 读回
    MetaCache.evictMemory();
    expect(MetaCache.peekMap('bgm_info:4'), isNull);
    expect(MetaCache.peekMap('bgm_info:15'), isNull);
    expect(savedCoverColor('https://example.com/cover.jpg')?.toARGB32(), 0xFFABCDEF);
    expect((await MetaCache.getMap('bgm_info:1'))?['id'], 1);
    expect((await MetaCache.getMap('bgm_info:15'))?['id'], 15);
  });

  test('MetaCache falls back to session box when meta_cache is not opened', () async {
    final session = await Hive.openBox('session');
    await session.put('ccolor', {'https://example.com/b.jpg': 0xFF445566});
    expect(MetaCache.isOpen, isTrue);
    expect(savedCoverColor('https://example.com/b.jpg')?.toARGB32(), 0xFF445566);
  });

  test('Hant.unload clears loaded dictionary instance', () {
    Hant.loaded = Hant.parse('发\t發\n', '');
    expect(Hant.loaded, isNotNull);
    Hant.unload();
    expect(Hant.loaded, isNull);
  });

  test('Backup.make excludes cache and local keys while keeping user data', () async {
    final session = await Hive.openBox('session');
    await session.putAll({
      'cookie': 'secret=1',
      'bgm:1': {'id': 1},
      'ccolor': {'a': 1},
      'bookmarks': [
        {'aid': '1', 'cid': '2', 'offset': 0, 'time': 100},
      ],
      'highlights': [
        {'id': 'hl_1', 'aid': '1', 'cid': '2', 'chapter': 'c', 'start': 0, 'end': 3, 'quote': 'abc', 'note': '', 'color': 0, 'at': 100},
      ],
    });
    final raw = jsonDecode(Backup.make()) as Map<String, dynamic>;
    final box = raw['box'] as Map<String, dynamic>;
    expect(box.containsKey('cookie'), isFalse);
    expect(box.containsKey('bgm:1'), isFalse);
    expect(box.containsKey('ccolor'), isFalse);
    expect(box.containsKey('bookmarks'), isTrue);
    expect(box.containsKey('highlights'), isTrue);
  });

  test('MetaCache.migrateFromSession 写入完成标记后 O(1) 跳过后续扫描，且 pruneStale 清理超期条目', () async {
    final session = await Hive.openBox('session');
    await session.put('bgm:1', {'id': 1, 't': 100});
    final cache = await MetaCache.open();
    expect(session.containsKey('bgm:1'), isFalse);
    expect(cache.containsKey('__migrated_from_session__'), isTrue);
    expect(session.containsKey('__migrated_from_session__'), isFalse);

    // 二次调用因迁移标记存在直接 O(1) 跳过
    await session.put('bgm:2', {'id': 2, 't': 100});
    expect(await MetaCache.migrateFromSession(), 0);
    expect(session.containsKey('bgm:2'), isTrue);
    expect(await MetaCache.migrateFromSession(force: true), 1);
    expect(session.containsKey('bgm:2'), isFalse);

    final now = DateTime.now().millisecondsSinceEpoch;
    final oldTs = now - const Duration(days: 100).inMilliseconds;
    await MetaCache.putMap('bgm_info:keep', {'id': 1, 't': oldTs});
    await MetaCache.putMap('bgm_info:drop', {'id': 2, 't': oldTs});
    await MetaCache.putMap('bgm_chars:drop', {'t': oldTs, 'list': const []});
    await MetaCache.putMap('bgm_info:fresh', {'id': 3, 't': now});

    final pruned = await MetaCache.pruneStale(keepAids: {'keep'}, nowMs: now);
    expect(pruned, 2);
    expect(await MetaCache.getMap('bgm_info:keep'), isNotNull);
    expect(await MetaCache.getMap('bgm_info:fresh'), isNotNull);
    expect(await MetaCache.getMap('bgm_info:drop'), isNull);
    expect(await MetaCache.getMap('bgm_chars:drop'), isNull);
  });
}
