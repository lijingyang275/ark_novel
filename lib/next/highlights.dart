import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'sync_merge.dart';

/// 自由划线配色（暖黄、青绿、晴蓝、樱粉、暮紫）。
const kHighlightColors = <int>[
  0xFFE6A700,
  0xFF3E9C6B,
  0xFF3B82F6,
  0xFFE05A86,
  0xFF8B5CF6,
];

/// 单条正文划线 / 摘录。
class HighlightEntry {
  const HighlightEntry({
    required this.id,
    required this.aid,
    required this.cid,
    required this.chapter,
    required this.start,
    required this.end,
    required this.quote,
    this.note = '',
    this.color = 0,
    required this.at,
  });

  final String id;
  final String aid;
  final String cid;
  final String chapter;
  final int start;
  final int end;
  final String quote;
  final String note;

  /// 对应 [kHighlightColors] 的下标（0~4）
  final int color;
  final int at;

  int get colorValue => kHighlightColors[color.clamp(0, kHighlightColors.length - 1)];

  HighlightEntry copyWith({String? chapter, int? start, int? end, String? quote, String? note, int? color, int? at}) => HighlightEntry(
    id: id,
    aid: aid,
    cid: cid,
    chapter: chapter ?? this.chapter,
    start: start ?? this.start,
    end: end ?? this.end,
    quote: quote ?? this.quote,
    note: note ?? this.note,
    color: color ?? this.color,
    at: at ?? this.at,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'aid': aid,
    'cid': cid,
    'chapter': chapter,
    'start': start,
    'end': end,
    'quote': quote,
    'note': note,
    'color': color,
    'at': at,
  };

  static HighlightEntry? fromMap(Map m) {
    final id = m['id'];
    final aid = m['aid'];
    final cid = m['cid'];
    final start = m['start'];
    final end = m['end'];
    final quote = m['quote'];
    final at = m['at'];
    if (id is! String || id.isEmpty || aid is! String || cid is! String || start is! int || end is! int || end <= start || quote is! String || at is! int) {
      return null;
    }
    return HighlightEntry(
      id: id,
      aid: aid,
      cid: cid,
      chapter: (m['chapter'] as String?) ?? '',
      start: start,
      end: end,
      quote: quote,
      note: (m['note'] as String?) ?? '',
      color: ((m['color'] as int?) ?? 0).clamp(0, kHighlightColors.length - 1),
      at: at,
    );
  }
}

/// 自由划线与摘录存储（Hive `session` 的 `highlights` 键，同步墓碑前缀 `hl:`）。
class HighlightStore {
  HighlightStore._();

  static Box get _box => Hive.box('session');

  static final changes = ValueNotifier<int>(0);

  static final _unset = Object();
  static Object? _cachedRaw = _unset;
  static List<HighlightEntry> _cachedRawOrder = const [];
  static List<HighlightEntry> _cachedAllSorted = const [];
  static Map<String, List<HighlightEntry>> _cachedByAid = const {};
  static Map<(String, String), List<HighlightEntry>> _cachedByChapter = const {};
  static Map<String, HighlightEntry> _cachedById = const {};

  static void _invalidateCache() {
    _cachedRaw = _unset;
    _cachedRawOrder = const [];
    _cachedAllSorted = const [];
    _cachedByAid = const {};
    _cachedByChapter = const {};
    _cachedById = const {};
  }

  static void notifyChanged() {
    _invalidateCache();
    changes.value++;
  }

