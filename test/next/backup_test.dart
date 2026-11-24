import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/backup.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String support;
  late String zip;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_backup_test');
    Hive.init(tmp.path);
    support = p.join(tmp.path, 'support');
    zip = p.join(tmp.path, 'b.zip');
    await Directory(p.join(support, 'imgcache')).create(recursive: true);
  });

  tearDown(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  test('导出、改乱、导入后除登录信息外完全恢复，多出来的数据被清掉', () async {
    final box = await Hive.openBox('session');
    final data = {
      'lib:books': {'1': {'aid': '1', 'added': 5, 'cats': ['c']}},
      'lib:cats': [{'id': 'c', 'name': '在追'}],
      'stats:day': {'2026-10-21': 2728},
      'stats:ch:1': {'a': {'2026-10-21': 7}},
      'vols:1': [{'t': '第一卷'}],
      'vdone:1': {'第一卷': 9},
      'vrate:1': {'第一卷': 5},
      'updates': [{'aid': '1', 'time': 3}],
      'updates:at:1': 3,
      'sync:device': 'dA',
      'sync:stats:dB': '{}',
      'r.fontSize': 18.0,
      'p.shelf.perCat': true,
      'palette': 7,
      'searchHistory': ['冰菓'],
    };
    await box.putAll(data);
    await box.putAll({'cookie': 'old-cookie', 'cf:a.com': 'old-cf', 'sync:user': 'old-user', 'avatar': '/data/old/files/avatar/x.png'});
    await File(p.join(support, 'imgcache', 'cover')).writeAsString('封面');
    await Directory(p.join(support, 'avatar')).create();
    await File(p.join(support, 'avatar', 'x.png')).writeAsString('头像');

    await Backup.pack(zip, Backup.make(), support);

    // 备份里没有登录信息
    final input = InputFileStream(zip);
    final files = ZipDecoder().decodeStream(input).files;
    expect(files.map((f) => f.name).toSet(), {'data.json', 'files/avatar/x.png'}); // 封面能重新下载，不进备份
    final json = utf8.decode(files.firstWhere((f) => f.name == 'data.json').content as List<int>);
    await input.close();
    expect(json, isNot(contains('old-cookie')));
    expect(json, isNot(contains('old-cf')));
    expect(json, isNot(contains('old-user')));

    // 恢复之前本机变了：多了书和新键，换了登录，头像没了
    await box.put('lib:books', {'2': {'aid': '2'}});
    await box.put('stats:ch:9', {});
    await box.put('cookie', 'new-cookie');
    await File(p.join(support, 'avatar', 'x.png')).delete();
    await box.close();

    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final restored = await Hive.openBox('session');
    for (final e in data.entries) {
      expect(restored.get(e.key), e.value, reason: e.key);
    }
    expect(restored.containsKey('stats:ch:9'), false);
    expect(restored.get('cookie'), 'new-cookie');
    expect(restored.get('avatar'), p.join(support, 'avatar', 'x.png'));
    expect(File(p.join(support, 'avatar', 'x.png')).readAsStringSync(), '头像');
    expect(File(p.join(support, 'imgcache', 'cover')).existsSync(), true); // 缓存不动
    expect(Directory(p.join(support, 'restore_pending')).existsSync(), false);

    // 没有待恢复的备份时什么也不做
    await restored.close();
    await Backup.apply(support);
    expect((await Hive.openBox('session')).get('palette'), 7);
  });

  Future<void> writeZip(Map<String, String> files) async {
    final z = ZipFileEncoder()..create(zip);
    files.forEach((k, v) => z.addArchiveFile(ArchiveFile.string(k, v)));
    await z.close();
  }

  test('不认识的文件不解压、不生效', () async {
    for (final files in [
      {'../evil': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/avatar/../../evil': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/imgcache/a': 'x', 'data.json': '{"backup":3,"box":{}}'},
      {'files/avatar/a': 'x'},
      {'data.json': '{"backup":2}'},
    ]) {
      await writeZip(files);
      await expectLater(Backup.unpack(zip, support), throwsA(isA<FormatException>()), reason: '$files');
      expect(Directory(p.join(support, 'restore_pending')).existsSync(), false);
    }
  });

  test('恢复到另一台设备：同步身份不跟着走，恢复来的统计记到原设备名下', () async {
    final box = await Hive.openBox('session');
    await box.putAll({
      'sync:device': 'dA',
      'sync:avatarUp': 5,
      'sync:last': 9,
      'stats:day': {'2026-10-21': 60},
      'stats:book': {'1': 60},
      'stats:chapters': 3,
      'stats:ch:1': {'a': {'2026-10-21': 60}},
      'stats:days:1': ['2026-10-21'],
      'palette': 4,
    });
    await Backup.pack(zip, Backup.make(), support);
    final input = InputFileStream(zip);
    final json = utf8.decode(ZipDecoder().decodeStream(input).files.firstWhere((f) => f.name == 'data.json').content as List<int>);
    await input.close();
    final box3 = (jsonDecode(json) as Map)['box'] as Map;
    expect(box3.containsKey('sync:device'), false);
    expect(box3.containsKey('sync:avatarUp'), false);
    expect(box3.containsKey('sync:last'), false);

    // 另一台设备 dB
    await box.clear();
    await box.put('sync:device', 'dB');
    await box.close();
    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final b = await Hive.openBox('session');
    expect(b.get('sync:device'), 'dB');
    expect(b.get('sync:avatarUp'), isNull);
    expect(b.get('palette'), 4);
    for (final k in ['stats:day', 'stats:book', 'stats:chapters', 'stats:ch:1', 'stats:days:1']) {
      expect(b.containsKey(k), false, reason: k);
    }
    final moved = jsonDecode(b.get('sync:stats:dA') as String) as Map;
    expect(moved['day'], {'2026-10-21': 60});
    expect(moved['chapters'], 3);
    expect(moved['ch'], {'1': {'a': {'2026-10-21': 60}}});
    expect(moved['days'], {'1': ['2026-10-21']});
  });

  test('旧版备份把 sync:device 放在 box 里：恢复时也认得是哪台设备的', () async {
    final box = await Hive.openBox('session');
    await box.close();
    await writeZip({'data.json': '{"backup":3,"box":{"sync:device":"dOld","stats:chapters":2,"palette":3}}'});
    await Backup.unpack(zip, support);
    await Backup.apply(support);
    final b = await Hive.openBox('session');
    expect(b.get('sync:device'), isNull); // 本机还没有，之后第一次用时新生成
    expect(b.get('stats:chapters'), isNull);
    expect((jsonDecode(b.get('sync:stats:dOld') as String) as Map)['chapters'], 2);
    expect(b.get('palette'), 3);
  });

  test('备份里的登录信息即使被手动加进去也不会写入', () async {
    final box = await Hive.openBox('session');
    await box.put('cookie', 'mine');
    await box.close();
    await writeZip({'data.json': '{"backup":3,"box":{"cookie":"evil","palette":3}}'});
    await Backup.unpack(zip, support);
    await Backup.apply(support);
    final b = await Hive.openBox('session');
    expect(b.get('cookie'), 'mine');
    expect(b.get('palette'), 3);
  });

  test('恢复到曾与原设备同步过的目标设备：目标设备原本的云端统计还原为本机统计', () async {
    final box = await Hive.openBox('session');
    await box.putAll({
      'sync:device': 'dA',
      'stats:day': {'2026-10-21': 120},
      'stats:book': {'1': 120},
      'stats:chapters': 2,
      'sync:stats:dB': jsonEncode({
        'day': {'2026-10-20': 300},
        'book': {'2': 300},
        'chapters': 5,
        'days': {'2': ['2026-10-20']},
      }),
    });
    await Backup.pack(zip, Backup.make(), support);
    await box.clear();
    await box.put('sync:device', 'dB');
    await box.close();

    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final b = await Hive.openBox('session');
    expect(b.get('sync:device'), 'dB');
    expect(b.containsKey('sync:stats:dB'), isFalse);
    expect(b.get('stats:day'), {'2026-10-20': 300});
    expect(b.get('stats:book'), {'2': 300});
    expect(b.get('stats:chapters'), 5);
    expect((jsonDecode(b.get('sync:stats:dA') as String) as Map)['chapters'], 2);
  });

  test('新导出排除设备私有键（sync:avatarFile、unlock:txt:*）及可再生缓存（bgm:*、ccolor）；旧备份导入向后兼容', () async {
    final box = await Hive.openBox('session');
    await box.putAll({
      'palette': 2,
      'sync:avatarFile': 'dA.avatar',
      'unlock:txt:123': {'cid': '1'},
      'bgm:123': {'id': 1},
      'ccolor': {'https://img.example/1.jpg': 0xFF123456},
    });
    final exported = jsonDecode(Backup.make()) as Map<String, dynamic>;
    final exportedBox = exported['box'] as Map<String, dynamic>;
    expect(exportedBox['palette'], 2);
    expect(exportedBox.containsKey('sync:avatarFile'), isFalse);
    expect(exportedBox.containsKey('unlock:txt:123'), isFalse);
    expect(exportedBox.containsKey('bgm:123'), isFalse);
    expect(exportedBox.containsKey('ccolor'), isFalse);

    // 恢复旧备份：包含旧版导出的 bgm:*、ccolor、sync:avatarFile、unlock:txt:*
    await box.put('sync:avatarFile', 'local.avatar');
    await box.put('unlock:txt:999', {'cid': 'local'});
    await box.close();

    await writeZip({
      'data.json': jsonEncode({
        'backup': 3,
        'box': {
          'palette': 5,
          'sync:avatarFile': 'evil.avatar',
          'unlock:txt:999': {'cid': 'evil'},
          'unlock:txt:123': {'cid': 'old'},
          'unlock:txt:456': {'cid': 'from-backup'},
          'bgm:123': {'id': 42},
          'ccolor': {'https://img.example/legacy.jpg': 0xFF654321},
        },
      }),
    });
    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final restored = await Hive.openBox('session');
    expect(restored.get('palette'), 5);
    // 设备私有键保持本机原值，不被旧备份覆盖或注入
    expect(restored.get('sync:avatarFile'), 'local.avatar');
    expect(restored.get('unlock:txt:999'), {'cid': 'local'});
    expect(restored.get('unlock:txt:123'), {'cid': '1'});
    expect(restored.containsKey('unlock:txt:456'), isFalse);
    // 旧备份里的可再生缓存仍向后兼容恢复，不报错
    expect(restored.get('bgm:123'), {'id': 42});
    expect(restored.get('ccolor'), {'https://img.example/legacy.jpg': 0xFF654321});
  });

  test('备份包含 reader_bg 目录时完整打包并修正恢复路径；旧版无 reader_bg 目录备份向后兼容', () async {
    final box = await Hive.openBox('session');
    await box.putAll({
      'reader_bg:path': '/data/old_device/files/reader_bg/bg_001.jpg',
      'r.bgTexture': 1,
      'r.bgImageOpacity': 0.45,
    });
    await Directory(p.join(support, 'reader_bg')).create(recursive: true);
    await File(p.join(support, 'reader_bg', 'bg_001.jpg')).writeAsString('bg-bytes');

    await Backup.pack(zip, Backup.make(), support);

    // zip 中包含 files/reader_bg/bg_001.jpg
    final input = InputFileStream(zip);
    final names = ZipDecoder().decodeStream(input).files.map((f) => f.name).toSet();
    await input.close();
    expect(names, {'data.json', 'files/reader_bg/bg_001.jpg'});

    // 清空本机后恢复到新 supportDir
    await box.clear();
    await Directory(p.join(support, 'reader_bg')).delete(recursive: true);
    await box.close();

    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final restored = await Hive.openBox('session');
    expect(restored.get('reader_bg:path'), p.join(support, 'reader_bg', 'bg_001.jpg'));
    expect(File(p.join(support, 'reader_bg', 'bg_001.jpg')).readAsStringSync(), 'bg-bytes');
    expect(restored.get('r.bgTexture'), 1);
    expect(restored.get('r.bgImageOpacity'), 0.45);
    await restored.close();

    // 旧版备份（zip 中没有 files/reader_bg/ 目录且无 reader_bg:path 键）可正常恢复并清掉旧本机残留背景图
    await writeZip({
      'data.json': jsonEncode({
        'backup': 3,
        'box': {'palette': 6},
      }),
    });
    await Backup.unpack(zip, support);
    await Backup.apply(support);

    final legacyRestored = await Hive.openBox('session');
    expect(legacyRestored.get('palette'), 6);
    expect(legacyRestored.containsKey('reader_bg:path'), isFalse);
    expect(Directory(p.join(support, 'reader_bg')).listSync(), isEmpty);
  });
}
