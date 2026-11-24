import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/cat_volume.dart';
import 'cache.dart';
import 'local_books.dart' show LocalBooks, isLocalAid;
import 'progress.dart';
import 'read_state.dart';
import 'stats.dart';
import 'sync.dart';

/// 目录里的一卷：卷名、章节 cid（按顺序）、插图章节的 cid（没有为 null）。
class Vol {
  const Vol(this.title, this.cids, this.illus);

  factory Vol.from(CatVolume v) => Vol(v.title, [for (final c in v.chapters) c.cid], v.chapters.where((c) => isIllustration(c.title)).firstOrNull?.cid);

  final String title;
  final List<String> cids;
  final String? illus;

  /// 判断读完用的章节：不算插图章（只有图，很多人会跳过）
  Iterable<String> get textCids => cids.where((c) => c != illus);
}

bool isIllustration(String title) => title.contains('插图') || title.contains('插圖') || title.contains('插画') || title.contains('插畫');

/// 分卷数据，全部存在本机（不用每次都请求网页）：
/// - `vols:aid` 卷列表（目录加载时记下，书架、报告页同步就能用）
/// - `vcover2:aid` 卷名 → 封面地址（插图章节里第一张竖着的图，见 `chooseCover`；'' 表示这卷没有插图）
///   （`vcover:` 是旧版直接取第一张图的记录，作废不用）
/// - `vdone:aid` 卷名 → 读完的时间（毫秒）
/// - `vrate:aid` 卷名 → 星级
class Volumes {
  Volumes._();

  static Box get _box => Hive.box('session');

  /// 卷封面、读完状态变了：书架、书籍墙、报告页据此刷新
  static final changes = ValueNotifier<int>(0);
  static final _aidNotifiers = <String, _AidVolumeNotifier>{};
  static bool _inSingleNotify = false;
  static bool _globalBridgeAttached = false;

  static void _ensureGlobalBridge() {
    if (_globalBridgeAttached) return;
    _globalBridgeAttached = true;
    changes.addListener(_onGlobalChange);
  }

  static void _onGlobalChange() {
    if (_inSingleNotify) return;
    for (final n in _aidNotifiers.values.toList()) {
      n.value++;
    }
  }

  /// 按书号获取局部卷数据变更通知器（仅该书变更或全局广播时递增）。
  static ValueNotifier<int> notifierFor(String aid) {
    _ensureGlobalBridge();
    return _aidNotifiers.putIfAbsent(aid, _AidVolumeNotifier.new);
  }

  static void _releaseNotifierIfUnused(String aid) {
    final n = _aidNotifiers[aid];
    if (n != null && !n.active) {
      _aidNotifiers.remove(aid);
      n.dispose();
    }
  }

  /// 通知单本书的卷数据（封面、读完、评分等）发生变化：只刷新该书局部订阅者并同步递增全局 [changes]。
  static void notifyAid(String aid) {
    _aidNotifiers[aid]?.value++;
    _inSingleNotify = true;
    try {
      changes.value++;
    } finally {
      _inSingleNotify = false;
    }
  }

  // 参照 ReadState._sets：Hive 底层对象未换（identical）时复用只读视图，避免书架/3D/翻页高频重复反序列化。
  static final _volsCache = <String, (List, List<Vol>)>{};
  static final _coversCache = <String, (Map, Map<String, String>)>{};
  static final _doneCache = <String, (Map, Map<String, int>)>{};

  static List<Vol> of(String aid) {
    final raw = _box.get('vols:$aid') as List?;
    if (raw == null) {
      _volsCache.remove(aid);
      return const [];
    }
    final hit = _volsCache[aid];
    if (hit != null && identical(hit.$1, raw)) return hit.$2;
    final list = List<Vol>.unmodifiable([
      for (final m in raw.cast<Map>()) Vol(m['t'] as String, List<String>.unmodifiable((m['c'] as List).cast<String>()), m['i'] as String?),
    ]);
    _volsCache[aid] = (raw, list);
    return list;
  }

