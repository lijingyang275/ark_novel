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

  static List<Bookmark> all([String? aid]) {
    final list = ((_box.get('bookmarks') as List?) ?? const []).cast<Map>().map((e) {
      return Bookmark(aid: e['aid'] as String, book: e['book'] as String, cid: e['cid'] as String, chapter: e['chapter'] as String, offset: e['offset'] as int, excerpt: e['excerpt'] as String, time: DateTime.fromMillisecondsSinceEpoch(e['time'] as int));
    });
    return (aid == null ? list : list.where((b) => b.aid == aid)).toList();
  }

  static Future<void> _save(List<Bookmark> list) => _box.put('bookmarks', [
    for (final b in list) {'aid': b.aid, 'book': b.book, 'cid': b.cid, 'chapter': b.chapter, 'offset': b.offset, 'excerpt': b.excerpt, 'time': b.time.millisecondsSinceEpoch},
  ]);

  static bool _near(Bookmark b, String aid, String cid, int offset) => b.aid == aid && b.cid == cid && (b.offset - offset).abs() <= 40;

  static bool has(String aid, String cid, int offset) => all(aid).any((b) => _near(b, aid, cid, offset));

  /// 有书签的书号集合（书架筛选直接查，不逐本构造对象）。
  static Set<String> bookmarkedAids() => {
    for (final e in ((_box.get('bookmarks') as List?) ?? const []).cast<Map>()) '${e['aid']}',
  };

  /// 指定书中有书签的章节 cid 集合（目录列表渲染图标用）。
  static Set<String> bookmarkedCids(String aid) => {
    for (final e in ((_box.get('bookmarks') as List?) ?? const []).cast<Map>())
      if (e['aid'] == aid) '${e['cid']}',
  };

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
