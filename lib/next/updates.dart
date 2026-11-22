import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_client.dart';
import 'app_prefs.dart';
import 'data.dart';
import 'library.dart';
import 'net_state.dart';
import 'progress.dart';
import 'read_state.dart';
import 'session.dart' show friendlyError;
import 'volumes.dart';

class UpdateEntry {
  const UpdateEntry({required this.aid, required this.title, required this.img, required this.chapter, required this.cid, required this.time});

  final String aid;
  final String title;
  final String img;
  final String chapter;
  final String cid;
  final DateTime time;
}

/// 书架更新追踪：对比每本书上次看到的目录，新增的章节记入"更新"列表。
class UpdateStore {
  UpdateStore._();

  static Box get _box => Hive.box('session');

  static List<UpdateEntry> feed() => ((_box.get('updates') as List?) ?? const []).cast<Map>().map((e) {
    return UpdateEntry(aid: e['aid'] as String, title: e['title'] as String, img: e['img'] as String, chapter: e['chapter'] as String, cid: e['cid'] as String, time: DateTime.fromMillisecondsSinceEpoch(e['time'] as int));
  }).toList();

  static int get lastCheck => (_box.get('updates:check') as int?) ?? 0;

  /// 上次打开"更新"页的时间，比它新的条目显示为未读。
  static int get lastSeen => (_box.get('updates:seen') as int?) ?? 0;

  static Future<void> markSeen() => _box.put('updates:seen', DateTime.now().millisecondsSinceEpoch);

  static int unread() => feed().where((e) => e.time.millisecondsSinceEpoch > lastSeen).length;

  /// 这本书最近一次发现更新的时间（毫秒），没有为 0。
  static int updatedAt(String aid) => (_box.get('updates:at:$aid') as int?) ?? 0;

  static Map get _known => (_box.get('updates:known') as Map?) ?? {};

  static Future<void> save(Map<String, int> known, List<Map> feed, {required Map<String, int> at}) async {
    await _box.put('updates:known', known);
    await _box.put('updates', feed.take(300).toList());
    await _box.put('updates:check', DateTime.now().millisecondsSinceEpoch);
    for (final e in at.entries) {
      await _box.put('updates:at:${e.key}', e.value);
    }
  }

  /// 只存基准，不算检查完成。
  static Future<void> saveBaseline(Map<String, int> known) => _box.put('updates:known', known);

  static Map<String, int> knownCounts() => _known.map((k, v) => MapEntry(k as String, v as int));

  /// 上次检查时这本书的总章数（书架每本书都要查，不复制整张表）
  static int known(String aid) => (_known[aid] as int?) ?? 0;

  /// 打开详情页或分卷页拿到最新目录时顺手刷新这本书的已知总章数，避免读完最新章回到书架仍挂着旧未读角标。
  static Future<void> noteKnownCount(String aid, int count) async {
    if (!LibraryStore.contains(aid) || count <= 0 || known(aid) == count) return;
    final next = knownCounts()..[aid] = count;
    await _box.put('updates:known', next);
  }
}

class UpdateProgress {
  const UpdateProgress({this.done = 0, this.total = 0, this.running = false, this.error});

  final int done;
  final int total;
  final bool running;
  final String? error;
}

class UpdateController extends Notifier<UpdateProgress> {
  @override
  UpdateProgress build() => const UpdateProgress();

  /// 自动检查是否该跑了：设了"不自动"、没到间隔、不在 Wi-Fi / 没充电（设置里勾了限制时）都不跑。手动检查不受这些限制。
  Future<bool> _autoAllowed() async {
    final hours = AppPrefs.read(P.updInterval, 1);
    if (hours == 0) return false;
    if (UpdateStore.lastCheck != 0 && DateTime.now().millisecondsSinceEpoch - UpdateStore.lastCheck < hours * 3600 * 1000) return false;
    if (kIsWeb) return true;
    try {
      if (AppPrefs.read(P.updWifi, false) && !await onWifi()) return false;
      if (AppPrefs.read(P.updCharging, false)) {
        final b = await Battery().batteryState;
        if (b != BatteryState.charging && b != BatteryState.full) return false;
      }
    } catch (_) {} // 查不出来就当满足，别让更新一直不跑
    return true;
  }

