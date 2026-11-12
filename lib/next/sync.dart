import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';
import 'avatar.dart';
import 'files.dart';
import 'library.dart';
import 'progress.dart';
import 'settings.dart';
import 'stats.dart';
import 'sync_validation.dart';
import 'theme.dart';
import 'updates.dart';
import 'volumes.dart';

/// 同步：每台设备把自己的数据整份写成 `<文件夹>/<设备ID>.json` 放到 WebDAV（坚果云），
/// 同步时读取其他设备的文件，按下面的规则并入本机。不依赖服务端，只要能 GET / PUT / PROPFIND。
///
/// 合并规则（都是幂等的，重复同步不会翻倍）：
/// - 阅读进度：按时间，新的赢
/// - 阅读历史：每本书取最近一次；书签：同一章 40 字以内视为同一个，取较新的；规则：按编号并集，本机优先
/// - 已读章节：并集；已读字数、评分：取较大 / 本机没有才用对方的；备注：并集，本机优先
/// - 书签、规则的删除靠"墓碑"同步（编号 → 删除时间，留 90 天）；规则的修改按修改时间，新的赢
/// - 阅读统计：其他设备的统计**单独存放**，显示时和本机相加，所以两边同时读也不会互相覆盖
///
/// shortcut: 备注的删除和修改不同步（本机优先），书签的墓碑按精确偏移匹配；需要时再给备注加时间。
/// shortcut: 设置（字号、主题等）不同步，每台设备外观习惯本来就不一样。
class Sync {
  Sync._();

  static Box get _box => Hive.box('session');

