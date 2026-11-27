import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, compute, debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import 'app_prefs.dart';
import 'avatar.dart';
import 'diag_log.dart';
import 'incognito.dart';
import 'library.dart';
import 'meta_cache.dart';
import 'pages/bookshelf_page.dart' show shelfOptionsProvider;
import 'reader/reader_bg.dart' show readerBgImageProvider;
import 'session.dart' show sharedHttpAdapterProvider;
import 'settings.dart';
import 'swipe.dart';
import 'sync_merge.dart';
import 'sync_validation.dart';
import 'updates.dart';
import 'webdav_client.dart';

export 'sync_merge.dart' show LocalSyncExpiredException, StaleSnapshotException;
export 'webdav_client.dart' show SyncException, WebDavClient, WebDavFileEntry;

const _jsonComputeThreshold = 64 * 1024;
const _etagMetaKey = 'sync_meta:etags';

dynamic _decodeJsonDynamic(String text) => jsonDecode(text);

String _fnvPairHash(String text) {
  final bytes = utf8.encode(text);
  String hash(int seed) {
    var h = seed;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  return '${bytes.length}:${hash(0x811c9dc5)}${hash(0x9747b28c)}';
}

({String json, String fingerprint}) _encodeSnapshotTask(Map<String, dynamic> snap) {
  final at = snap['at'];
  final withoutAt = Map<String, dynamic>.of(snap)..remove('at');
  final body = jsonEncode(withoutAt);
  final fp = _fnvPairHash(body);
  final json = (at is int && body.startsWith('{'))
      ? (body == '{}' ? '{"at":$at}' : '{"at":$at,${body.substring(1)}')
      : jsonEncode(snap);
  return (json: json, fingerprint: fp);
}

bool _looksLargeSnapshot(Map<String, dynamic> snap) {
  var score = 0;
  void addCollection(Object? v) {
    if (v is Map) {
      score += v.length;
    } else if (v is List) {
      score += v.length;
    }
  }

  for (final k in const ['progress', 'history', 'bookmarks', 'highlights', 'read', 'books', 'vols', 'vcover', 'chars']) {
    addCollection(snap[k]);
    if (score >= 250) return true;
  }
  final upd = snap['updates'];
  if (upd is Map) {
    addCollection(upd['feed']);
    addCollection(upd['known']);
  }
  final stats = snap['stats'];
  if (stats is Map) {
    addCollection(stats['day']);
    addCollection(stats['book']);
    addCollection(stats['ch']);
  }
  return score >= 250;
}

/// 同步：每台设备把自己的数据整份写成 `<文件夹>/<设备ID>.json` 放到 WebDAV（坚果云），
/// 同步时读取其他设备的文件，按下面的规则并入本机。不依赖服务端，只要能 GET / PUT / PROPFIND。
///
/// 合并规则（都是幂等的，重复同步不会翻倍），核心实现见 [SyncMerge]，WebDAV 传输见 [WebDavClient]：
/// - 阅读进度：按时间，新的赢
/// - 阅读历史：每本书取最近一次；书签：同一章 40 字以内视为同一个，取较新的；规则：按编号并集，本机优先
/// - 已读章节：并集；已读字数、评分：取较大 / 本机没有才用对方的；备注：并集，本机优先
/// - 书签、规则的删除靠"墓碑"同步（编号 → 删除时间，留 90 天）；规则的修改按修改时间，新的赢
/// - 阅读统计：其他设备的统计**单独存放**，显示时和本机相加，所以两边同时读也不会互相覆盖
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
      } catch (e) {
        debugPrint('读取旧钥匙串同步密码失败：$e');
        return '';
      }
    }
    try {
      final p = await _secure.read(key: 'syncPass');
      if (p != null) return p;
    } catch (e) {
      debugPrint('读取安全存储同步密码失败：$e');
    }
    return (_box.get('sync:pass') as String?) ?? '';
  }

  static Future<void> save({required String url, required String user, required String pass, required String folder}) async {
    final nextFolder = folder.trim().isEmpty ? defaultFolder : folder.trim();
    final changed = url.trim().replaceFirst(RegExp(r'/+$'), '') != Sync.url.replaceFirst(RegExp(r'/+$'), '') || user.trim() != Sync.user || nextFolder != Sync.folder;
    await _box.putAll({'sync:url': url.trim(), 'sync:user': user.trim(), 'sync:folder': nextFolder});
    if (changed) {
      await _box.deleteAll(['sync:last', 'sync:avatarUp']); // 新目录没有旧目录的同步基准或头像
      _clearRemoteMetaCache();
      await MetaCache.deleteMetaOnly(_etagMetaKey);
    }
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

  /// [time] 时的 [key] 是否已被删除（有不早于它的墓碑）。
  static bool isDeleted(String key, int time) => SyncMerge.isDeleted(key, time);

  /// 记下被删掉的东西（`b:书:章:偏移`、`r:规则编号`），同步时告诉其他设备也删掉。
  static Future<void> tombstone(Iterable<String> keys) => SyncMerge.tombstone(keys);

  static String bookmarkKey(Map b) => SyncMerge.bookmarkKey(b);

  static String get deviceId {
    var id = _box.get('sync:device') as String?;
    if (id == null) {
      id = 'd${Random.secure().nextInt(1 << 32).toRadixString(36)}${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      _box.put('sync:device', id);
    }
    return id;
  }

  /// 本机要同步的数据（不含从别的设备并入的统计）。
  static Map<String, dynamic> snapshot() => SyncMerge.snapshot(deviceId);

  /// 从别的设备（[device]）的备份恢复后：恢复来的阅读统计是那台设备的，改记到它名下（和同步来的统计放一起）。
  static Future<void> adoptLocalStatsAs(String device) => SyncMerge.adoptLocalStatsAs(device);

  /// 跨设备恢复备份回原设备 [own] 时：若备份里带有原设备之前同步出去的 `sync:stats:$own`，还原回本机 `stats:*`。
  static Future<void> restoreOwnStatsFromSynced(String own) => SyncMerge.restoreOwnStatsFromSynced(own);

  /// 把 [remote]（别的设备的快照，已解码的 JSON）按规则并入本机；无实质变更返回 false。
  static Future<bool> merge(Map<String, dynamic> remote) async {
    final merged = await SyncMerge.merge(remote, deviceId: deviceId);
    if (merged) changes.value++;
    return merged;
  }

  /// 删掉一本书的统计：记下墓碑，已经同步来的其他设备的统计也去掉。
  static Future<void> forgetBookStats(String aid) => SyncMerge.forgetBookStats(aid);

  /// 其他设备的统计（设备 → 内容），统计页把它们加到本机数据上。
  static Iterable<Map<String, dynamic>> otherStats() => SyncMerge.otherStats();

  /// 导入备份文件（别的设备或本机导出的快照）：规则同同步；返回 false 表示这是本机自己导出的。
  static Future<bool> importBackup(String json) async {
    if (_running) throw const SyncException('正在同步，请稍候');
    final decoded = await _decodeJsonAsync(json);
    if (decoded is! Map<String, dynamic>) throw const FormatException('同步文件格式无效');
    return importDecodedBackup(decoded);
  }

  /// 导入已解码的备份快照，避免调用方重复 `jsonDecode`。
  static Future<bool> importDecodedBackup(Map<String, dynamic> decoded) async {
    if (_running) throw const SyncException('正在同步，请稍候');
    if (decoded['device'] == deviceId) return false;
    await merge(decoded);
    return true;
  }

  static Future<dynamic> _decodeJsonAsync(String text) =>
      !kIsWeb && text.length > _jsonComputeThreshold ? compute(_decodeJsonDynamic, text) : Future.value(jsonDecode(text));

  static Future<({String json, String fingerprint})> _encodeSnapshotAsync(Map<String, dynamic> snap) =>
      !kIsWeb && _looksLargeSnapshot(snap) ? compute(_encodeSnapshotTask, snap) : Future.value(_encodeSnapshotTask(snap));

  // ---- WebDAV ----

  static ({String proxy, bool nativeNet, HttpClientAdapter adapter})? _cachedAdapter;
  static String? _remoteCacheScope;
  static final _remoteFingerprints = <String, String>{};
  static String? _lastUploadFingerprint;

  static void _clearRemoteMetaCache() {
    _remoteCacheScope = null;
    _remoteFingerprints.clear();
    _lastUploadFingerprint = null;
  }

  @visibleForTesting
  static void resetMemoryCache() {
    _clearRemoteMetaCache();
  }

  static String _currentScope() => '${url.replaceFirst(RegExp(r'/+$'), '')}|$user|$folder|$deviceId';

  static Future<void> _ensureRemoteMetaLoaded(String scope) async {
    if (_remoteCacheScope == scope) return;
    _remoteCacheScope = scope;
    _remoteFingerprints.clear();
    _lastUploadFingerprint = null;
    final stored = await MetaCache.getMetaOnlyMap(_etagMetaKey);
    if (stored != null && stored['scope'] == scope) {
      final files = stored['files'];
      if (files is Map) {
        for (final e in files.entries) {
          if (e.key is String && e.value is String) _remoteFingerprints[e.key as String] = e.value as String;
        }
      }
      final up = stored['uploadFp'];
      if (up is String && up.isNotEmpty) _lastUploadFingerprint = up;
    }
  }

  static Future<void> _persistRemoteMeta(String scope) async {
    await MetaCache.putMetaOnlyMap(_etagMetaKey, {
      'scope': scope,
      'files': Map<String, String>.of(_remoteFingerprints),
      if (_lastUploadFingerprint != null) 'uploadFp': _lastUploadFingerprint,
    });
  }

  static HttpClientAdapter? _reusableAdapter() {
    if (kIsWeb || !Hive.isBoxOpen('session')) return null;
    final box = Hive.box('session');
    final proxy = (box.get('proxy') as String?) ?? '';
    final nativeNet = (box.get('nativeNet') as bool?) ?? true;
    final cur = _cachedAdapter;
    if (cur != null && cur.proxy == proxy && cur.nativeNet == nativeNet) return cur.adapter;
    if (cur != null) {
      try {
        cur.adapter.close(force: false);
      } catch (_) {}
      _cachedAdapter = null;
    }
    final next = webDavAdapterFromSessionBox();
    if (next != null) _cachedAdapter = (proxy: proxy, nativeNet: nativeNet, adapter: next);
    return next;
  }

  /// 目录里所有 `*.json` 的文件名（PROPFIND 的返回里取 href）。
  static List<String> parseListing(String xml) => parseWebDavListing(xml);

  static Future<WebDavClient> _client({Dio? dio, HttpClientAdapter? adapter}) async => WebDavClient(
    baseUrl: url,
    folder: folder,
    user: user,
    password: dio == null ? await password() : '',
    dio: dio,
    adapter: dio != null ? null : (adapter ?? _reusableAdapter()),
  );

  static Future<void> _pushAvatar(WebDavClient client, {Map<String, dynamic>? avatar}) async {
    final a = avatar ?? await SyncMerge.avatarSnapshotAsync(deviceId);
    if (a == null || a['file'] == null || _box.get('sync:avatarUp') == a['ts']) return;
    final bytes = await File(_box.get('avatar') as String).readAsBytes();
    await client.putBytes(a['file'] as String, bytes, what: '上传头像');
    await _box.delete('sync:avatarFile');
    await _box.put('sync:avatarUp', a['ts']);
  }

  /// 对方的头像比本机新才下载，放进快照交给 [merge]；下载失败就当没变，下次再试。
  static Future<void> _pullAvatar(WebDavClient client, Map<String, dynamic> remote) async {
    final a = remote['avatar'];
    if (kIsWeb || !AppPrefs.read(P.syncAvatar, true) || a is! Map || a['file'] is! String) return;
    if (((a['ts'] as int?) ?? 0) <= ((_box.get('avatar:ts') as int?) ?? 0)) return;
    try {
      final bytes = await client.getBytes(p.basename(a['file'] as String), what: '下载头像');
      a['data'] = base64Encode(bytes);
    } catch (e) {
      debugPrint('下载同步头像失败：$e');
      remote.remove('avatar');
    }
  }

  /// 测试连接：目录不存在就逐级建出来。支持注入 [dio]（复用或单测）。
  static Future<void> test({Dio? dio, HttpClientAdapter? adapter}) async {
    final client = await _client(dio: dio, adapter: adapter);
    try {
      await client.ensureDirectory();
    } finally {
      client.close();
    }
  }

  static bool _running = false;

  /// 上次 [run] 时因为超过 90 天没更新而跳过的设备文件名。
  static List<String> lastSkipped = const [];

  /// 最近一次同步的诊断摘要（仅内存保存，供同步页排查用）。
  static ({int at, int merged, List<String> skipped, List<String> failed, String? error})? lastDiag;

  /// 本机待回放的书架离线操作数（`lib:ops`）与当前墓碑数，供同步诊断面板展示（纯只读，不在 build 期间触发写盘）。
  static ({String deviceId, int lastSync, int pendingOps, int tombCount}) localDiagnostics() {
    final ops = _box.get('lib:ops');
    final pendingOps = ops is Map ? ops.length : (ops is List ? ops.length : 0);
    final id = (_box.get('sync:device') as String?) ?? '';
    return (deviceId: id, lastSync: lastSync, pendingOps: pendingOps, tombCount: SyncMerge.tombs().length);
  }

  /// 仅拉取并合并其他设备快照（不上传本机）。
  static Future<int> pullOnly({Dio? dio, HttpClientAdapter? adapter}) => _execute(upload: false, pull: true, dio: dio, adapter: adapter);

  /// 仅上传本机当前快照（跳过拉取其他设备）。
  static Future<void> pushOnly({Dio? dio, HttpClientAdapter? adapter, bool skipUnchangedUpload = false}) async {
    await _execute(upload: true, pull: false, dio: dio, adapter: adapter, skipUnchangedUpload: skipUnchangedUpload);
  }

  /// 完整同步一次：单次复用同一个 [WebDavClient]/[Dio] 拉取合并其他设备快照（按 ETag/mtime 跳过未变文件），再按需上传本机最新快照。
  static Future<int> run({Dio? dio, HttpClientAdapter? adapter, bool skipUnchangedUpload = false}) =>
      _execute(upload: true, pull: true, dio: dio, adapter: adapter, skipUnchangedUpload: skipUnchangedUpload);

  static Future<int> _execute({
    required bool upload,
    required bool pull,
    Dio? dio,
    HttpClientAdapter? adapter,
    bool skipUnchangedUpload = false,
  }) async {
    if (_running) throw const SyncException('正在同步，请稍候');
    _running = true;
    WebDavClient? client;
    var merged = 0;
    final failed = <String>[];
    final stale = <String>[];
    try {
      if (upload && lastSync > 0 && lastSync < SyncMerge.tombCutoff) throw const LocalSyncExpiredException();
      final scope = _currentScope();
      await _ensureRemoteMetaLoaded(scope);
      client = await _client(dio: dio, adapter: adapter);
      List<WebDavFileEntry>? entries;
      if (pull) {
        entries = await client.listJsonFileEntries();
      } else {
        await client.ensureDirectory();
      }
      // 首次同步或换回旧目录时，本机没有 lastSync；仍要检查云端属于本机的旧快照，不能直接覆盖成「新」数据。
      if (upload && lastSync == 0) {
        final ownText = await client.getText('$deviceId.json', what: '检查本机快照', allowNotFound: true);
        if (ownText != null) {
          final previous = await _decodeJsonAsync(ownText) as Map<String, dynamic>;
          validateSyncSnapshot(previous);
          if (previous['device'] != deviceId) throw const FormatException('同步目录中的本机快照设备编号不匹配');
          final at = previous['at'];
          if (at is! int) throw const FormatException('云端本机快照缺少时间，无法确认是否过期，请先备份并使用新的同步文件夹');
          if (at < SyncMerge.tombCutoff) throw const LocalSyncExpiredException();
        }
      }
      var ownExistsRemotely = false;
      var metaDirty = false;
      if (pull && entries != null) {
        final liveNames = <String>{};
        for (final entry in entries) {
          final name = entry.name;
          if (name == '$deviceId.json') {
            ownExistsRemotely = true;
            continue;
          }
          liveNames.add(name);
          final fp = entry.fingerprint;
          if (fp != null && _remoteFingerprints[name] == fp) {
            continue;
          }
          // 一台设备的文件坏了（或者是认不得的格式）只跳过它，别的设备照样合并，并记录详细日志便于排查
          try {
            final text = await client.getText(name, what: '下载 $name');
            final remote = await _decodeJsonAsync(text!) as Map<String, dynamic>;
            validateSyncSnapshot(remote);
            if (remote['at'] case final num at when at < SyncMerge.tombCutoff) throw const StaleSnapshotException();
            await _pullAvatar(client, remote);
            await merge(remote);
            merged++;
            if (fp != null) {
              _remoteFingerprints[name] = fp;
              metaDirty = true;
            }
          } on StaleSnapshotException {
            stale.add(name);
          } catch (e, st) {
            debugPrint('同步合并 $name 失败：$e\n$st');
            DiagLog.record('sync.merge:$name', e, st);
            failed.add(name);
          }
        }
        final beforeLen = _remoteFingerprints.length;
        _remoteFingerprints.removeWhere((k, _) => !liveNames.contains(k));
        if (_remoteFingerprints.length != beforeLen) metaDirty = true;
      }
      if (upload) {
        final avatarSnap = await SyncMerge.avatarSnapshotAsync(deviceId);
        final avatarPending = avatarSnap != null && avatarSnap['file'] != null && _box.get('sync:avatarUp') != avatarSnap['ts'];
        if (avatarPending) {
          await _pushAvatar(client, avatar: avatarSnap);
        }
        final snap = await SyncMerge.snapshotAsync(deviceId);
        final encoded = await _encodeSnapshotAsync(snap);
        final canSkipPut = skipUnchangedUpload &&
            lastSync > 0 &&
            ownExistsRemotely &&
            !avatarPending &&
            _lastUploadFingerprint != null &&
            _lastUploadFingerprint == encoded.fingerprint;
        if (!canSkipPut) {
          await client.putJson('$deviceId.json', encoded.json);
          _lastUploadFingerprint = encoded.fingerprint;
          metaDirty = true;
        }
      }
      if (metaDirty) await _persistRemoteMeta(scope);
      lastSkipped = stale;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (upload) await _box.put('sync:last', now);
      lastDiag = (at: now, merged: merged, skipped: List.unmodifiable(stale), failed: List.unmodifiable(failed), error: null);
      if (failed.isNotEmpty) throw SyncException('已合并 $merged 台设备，这些文件读不了，跳过了：${failed.join('、')}');
      return merged;
    } catch (e, st) {
      DiagLog.record('sync', e, st);
      lastDiag = (at: DateTime.now().millisecondsSinceEpoch, merged: merged, skipped: List.unmodifiable(stale), failed: List.unmodifiable(failed), error: '$e');
      rethrow;
    } finally {
      client?.close();
      _running = false;
    }
  }

  /// [lastSkipped] 的说明，没有跳过的返回 null。
  static String? get skippedNote => lastSkipped.isEmpty
      ? null
      : '${lastSkipped.join('、')} 超过 ${SyncMerge.tombDays} 天没同步，没有合并（合并会把那之后删掉的内容加回来）。这台设备不用了的话，可以在网盘里删掉这个文件';

  /// 自动同步用：没配置、正在同步、距上次不到 [minGap]（默认 10 分钟）就跳过；无实质变化时跳过冗余 PUT；出错不打扰用户。
  static Future<void> auto({Duration minGap = const Duration(minutes: 10), HttpClientAdapter? adapter}) async {
    if (!configured || _running || DateTime.now().millisecondsSinceEpoch - lastSync < minGap.inMilliseconds) return;
    try {
      await run(adapter: adapter, skipUnchangedUpload: true);
    } catch (e) {
      debugPrint('自动同步失败：$e');
    }
  }
}