  /// 目录加载后记下卷列表，并顺带核对一遍哪些卷读完了。
  /// 若某卷原本没有插图章（或之前取封面时记成了空串 `''` / Bangumi 兜底），后来更新补上了插图章，
  /// 自动清掉非手动挑选的旧封面记录与插图章缓存，让封面队列重新去取真正的卷插图。
  static Future<void> saveCatalogue(String aid, List<CatVolume> cat) async {
    final old = of(aid);
    final oldIllus = {for (final v in old) v.title: v.illus};
    final next = [
      for (final v in cat)
        {'t': v.title, 'c': [for (final c in v.chapters) c.cid], 'i': v.chapters.where((c) => isIllustration(c.title)).firstOrNull?.cid},
    ];
    if (!listEquals(
      next.map((e) => '${e['t']}|${(e['c'] as List).join(',')}|${e['i']}').toList(),
      old.map((v) => '${v.title}|${v.cids.join(',')}|${v.illus}').toList(),
    )) {
      await _box.put('vols:$aid', next);
    }
    final coversMap = covers(aid);
    if (coversMap.isNotEmpty) {
      final picked = _picked(aid);
      final updated = {...coversMap};
      final staleCids = <String>[];
      for (final e in next) {
        final title = e['t'] as String;
        final illus = e['i'] as String?;
        final saved = coversMap[title];
        if (illus == null || saved == null) continue;
        final manual = picked.contains(title) || saved.contains('#crop=');
        if (manual) continue;
        // 插图章变了（比如后来才补上）：清掉旧记录重新抓取。记成 '' 而插图章没变的，由 [VolumeCoverQueue.get] 每次运行重试一次
        if (old.isNotEmpty && oldIllus[title] != illus) {
          updated.remove(title);
          staleCids.add(illus);
        }
      }
      if (updated.length != coversMap.length) {
        await _box.put('vcover2:$aid', updated);
        if (staleCids.isNotEmpty && Hive.isBoxOpen('chapter_index')) {
          await ChapterCache.removeChapters(aid, staleCids, compact: false);
        }
        notifyAid(aid);
      }
    }
    await refreshDone(aid);
  }

  /// [cid] 在第几卷，找不到为 -1。
  static int indexOf(String aid, String cid) => of(aid).indexWhere((v) => v.cids.contains(cid));

  // ---- 封面 ----

  /// 这本书的卷封面只读视图（按 Hive 引用缓存，调用方勿修改）。
  static Map<String, String> covers(String aid) {
    final raw = _box.get('vcover2:$aid') as Map?;
    if (raw == null) {
      _coversCache.remove(aid);
      return const {};
    }
    final hit = _coversCache[aid];
    if (hit != null && identical(hit.$1, raw)) return hit.$2;
    final map = Map<String, String>.unmodifiable({for (final e in raw.entries) e.key as String: e.value as String});
    _coversCache[aid] = (raw, map);
    return map;
  }

  /// 这卷的封面：null 还没取过，'' 这卷没有插图。
  static String? cover(String aid, String title) => covers(aid)[title];

  /// 手动挑过封面的卷（标题）
  static Set<String> _picked(String aid) => ((_box.get('vpick:$aid') as List?) ?? const []).cast<String>().toSet();

  /// [url] 可以带裁剪框（见 [withCrop]），自选封面就是这样存的；[picked] 是手动挑的，图片缓存清理时一直留着
  static Future<void> setCover(String aid, String title, String url, {bool picked = false}) async {
    await _box.put('vcover2:$aid', {...covers(aid), title: url});
    if (picked) {
      await _box.put('vpick:$aid', (_picked(aid)..add(title)).toList());
      await _box.put('vpickTs:$aid', {...((_box.get('vpickTs:$aid') as Map?) ?? const {}), title: DateTime.now().millisecondsSinceEpoch});
    }
    notifyAid(aid);
  }

  /// 一次记好几卷的封面（只发一次变化通知）
  static Future<void> setCovers(String aid, Map<String, String> next) async {
    if (next.isEmpty) return;
    await _box.put('vcover2:$aid', {...covers(aid), ...next});
    notifyAid(aid);
  }

  /// 忘掉这本书所有卷的封面记录（没加入书架的书退出详情页时）
  static Future<void> forgetCovers(String aid) async {
    await _box.delete('vcover2:$aid');
    await _box.delete('vpick:$aid');
    notifyAid(aid);
  }

  /// 去掉自选的封面，下次显示时重新自动挑（同时清掉该卷插图章的本地缓存，以便重新联网抓取最新插图）
  static Future<void> resetCover(String aid, String title) async {
    await _box.put('vcover2:$aid', {...covers(aid)}..remove(title));
    await _box.put('vpick:$aid', (_picked(aid)..remove(title)).toList());
    await Sync.tombstone(['vcover:$aid:$title']);
    final illus = of(aid).where((v) => v.title == title).firstOrNull?.illus;
    if (illus != null && Hive.isBoxOpen('chapter_index')) {
      await ChapterCache.removeChapters(aid, [illus], compact: false);
    }
    notifyAid(aid);
  }

  /// 图片缓存清理时要留着的卷封面：书架上这些书显示的那张（第一卷），加上所有手动挑过的
  static Iterable<String> keptCovers(Iterable<String> shelf) => {
    for (final aid in shelf)
      if (of(aid).firstOrNull case final v?) ?cover(aid, v.title),
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vpick:')))
      for (final title in _picked(k.substring(6))) ?cover(k.substring(6), title),
    // 有这个标记之前手动裁过的：带裁剪框的一定是手动挑的
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vcover2:')))
      ...(_box.get(k) as Map).values.cast<String>().where((e) => e.contains('#crop=')),
  }.where((e) => e.isNotEmpty);

