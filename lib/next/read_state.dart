import 'package:hive_ce_flutter/hive_flutter.dart';

import 'incognito.dart';
import 'volumes.dart';

/// 每本书哪些章节读过（读到章末，或者翻到了下一章）、读过多少字，用于详情页的已读/未读和阅读报告。
class ReadState {
  ReadState._();

  static Box get _box => Hive.box('session');

  // 存的 List 没换（Hive 每次 put 都是新对象，同步、导入直接写 Box 也一样）就复用转好的 Set（LRU 上限 128）
  static const _setsCap = 128;
  static final _sets = <String, (List, Set<String>)>{};

  /// 释放已读集合内存缓存。
  static void evictMemory() => _sets.clear();

  /// 读过的章节。返回的是副本，改了不影响缓存。
  static Set<String> read(String aid) => {...readView(aid)};

  /// 读过的章节（只读视图，不复制 Set，适合书架角标、卷完成度等高频只读查询）。
  static Set<String> readView(String aid) {
    final list = _box.get('read:$aid') as List?;
    if (list == null) {
      _sets.remove(aid);
      return const {};
    }
    final hit = _sets.remove(aid);
    if (hit != null && identical(hit.$1, list)) {
      _sets[aid] = hit;
      return hit.$2;
    }
    final set = Set<String>.unmodifiable(list.cast<String>());
    _sets[aid] = (list, set);
    while (_sets.length > _setsCap) {
      _sets.remove(_sets.keys.first);
    }
    return set;
  }

  /// 读过几章（书架算未读数用，不复制）
  static int readCount(String aid) => readView(aid).length;

  static bool isRead(String aid, String cid) => readView(aid).contains(cid);

  /// 标记已读；第一次标记时把字数计入这本书的"已读字数"。
  static Future<void> mark(String aid, String cid, int chars) async {
    if (Incognito.on) return;
    final set = read(aid);
    if (!set.add(cid)) return;
    await _box.putAll({
      'read:$aid': set.toList(),
      'readchars:$aid': readChars(aid) + chars,
    });
    await Volumes.refreshDone(aid);
  }

  /// 手动标记一批章节已读 / 未读（详情页多选）。不改"已读字数"。
  /// shortcut: 同步时已读记录按并集合并，标成未读不会同步到其他设备；要同步得给已读加墓碑
  static Future<void> setRead(String aid, Iterable<String> cids, bool read) {
    final set = ReadState.read(aid);
    read ? set.addAll(cids) : set.removeAll(cids);
    return _box.put('read:$aid', set.toList()).then((_) => Volumes.refreshDone(aid));
  }

  static int readChars(String aid) => (_box.get('readchars:$aid') as int?) ?? 0;

  /// 书的评分（1 到 5 星），没评过为 0。
  static int rating(String aid) => (_box.get('rating:$aid') as int?) ?? 0;

  static Future<void> setRating(String aid, int stars) async {
    await _box.putAll({'rating:$aid': stars, 'ratingTs:$aid': DateTime.now().millisecondsSinceEpoch});
    Volumes.notifyMetaAid(aid);
  }
}
