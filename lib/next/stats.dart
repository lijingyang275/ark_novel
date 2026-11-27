import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'cache.dart';
import 'incognito.dart';
import 'library.dart';
import 'sync.dart';

/// 阅读统计：按天和按书累计阅读秒数，以及读过的章节数（同一章同一天只算一次）。
class ReadingStats {
  ReadingStats._();

  static Box get _box => Hive.box('session');

  /// 统计数据变化通知（避免页面用定时器轮询）。
  static final changes = ValueNotifier<int>(0);

  /// 统一的时长格式化：避免 59分01秒~59分59秒 因 ceil 显示成「60 分钟」。
  /// [compact] 为 true 时用于个人页简短展示（如 `1.5 小时` / `12 分钟`）。
  static String formatDuration(int seconds, {bool compact = false}) {
    if (seconds <= 0) return '0 分钟';
    if (compact && seconds >= 3600) {
      return '${(seconds / 3600).toStringAsFixed(seconds >= 36000 ? 0 : 1)} 小时';
    }
    final totalMinutes = (seconds + 59) ~/ 60;
    if (totalMinutes >= 60) {
      final h = totalMinutes ~/ 60;
      final m = totalMinutes % 60;
      return compact ? '${(seconds / 3600).toStringAsFixed(seconds >= 36000 ? 0 : 1)} 小时' : '$h 小时 $m 分';
    }
    return '$totalMinutes 分钟';
  }

  static String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Map<String, int> _map(String key) => ((_box.get(key) as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as int));

  /// 本机的统计加上同步来的其他设备的统计。[key] 是 day / book。
  static Map<String, int> _total(String key) {
    final out = _map('stats:$key');
    for (final s in Sync.otherStats()) {
      for (final e in ((s[key] as Map?) ?? const {}).entries) {
        out['${e.key}'] = (out['${e.key}'] ?? 0) + (e.value as int);
      }
    }
    return out;
  }

  /// 日期 → 秒
  static Map<String, int> perDay() => _total('day');

  /// aid → 秒
  static Map<String, int> perBook() => _total('book');

  static int get chapters => ((_box.get('stats:chapters') as int?) ?? 0) + Sync.otherStats().fold(0, (a, s) => a + ((s['chapters'] as int?) ?? 0));

  /// 读过这本书的日期（`yyyy-MM-dd`，去重）
  static List<String> bookDays(String aid) => {
    ...((_box.get('stats:days:$aid') as List?) ?? const []).cast<String>(),
    for (final s in Sync.otherStats()) ...(((s['days'] as Map?)?[aid] as List?) ?? const []).cast<String>(),
  }.toList()..sort();

  /// 书的信息（标题、作者、封面），统计页和阅读报告用。
  static ({String title, String author, String img})? meta(String aid) {
    final m = (_box.get('stats:meta') as Map?)?[aid] ?? Sync.otherStats().map((s) => (s['meta'] as Map?)?[aid]).whereType<Map>().firstOrNull;
    return m is Map ? (title: m['t'] as String, author: (m['a'] as String?) ?? '', img: (m['i'] as String?) ?? '') : null;
  }

  /// 书名、作者、封面：统计里记的没有时（例如离线时读的），依次从本地书架、阅读历史、离线缓存里找；都没有才显示书号。
  static ({String title, String author, String img}) info(String aid) {
    final m = meta(aid);
    if (m != null && m.title.isNotEmpty) return (title: LibraryStore.shown(aid, m.title), author: m.author, img: m.img);
    final lib = LibraryStore.get(aid);
    String? histTitle;
    String? histImg;
    if (lib == null) {
      final rawHist = ((_box.get('history2') as List?) ?? const []).cast<Map>().where((e) => e['aid'] == aid).firstOrNull;
      histTitle = rawHist?['title'] as String?;
      histImg = rawHist?['img'] as String?;
    }
    final cached = lib == null && histTitle == null ? ChapterCache.metaOf(aid) : null;
    final title = (lib?['title'] as String?) ?? histTitle ?? cached?.$1;
    final img = [m?.img, lib?['img'] as String?, histImg, cached?.$3].whereType<String>().where((e) => e.isNotEmpty).firstOrNull ?? '';
    return (title: LibraryStore.shown(aid, title ?? '书号 $aid'), author: m?.author ?? '', img: img);
  }