  /// 同步合并完成时通知界面刷新（书架、分类、封面、头像、偏好等）
  static final changes = ValueNotifier<int>(0);

  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)); // 没开发者签名的 Mac 版用不了新式钥匙串（-34018）

  static String get url => (_box.get('sync:url') as String?) ?? 'https://dav.jianguoyun.com/dav/';
  static String get user => (_box.get('sync:user') as String?) ?? '';
  static const defaultFolder = 'ArkNovel';
  static String get folder => (_box.get('sync:folder') as String?) ?? defaultFolder;
  static int get lastSync => (_box.get('sync:last') as int?) ?? 0;
  static bool get configured => user.isNotEmpty;

  static bool get _useLocalPass => kIsWeb || Platform.isMacOS;

  /// 应用密码：安卓/iOS 放系统安全存储；Mac 版（无开发者证书签名访问钥匙串会反复弹窗要密码）直接存沙盒本地库。
  static Future<String> password() async {
    if (_useLocalPass) {
      final local = _box.get('sync:pass') as String?;
      if (local != null || _box.get('sync:passMoved') == true) return local ?? '';
      // 旧版存在钥匙串里的搬过来，只试一次，免得反复弹窗
      await _box.put('sync:passMoved', true);
      try {
        final old = await _secure.read(key: 'syncPass');
        if (old != null) await _box.put('sync:pass', old);
        return old ?? '';
      } catch (_) {
        return '';
      }
    }
    try {
      final p = await _secure.read(key: 'syncPass');
      if (p != null) return p;
    } catch (_) {}
    return (_box.get('sync:pass') as String?) ?? '';
  }

  static Future<void> save({required String url, required String user, required String pass, required String folder}) async {
    final nextFolder = folder.trim().isEmpty ? defaultFolder : folder.trim();
    final changed = url.trim().replaceFirst(RegExp(r'/+$'), '') != Sync.url.replaceFirst(RegExp(r'/+$'), '') || user.trim() != Sync.user || nextFolder != Sync.folder;
    await _box.putAll({'sync:url': url.trim(), 'sync:user': user.trim(), 'sync:folder': nextFolder});
    if (changed) await _box.deleteAll(['sync:last', 'sync:avatarUp']); // 新目录没有旧目录的同步基准或头像
    if (_useLocalPass) {
      await _box.put('sync:pass', pass);
      return;
    }
    try {
      await _secure.write(key: 'syncPass', value: pass);
      await _box.delete('sync:pass');
    } catch (_) {
      await _box.put('sync:pass', pass);
    }
  }

  static const _tombDays = 90;

  static int get _tombCutoff => DateTime.now().millisecondsSinceEpoch - const Duration(days: _tombDays).inMilliseconds;

  static Map<String, int> _tombs() => Map<String, int>.from((_box.get('sync:tomb') as Map?) ?? const {});

  /// [time] 时的 [key] 是否已被删除（有不早于它的墓碑）。
  static bool isDeleted(String key, int time) {
    final t = _tombs()[key];
    return t != null && t >= time;
  }

  /// 记下被删掉的东西（`b:书:章:偏移`、`r:规则编号`），同步时告诉其他设备也删掉。
  static Future<void> tombstone(Iterable<String> keys) async {
    if (keys.isEmpty) return;
    final t = _tombs();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final k in keys) {
      t[k] = now;
    }
    await _box.put('sync:tomb', t);
  }

  static String bookmarkKey(Map b) => 'b:${b['aid']}:${b['cid']}:${b['offset']}';

  static String get deviceId {
    var id = _box.get('sync:device') as String?;
    if (id == null) {
      id = 'd${Random.secure().nextInt(1 << 32).toRadixString(36)}${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      _box.put('sync:device', id);
    }
    return id;
  }

  // ---- 本机数据 → 快照 ----

  static Iterable<String> _keys(String prefix) => _box.keys.whereType<String>().where((k) => k.startsWith(prefix));

  /// 书架和更新偏好里跨设备同步的：列数、上次停在的标签各设备自己的。
  static bool _isShelfPref(String k) => (k.startsWith('p.shelf.') || k.startsWith('p.upd.')) && !{P.colsPortrait, P.colsLandscape, P.lastTab}.any((x) => k == 'p.$x');

  /// 头像图片不进快照：单独传成 `<设备ID>.avatar`，变了才传；快照里只记时间和文件名。
  static Map<String, dynamic>? _avatarSnapshot() {
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true)) return null;
    final path = _box.get('avatar') as String?;
    final ts = _box.get('avatar:ts') as int?;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (file.existsSync()) return {'ts': ts ?? file.lastModifiedSync().millisecondsSinceEpoch, 'ext': p.extension(path), 'file': '$deviceId.avatar'};
    }
    return ts == null ? null : {'ts': ts};
  }

  static Future<void> _pushAvatar(Dio dio) async {
    final a = _avatarSnapshot();
    if (a == null || a['file'] == null || _box.get('sync:avatarUp') == a['ts']) return;
    final bytes = await File(_box.get('avatar') as String).readAsBytes();
    _ok(await dio.put('${_dir()}${a['file']}', data: Stream.fromIterable([bytes]), options: Options(contentType: 'application/octet-stream', headers: {Headers.contentLengthHeader: bytes.length})), '上传头像');
    await _box.put('sync:avatarUp', a['ts']);
  }

  /// 对方的头像比本机新才下载，放进快照交给 [merge]；下载失败就当没变，下次再试。
  static Future<void> _pullAvatar(Dio dio, Map<String, dynamic> remote) async {
    final a = remote['avatar'];
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true) || a is! Map || a['file'] is! String) return;
    if (((a['ts'] as int?) ?? 0) <= ((_box.get('avatar:ts') as int?) ?? 0)) return;
    try {
      final r = await dio.get<List<int>>('${_dir()}${Uri.encodeComponent(p.basename(a['file'] as String))}', options: Options(responseType: ResponseType.bytes));
      _ok(r, '下载头像');
      a['data'] = base64Encode(r.data!);
    } catch (_) {
      remote.remove('avatar');
    }
  }

  /// 本机要同步的数据（不含从别的设备并入的统计）。
  static Map<String, dynamic> snapshot() {
    Map<String, dynamic> byAid(String prefix) => {for (final k in _keys(prefix)) k.substring(prefix.length): _box.get(k)};
    final avatar = _avatarSnapshot();
    return {
      'v': 3,
      'device': deviceId,
      'at': DateTime.now().millisecondsSinceEpoch,
      'progress': byAid('progress:'),
      'history': _box.get('history2') ?? const [],
      'bookmarks': _box.get('bookmarks') ?? const [],
      'read': byAid('read:'),
      'readchars': byAid('readchars:'),
      'rating': byAid('rating:'),
      'vrate': byAid('vrate:'),
      'rules': _box.get('rules') ?? const [],
      'notes': byAid('notes:'),
      'tomb': _tombs(),
      'books': _box.get('lib:books') ?? const {},
      'cats': _box.get('lib:cats') ?? const [],
      'shelfTabOrder': _box.get('shelfTabOrder'),
      'shelfOrder': byAid('shelfOrder:'),
      'vcover': byAid('vcover2:'),
      'vpick': byAid('vpick:'),
      'vpickTs': byAid('vpickTs:'),
      'vols': byAid('vols:'),
      'updates': {
        'feed': _box.get('updates') ?? const [],
        'known': _box.get('updates:known') ?? const {},
        'seen': _box.get('updates:seen') ?? 0,
        'at': byAid('updates:at:'),
      },
      'avatar': ?avatar,
      'shelfPrefs': {
        'ts': (_box.get('sync:prefsTs') as int?) ?? 0,
        'shelfOpts': _box.get('shelfOpts'),
        'p': {
          for (final k in _keys('p.'))
            if (_isShelfPref(k)) k: _box.get(k),
        },
      },
      'readerPrefs': {
        'ts': (_box.get('sync:readerTs') as int?) ?? 0,
        'r': {for (final k in _keys('r.')) k: _box.get(k)},
        'volumeDone': _box.get('p.${P.volumeDone}'),
      },
      'appearance': {
        'ts': (_box.get('sync:appearanceTs') as int?) ?? 0,
        'themeMode': _box.get('themeMode'),
        'palette': _box.get('palette'),
        'p': {for (final k in _keys('p.ui.')) k: _box.get(k)},
      },
      'stats': _localStats(),
    };
  }

  static Map<String, dynamic> _localStats() => {
    'day': _box.get('stats:day') ?? const {},
    'book': _box.get('stats:book') ?? const {},
    'chapters': _box.get('stats:chapters') ?? 0,
    'meta': _box.get('stats:meta') ?? const {},
    'days': {for (final k in _keys('stats:days:')) k.substring(11): _box.get(k)},
    'ch': {for (final k in _keys('stats:ch:')) k.substring(9): _box.get(k)},
    'last': _box.get('stats:last') ?? const {},
  };

  /// 从别的设备（[device]）的备份恢复后：恢复来的阅读统计是那台设备的，改记到它名下（和同步来的统计放一起）。
  /// 那台设备还在用的话，下次同步它的快照会覆盖这份，不会重复计算；本机自己的统计从零开始累加。
  static Future<void> adoptLocalStatsAs(String device) async {
    final stats = _localStats();
    await _box.put('sync:stats:$device', jsonEncode(stats));
    await _box.deleteAll([
      'stats:day',
      'stats:book',
      'stats:chapters',
      'stats:meta',
      'stats:last',
      ..._keys('stats:days:'),
      ..._keys('stats:ch:'),
    ]);
  }

  // ---- 其他设备的快照 → 并入本机 ----

  static List<Map> _maps(Object? v) => [for (final e in (v as List?) ?? const []) Map<String, dynamic>.from(e as Map)];

  /// 把 [remote]（别的设备的快照，已解码的 JSON）按规则并入本机。
  ///
  /// 超过 90 天没更新的快照抛 [StaleSnapshotException]：那之前的墓碑已经清掉了，并进来会把删过的东西加回来。
  static Future<void> merge(Map<String, dynamic> remote) async {
    validateSyncSnapshot(remote);
    if (remote['device'] == deviceId) return;
    if (remote['at'] case final num at when at < _tombCutoff) throw const StaleSnapshotException();
    // 要读写文件的头像先做完：从下面读本机数据到最后一起写入之间不能有 await，
    // 否则这段时间里本机的改动（阅读器记历史、加书签）会被这里读到的旧值盖掉
    final avatar = await _mergeAvatar(remote);
    final puts = <String, Object?>{...avatar.puts};
    final dels = <String>{...avatar.dels};

    // 墓碑：取较新的删除时间，超过 90 天的丢掉；比删除时间旧的东西视为已删
    final tomb = _tombs();
    for (final e in ((remote['tomb'] as Map?) ?? const {}).entries) {
      if (e.value is int && (e.value as int) > (tomb[e.key] ?? 0)) tomb['${e.key}'] = e.value as int;
    }
    final cutoff = _tombCutoff;
    tomb.removeWhere((_, t) => t < cutoff);
    puts['sync:tomb'] = tomb;
    bool dead(String key, int time) => tomb.containsKey(key) && tomb[key]! >= time;

    // 进度：[章, 偏移, 时间]，旧版本机数据可能只有前两项（当作时间 0）；对方格式不对的单条跳过
    for (final e in ((remote['progress'] as Map?) ?? const {}).entries) {
      final r = e.value;
      if (r is! List || r.length < 3 || r[0] is! String || r[1] is! int || r[2] is! int) continue;
      final l = _box.get('progress:${e.key}');
      final lTime = l is List && l.length >= 3 && l[2] is int ? l[2] as int : 0;
      if ((r[2] as int) > lTime) puts['progress:${e.key}'] = r;
    }

    // 历史：每本书取较新的；删除、清空过的（`h:书`、`h:*` 墓碑）不再带回来
    final hist = <String, Map>{};
    for (final h in [..._maps(_box.get('history2')), ..._maps(remote['history'])]) {
      final time = h['time'] as int;
      if (dead('h:${h['aid']}', time) || dead('h:*', time)) continue;
      final old = hist[h['aid']];
      if (old == null || time > (old['time'] as int)) hist[h['aid'] as String] = h;
    }
    puts['history2'] = (hist.values.toList()..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int))).take(300).toList();

    // 书签
    final marks = _maps(_box.get('bookmarks')).where((l) => !dead(bookmarkKey(l), l['time'] as int)).toList();
    for (final r in _maps(remote['bookmarks'])) {
      if (dead(bookmarkKey(r), r['time'] as int)) continue;
      final i = marks.indexWhere((l) => l['aid'] == r['aid'] && l['cid'] == r['cid'] && ((l['offset'] as int) - (r['offset'] as int)).abs() <= 40);
      if (i < 0) {
        marks.add(r);
      } else if ((r['time'] as int) > (marks[i]['time'] as int)) {
        marks[i] = r;
      }
    }
    puts['bookmarks'] = (marks..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int)));

    // 已读章节、字数、评分
    for (final e in ((remote['read'] as Map?) ?? const {}).entries) {
      puts['read:${e.key}'] = {...((_box.get('read:${e.key}') as List?) ?? const []).cast<String>(), ...(e.value as List).cast<String>()}.toList();
    }
    for (final e in ((remote['readchars'] as Map?) ?? const {}).entries) {
      puts['readchars:${e.key}'] = max((_box.get('readchars:${e.key}') as int?) ?? 0, e.value as int);
    }
    for (final e in ((remote['rating'] as Map?) ?? const {}).entries) {
      if (((_box.get('rating:${e.key}') as int?) ?? 0) == 0 && (e.value as int) > 0) puts['rating:${e.key}'] = e.value;
    }
    for (final e in ((remote['vrate'] as Map?) ?? const {}).entries) {
      if (e.value is! Map) continue;
      final local = Map<String, int>.from(((_box.get('vrate:${e.key}') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      for (final vr in (e.value as Map).entries) {
        if ((local['${vr.key}'] ?? 0) == 0 && (vr.value as int) > 0) local['${vr.key}'] = vr.value as int;
      }
      if (local.isNotEmpty) puts['vrate:${e.key}'] = local;
    }

    // 规则：按编号并集，同一条取修改时间较新的；备注：并集，本机优先
    int ts(Map r) => (r['ts'] as int?) ?? 0;
    final rules = _maps(_box.get('rules')).where((r) => !dead('r:${r['id']}', ts(r))).toList();
    for (final r in _maps(remote['rules'])) {
      if (r['id'] == null || dead('r:${r['id']}', ts(r))) continue;
      final i = rules.indexWhere((l) => l['id'] == r['id']);
      if (i < 0) {
        rules.add(r);
      } else if (ts(r) > ts(rules[i])) {
        rules[i] = r;
      }
    }
    puts['rules'] = rules;
    for (final e in ((remote['notes'] as Map?) ?? const {}).entries) {
      final local = Map<String, String>.from(((_box.get('notes:${e.key}') as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      for (final n in (e.value as Map).entries) {
        local.putIfAbsent('${n.key}', () => '${n.value}');
      }
      puts['notes:${e.key}'] = local;
    }

    // 书架分类（例如"在追"）与书架书籍（含重命名 name、所属分类 cats）
    final catIdMap = <String, String>{};
    final readAfter = <LibBook>[]; // 被墓碑删掉、但本机在删除之后读过的书
    final localCatMap = <String, String>{}; // 本机分类换了 id：旧 → 新
    if (remote['cats'] != null || remote['books'] != null) {
      final cats = _maps(_box.get('lib:cats')).where((c) => !dead('cat:${c['id']}', ts(c))).toList();
      for (final r in _maps(remote['cats'])) {
        final rId = '${r['id']}';
        final rName = '${r['name']}';
        final rTs = ts(r);
        if (dead('cat:$rId', rTs)) continue;
        final byId = cats.indexWhere((c) => c['id'] == rId);
        if (byId >= 0) {
          if (rTs > ts(cats[byId])) cats[byId] = {'id': rId, 'name': rName, 'ts': rTs};
        } else {
          final byName = cats.indexWhere((c) => c['name'] == rName);
          if (byName >= 0) {
            // 同名分类两边统一成同一个 id（取较小的），之后改名、删除才能跨设备对上
            final lId = '${cats[byName]['id']}';
            if (rId.compareTo(lId) < 0) {
              cats[byName] = {...cats[byName], 'id': rId};
              localCatMap[lId] = rId;
            } else {
              catIdMap[rId] = lId;
            }
          } else {
            cats.add({'id': rId, 'name': rName, 'ts': rTs});
          }
        }
      }
      puts['lib:cats'] = cats;

      final validCatIds = {for (final c in cats) '${c['id']}'};
      // 书的删除只看加入时间：删除之后改名、改分类、阅读都不让它回来，重新加入才算（[LibraryController.restore]）
      final localBooks = <String, Map<String, dynamic>>{};
      final gone = <String, Map<String, dynamic>>{};
      for (final e in ((_box.get('lib:books') as Map?) ?? const {}).entries) {
        final aid = '${e.key}';
        final b = Map<String, dynamic>.from(e.value as Map);
        b['cats'] = {for (final c in ((b['cats'] as List?) ?? const []).cast<String>()) localCatMap[c] ?? c}.toList();
        (dead('lib:$aid', (b['added'] as int?) ?? 0) ? gone : localBooks)[aid] = b;
      }
      for (final e in ((remote['books'] as Map?) ?? const {}).entries) {
        final aid = '${e.key}';
        if (e.value is! Map) continue;
        final r = Map<String, dynamic>.from(e.value as Map);
        final rAdded = (r['added'] as int?) ?? 0;
        final rTs = (r['ts'] as int?) ?? 0;
        if (dead('lib:$aid', rAdded)) continue;
        final rCats = {
          for (final c in ((r['cats'] as List?) ?? const []).cast<String>())
            if (validCatIds.contains(catIdMap[c] ?? c)) catIdMap[c] ?? c,
        }.toList();
        final l = localBooks[aid];
        if (l == null) {
          localBooks[aid] = {
            'aid': aid,
            'title': r['title'] ?? '',
            'img': r['img'] ?? '',
            'added': rAdded,
            'cats': rCats,
            'bid': null,
            'done': r['done'] == true,
            'name': r['name'],
            'ts': rTs,
          };
        } else {
          final lAdded = (l['added'] as int?) ?? 0;
          final lTs = (l['ts'] as int?) ?? 0;
          final lCats = [
            for (final c in ((l['cats'] as List?) ?? const []).cast<String>())
              if (validCatIds.contains(c)) c,
          ];
          final mergedName = rTs > lTs ? r['name'] : (lTs > rTs ? l['name'] : (l['name'] ?? r['name']));
          final mergedCats = rTs > lTs ? rCats : (lTs > rTs ? lCats : (lCats.isNotEmpty ? lCats : rCats));
          localBooks[aid] = {
            'aid': aid,
            'title': (l['title'] as String?)?.isNotEmpty == true ? l['title'] : (r['title'] ?? ''),
            'img': (l['img'] as String?)?.isNotEmpty == true ? l['img'] : (r['img'] ?? ''),
            'added': lAdded > 0 && rAdded > 0 ? min(lAdded, rAdded) : max(lAdded, rAdded),
            'cats': mergedCats,
            'bid': l['bid'],
            'done': (l['done'] == true) || (r['done'] == true),
            'name': mergedName,
            'ts': max(lTs, rTs),
          };
        }
      }
      puts['lib:books'] = localBooks;
      final ops = Map<String, Object?>.from((_box.get('lib:ops') as Map?) ?? const {});
      for (final MapEntry(key: aid, value: b) in gone.entries) {
        if (localBooks.containsKey(aid)) continue; // 对方删了之后又重新加过
        // 本机推到过网站书架的也从网站移出，不然下次对网站书架时又被加回来
        if (b['bid'] != null) ops[aid] = {'op': 'remove', 'bid': b['bid']};
        if (ReadingProgress.lastRead(aid) > tomb['lib:$aid']!) {
          try {
            readAfter.add(LibBook.fromMap(b));
          } catch (_) {}
        }
      }
      if (gone.isNotEmpty) puts['lib:ops'] = ops;
      _renameCatRefs(localCatMap, puts, dels);
    }

    if (remote['shelfTabOrder'] is List && _box.get('shelfTabOrder') == null) {
      puts['shelfTabOrder'] = [for (final c in (remote['shelfTabOrder'] as List).cast<String>()) catIdMap[c] ?? c];
    }
    for (final e in ((remote['shelfOrder'] as Map?) ?? const {}).entries) {
      final key = '${e.key}'; // lib:<分类 id>
      final catKey = key.startsWith('lib:') ? 'lib:${catIdMap[key.substring(4)] ?? key.substring(4)}' : key;
      if (_box.get('shelfOrder:$catKey') == null && !puts.containsKey('shelfOrder:$catKey') && e.value is List) {
        puts['shelfOrder:$catKey'] = (e.value as List).cast<String>();
      }
    }

    // 分卷目录与卷封面（含手动挑过 / 裁剪过的 #crop= 封面，手动挑的优先于自动挑的）
    for (final e in ((remote['vols'] as Map?) ?? const {}).entries) {
      final l = _box.get('vols:${e.key}') as List?;
      final r = e.value;
      // 格式不对的整本跳过，免得写进本机后 [Volumes.of] 每次读都出错
      if (r is! List || !r.every(_isVol)) continue;
      if (l == null || r.length > l.length) puts['vols:${e.key}'] = r;
    }
    var coverChanged = false;
    final rVcover = (remote['vcover'] as Map?) ?? const {};
    final rVpick = (remote['vpick'] as Map?) ?? const {};
    for (final aid in {...rVcover.keys.map((k) => '$k'), ...rVpick.keys.map((k) => '$k')}) {
      final lPick = ((_box.get('vpick:$aid') as List?) ?? const []).cast<String>().toSet();
      final rPick = ((rVpick[aid] as List?) ?? const []).cast<String>().toSet();
      final lCover = Map<String, String>.from(((_box.get('vcover2:$aid') as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      final rCover = Map<String, String>.from(((rVcover[aid] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
      final lTime = Map<String, int>.from(((_box.get('vpickTs:$aid') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      final rTime = Map<String, int>.from((((remote['vpickTs'] as Map?)?[aid] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      bool manual(Set<String> picks, String title, String? url) => picks.contains(title) || (url?.contains('#crop=') ?? false);
      // 有一台设备恢复了自动封面：比那次恢复早的手动封面作废，两边都去掉
      bool reset(Map<String, int> time, String title) => dead('vcover:$aid:$title', time[title] ?? 0);
      for (final title in lCover.keys.toList()) {
        if (manual(lPick, title, lCover[title]) && reset(lTime, title)) {
          lCover.remove(title);
          lPick.remove(title);
          lTime.remove(title);
          coverChanged = true;
        }
      }
      for (final e in rCover.entries) {
        final title = e.key, rUrl = e.value;
        final lUrl = lCover[title];
        if (manual(rPick, title, rUrl) && reset(rTime, title)) continue; // 已作废的手动封面
        final rManual = manual(rPick, title, rUrl);
        final lManual = manual(lPick, title, lUrl);
        final take = rManual
            ? !lManual || lUrl == null || lUrl.isEmpty || (rTime[title] ?? 0) > (lTime[title] ?? 0)
            : !lManual && (lUrl == null || lUrl.isEmpty) && rUrl.isNotEmpty;
        if (take && lUrl != rUrl) {
          lCover[title] = rUrl;
          coverChanged = true;
        }
        if (rManual && (rTime[title] ?? 0) > (lTime[title] ?? 0)) lTime[title] = rTime[title]!;
      }
      rPick.removeWhere((title) => reset(rTime, title));
      final mergedPick = {...lPick, ...rPick};
      puts['vcover2:$aid'] = lCover;
      puts['vpick:$aid'] = mergedPick.toList();
      if (lTime.isNotEmpty) puts['vpickTs:$aid'] = lTime;
    }

    // 更新列表与章节基准（让手机和电脑看到的更新一致）
    if (remote['updates'] is Map) {
      final ru = remote['updates'] as Map;
      final feedMap = <String, Map>{};
      for (final f in [..._maps(_box.get('updates')), ..._maps(ru['feed'])]) {
        final key = '${f['aid']}:${f['cid']}';
        final old = feedMap[key];
        if (old == null || (f['time'] as int) > (old['time'] as int)) feedMap[key] = f;
      }
      puts['updates'] = (feedMap.values.toList()..sort((a, b) => (b['time'] as int).compareTo(a['time'] as int))).take(300).toList();
      final known = Map<String, int>.from(((_box.get('updates:known') as Map?) ?? const {}).map((k, v) => MapEntry('$k', v as int)));
      for (final e in ((ru['known'] as Map?) ?? const {}).entries) {
        known['${e.key}'] = max(known['${e.key}'] ?? 0, e.value as int);
      }
      puts['updates:known'] = known;
      final rSeen = (ru['seen'] as int?) ?? 0;
      final lSeen = (_box.get('updates:seen') as int?) ?? 0;
      if (rSeen > lSeen) puts['updates:seen'] = rSeen;
      for (final e in ((ru['at'] as Map?) ?? const {}).entries) {
        final k = 'updates:at:${e.key}';
        final rAt = e.value as int;
        final lAt = (_box.get(k) as int?) ?? 0;
        if (rAt > lAt) puts[k] = rAt;
      }
    }

    // 可选同步项：按本机的开关决定是否并入。键名只认这一组自己的前缀、值的类型和本机一致，
    // 别人发来的文件改不了同步地址、登录信息这类键
    if (AppPrefs.read(P.syncShelfPrefs, false) && remote['shelfPrefs'] is Map) {
      final sp = remote['shelfPrefs'] as Map;
      final rTs = (sp['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:prefsTs') as int?) ?? 0;
      if (rTs > lTs) {
        if (sp['shelfOpts'] is Map) {
          final options = syncShelfOptions(sp['shelfOpts'] as Map);
          if (options.isNotEmpty) puts['shelfOpts'] = {...((_box.get('shelfOpts') as Map?) ?? const {}), ...options};
        }
        _putPrefs(sp['p'], _isShelfPref, puts);
        puts['sync:prefsTs'] = rTs;
      }
    }

    if (AppPrefs.read(P.syncReaderPrefs, false) && remote['readerPrefs'] is Map) {
      final rp = remote['readerPrefs'] as Map;
      final rTs = (rp['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:readerTs') as int?) ?? 0;
      if (rTs > lTs) {
        _putPrefs(rp['r'], (k) => k.startsWith('r.'), puts);
        _putPrefs({'p.${P.volumeDone}': rp['volumeDone']}, (_) => true, puts);
        puts['sync:readerTs'] = rTs;
      }
    }

    if (AppPrefs.read(P.syncAppearance, false) && remote['appearance'] is Map) {
      final ap = remote['appearance'] as Map;
      final rTs = (ap['ts'] as int?) ?? 0;
      final lTs = (_box.get('sync:appearanceTs') as int?) ?? 0;
      if (rTs > lTs) {
        if (ap['themeMode'] case final int m when m >= 0 && m < ThemeMode.values.length) puts['themeMode'] = m;
        if (ap['palette'] case final int i when i >= 0 && i < appPalettes.length) puts['palette'] = i;
        _putPrefs(ap['p'], (k) => k.startsWith('p.ui.'), puts);
        puts['sync:appearanceTs'] = rTs;
      }
    }

    // 统计：单独存放；删掉的书从对方的统计里去掉（删除之后又读过的留下，见 ReadingStats.stripBook），本机的也删一次
    final stats = Map<String, dynamic>.from((remote['stats'] as Map?) ?? const {}); // 旧版快照可能没有
    final purged = Map<String, int>.from((_box.get('stats:purged') as Map?) ?? const {});
    final purge = <String, int>{};
    for (final e in tomb.entries.where((e) => e.key.startsWith('stats:'))) {
      final aid = e.key.substring(6);
      ReadingStats.stripBook(stats, aid, before: e.value);
      if (e.value > (purged[aid] ?? 0)) purge[aid] = e.value;
    }
    puts['sync:stats:${remote['device']}'] = jsonEncode(stats);
    // 删除和写入放在最后一起做：前面出错时本机什么都没改
    dels.removeAll(puts.keys);
    // 两个调用都先更新 Hive 内存，再一起等落盘；删除和写入之间不能让出事件循环。
    await Future.wait([if (dels.isNotEmpty) _box.deleteAll(dels), _box.putAll(puts)]);
    await avatar.cleanup?.call();
    // 先删本机的再记「删过了」：中途被打断的话下次合并会再删一次（按日期删，重复删没有副作用）
    for (final MapEntry(key: aid, value: at) in purge.entries) {
      await ReadingStats.purgeLocal(aid, before: at);
      purged[aid] = at;
    }
    if (purge.isNotEmpty) await _box.put('stats:purged', purged);
    for (final aid in ((remote['read'] as Map?) ?? const {}).keys) {
      await Volumes.refreshDone('$aid');
    }
    if (coverChanged) Volumes.changes.value++;
    LibraryStore.noteRemovedElsewhere(readAfter);
    changes.value++;
  }

  /// 本机分类换了 id：书架顺序、标签顺序和存着分类 id 的设置跟着改。
  static void _renameCatRefs(Map<String, String> ids, Map<String, Object?> puts, Set<String> dels) {
    if (ids.isEmpty) return;
    for (final MapEntry(key: from, value: to) in ids.entries) {
      final order = _box.get('shelfOrder:lib:$from');
      if (order != null) puts['shelfOrder:lib:$to'] = order;
      dels.add('shelfOrder:lib:$from');
    }
    List<String> mapped(Object? v) => [for (final c in ((v as List?) ?? const []).cast<String>()) ids[c] ?? c];
    if (_box.get('shelfTabOrder') != null) puts['shelfTabOrder'] = mapped(_box.get('shelfTabOrder'));
    for (final k in [P.hiddenTabs, P.updInclude, P.updExclude]) {
      if (_box.get('p.$k') != null) puts['p.$k'] = mapped(_box.get('p.$k'));
    }
    final def = _box.get('p.${P.defaultCat}');
    if (ids[def] != null) puts['p.${P.defaultCat}'] = ids[def];
  }

  static bool _isVol(Object? v) => v is Map && v['t'] is String && v['c'] is List && (v['c'] as List).every((c) => c is String) && (v['i'] == null || v['i'] is String);

  /// 可选设置并入 [puts]：只收本组已知的键，并按固定字段定义检查类型和范围。
  static void _putPrefs(Object? remote, bool Function(String key) allowed, Map<String, Object?> puts) {
    if (remote is! Map) return;
    for (final e in remote.entries) {
      final k = '${e.key}';
      final v = e.value;
      if (!allowed(k) || v == null) continue;
      final typed = syncPreference(k, v);
      if (typed != null) puts[k] = typed;
    }
  }

  /// 对方的头像比本机新就换上（文件先写好，旧文件等数据库写完再删）。
  /// 返回要写入、删除的键，和写入成功后清理旧头像文件的回调。
  static Future<({Map<String, Object?> puts, Set<String> dels, Future<void> Function()? cleanup})> _mergeAvatar(Map<String, dynamic> remote) async {
    const none = (puts: <String, Object?>{}, dels: <String>{}, cleanup: null);
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true) || remote['avatar'] is! Map) return none;
    final ra = remote['avatar'] as Map;
    final rTs = (ra['ts'] as int?) ?? 0;
    final lTs = (_box.get('avatar:ts') as int?) ?? 0;
    if (rTs <= lTs) return none;
    final data = ra['data'] as String?;
    if (data == null && ra['file'] != null) return none; // 导入的备份文件不带图片，保持原样
    if (data == null || data.isEmpty) return (puts: <String, Object?>{'avatar:ts': rTs}, dels: {'avatar'}, cleanup: null);
    try {
      final bytes = base64Decode(data);
      final ext = p.extension('a${(ra['ext'] as String?) ?? '.png'}'); // 来自外部，只取扩展名
      Directory dir;
      try {
        dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'avatar'));
      } catch (_) {
        dir = Directory(p.join(Directory.systemTemp.path, 'ark_avatar'));
      }
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, 'avatar_$rTs$ext'));
      await writeFileAtomic(dest, bytes);
      Future<void> cleanup() async {
        try {
          await for (final f in dir.list()) {
            if (f is File && f.path != dest.path) await f.delete();
          }
        } catch (_) {}
      }

      return (puts: <String, Object?>{'avatar': dest.path, 'avatar:ts': rTs}, dels: <String>{}, cleanup: cleanup);
    } catch (_) {
      return none;
    }
  }

  /// 删掉一本书的统计：记下墓碑（本机已删过，下次合并不用再删），已经同步来的其他设备的统计也去掉。
  static Future<void> forgetBookStats(String aid) async {
    await tombstone(['stats:$aid']);
    final purged = Map<String, int>.from((_box.get('stats:purged') as Map?) ?? const {});
    purged[aid] = _tombs()['stats:$aid']!;
    await _box.put('stats:purged', purged);
    for (final k in _keys('sync:stats:').toList()) {
      final stats = Map<String, dynamic>.from(jsonDecode(_box.get(k) as String) as Map);
      ReadingStats.stripBook(stats, aid, before: purged[aid]);
      await _box.put(k, jsonEncode(stats));
    }
  }

  /// 其他设备的统计（设备 → 内容），统计页把它们加到本机数据上。
  /// 统计页一次构建要调用几百次：原文没变就复用解码结果（只读，调用方不要改）。
  static Iterable<Map<String, dynamic>> otherStats() => [
    for (final k in _keys('sync:stats:')) _decodeStats(k, _box.get(k) as String),
  ];

  static final _statsCache = <String, (String, Map<String, dynamic>)>{};

  static Map<String, dynamic> _decodeStats(String key, String raw) {
    final hit = _statsCache[key];
    if (hit != null && hit.$1 == raw) return hit.$2;
    final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    _statsCache[key] = (raw, m);
    return m;
  }

  /// 导入备份文件（别的设备或本机导出的快照）：规则同同步；返回 false 表示这是本机自己导出的。
  static Future<bool> importBackup(String json) async {
    final m = jsonDecode(json) as Map<String, dynamic>;
    if (m['device'] == deviceId) return false;
    await merge(m);
    return true;
  }

  // ---- WebDAV ----

  static Dio _dio(String pass) => Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30), headers: {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$pass'))}'}, validateStatus: (s) => s != null && s < 500));

  static String _dir() => '${url.endsWith('/') ? url : '$url/'}${Uri.encodeComponent(folder)}/';

  static String _decodeHref(String s) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  /// 目录里所有 `*.json` 的文件名（PROPFIND 的返回里取 href）。
  static List<String> parseListing(String xml) => [
    for (final m in RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>', caseSensitive: false).allMatches(xml))
      if (_decodeHref(m.group(1)!) case final href when href.endsWith('.json') && !href.endsWith('/')) href.split('/').last,
  ];

  static void _ok(Response r, String what) {
    if (r.statusCode == 401) throw '$what：用户名或应用密码不对（坚果云要用"第三方应用密码"，不是登录密码）';
    if (r.statusCode! >= 400) throw '$what失败（HTTP ${r.statusCode}）';
  }

  /// 测试连接：目录不存在就建出来。
  static Future<void> test() async {
    final dio = _dio(await password());
    try {
      final r = await dio.request(_dir(), options: Options(method: 'PROPFIND', headers: {'Depth': '0'}));
      if (r.statusCode == 404) {
        _ok(await dio.request(_dir(), options: Options(method: 'MKCOL')), '创建同步文件夹');
      } else {
        _ok(r, '连接');
      }
    } finally {
      dio.close();
    }
  }

  static bool _running = false;

  /// 上次 [run] 时因为超过 90 天没更新而跳过的设备文件名。
  static List<String> lastSkipped = const [];

  /// 完整同步一次：上传本机快照，读取并合并其他设备的快照。返回合并了几台设备。
  static Future<int> run() async {
    if (_running) throw '正在同步，请稍候';
    _running = true;
    Dio? dio;
    try {
      if (lastSync > 0 && lastSync < _tombCutoff) throw const LocalSyncExpiredException();
      dio = _dio(await password());
      await test();
      // 首次同步或换回旧目录时，本机没有 lastSync；仍要检查云端属于本机的旧快照，不能直接覆盖成「新」数据。
      if (lastSync == 0) {
        final own = await dio.get('${_dir()}$deviceId.json', options: Options(responseType: ResponseType.plain));
        if (own.statusCode != 404) {
          _ok(own, '检查本机快照');
          final previous = jsonDecode(own.data as String) as Map<String, dynamic>;
          validateSyncSnapshot(previous);
          if (previous['device'] != deviceId) throw const FormatException('同步目录中的本机快照设备编号不匹配');
          final at = previous['at'];
          if (at is! int) throw const FormatException('云端本机快照缺少时间，无法确认是否过期，请先备份并使用新的同步文件夹');
          if (at < _tombCutoff) throw const LocalSyncExpiredException();
        }
      }
      await _pushAvatar(dio);
      final put = await dio.put('${_dir()}$deviceId.json', data: jsonEncode(snapshot()), options: Options(contentType: 'application/json; charset=utf-8'));
      _ok(put, '上传');
      final list = await dio.request(_dir(), options: Options(method: 'PROPFIND', headers: {'Depth': '1'}, responseType: ResponseType.plain));
      _ok(list, '读取目录');
      var merged = 0;
      final failed = <String>[];
      final stale = <String>[];
      for (final name in parseListing(list.data as String)) {
        if (name == '$deviceId.json') continue;
        // 一台设备的文件坏了（或者是认不得的格式）只跳过它，别的设备照样合并
        try {
          final r = await dio.get('${_dir()}${Uri.encodeComponent(name)}', options: Options(responseType: ResponseType.plain));
          _ok(r, '下载 $name');
          final remote = jsonDecode(r.data as String) as Map<String, dynamic>;
          validateSyncSnapshot(remote);
          if (remote['at'] case final num at when at < _tombCutoff) throw const StaleSnapshotException();
          await _pullAvatar(dio, remote);
          await merge(remote);
          merged++;
        } on StaleSnapshotException {
          stale.add(name);
        } catch (_) {
          failed.add(name);
        }
      }
      lastSkipped = stale;
      await _box.put('sync:last', DateTime.now().millisecondsSinceEpoch);
      if (failed.isNotEmpty) throw '已合并 $merged 台设备，这些文件读不了，跳过了：${failed.join('、')}';
      return merged;
    } finally {
      dio?.close();
      _running = false;
    }
  }

  /// [lastSkipped] 的说明，没有跳过的返回 null。
  static String? get skippedNote => lastSkipped.isEmpty
      ? null
      : '${lastSkipped.join('、')} 超过 $_tombDays 天没同步，没有合并（合并会把那之后删掉的内容加回来）。这台设备不用了的话，可以在网盘里删掉这个文件';

  /// 自动同步用：没配置、正在同步、距上次不到 [minGap] 就跳过；出错不打扰用户。
  static Future<void> auto({Duration minGap = const Duration(minutes: 3)}) async {
    if (!configured || _running || DateTime.now().millisecondsSinceEpoch - lastSync < minGap.inMilliseconds) return;
    try {
      await run();
    } catch (_) {}
  }
}

/// 本机长期离线时，不把旧数据重新标成最新后上传；继续保留本机和云端原文件。
class LocalSyncExpiredException implements Exception {
  const LocalSyncExpiredException();

  @override
  String toString() => '本机超过 90 天没同步，已停止上传，避免让其他设备删过的数据复活。请先导出完整备份；如需保留并合并本机旧数据，请使用新的同步文件夹，并让其他设备也切换到该文件夹。';
}

/// 快照超过 90 天没更新：那之前的墓碑已经清掉，合并会让删掉的东西复活，所以不合并。
class StaleSnapshotException implements Exception {
  const StaleSnapshotException();

  @override
  String toString() => '这份数据超过 90 天没有更新，合并会把那之后删掉的书、书签加回来，所以没有合并';
}

/// 同步页用：手动同步的状态，同步完成后让用到统计的界面重新读取。
class SyncStatus {
  const SyncStatus({this.busy = false, this.message});

  final bool busy;
  final String? message;
}

class SyncController extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => const SyncStatus();

  void refreshProviders() {
    ref.invalidate(libraryProvider);
    ref.invalidate(updateProvider);
    ref.invalidate(avatarProvider);
    ref.invalidate(appPrefsProvider);
    ref.invalidate(readerPrefsProvider);
    ref.invalidate(themeModeProvider);
    ref.invalidate(paletteProvider);
  }

  Future<void> run() async {
    if (state.busy) return;
    state = const SyncStatus(busy: true);
    try {
      final n = await Sync.run();
      final done = n == 0 ? '已同步（还没有别的设备的数据）' : '已同步，合并了 $n 台设备的数据';
      state = SyncStatus(message: [done, ?Sync.skippedNote].join('\n'));
    } catch (e) {
      state = SyncStatus(message: e is DioException ? '网络错误：${e.message ?? e.type.name}' : '$e');
    }
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
