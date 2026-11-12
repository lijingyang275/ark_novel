import 'app_prefs.dart';

/// 同步文件是外部输入。先检查整份快照的身份和统计，错误时不写任何本机数据。
/// v1/v2 的旧快照允许没有 at；新快照必须有时间，不能绕过过期判断。
void validateSyncSnapshot(Map<String, dynamic> remote) {
  final version = remote['v'];
  final device = remote['device'];
  if (version is! int || version < 1 || version > 3 || device is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(device)) {
    throw const FormatException('同步文件的版本或设备编号无效');
  }
  final at = remote['at'];
  if ((at != null || version == 3) && (at is! int || at <= 0)) throw const FormatException('同步文件的时间无效');
  final stats = remote['stats'];
  if (stats == null) return; // 旧快照可能没有统计
  bool ints(Object? v) => v is Map && v.keys.every((k) => k is String) && v.values.every((n) => n is int && n >= 0);
  bool dates(Object? v) => v is List && v.every((d) => d is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d));
  bool valid = stats is Map;
  if (stats is Map) {
    for (final key in ['day', 'book', 'last']) {
      if (stats[key] != null && !ints(stats[key])) valid = false;
    }
    if (stats['chapters'] != null && (stats['chapters'] is! int || (stats['chapters'] as int) < 0)) valid = false;
    final meta = stats['meta'];
    if (meta != null &&
        (meta is! Map ||
            !meta.values.every((m) => m is Map && m['t'] is String && (m['a'] == null || m['a'] is String) && (m['i'] == null || m['i'] is String)))) {
      valid = false;
    }
    final days = stats['days'];
    if (days != null && (days is! Map || !days.values.every(dates))) valid = false;
    final ch = stats['ch'];
    if (ch != null && (ch is! Map || !ch.values.every((book) => book is Map && book.values.every(ints)))) valid = false;
  }
  if (!valid) throw const FormatException('同步文件的阅读统计格式无效');
}

/// 类型由已知字段定义，而不是取决于本机是否碰巧保存过这个设置。
const _preferences = <String, Object>{
  'r.fontSize': 18.0,
  'r.lineHeight': 1.8,
  'r.theme': 5,
  'r.mode': 3,
  'r.ttsRate': 1.0,
  'r.margin': 22.0,
  'r.font': 1,
  'r.ttsPitch': 1.0,
  'r.ttsVoice': '',
  'r.ttsHighlight': true,
  'r.ttsAutoNext': true,
  'r.dual': true,
  'r.dim': 0.0,
  'r.volumeKeys': true,
  'r.tapZone': 2,
  'r.tapInvert': 0,
  'r.keepScreenOn': true,
  'r.fullscreen': true,
  'r.showStatus': true,
  'r.skipRead': false,
  'r.chapterToast': false,
  'r.warm': 0.0,
  'r.grayscale': false,
  'r.invert': false,
  'r.customBrightness': false,
  'r.brightness': 0.5,
  'r.volumeInvert': false,
  'r.pageAnim': true,
  'r.prefetch': 2,
  'r.prefetchWifi': false,
  'r.prefetchBook': false,
  'r.hant': false,
  'p.${P.resumeButton}': true,
  'p.${P.unreadBadge}': true,
  'p.${P.cacheBadge}': true,
  'p.${P.tabCounts}': true,
  'p.${P.perCat}': false,
  'p.${P.defaultCat}': '',
  'p.${P.hiddenTabs}': <String>[],
  'p.${P.resumeBar}': true,
  'p.${P.coverTrim}': true,
  'p.${P.coverSr}': 0,
  'p.${P.updInterval}': 1,
  'p.${P.updWifi}': false,
  'p.${P.updCharging}': false,
  'p.${P.updSkipDone}': false,
  'p.${P.updSkipNotStarted}': false,
  'p.${P.updSkipUnread}': false,
  'p.${P.updInclude}': <String>[],
  'p.${P.updExclude}': <String>[],
  'p.${P.volumeDone}': true,
  'p.${P.pureBlack}': false,
  'p.${P.sceneMotion}': true,
  'p.${P.uiHant}': false,
};

const _ranges = <String, (num, num)>{
  'r.fontSize': (14, 32),
  'r.lineHeight': (1.3, 2.4),
  'r.margin': (8, 48),
  'r.theme': (0, 5),
  'r.mode': (0, 3),
  'r.font': (0, 2),
  'r.ttsRate': (0.1, 1),
  'r.ttsPitch': (0.5, 2),
  'r.dim': (0, 0.7),
  'r.warm': (0, 0.5),
  'r.brightness': (0.02, 1),
  'r.tapZone': (0, 4),
  'r.tapInvert': (0, 3),
  'r.prefetch': (0, 10),
  'p.${P.coverSr}': (0, 1),
  'p.${P.updInterval}': (0, 168),
};

Object? _typed(Object? value, Object? expected) => switch (expected) {
  int() => value is int ? value : null,
  double() => value is num && value.isFinite ? value.toDouble() : null,
  bool() => value is bool ? value : null,
  String() => value is String ? value : null,
  List() => value is List && value.every((x) => x is String) ? value.cast<String>().toList() : null,
  _ => null,
};

Object? syncPreference(String key, Object? value) {
  final typed = _typed(value, _preferences[key]);
  final range = _ranges[key];
  if (range != null && typed is num && (typed < range.$1 || typed > range.$2)) return null;
  return typed;
}

Map<String, Object> syncShelfOptions(Map remote) {
  const fields = {'sort': 0, 'reverse': false, 'display': 3, 'unread': 0, 'started': 0, 'cached': 0, 'bookmarked': 0, 'completed': 0};
  return {
    for (final e in fields.entries)
      if (_typed(remote[e.key], e.value) case final Object v)
        if (v is! int || (v >= 0 && (e.key == 'sort' || v <= (e.key == 'display' ? 3 : 2)))) e.key: v,
  };
}
