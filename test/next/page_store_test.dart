import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/cache.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_pages_test');
    Hive.init(tmp.path);
    await ChapterCache.open();
  });
  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('网页备份超过上限时删写入最早的，而不是键排序最靠前的', () async {
    await PageStore.put('zzz|first', 'x'); // 键排序最靠后，但写得最早
    for (var i = 0; i < 400; i++) {
      await PageStore.put('a|$i', 'x');
    }
    expect(await PageStore.get('zzz|first'), isNull);
    expect(await PageStore.get('a|0'), 'x');
    expect(await PageStore.get('a|399'), 'x');
    final stamp = Hive.box('chapter_index');
    final times = [for (var i = 0; i < 400; i++) stamp.get('pt|a|$i') as int];
    expect(times.toSet().length, 400); // 连续写入即使落在同一毫秒，时间也不重复
  });

  test('重启后系统时间落后于已有记录：新写入仍排在旧记录之后', () async {
    await PageStore.put('first', 'x');
    final future = DateTime.now().millisecondsSinceEpoch + 60000;
    await Hive.box('chapter_index').put('pt|first', future);
    await Hive.close();
    await ChapterCache.open();
    await PageStore.put('second', 'y');
    expect(Hive.box('chapter_index').get('pt|second'), greaterThan(future));
  });
}
