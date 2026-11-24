import 'dart:io';

import 'package:ark_novel/next/app_prefs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ark_app_prefs_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
  });

  setUp(() async {
    await Hive.box('session').clear();
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('appPrefProvider / appPref 按 key 细粒度通知，修改无关 key 不触发重建', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var resumeCount = 0;
    var hideCount = 0;
    var rawCount = 0;

    container.listen(appPref(P.resumeBar, true), (_, _) => resumeCount++, fireImmediately: true);
    container.listen(appPref(P.hideShelved, false), (_, _) => hideCount++, fireImmediately: true);
    container.listen(appPrefProvider(P.colsPortrait), (_, _) => rawCount++, fireImmediately: true);

    expect(resumeCount, 1);
    expect(hideCount, 1);
    expect(rawCount, 1);
    expect(container.read(appPref(P.resumeBar, true)), isTrue);
    expect(container.read(appPref(P.hideShelved, false)), isFalse);

    // 修改 hideShelved，只通知 hideShelved，不打扰 resumeBar 与 colsPortrait
    container.read(appPrefsProvider.notifier).set(P.hideShelved, true);
    await container.pump();
    expect(hideCount, 2);
    expect(resumeCount, 1);
    expect(rawCount, 1);
    expect(container.read(appPref(P.hideShelved, false)), isTrue);

    // 写入相同值也不触发重复通知
    container.read(appPrefsProvider.notifier).set(P.hideShelved, true);
    await container.pump();
    expect(hideCount, 2);

    // 修改 colsPortrait，只通知 colsPortrait
    container.read(appPrefsProvider.notifier).set(P.colsPortrait, 4);
    await container.pump();
    expect(rawCount, 2);
    expect(resumeCount, 1);
    expect(hideCount, 2);
    expect(container.read(appPrefProvider(P.colsPortrait)), 4);
  });

  test('List 与 Map 偏好按内容深比较，同内容不触发重建', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var listCount = 0;
    var mapCount = 0;
    container.listen(appPrefList(P.hiddenTabs), (_, _) => listCount++, fireImmediately: true);
    container.listen(appPrefProvider('shelf.tab.all'), (_, _) => mapCount++, fireImmediately: true);
    expect(listCount, 1);
    expect(mapCount, 1);

    container.read(appPrefsProvider.notifier).set(P.hiddenTabs, ['a', 'b']);
    await container.pump();
    expect(listCount, 2);
    expect(mapCount, 1);
    expect(container.read(appPrefList(P.hiddenTabs)), ['a', 'b']);

    // 写入内容相同的新 List 实例，不触发重建
    container.read(appPrefsProvider.notifier).set(P.hiddenTabs, ['a', 'b']);
    await container.pump();
    expect(listCount, 2);

    // 修改内容后触发重建
    container.read(appPrefsProvider.notifier).set(P.hiddenTabs, ['a', 'c']);
    await container.pump();
    expect(listCount, 3);
    expect(container.read(appPrefList(P.hiddenTabs)), ['a', 'c']);

    // Map 偏好同样深比较
    container.read(appPrefsProvider.notifier).set('shelf.tab.all', {'sort': 1, 'reverse': true});
    await container.pump();
    expect(mapCount, 2);
    expect(listCount, 3);

    container.read(appPrefsProvider.notifier).set('shelf.tab.all', {'sort': 1, 'reverse': true});
    await container.pump();
    expect(mapCount, 2);

    container.read(appPrefsProvider.notifier).set('shelf.tab.all', {'sort': 2, 'reverse': true});
    await container.pump();
    expect(mapCount, 3);
  });

  test('直接写 Hive 后 ref.invalidate(appPrefsProvider) 仅刷新发生变化的 key', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var motionCount = 0;
    var lockCount = 0;
    container.listen(appPref(P.sceneMotion, true), (_, _) => motionCount++, fireImmediately: true);
    container.listen(appPref(P.lock, false), (_, _) => lockCount++, fireImmediately: true);
    expect(motionCount, 1);
    expect(lockCount, 1);

    // 模拟冷启动后首次同步/恢复备份直接写盘，尚未调用过 set()
    await Hive.box('session').put('p.${P.sceneMotion}', false);
    container.invalidate(appPrefsProvider);

    expect(container.read(appPref(P.sceneMotion, true)), isFalse);
    expect(motionCount, 2);
    expect(lockCount, 1);
  });

  test('原有 AppPrefs.read / readList / get / set 与同步时间戳保持向后兼容', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(appPrefsProvider.notifier);
    final before = container.read(appPrefsProvider);
    notifier.set(P.resumeBar, false);
    expect(container.read(appPrefsProvider), greaterThan(before));
    expect(notifier.get(P.resumeBar, true), isFalse);
    expect(AppPrefs.read(P.resumeBar, true), isFalse);
    expect(Hive.box('session').get('sync:prefsTs'), isA<int>());

    await AppPrefs.write(P.updInclude, ['c1', 'c2']);
    expect(AppPrefs.readList(P.updInclude), ['c1', 'c2']);
  });
}
