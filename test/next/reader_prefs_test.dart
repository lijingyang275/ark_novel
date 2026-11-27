import 'dart:io';

import 'package:ark_novel/next/incognito.dart';
import 'package:ark_novel/next/progress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/settings.dart';

void main() {
  test('ReaderPrefs.dim 默认不遮，copyWith 只改 dim', () {
    const p = ReaderPrefs();
    expect(p.dim, 0);
    final q = p.copyWith(dim: 0.4);
    expect(q.dim, 0.4);
    expect(q.fontSize, p.fontSize);
    expect(q.copyWith(fontSize: 20).dim, 0.4);
  });

  test('ReaderPrefs 新字段默认值、copyWith、相等性与 Hive 持久化读写', () async {
    const def = ReaderPrefs();
    expect(def.autoScrollSpeed, 60);
    expect(def.autoTurnSeconds, 8);
    expect(def.bgTexture, 0);
    expect(def.bgImageOpacity, 0.35);
    expect(def.headerLeft, 1);
    expect(def.headerRight, 0);
    expect(def.footerLeft, 3);
    expect(def.footerRight, 4);

    final updated = def.copyWith(
      autoScrollSpeed: 120,
      autoTurnSeconds: 12,
      bgTexture: 2,
      bgImageOpacity: 0.5,
      headerLeft: 2,
      headerRight: 5,
      footerLeft: 6,
      footerRight: 3,
    );
    expect(updated, isNot(def));
    expect(updated.hashCode, isNot(def.hashCode));
    expect(updated.autoScrollSpeed, 120);
    expect(updated.autoTurnSeconds, 12);
    expect(updated.bgTexture, 2);
    expect(updated.bgImageOpacity, 0.5);
    expect(updated.headerLeft, 2);
    expect(updated.headerRight, 5);
    expect(updated.footerLeft, 6);
    expect(updated.footerRight, 3);

    final dir = Directory.systemTemp.createTempSync('ark_reader_prefs_test');
    addTearDown(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    Hive.init(dir.path);
    final box = await Hive.openBox('session');

    final c1 = ProviderContainer();
    addTearDown(c1.dispose);
    c1.read(readerPrefsProvider.notifier).update(updated);
    expect(box.get('r.autoScrollSpeed'), 120);
    expect(box.get('r.autoTurnSeconds'), 12);
    expect(box.get('r.bgTexture'), 2);
    expect(box.get('r.bgImageOpacity'), 0.5);
    expect(box.get('r.headerLeft'), 2);
    expect(box.get('r.headerRight'), 5);
    expect(box.get('r.footerLeft'), 6);
    expect(box.get('r.footerRight'), 3);

    // 重新构造容器读取持久化值
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(readerPrefsProvider), updated);

    // 越界损坏数据读取时安全钳位
    await box.putAll({
      'r.autoScrollSpeed': 999.0,
      'r.autoTurnSeconds': 1,
      'r.bgTexture': 99,
      'r.bgImageOpacity': 0.01,
      'r.headerLeft': -5,
      'r.footerRight': 99,
    });
    final c3 = ProviderContainer();
    addTearDown(c3.dispose);
    final clamped = c3.read(readerPrefsProvider);
    expect(clamped.autoScrollSpeed, 220);
    expect(clamped.autoTurnSeconds, 3);
    expect(clamped.bgTexture, 3);
    expect(clamped.bgImageOpacity, 0.05);
    expect(clamped.headerLeft, 0);
    expect(clamped.footerRight, 6);
  });

  test('ReaderPrefsController 差分写盘：仅写变化键 + sync:readerTs，preview 不落盘，flush/commit 落盘', () async {
    final dir = Directory.systemTemp.createTempSync('ark_reader_prefs_diff_test');
    addTearDown(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    Hive.init(dir.path);
    final box = await Hive.openBox('session');

    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(readerPrefsProvider.notifier);

    // 1. 仅改 1 个字段：Hive 只写入 2 个键（r.dim + sync:readerTs），而不是 43 键
    notifier.update(c.read(readerPrefsProvider).copyWith(dim: 0.3));
    expect(box.keys.toSet(), {'r.dim', 'sync:readerTs'});
    expect(box.get('r.dim'), 0.3);
    final ts1 = box.get('sync:readerTs') as int;

    // 2. 无变化调用 update：不触发任何 Hive 写入，sync:readerTs 不变
    await Future<void>.delayed(const Duration(milliseconds: 2));
    notifier.update(c.read(readerPrefsProvider));
    expect(box.keys.toSet(), {'r.dim', 'sync:readerTs'});
    expect(box.get('sync:readerTs'), ts1);

    // 3. preview 仅更新内存 state，不落盘
    notifier.preview(c.read(readerPrefsProvider).copyWith(warm: 0.25));
    expect(c.read(readerPrefsProvider).warm, 0.25);
    expect(box.containsKey('r.warm'), isFalse);
    expect(box.get('sync:readerTs'), ts1);

    // 4. 连续 preview 后调用 update(state) 或 flush()，基于上次落盘快照差分写入 r.warm
    notifier.preview(c.read(readerPrefsProvider).copyWith(warm: 0.4));
    expect(box.containsKey('r.warm'), isFalse);
    notifier.flush();
    expect(box.keys.toSet(), {'r.dim', 'r.warm', 'sync:readerTs'});
    expect(box.get('r.warm'), 0.4);

    // 5. persist: false 等同于 preview，commit 立即差分落盘
    notifier.update(c.read(readerPrefsProvider).copyWith(bgImageOpacity: 0.6), persist: false);
    expect(c.read(readerPrefsProvider).bgImageOpacity, 0.6);
    expect(box.containsKey('r.bgImageOpacity'), isFalse);
    notifier.commit(c.read(readerPrefsProvider));
    expect(box.get('r.bgImageOpacity'), 0.6);
    expect(box.keys.toSet(), {'r.dim', 'r.warm', 'r.bgImageOpacity', 'sync:readerTs'});
  });

  test('ReadingProgress 内存热缓存即时可读、防抖合并落盘与 flush 立即刷盘', () async {
    final dir = Directory.systemTemp.createTempSync('ark_progress_debounce_test');
    final prevDebounce = ReadingProgress.debounceDuration;
    final prevMaxWait = ReadingProgress.maxWaitDuration;
    ReadingProgress.debounceDuration = const Duration(milliseconds: 60);
    ReadingProgress.maxWaitDuration = const Duration(milliseconds: 300);
    addTearDown(() async {
      ReadingProgress.debounceDuration = prevDebounce;
      ReadingProgress.maxWaitDuration = prevMaxWait;
      await ReadingProgress.flush();
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    Hive.init(dir.path);
    final box = await Hive.openBox('session');

    // 1. save 立即更新内存热缓存，但未立刻写盘
    await ReadingProgress.save('10', 'c1', 120);
    expect(ReadingProgress.of('10')?.cid, 'c1');
    expect(ReadingProgress.get('10')?.offset, 120);
    expect(ReadingProgress.lastRead('10'), greaterThan(0));
    expect(box.get('progress:10'), isNull);

    // 2. 连续快速更新合并，等待防抖到期后只落盘最新值
    await ReadingProgress.save('10', 'c1', 350);
    await ReadingProgress.save('10', 'c2', 88);
    expect(ReadingProgress.of('10')?.cid, 'c2');
    expect(ReadingProgress.of('10')?.offset, 88);
    expect(box.get('progress:10'), isNull);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    final stored = box.get('progress:10') as List?;
    expect(stored, isNotNull);
    expect(stored![0], 'c2');
    expect(stored[1], 88);

    // 3. flush() 立即同步刷盘，无需等待防抖
    await ReadingProgress.save('10', 'c3', 512);
    expect((box.get('progress:10') as List)[0], 'c2');
    await ReadingProgress.flush();
    expect((box.get('progress:10') as List)[0], 'c3');
    expect((box.get('progress:10') as List)[1], 512);

    // 4. 无痕模式不更新进度也不落盘
    await box.put('incognito', true);
    expect(Incognito.on, isTrue);
    await ReadingProgress.save('10', 'c9', 999);
    await ReadingProgress.flush();
    expect(ReadingProgress.of('10')?.cid, 'c3');
    expect((box.get('progress:10') as List)[0], 'c3');
    await box.put('incognito', false);
  });
}
