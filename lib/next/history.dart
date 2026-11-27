import 'package:hive_ce_flutter/hive_flutter.dart';

import 'incognito.dart';
import 'sync.dart';

class HistoryEntry {
  const HistoryEntry({required this.aid, required this.title, required this.img, required this.cid, required this.chapter, required this.time});

  final String aid;
  final String title;
  final String img;
  final String cid;
  final String chapter;
  final DateTime time;
}

/// 阅读历史：每本书一条，记最后读到的章节和时间，新的在前，最多 300 本。
class ReadingHistory {
  ReadingHistory._();

  static Box get _box => Hive.box('session');

  static HistoryEntry _parse(Map e) => HistoryEntry(
    aid: e['aid'] as String,
    title: e['title'] as String,
    img: e['img'] as String,
    cid: e['cid'] as String,
    chapter: e['chapter'] as String,
    time: DateTime.fromMillisecondsSinceEpoch(e['time'] as int),
  );

  /// 仅反序列化最近 [limit] 条阅读历史，避免续读卡片/桌面小组件全表解析 300 条。
  static List<HistoryEntry> latest({int limit = 1}) {
    if (limit <= 0) return const [];
    final raw = _box.get('history2') as List?;
    if (raw == null || raw.isEmpty) return const [];
    final end = limit < raw.length ? limit : raw.length;
    return [for (var i = 0; i < end; i++) _parse(raw[i] as Map)];
  }

  static List<HistoryEntry> all() => ((_box.get('history2') as List?) ?? const []).cast<Map>().map(_parse).toList();

  static Future<void> record(String aid, String title, String img, String cid, String chapter) {
    if (Incognito.on) return Future.value();
    final rest = ((_box.get('history2') as List?) ?? const []).cast<Map>().where((e) => e['aid'] != aid);
    return _box.put('history2', [
      {'aid': aid, 'title': title, 'img': img, 'cid': cid, 'chapter': chapter, 'time': DateTime.now().millisecondsSinceEpoch},
      ...rest,
    ].take(300).toList());
  }

  /// 删除、清空都记墓碑（`h:书`、`h:*`），不然同步时别的设备又把记录带回来。
  static Future<void> remove(String aid) async {
    await Sync.tombstone(['h:$aid']);
    await _box.put('history2', ((_box.get('history2') as List?) ?? const []).cast<Map>().where((e) => e['aid'] != aid).toList());
  }

  static Future<void> clear() async {
    await Sync.tombstone(['h:*']);
    await _box.delete('history2');
  }
}