  static Future<void> setMeta(String aid, String title, String author, String img) async {
    if (Incognito.on) return;
    final raw = _box.get('stats:meta') as Map?;
    final cur = raw?[aid];
    if (cur is Map && cur['t'] == title && cur['a'] == author && cur['i'] == img) return;
    final all = Map.of(raw ?? const {});
    all[aid] = {'t': title, 'a': author, 'i': img};
    await _box.put('stats:meta', all);
  }

  static Map<String, Map<String, int>> _localChapterSeconds(String aid) => ((_box.get('stats:ch:$aid') as Map?) ?? const {}).map(
    (k, v) => MapEntry(k as String, (v as Map).map((d, s) => MapEntry(d as String, s as int))),
  );

  /// 每章每天读了多少秒：cid → 日期 → 秒。按卷统计时长、天数用（这个功能加上之后才开始记）。
  static Map<String, Map<String, int>> chapterSeconds(String aid) {
    final out = _localChapterSeconds(aid);
    for (final s in Sync.otherStats()) {
      final ch = (s['ch'] as Map?)?[aid];
      if (ch is! Map) continue;
      for (final ce in ch.entries) {
        if (ce.value is! Map) continue;
        final days = out['${ce.key}'] ??= {};
        for (final de in (ce.value as Map).entries) {
          if (de.value is int) days['${de.key}'] = (days['${de.key}'] ?? 0) + (de.value as int);
        }
      }
    }
    return out;
  }

  /// 读过的书 aid（按章记过时长的）
  static Iterable<String> chapterBooks() => {
    ..._box.keys.whereType<String>().where((k) => k.startsWith('stats:ch:')).map((k) => k.substring(9)),
    for (final s in Sync.otherStats()) ...(((s['ch'] as Map?) ?? const {}).keys.map((k) => '$k')),
  };

  /// 日期满足 [inDay] 的那些天里，每本书读了多少秒：aid → 秒。按章记的时长合计，只有本机的、这个功能加上之后的。
  static Map<String, int> booksOn(bool Function(String day) inDay) => {
    for (final aid in chapterBooks())
      if (chapterSeconds(aid).values.expand((d) => d.entries).where((e) => inDay(e.key)).fold(0, (a, e) => a + e.value) case final s when s > 0) aid: s,
  };

  /// 删掉一本书的阅读记录，同步时其他设备也删。若删完后已无任何书籍记录，同步清零本地残留章数。
  static Future<void> deleteBook(String aid) async {
    await purgeLocal(aid);
    await Sync.forgetBookStats(aid);
    if (perBook().isEmpty) await _box.delete('stats:chapters');
    changes.value++;
  }

  /// 从一份统计（同步时的格式：day / book / meta / days / ch / last）里去掉一本书在 [before]（毫秒时间戳）之前的记录，
  /// [before] 为 null 时整本去掉。只记到天：删除那天的记录也去掉，除非这本书最后一次读是在删除之后（那天就整天留下）。
  /// 每天的时长只能减去按章记过的部分（这个功能加上之前的不知道属于哪本书）；删完没有剩下的日子就整本去掉。
  static void stripBook(Map<String, dynamic> stats, String aid, {int? before}) {
    Map<String, dynamic> mapOf(String k) => Map<String, dynamic>.from((stats[k] as Map?) ?? const {});
    final cut = before == null ? null : dayKey(DateTime.fromMillisecondsSinceEpoch(before));
    final readAfter = before != null && (((stats['last'] as Map?)?[aid] as int?) ?? 0) > before;
    bool drop(String day) => cut == null || day.compareTo(cut) < 0 || (day == cut && !readAfter);

    final dayTotals = mapOf('day');
    final book = mapOf('book');
    final chAll = mapOf('ch');
    final daysAll = mapOf('days');
    var removed = 0;
    final keptCh = <String, Map<String, int>>{};
    for (final ce in ((chAll[aid] as Map?) ?? const {}).entries) {
      if (ce.value is! Map) continue;
      final kept = <String, int>{};
      for (final de in (ce.value as Map).entries) {
        final day = '${de.key}';
        final sec = (de.value as num).toInt();
        if (!drop(day)) {
          kept[day] = sec;
          continue;
        }
        removed += sec;
        final left = ((dayTotals[day] as num?)?.toInt() ?? 0) - sec;
        left > 0 ? dayTotals[day] = left : dayTotals.remove(day);
      }
      if (kept.isNotEmpty) keptCh['${ce.key}'] = kept;
    }
    final keptDays = [for (final d in ((daysAll[aid] as List?) ?? const [])) '$d'].where((d) => !drop(d)).toList();
    stats['day'] = dayTotals;
    if (keptDays.isEmpty && keptCh.isEmpty) {
      for (final k in const ['book', 'meta', 'days', 'ch', 'last']) {
        stats[k] = mapOf(k)..remove(aid);
      }
      return;
    }
    final rest = ((book[aid] as num?)?.toInt() ?? 0) - removed;
    rest > 0 ? book[aid] = rest : book.remove(aid);
    stats['book'] = book;
    stats['days'] = daysAll..[aid] = keptDays;
    stats['ch'] = chAll..[aid] = keptCh;
  }