void _invalidateSynced(void Function(NotifierProvider<dynamic, dynamic> provider) invalidate) {
  invalidate(libraryProvider);
  invalidate(shelfOptionsProvider);
  invalidate(updateProvider);
  invalidate(avatarProvider);
  invalidate(readerBgImageProvider);
  invalidate(appPrefsProvider);
  invalidate(readerPrefsProvider);
  invalidate(swipePrefsProvider);
  invalidate(themeModeProvider);
  invalidate(paletteProvider);
  invalidate(incognitoProvider);
}

/// 同步或 JSON 备份恢复后统一刷新全部关联 Provider；支持传入 [Ref]、[WidgetRef] 或 [ProviderContainer]。
void refreshAllSyncedProviders(Object ref) {
  if (ref is Ref) {
    _invalidateSynced(ref.invalidate);
  } else if (ref is WidgetRef) {
    _invalidateSynced(ref.invalidate);
  } else if (ref is ProviderContainer) {
    _invalidateSynced(ref.invalidate);
  } else {
    throw ArgumentError.value(ref, 'ref', 'Expected Ref, WidgetRef, or ProviderContainer');
  }
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

  void refreshProviders() => refreshAllSyncedProviders(ref);

  Future<void> run() async {
    if (state.busy) return;
    state = const SyncStatus(busy: true);
    try {
      HttpClientAdapter? shared;
      try {
        shared = ref.read(sharedHttpAdapterProvider);
      } catch (_) {}
      final n = await Sync.run(adapter: shared);
      final done = n == 0 ? '已同步（还没有别的设备的数据）' : '已同步，合并了 $n 台设备的数据';
      state = SyncStatus(message: [done, ?Sync.skippedNote].join('\n'));
    } catch (e) {
      final raw = e is FormatException ? e.message : (e is StateError ? e.message : '$e');
      state = SyncStatus(message: e is DioException ? '网络连接失败，请检查 WebDAV 地址或网络状态' : raw);
    }
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
