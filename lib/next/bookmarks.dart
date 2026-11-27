import 'package:hive_ce_flutter/hive_flutter.dart';

import 'sync.dart';

class Bookmark {
  const Bookmark({required this.aid, required this.book, required this.cid, required this.chapter, required this.offset, required this.excerpt, required this.time});

  final String aid;
  final String book;
  final String cid;
  final String chapter;

  /// 章内字符偏移
  final int offset;

  /// 书签处的一小段文字，列表里用来认出位置
  final String excerpt;
  final DateTime time;
}

/// 书签：全局一个列表，新的在前。同一章同一位置（偏移相差 40 字以内）视为同一个，再加一次就是取消。
class Bookmarks {
  Bookmarks._();

  static Box get _box => Hive.box('session');

  static final _unset = Object();
  static Object? _cachedRaw = _unset;
  static List<Bookmark> _cachedAll = const [];
  static Map<String, List<Bookmark>> _cachedByAid = const {};
  static Map<(String, String), List<int>> _cachedByChapter = const {};
  static Set<String> _cachedAids = const {};
  static Map<String, Set<String>> _cachedCidsByAid = const {};

  static void _ensureCache() {
    if (!Hive.isBoxOpen('session')) {
      _cachedRaw = _unset;
      _cachedAll = const [];
      _cachedByAid = const {};
      _cachedByChapter = const {};
      _cachedAids = const {};
      _cachedCidsByAid = const {};
      return;
    }
    final raw = _box.get('bookmarks');
    if (identical(raw, _cachedRaw)) return;
    final all = <Bookmark>[];
    final byAid = <String, List<Bookmark>>{};
    final byChapter = <(String, String), List<int>>{};
    final aids = <String>{};
    final cidsByAid = <String, Set<String>>{};
    for (final e in ((raw as List?) ?? const []).cast<Map>()) {
      final aid = e['aid'] as String;
      final cid = e['cid'] as String;
      final offset = e['offset'] as int;
      final b = Bookmark(
        aid: aid,
        book: e['book'] as String,
        cid: cid,
        chapter: e['chapter'] as String,
        offset: offset,
        excerpt: e['excerpt'] as String,
        time: DateTime.fromMillisecondsSinceEpoch(e['time'] as int),
      );
      all.add(b);
      (byAid[aid] ??= <Bookmark>[]).add(b);
      (byChapter[(aid, cid)] ??= <int>[]).add(offset);
      aids.add(aid);
      (cidsByAid[aid] ??= <String>{}).add(cid);
    }
    _cachedRaw = raw;
    _cachedAll = List<Bookmark>.unmodifiable(all);
    _cachedByAid = {for (final e in byAid.entries) e.key: List<Bookmark>.unmodifiable(e.value)};
    _cachedByChapter = {for (final e in byChapter.entries) e.key: List<int>.unmodifiable(e.value)};
    _cachedAids = Set<String>.unmodifiable(aids);
    _cachedCidsByAid = {for (final e in cidsByAid.entries) e.key: Set<String>.unmodifiable(e.value)};
  }

  static List<Bookmark> all([String? aid]) {
    _ensureCache();
    return List<Bookmark>.of(aid == null ? _cachedAll : (_cachedByAid[aid] ?? const []));
  }

  static Future<void> _save(List<Bookmark> list) {
    _cachedRaw = _unset;
    return _box.put('bookmarks', [
      for (final b in list) {'aid': b.aid, 'book': b.book, 'cid': b.cid, 'chapter': b.chapter, 'offset': b.offset, 'excerpt': b.excerpt, 'time': b.time.millisecondsSinceEpoch},
    ]);
  }

  static bool _near(Bookmark b, String aid, String cid, int offset) => b.aid == aid && b.cid == cid && (b.offset - offset).abs() <= 40;

  static bool has(String aid, String cid, int offset) {
    _ensureCache();
    final offsets = _cachedByChapter[(aid, cid)];
    if (offsets == null) return false;
    for (var i = 0; i < offsets.length; i++) {
      if ((offsets[i] - offset).abs() <= 40) return true;
    }
    return false;
  }

  /// 有书签的书号集合（书架筛选直接查，不逐本构造对象）。
  static Set<String> bookmarkedAids() {
    _ensureCache();
    return _cachedAids;
  }

  /// 指定书中有书签的章节 cid 集合（目录列表渲染图标用）。
  static Set<String> bookmarkedCids(String aid) {
    _ensureCache();
    return _cachedCidsByAid[aid] ?? const <String>{};
  }

  /// 已有就删除，没有就添加；返回添加后是否存在。
  static Future<bool> toggle(String aid, String book, String cid, String chapter, int offset, String excerpt) async {
    final list = all();
    if (list.any((b) => _near(b, aid, cid, offset))) {
      await Sync.tombstone(list.where((b) => _near(b, aid, cid, offset)).map(_key));
      await _save(list.where((b) => !_near(b, aid, cid, offset)).toList());
      return false;
    }
    await _save([Bookmark(aid: aid, book: book, cid: cid, chapter: chapter, offset: offset, excerpt: excerpt, time: DateTime.now()), ...list]);
    return true;
  }

  static String _key(Bookmark b) => 'b:${b.aid}:${b.cid}:${b.offset}';

  static Future<void> remove(Bookmark b) async {
    await Sync.tombstone([_key(b)]);
    await _save(all().where((e) => !(e.aid == b.aid && e.cid == b.cid && e.offset == b.offset)).toList());
  }
}
