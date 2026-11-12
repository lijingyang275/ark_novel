import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sync.dart';

/// 完整备份：一个 zip，里面是本地数据库里除登录信息外的全部键（`data.json`），加上自选的头像和字体（`files/`）。
/// 封面、缓存的正文能重新下载，不进备份，恢复时也不动。
/// 恢复是整份覆盖：导入时先解压到 [_pending]，重新打开 App 时在打开数据库之前换上，所以不用管运行中的各种状态。
class Backup {
  Backup._();

  static Box get _box => Hive.box('session');

  static const _pending = 'restore_pending';
  static const _dirs = ['avatar', 'font'];

  /// 登录信息、代理、WebDAV 账号和这台设备的同步身份留在本机：不进备份，恢复时也不动。
  /// `sync:device` 跟着备份走的话，恢复到另一台设备后两台用同一个 ID，同步时互相覆盖、也不再合并对方。
  static const _localKeys = {
    'cookie',
    'ua',
    'savedUser',
    'savedPass',
    'userHtml',
    'proxy',
    'sync:url',
    'sync:user',
    'sync:pass',
    'sync:folder',
    'sync:device',
    'sync:avatarUp',
    'sync:last',
    'sync:passMoved',
    'lib:imported',
    'lib:ops',
    'lib:opsFor',
    'imgShrunk2',
    'imgHq',
    'coverSkipDropped',
    'coverRetrimmed',
  };

  static bool _isLocal(String k) => _localKeys.contains(k) || k.startsWith('cf:');

  static String make() => jsonEncode({
    'backup': 3,
    'device': Sync.deviceId,
    'box': {for (final k in _box.keys.whereType<String>().where((k) => !_isLocal(k))) k: _box.get(k)},
  });

  static Future<String> _supportDir() async => (await getApplicationSupportDirectory()).path;

  /// 打包成临时目录里的 zip，返回文件路径。
  static Future<String> export() async {
    final out = p.join((await getTemporaryDirectory()).path, 'ark_novel_backup.zip');
    final args = (out: out, data: make(), supportDir: await _supportDir());
    await compute((a) => pack(a.out, a.data, a.supportDir), args);
    return out;
  }

  /// 检查并解压 zip，下次打开 App 时生效。
  static Future<void> importZip(String zip) async {
    final dir = await _supportDir();
    await compute((a) => unpack(a.zip, a.dir), (zip: zip, dir: dir));
    await Hive.close();
  }

  static Future<void> applyPending() async => apply(await _supportDir());

  static Future<void> pack(String out, String data, String supportDir) async {
    var total = utf8.encode(data).length;
    for (final d in _dirs) {
      final dir = Directory(p.join(supportDir, d));
      if (!await dir.exists()) continue;
      await for (final f in dir.list().where((e) => e is File).cast<File>()) {
        total += await f.length();
      }
    }
    // 和 [unpack] 同一个上限：超了导出也恢复不了
    if (total > _maxUnpackedBytes) throw const FormatException('备份超过 256 MB（多半是字体太多），删掉一些字体再导出');
    final zip = ZipFileEncoder()..create(out);
    zip.addArchiveFile(ArchiveFile.string('data.json', data));
    for (final d in _dirs) {
      final dir = Directory(p.join(supportDir, d));
      if (!await dir.exists()) continue;
      await for (final f in dir.list().where((e) => e is File).cast<File>()) {
        await zip.addFile(f, 'files/$d/${p.basename(f.path)}');
      }
    }
    await zip.close();
  }

  static const _maxUnpackedBytes = 256 << 20;