  static void _ensureCache() {
    if (!Hive.isBoxOpen('session')) {
      _invalidateCache();
      return;
    }
    final raw = _box.get('highlights');
    if (identical(raw, _cachedRaw)) return;
    final rawOrder = <HighlightEntry>[];
    final byAid = <String, List<HighlightEntry>>{};
    final byChapter = <(String, String), List<HighlightEntry>>{};
    final byId = <String, HighlightEntry>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final e = HighlightEntry.fromMap(item);
          if (e != null) {
            rawOrder.add(e);
            (byAid[e.aid] ??= <HighlightEntry>[]).add(e);
            (byChapter[(e.aid, e.cid)] ??= <HighlightEntry>[]).add(e);
            byId.putIfAbsent(e.id, () => e);
          }
        }
      }
    }
    final allSorted = List<HighlightEntry>.of(rawOrder)..sort((a, b) => b.at.compareTo(a.at));
    final frozenByAid = <String, List<HighlightEntry>>{};
    for (final entry in byAid.entries) {
      entry.value.sort((a, b) => b.at.compareTo(a.at));
      frozenByAid[entry.key] = List<HighlightEntry>.unmodifiable(entry.value);
    }
    final frozenByChapter = <(String, String), List<HighlightEntry>>{};
    for (final entry in byChapter.entries) {
      entry.value.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.end.compareTo(b.end));
      frozenByChapter[entry.key] = List<HighlightEntry>.unmodifiable(entry.value);
    }
    _cachedRaw = raw;
    _cachedRawOrder = List<HighlightEntry>.unmodifiable(rawOrder);
    _cachedAllSorted = List<HighlightEntry>.unmodifiable(allSorted);
    _cachedByAid = frozenByAid;
    _cachedByChapter = frozenByChapter;
    _cachedById = byId;
  }

  /// 全部划线或某本书的划线（按时间倒序）。
  static List<HighlightEntry> all([String? aid]) {
    _ensureCache();
    return List<HighlightEntry>.of(aid == null ? _cachedAllSorted : (_cachedByAid[aid] ?? const []));
  }

  /// 某章的全部划线（按起始偏移升序，O(1) 返回不可变列表，供阅读器渲染和命中检测使用）。
  static List<HighlightEntry> forChapter(String aid, String cid) {
    _ensureCache();
    return _cachedByChapter[(aid, cid)] ?? const <HighlightEntry>[];
  }

  static HighlightEntry? byId(String id) {
    _ensureCache();
    return _cachedById[id];
  }

  /// 新增或更新一条划线。
  static Future<HighlightEntry> upsert(HighlightEntry entry) async {
    _ensureCache();
    final list = List<HighlightEntry>.of(_cachedRawOrder);
    final idx = list.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.insert(0, entry);
    }
    await _box.put('highlights', [for (final e in list) e.toMap()]);
    _invalidateCache();
    changes.value++;
    return entry;
  }

  /// 新建一条划线（自动生成 ID 与时间戳）。
  static Future<HighlightEntry> add({
    required String aid,
    required String cid,
    required String chapter,
    required int start,
    required int end,
    required String quote,
    String note = '',
    int color = 0,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'hl_${DateTime.now().microsecondsSinceEpoch}';
    return upsert(
      HighlightEntry(
        id: id,
        aid: aid,
        cid: cid,
        chapter: chapter,
        start: start,
        end: end,
        quote: quote,
        note: note,
        color: color.clamp(0, kHighlightColors.length - 1),
        at: now,
      ),
    );
  }

  /// 删除划线并写入同步墓碑 `hl:$id`。
  static Future<void> remove(String id) async {
    _ensureCache();
    final list = List<HighlightEntry>.of(_cachedRawOrder);
    final before = list.length;
    list.removeWhere((e) => e.id == id);
    if (list.length == before) return;
    await _box.put('highlights', [for (final e in list) e.toMap()]);
    await SyncMerge.tombstone(['hl:$id']);
    _invalidateCache();
    changes.value++;
  }

  /// 导出本书的全部划线与摘录为 Markdown 文本。
  static String exportMarkdown(String aid, String bookTitle) {
    final items = all(aid);
    if (items.isEmpty) return '';
    // 按章节分组，保留首次出现顺序，章内按位置升序
    final groups = <String, List<HighlightEntry>>{};
    final titles = <String, String>{};
    for (final e in items.reversed) {
      (groups[e.cid] ??= <HighlightEntry>[]).add(e);
      if (e.chapter.isNotEmpty) titles[e.cid] = e.chapter;
    }
    final buf = StringBuffer()..writeln('# ${bookTitle.isEmpty ? '摘录笔记' : bookTitle}');
    for (final entry in groups.entries) {
      final list = entry.value..sort((a, b) => a.start.compareTo(b.start));
      final title = titles[entry.key];
      buf.writeln();
      if (title != null && title.isNotEmpty) {
        buf.writeln('## $title');
        buf.writeln();
      }
      for (final item in list) {
        for (final line in item.quote.trim().split('\n')) {
          buf.writeln('> ${line.trim()}');
        }
        if (item.note.trim().isNotEmpty) {
          buf.writeln();
          buf.writeln('- 笔记：${item.note.trim()}');
        }
        buf.writeln();
      }
    }
    return buf.toString().trimRight();
  }
}
