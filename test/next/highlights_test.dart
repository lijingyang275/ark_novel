import 'dart:io';

import 'package:ark_novel/next/highlights.dart';
import 'package:ark_novel/next/sync_merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ark_highlights_test_');
    Hive.init(dir.path);
    await Hive.openBox('session');
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('HighlightStore CRUD, ordering, tombstone, and Markdown export', () async {
    final h1 = await HighlightStore.add(
      aid: '100',
      cid: 'c1',
      chapter: '第一章 序幕',
      start: 20,
      end: 32,
      quote: '夕阳沉入地平线。',
      note: '氛围很棒',
      color: 1,
    );
    final h2 = await HighlightStore.add(
      aid: '100',
      cid: 'c1',
      chapter: '第一章 序幕',
      start: 4,
      end: 12,
      quote: '清晨的风吹过。',
      color: 2,
    );

    final byChapter = HighlightStore.forChapter('100', 'c1');
    expect(byChapter.map((e) => e.id).toList(), [h2.id, h1.id]); // 按 start 升序

    final md = HighlightStore.exportMarkdown('100', '测试轻小说');
    expect(md, contains('# 测试轻小说'));
    expect(md, contains('## 第一章 序幕'));
    expect(md, contains('> 清晨的风吹过。'));
    expect(md, contains('> 夕阳沉入地平线。'));
    expect(md, contains('- 笔记：氛围很棒'));

    await HighlightStore.remove(h2.id);
    expect(HighlightStore.all('100').map((e) => e.id).toList(), [h1.id]);
    expect(SyncMerge.tombs().containsKey('hl:${h2.id}'), isTrue);
  });

  test('SyncMerge merges highlights by id/timestamp and respects hl: tombstones', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await HighlightStore.upsert(
      HighlightEntry(
        id: 'hl_keep',
        aid: '100',
        cid: 'c1',
        chapter: '第一章',
        start: 0,
        end: 5,
        quote: '旧句子',
        note: '旧笔记',
        color: 0,
        at: now - 5000,
      ),
    );
    await HighlightStore.upsert(
      HighlightEntry(
        id: 'hl_deleted',
        aid: '100',
        cid: 'c1',
        chapter: '第一章',
        start: 10,
        end: 15,
        quote: '将被删除',
        at: now - 5000,
      ),
    );

    final remote = <String, dynamic>{
      'v': 3,
      'device': 'remote-dev',
      'at': now,
      'tomb': {'hl:hl_deleted': now - 1000},
      'highlights': [
        {
          'id': 'hl_keep',
          'aid': '100',
          'cid': 'c1',
          'chapter': '第一章',
          'start': 0,
          'end': 5,
          'quote': '旧句子',
          'note': '新笔记',
          'color': 3,
          'at': now - 1000,
        },
        {
          'id': 'hl_new',
          'aid': '100',
          'cid': 'c2',
          'chapter': '第二章',
          'start': 2,
          'end:': 8,
          'end': 8,
          'quote': '远端新增',
          'note': '',
          'color': 2,
          'at': now - 500,
        },
      ],
    };

    final merged = await SyncMerge.merge(remote, deviceId: 'local-dev');
    expect(merged, isTrue);

    final all = HighlightStore.all('100');
    expect(all.map((e) => e.id).toSet(), {'hl_keep', 'hl_new'});
    final kept = HighlightStore.byId('hl_keep')!;
    expect(kept.note, '新笔记');
    expect(kept.color, 3);

    // 快照中包含 highlights
    final snap = SyncMerge.snapshot('local-dev');
    expect((snap['highlights'] as List).length, 2);
  });

  test('HighlightStore.forChapter 返回缓存不可变列表并在变更时失效刷新', () async {
    await HighlightStore.add(aid: '200', cid: 'c1', chapter: '第一章', start: 10, end: 20, quote: '第二句');
    await HighlightStore.add(aid: '200', cid: 'c1', chapter: '第一章', start: 2, end: 8, quote: '第一句');

    final l1 = HighlightStore.forChapter('200', 'c1');
    final l2 = HighlightStore.forChapter('200', 'c1');
    expect(identical(l1, l2), isTrue);
    expect(l1.map((e) => e.start).toList(), [2, 10]);
    expect(() => l1.add(l1.first), throwsUnsupportedError);

    final added = await HighlightStore.add(aid: '200', cid: 'c1', chapter: '第一章', start: 5, end: 9, quote: '中间句');
    final l3 = HighlightStore.forChapter('200', 'c1');
    expect(identical(l1, l3), isFalse);
    expect(l3.map((e) => e.start).toList(), [2, 5, 10]);
    expect(HighlightStore.byId(added.id)?.quote, '中间句');
  });
}