  /// 先解压到临时目录，全部成功才改名成 [_pending]，中途出错不会留下半份。文件来自外部：只认约定好的路径。
  static Future<void> unpack(String zip, String supportDir) async {
    final tmp = Directory(p.join(supportDir, '$_pending.tmp'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
    try {
      final input = InputFileStream(zip);
      try {
        var totalBytes = 0;
        for (final f in ZipDecoder().decodeStream(input).files) {
          if (!f.isFile) continue;
          final parts = f.name.split('/');
          final validSub = parts.length == 3 &&
              parts[0] == 'files' &&
              _dirs.contains(parts[1]) &&
              parts[2].isNotEmpty &&
              parts[2] != '.' &&
              parts[2] != '..' &&
              !f.name.contains(r'\') &&
              p.basename(parts[2]) == parts[2];
          final ok = f.name == 'data.json' || validSub;
          if (!ok) throw const FormatException('不是 Ark Novel 的备份文件');
          totalBytes += f.size;
          if (f.size < 0 || totalBytes > _maxUnpackedBytes) throw const FormatException('备份文件超出大小限制');
          final dest = File(p.join(tmp.path, f.name));
          await dest.parent.create(recursive: true);
          final output = OutputFileStream(dest.path);
          f.writeContent(output);
          await output.close();
        }
      } finally {
        await input.close();
      }
      final data = File(p.join(tmp.path, 'data.json'));
      if (!await data.exists()) throw const FormatException('不是 Ark Novel 的备份文件');
      final m = jsonDecode(await data.readAsString());
      if (m is! Map || m['backup'] != 3 || m['box'] is! Map) throw const FormatException('不是 Ark Novel 的备份文件');
      // 备份时没有的目录也建出来，恢复时才会把本机多出来的清掉
      for (final d in _dirs) {
        await Directory(p.join(tmp.path, 'files', d)).create(recursive: true);
      }
      final pending = Directory(p.join(supportDir, _pending));
      if (await pending.exists()) await pending.delete(recursive: true);
      await tmp.rename(pending.path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete(recursive: true);
      rethrow;
    }
  }

  /// 换上待恢复的备份。必须在打开数据库之前调用；中途被杀掉的话，下次启动接着做，结果一样。
  static Future<void> apply(String supportDir) async {
    final pending = Directory(p.join(supportDir, _pending));
    if (!await pending.exists()) return;
    for (final d in _dirs) {
      final src = Directory(p.join(pending.path, 'files', d));
      if (!await src.exists()) continue;
      final dest = Directory(p.join(supportDir, d));
      if (await dest.exists()) await dest.delete(recursive: true);
      await src.rename(dest.path);
    }
    final m = jsonDecode(await File(p.join(pending.path, 'data.json')).readAsString()) as Map;
    final saved = Map<String, dynamic>.from(m['box'] as Map);
    // 备份是哪台设备的（旧版备份记在 box 的 sync:device 里）
    final from = m['device'] ?? saved['sync:device'];
    saved.removeWhere((k, _) => _isLocal(k));
    // 这两个存的是绝对路径，换设备、换包名后要指到新位置
    if (saved['avatar'] case final String v) saved['avatar'] = p.join(supportDir, 'avatar', p.basename(v));
    if (saved['font:path'] case final String v) saved['font:path'] = p.join(supportDir, 'font', p.basename(v));
    final box = await Hive.openBox('session');
    await box.deleteAll(box.keys.whereType<String>().where((k) => !_isLocal(k)).toList());
    await box.putAll(saved);
    // 恢复的是别的设备（或重装前的本机）的备份：统计记到那台设备名下，和它同步来的统计不会重复相加
    if (from is String && from != box.get('sync:device')) await Sync.adoptLocalStatsAs(from);
    await box.close(); // 重新打开时读到的才和平时的类型一样
    await pending.delete(recursive: true);
  }

  // ---- 旧版的 JSON 备份（backup: 2）----

  static const _exact = {'lib:books', 'lib:cats', 'shelfTabOrder', 'shelfOpts', 'catReverse', 'incognito'};
  static const _prefixes = ['shelfOrder:', 'vcover2:', 'vpick:', 'vrate:', 'r.', 'p.', 'swipe', 'chl:'];

  static bool _wanted(String k) => _exact.contains(k) || _prefixes.any(k.startsWith);

  /// 导入旧版的 JSON 备份：只合并，不覆盖现有的。同步快照按同步规则并入（本机自己导出的跳过）；书架里没有的书、没有的分类补上；
  /// 其余设置只补本机还没有的；删除过（有墓碑）的书和分类不补回来。返回恢复了多少本书。
  static Future<int> restore(String json) async {
    final m = jsonDecode(json) as Map<String, dynamic>;
    try {
      await Sync.importBackup(json);
    } on StaleSnapshotException {
      // 太旧的快照不按同步规则合并，下面只补书架上还没有、也没删过的书
    }
    final extra = (m['extra'] as Map?) ?? const {};
    var books = 0;
    for (final e in extra.entries) {
      final k = e.key as String;
      if (!_wanted(k)) continue;
      if (k == 'lib:books') {
        final mine = Map.of((_box.get(k) as Map?) ?? const {});
        for (final b in (e.value as Map).entries) {
          if (!mine.containsKey(b.key) && !Sync.isDeleted('lib:${b.key}', ((b.value as Map)['added'] as int?) ?? 0)) {
            mine[b.key] = b.value;
            books++;
          }
        }
        await _box.put(k, mine);
      } else if (k == 'lib:cats') {
        final mine = ((_box.get(k) as List?) ?? const []).cast<Map>().toList();
        final ids = mine.map((c) => c['id']).toSet();
        await _box.put(k, [
          ...mine,
          for (final c in (e.value as List).cast<Map>())
            if (!ids.contains(c['id']) && !Sync.isDeleted('cat:${c['id']}', (c['ts'] as int?) ?? 0)) c,
        ]);
      } else if (!_box.containsKey(k)) {
        await _box.put(k, e.value);
      }
    }
    return books;
  }
}