  /// 删掉本机记的这本书在 [before] 之前的记录（null 时全删），见 [stripBook]。
  static Future<void> purgeLocal(String aid, {int? before}) async {
    final s = <String, dynamic>{
      'day': _map('stats:day'),
      'book': _map('stats:book'),
      'meta': Map<String, dynamic>.from((_box.get('stats:meta') as Map?) ?? const {}),
      'days': {aid: (_box.get('stats:days:$aid') as List?) ?? const []},
      'ch': {aid: _localChapterSeconds(aid)},
      'last': _map('stats:last'),
    };
    stripBook(s, aid, before: before);
    Map<String, int> ints(Object? m) => ((m as Map?) ?? const {}).map((k, v) => MapEntry('$k', (v as num).toInt()));
    await _box.putAll({'stats:day': ints(s['day']), 'stats:book': ints(s['book']), 'stats:meta': s['meta'], 'stats:last': ints(s['last'])});
    final days = (s['days'] as Map)[aid] as List?;
    final ch = (s['ch'] as Map)[aid] as Map?;
    if (days == null || days.isEmpty) {
      await _box.delete('stats:days:$aid');
    } else {
      await _box.put('stats:days:$aid', days.cast<String>());
    }
    if (ch == null || ch.isEmpty) {
      await _box.delete('stats:ch:$aid');
    } else {
      await _box.put('stats:ch:$aid', ch);
    }
    changes.value++;
  }

  static Future<void> addSeconds(String aid, int seconds, {String? cid}) async {
    if (seconds <= 0 || Incognito.on) return;
    final now = DateTime.now();
    final secToday = now.hour * 3600 + now.minute * 60 + now.second;
    // 横跨午夜 0 点时（例如 23:59 开始读、00:00 后刷新），将午夜前的秒数归入昨天，避免前一天断签
    final slices = seconds > secToday && secToday >= 0 && seconds <= 7200
        ? [(dayKey(now.subtract(const Duration(days: 1))), seconds - secToday), if (secToday > 0) (dayKey(now), secToday)]
        : [(dayKey(now), seconds)];
    final ch = cid != null ? _localChapterSeconds(aid) : null;
    final days = ((_box.get('stats:days:$aid') as List?) ?? const []).cast<String>().toList();
    var daysAdded = false;
    final day = _map('stats:day'); // 只累加本机自己的，别的设备的统计单独存放
    final book = _map('stats:book');
    for (final (dKey, sec) in slices) {
      if (sec <= 0) continue;
      if (ch != null && cid != null) {
        final cDays = ch[cid] ??= {};
        cDays[dKey] = (cDays[dKey] ?? 0) + sec;
      }
      if (!days.contains(dKey)) {
        days.add(dKey);
        daysAdded = true;
      }
      day[dKey] = (day[dKey] ?? 0) + sec;
      book[aid] = (book[aid] ?? 0) + sec;
    }
    await _box.putAll({
      'stats:ch:$aid': ?ch,
      if (daysAdded) 'stats:days:$aid': days,
      'stats:day': day,
      'stats:book': book,
      // 最后一次读的时间：别的设备删了这本书的统计时，用来判断删除那天的记录是不是删之后读的
      'stats:last': _map('stats:last')..[aid] = now.millisecondsSinceEpoch,
    });
    changes.value++;
  }

  static Future<void> addChapter(String aid, String cid) async {
    if (Incognito.on) return;
    final today = dayKey(DateTime.now());
    final seen = ((_box.get('stats:seen') as List?) ?? const []).cast<String>();
    final key = '$today:$aid:$cid';
    if (seen.contains(key)) return;
    await _box.putAll({
      'stats:seen': [...seen.where((e) => e.startsWith(today)), key],
      'stats:chapters': ((_box.get('stats:chapters') as int?) ?? 0) + 1,
    });
    changes.value++;
  }
}
