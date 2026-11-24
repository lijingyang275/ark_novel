import 'dart:io';

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
}