  /// 设置里"只更新哪些书"的条件：跳过已完结 / 没开始读 / 还有未读的，以及只更新 / 不更新某些分类（[only] 指定书时不看分类）。
  bool _wanted(LibBook b, Map<String, int> known) {
    if (AppPrefs.read(P.updSkipDone, false) && b.done) return false;
    final read = ReadState.read(b.aid);
    final started = ReadingProgress.of(b.aid) != null || read.isNotEmpty;
    if (AppPrefs.read(P.updSkipNotStarted, false) && !started) return false;
    final total = known[b.aid] ?? 0;
    if (AppPrefs.read(P.updSkipUnread, false) && total > 0) {
      final vols = Volumes.of(b.aid);
      final hasUnread = vols.isNotEmpty ? vols.expand((v) => v.textCids).any((c) => !read.contains(c)) : total - read.length > 0;
      if (hasUnread) return false;
    }
    return true;
  }

  bool _catOk(LibBook b) {
    final include = AppPrefs.readList(P.updInclude);
    final exclude = AppPrefs.readList(P.updExclude);
    if (include.isNotEmpty && !b.cats.any(include.contains)) return false;
    return !b.cats.any(exclude.contains);
  }

  /// 检查本地书架里的书。第一次只记录当前章节数作为基准，不产生更新。
  /// [force] 为 false 是自动检查（要看间隔和网络限制）；[only] 只检查这几本（检查某个分类）。
  Future<void> refresh({bool force = true, Set<String>? only}) async {
    if (state.running) return;
    if (!force && !await _autoAllowed()) return;
    final api = ref.read(apiProvider);
    state = const UpdateProgress(running: true);
    try {
      final all = ref.read(libraryProvider).books.values.toList();
      final known = UpdateStore.knownCounts();
      final firstRun = UpdateStore.lastCheck == 0; // 第一次要查全部的书，中途关掉下次接着查
      final books = {
        for (final b in all)
          if ((only == null ? _catOk(b) && !(firstRun && known.containsKey(b.aid)) : only.contains(b.aid)) && _wanted(b, known)) b.aid: (title: b.title, img: b.img),
      };
      final feed = UpdateStore.feed().map((e) => {'aid': e.aid, 'title': e.title, 'img': e.img, 'chapter': e.chapter, 'cid': e.cid, 'time': e.time.millisecondsSinceEpoch}).toList();
      final at = <String, int>{};
      final fresh = <Map>[];
      var done = 0;
      var succeeded = 0;
      Object? lastErr;
      state = UpdateProgress(running: true, total: books.length);
      // 请求的节奏由 Wenku8Client 统一管，这里每 4 本存一次进度；单本失败不影响其他
      final entries = books.entries.toList();
      for (var i = 0; i < entries.length; i += 4) {
        final batch = entries.skip(i).take(4);
        final results = await Future.wait(batch.map((e) async {
          try {
            final cat = await runInBackground(() => api.catalogue(e.key));
            await Volumes.saveCatalogue(e.key, cat);
            return cat.expand((v) => v.chapters).toList();
          } catch (err) {
            lastErr = err;
            return null;
          }
        }));
        for (final (j, e) in batch.indexed) {
          final chapters = results[j];
          if (chapters == null) continue;
          succeeded++;
          final before = known[e.key];
          if (before != null && chapters.length > before) {
            final now = DateTime.now().millisecondsSinceEpoch;
            for (final c in chapters.skip(before)) {
              fresh.add({'aid': e.key, 'title': e.value.title, 'img': e.value.img, 'chapter': c.title, 'cid': c.cid, 'time': now});
            }
            at[e.key] = now;
          }
          known[e.key] = chapters.length;
        }
        if (firstRun && succeeded > 0) await UpdateStore.saveBaseline(known);
        done += batch.length;
        state = UpdateProgress(running: true, done: done, total: books.length);
      }
      if (books.isNotEmpty && succeeded == 0 && lastErr != null) {
        state = UpdateProgress(done: done, total: books.length, error: '检查更新失败：${friendlyError(lastErr!)}');
        return;
      }
      final inLibrary = all.map((b) => b.aid).toSet();
      known.removeWhere((aid, _) => !inLibrary.contains(aid)); // 被跳过的书留着基准，只去掉已不在书架的
      await UpdateStore.save(known, [...fresh.reversed, ...feed], at: at);
      state = UpdateProgress(done: done, total: books.length);
    } catch (e) {
      state = UpdateProgress(error: friendlyError(e));
    }
  }
}

final updateProvider = NotifierProvider<UpdateController, UpdateProgress>(UpdateController.new);