  // ---- 读完 ----

  static Map<String, int> done(String aid) {
    final raw = _box.get('vdone:$aid') as Map?;
    if (raw == null) {
      _doneCache.remove(aid);
      return const {};
    }
    final hit = _doneCache[aid];
    if (hit != null && identical(hit.$1, raw)) return hit.$2;
    final map = Map<String, int>.unmodifiable({for (final e in raw.entries) e.key as String: e.value as int});
    _doneCache[aid] = (raw, map);
    return map;
  }

  /// 按已读章节核对每卷：正文章节全读了就记下读完时间，不再全读（标回未读）就去掉。
  /// 第一次核对这本书时（以前读完的卷没有日期），用最后一次阅读的时间代替。
  static Future<void> refreshDone(String aid) async {
    final vols = of(aid);
    if (vols.isEmpty) return;
    final first = !_box.containsKey('vdone:$aid');
    final last = ReadingProgress.lastRead(aid);
    final now = first && last > 0 ? last : DateTime.now().millisecondsSinceEpoch;
    final read = ReadState.readView(aid);
    final old = done(aid);
    final next = <String, int>{
      for (final v in vols)
        if (v.textCids.isNotEmpty && v.textCids.every(read.contains)) v.title: old[v.title] ?? now,
    };
    if (first || !mapEquals(old, next)) {
      await _box.put('vdone:$aid', next);
      notifyAid(aid);
    }
  }

  /// 所有读完的卷：(aid, 卷序号, 卷, 读完时间)，新的在前。书籍墙用。
  static List<(String, int, Vol, int)> allDone() {
    final out = <(String, int, Vol, int)>[];
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith('vdone:'))) {
      final aid = k.substring(6);
      final vols = of(aid);
      for (final e in done(aid).entries) {
        final i = vols.indexWhere((v) => v.title == e.key);
        if (i >= 0) out.add((aid, i, vols[i], e.value));
      }
    }
    return out..sort((a, b) => b.$4.compareTo(a.$4));
  }

  // ---- 评分 ----

  static int rating(String aid, String title) => ((_box.get('vrate:$aid') as Map?)?[title] as int?) ?? 0;

  static Future<void> setRating(String aid, String title, int stars) async {
    await _box.putAll({
      'vrate:$aid': {...((_box.get('vrate:$aid') as Map?) ?? const {}), title: stars},
      'vrateTs:$aid': {...((_box.get('vrateTs:$aid') as Map?) ?? const {}), title: DateTime.now().millisecondsSinceEpoch},
    });
    notifyAid(aid);
  }

  // ---- 统计 ----

  /// 这卷读了多少秒、哪些天读过（按章记录的时间，这个功能上线之后才有）。
  static ({int seconds, List<String> days}) time(String aid, Vol v) {
    final ch = ReadingStats.chapterSeconds(aid);
    var seconds = 0;
    final days = <String>{};
    for (final c in v.cids) {
      for (final e in (ch[c] ?? const <String, int>{}).entries) {
        seconds += e.value;
        days.add(e.key);
      }
    }
    return (seconds: seconds, days: days.toList()..sort());
  }

  /// 这卷读过的字数：读过、而且缓存过（读过的章节都会自动缓存）的章节字数之和。
  static int readChars(String aid, Vol v) {
    final read = ReadState.readView(aid);
    final local = isLocalAid(aid);
    return v.cids.where(read.contains).fold(0, (a, c) => a + ((local ? LocalBooks.chapterLength(aid, c) : ChapterCache.length(aid, c)) ?? 0));
  }
}

class _AidVolumeNotifier extends ValueNotifier<int> {
  _AidVolumeNotifier() : super(0);

  bool get active => hasListeners;
}

/// 卷数据变了就重建（书籍墙、统计等全局视图）
final volumeChangesProvider = Provider<int>((ref) {
  void listener() => ref.invalidateSelf();
  Volumes.changes.addListener(listener);
  ref.onDispose(() => Volumes.changes.removeListener(listener));
  return Volumes.changes.value;
});

/// 按书号细粒度订阅卷数据变化（封面、读完状态等）：单本书变更只刷新对应书卡片，不重建整个书架。
final volumeChangeForProvider = Provider.autoDispose.family<int, String>((ref, aid) {
  final notifier = Volumes.notifierFor(aid);
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() {
    notifier.removeListener(listener);
    Volumes._releaseNotifierIfUnused(aid);
  });
  return notifier.value;
});
