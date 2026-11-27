import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'incognito.dart';

/// 阅读进度：记在哪一章、章内第几个字符。按字符偏移保存，改字号、换设备尺寸后仍能回到同一处。
///
/// 写入走内存热缓存 + 1.5 秒防抖合并落盘（连续滚动最长 5 秒必落盘），切章、退后台、退出阅读页调用 [flush] 立即刷盘。
class ReadingProgress {
  const ReadingProgress(this.cid, this.offset);

  final String cid;
  final int offset;

  static Box get _box => Hive.box('session');

  @visibleForTesting
  static Duration debounceDuration = const Duration(milliseconds: 1500);

  @visibleForTesting
  static Duration maxWaitDuration = const Duration(seconds: 5);

  static Box? _lastBox;
  static final _dirty = <String, ({String cid, int offset, int ts})>{};
  static final _cached = <String, ({Object? raw, ReadingProgress? progress, int lastRead})>{};
  static Timer? _flushTimer;
  static DateTime? _firstDirtyAt;

  static Box? _activeBox() {
    if (!Hive.isBoxOpen('session')) {
      _resetMemory();
      return null;
    }
    final box = _box;
    if (!identical(box, _lastBox)) {
      _resetMemory();
      _lastBox = box;
    }
    return box;
  }

  static void _resetMemory() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _firstDirtyAt = null;
    _dirty.clear();
    _cached.clear();
    _lastBox = null;
  }

  static ({Object? raw, ReadingProgress? progress, int lastRead}) _readBox(Box box, String aid) {
    final raw = box.get('progress:$aid');
    final hit = _cached[aid];
    if (hit != null && identical(hit.raw, raw)) return hit;
    final progress = raw is List && raw.length >= 2 ? ReadingProgress(raw[0] as String, raw[1] as int) : null;
    final last = raw is List && raw.length >= 3 ? raw[2] as int : 0;
    final entry = (raw: raw, progress: progress, lastRead: last);
    if (_cached.length >= 128 && !_cached.containsKey(aid)) _cached.remove(_cached.keys.first);
    return _cached[aid] = entry;
  }

  static ReadingProgress? of(String aid) {
    final box = _activeBox();
    if (box == null) return null;
    final dirty = _dirty[aid];
    final stored = _readBox(box, aid);
    if (dirty != null) {
      if (stored.lastRead > dirty.ts) {
        _dirty.remove(aid);
        return stored.progress;
      }
      return ReadingProgress(dirty.cid, dirty.offset);
    }
    return stored.progress;
  }

  /// 等价于 [of]，供语义化读取最新内存/持久化阅读进度。
  static ReadingProgress? get(String aid) => of(aid);

  /// 最近阅读时间（毫秒），没读过为 0。
  static int lastRead(String aid) {
    final box = _activeBox();
    if (box == null) return 0;
    final dirty = _dirty[aid];
    final stored = _readBox(box, aid);
    if (dirty != null) {
      if (stored.lastRead > dirty.ts) {
        _dirty.remove(aid);
        return stored.lastRead;
      }
      return dirty.ts;
    }
    return stored.lastRead;
  }

  static Future<void> save(String aid, String cid, int offset) {
    if (Incognito.on) return Future.value();
    final box = _activeBox();
    if (box == null) return Future.value();
    final now = DateTime.now();
    _dirty[aid] = (cid: cid, offset: offset, ts: now.millisecondsSinceEpoch);
    final first = _firstDirtyAt ??= now;
    final elapsed = now.difference(first);
    if (elapsed >= maxWaitDuration) {
      return flush();
    }
    final remaining = maxWaitDuration - elapsed;
    final delay = remaining < debounceDuration ? remaining : debounceDuration;
    _flushTimer?.cancel();
    _flushTimer = Timer(delay, () {
      flush();
    });
    return Future.value();
  }

  /// 立即将内存热缓存中尚未落盘的进度批量写入 Hive（切章、退后台、退出阅读页时调用）。
  static Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _firstDirtyAt = null;
    if (_dirty.isEmpty) return;
    final box = _activeBox();
    if (box == null || _dirty.isEmpty) return;
    final batch = <String, List<Object>>{};
    for (final e in _dirty.entries) {
      final list = <Object>[e.value.cid, e.value.offset, e.value.ts];
      batch['progress:${e.key}'] = list;
      _cached[e.key] = (raw: list, progress: ReadingProgress(e.value.cid, e.value.offset), lastRead: e.value.ts);
    }
    _dirty.clear();
    await box.putAll(batch);
  }
}
