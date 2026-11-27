import 'dart:io';

import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/next/characters.dart';
import 'package:ark_novel/next/pages/characters_page.dart';
import 'package:ark_novel/next/progress.dart';
import 'package:ark_novel/next/reader/reader_sheets.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/sync_merge.dart';
import 'package:ark_novel/next/volumes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_characters_test');
    Hive.init(tmp.path);
    await Hive.openBox('session');
  });

  tearDown(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('萌娘百科纯文本首段解析与日文检测', () {
    test('MoegirlApi.parseExtract：正常提取纯文本首段，缺页或空白返回 null', () {
      final ok = {
        'batchcomplete': '',
        'query': {
          'pages': {
            '12345': {
              'pageid': 12345,
              'title': '八奈见杏菜',
              'extract': '八奈见杏菜是轻小说《败犬女主太多了！》及其衍生作品的登场角色。\n\n\n青梅竹马系败犬女主。  ',
            },
          },
        },
      };
      expect(MoegirlApi.parseExtract(ok), '八奈见杏菜是轻小说《败犬女主太多了！》及其衍生作品的登场角色。\n\n青梅竹马系败犬女主。');

      final missing = {
        'query': {
          'pages': {
            '-1': {'title': '不存在角色', 'missing': ''},
          },
        },
      };
      expect(MoegirlApi.parseExtract(missing), isNull);
      expect(MoegirlApi.parseExtract(const {'query': {'pages': {'9': {'extract': '   '}}}}), isNull);
      expect(MoegirlApi.parseExtract(null), isNull);
    });

    test('MoegirlApi.isMostlyJapanese / needsCnSummary：识别空简介和日文简介', () {
      expect(MoegirlApi.isMostlyJapanese('高校一年生。明るい性格のヒロイン。'), isTrue);
      expect(MoegirlApi.isMostlyJapanese('高一女生，性格开朗的青梅竹马。'), isFalse);
      expect(MoegirlApi.needsCnSummary('', ''), isTrue);
      expect(MoegirlApi.needsCnSummary('高校一年生。明るい性格のヒロイン。', ''), isTrue);
      expect(MoegirlApi.needsCnSummary('高一女生，性格开朗。', ''), isFalse);
      expect(MoegirlApi.needsCnSummary('高校一年生。明るい性格のヒロイン。', '已有中文简介'), isFalse);
    });
  });

  group('BookCharacters CRUD、自动高亮正则生成与防剧透判断', () {
    test('buildHighlightPattern：按名称与别名长度倒序去重并转义正则特殊字符', () {
      final pat = BookCharacter.buildHighlightPattern('杏菜', ['八奈见杏菜', '老八', '杏菜', 'A.B(真名)']);
      expect(pat, r'A\.B\(真名\)|八奈见杏菜|杏菜|老八');
      expect(ReplaceRule.validate(pat), isNull);
    });

    test('CRUD：新增/更新自动同步 ReplaceRule 与 RuleNotes，关闭高亮保留笔记，删除记墓碑', () async {
      const aid = '2501';
      final created = await BookCharacters.upsert(
        const BookCharacter(
          id: '',
          aid: aid,
          name: '八奈见杏菜',
          originalName: '八奈見杏菜',
          aliases: ['杏菜', '老八'],
          role: CharacterRole.main,
          color: 0xFF1E88E5,
          spoilerVol: 3,
        ),
        enableHighlight: true,
        note: '第一卷出场，爱吃零食',
      );

      expect(created.id, isNotEmpty);
      expect(created.ruleId, isNotEmpty);
      expect(BookCharacters.of(aid).length, 1);
      expect(BookCharacters.byRuleId(aid, created.ruleId)?.id, created.id);
      expect(BookCharacters.isHighlightActive(created), isTrue);

      // ReplaceRule 已创建并绑定到本书
      final rule = ReplaceRules.all().singleWhere((r) => r.id == created.ruleId);
      expect(rule.aid, aid);
      expect(rule.kind, RuleKind.highlight);
      expect(rule.pattern, '八奈见杏菜|杏菜|老八');
      expect(rule.color, 0xFF1E88E5);

      // 笔记直接互通 RuleNotes
      expect(RuleNotes.get(aid, created.ruleId), '第一卷出场，爱吃零食');
      expect(BookCharacters.noteOf(created), '第一卷出场，爱吃零食');

      // 更新别名与颜色同步更新高亮规则
      final updated = await BookCharacters.upsert(
        created.copyWith(aliases: ['杏菜', '老八', '八奈见同学'], color: 0xFFE53935),
        enableHighlight: true,
      );
      final updatedRule = ReplaceRules.all().singleWhere((r) => r.id == updated.ruleId);
      expect(updatedRule.pattern, '八奈见同学|八奈见杏菜|杏菜|老八');
      expect(updatedRule.color, 0xFFE53935);

      // 关闭正文高亮时删除高亮规则但保留个人笔记
      final disabled = await BookCharacters.upsert(updated, enableHighlight: false);
      expect(disabled.ruleId, isEmpty);
      expect(ReplaceRules.all().where((r) => r.id == updated.ruleId), isEmpty);
      expect(BookCharacters.noteOf(disabled), '第一卷出场，爱吃零食');

      // 删除词条时清空笔记并写入 ch:$aid:$id 墓碑
      await BookCharacters.delete(aid, disabled.id);
      expect(BookCharacters.of(aid), isEmpty);
      expect(BookCharacters.noteOf(disabled), isEmpty);
      expect(SyncMerge.tombs().containsKey('ch:$aid:${disabled.id}'), isTrue);
    });

    test('防剧透判断：spoilerVol == 0 不折叠，>0 时当前阅读卷 < spoilerVol 折叠', () async {
      const aid = '2502';
      await Volumes.saveCatalogue(aid, [
        CatVolume(title: '第一卷', chapters: [CatChapter(title: '序章', cid: 'c1')]),
        CatVolume(title: '第二卷', chapters: [CatChapter(title: '一章', cid: 'c2')]),
        CatVolume(title: '第三卷', chapters: [CatChapter(title: '二章', cid: 'c3')]),
      ]);

      const noSpoiler = BookCharacter(id: '1', aid: aid, name: 'A', spoilerVol: 0);
      const vol3Spoiler = BookCharacter(id: '2', aid: aid, name: 'B', spoilerVol: 3);

      expect(BookCharacters.currentReadingVolume(aid), 0);
      expect(noSpoiler.shouldHideSpoiler(0), isFalse);
      expect(vol3Spoiler.shouldHideSpoiler(0), isTrue);

      await ReadingProgress.save(aid, 'c2', 100);
      final v2 = BookCharacters.currentReadingVolume(aid);
      expect(v2, 2);
      expect(vol3Spoiler.shouldHideSpoiler(v2), isTrue);

      expect(BookCharacters.currentReadingVolume(aid, currentCid: 'c3'), 3);
      expect(vol3Spoiler.shouldHideSpoiler(3), isFalse);
      expect(vol3Spoiler.shouldHideSpoiler(4), isFalse);
    });

    test('智能拆姓/名、过滤冗余带空格日文别名与同姓冲突保护', () {
      final batch = [
        (name: '小鸠常悟朗', originalName: '小鳩常悟朗', spacedName: '小鳩 常悟朗', role: CharacterRole.main, aliases: const ['小鳩 常悟朗']),
        (name: '小佐内由纪', originalName: '小佐内ゆき', spacedName: '小佐内 ゆき', role: CharacterRole.main, aliases: const ['小佐内 ゆき']),
        (name: '小佐内母', originalName: '小佐内母', spacedName: '', role: CharacterRole.support, aliases: const <String>[]),
        (name: '堂岛健吾', originalName: '堂島健吾', spacedName: '堂島 健吾', role: CharacterRole.support, aliases: const ['堂島 健吾']),
        (name: '堂岛知里', originalName: '堂島知里', spacedName: '堂島 知里', role: CharacterRole.support, aliases: const <String>[]),
        (name: '艾莉丝·格雷拉特', originalName: 'エリス', spacedName: '', role: CharacterRole.main, aliases: const <String>[]),
      ];
      final out = BookCharacter.deriveCallNamesForBatch(batch);

      // 主角小鸠：拆出 小鸠 / 常悟朗，清除冗余日文带空格别名
      expect(out[0], containsAll(['小鸠', '常悟朗']));
      expect(out[0], isNot(contains('小鳩 常悟朗')));

      // 主角小佐内：优先独占 小佐内，拆出 由纪，清除 小佐内 ゆき
      expect(out[1], containsAll(['小佐内', '由纪']));
      expect(out[1], isNot(contains('小佐内 ゆき')));

      // 配角小佐内母：不抢占主角姓氏 小佐内
      expect(out[2], isNot(contains('小佐内')));

      // 同为配角的堂岛兄妹：跳过歧义姓氏 堂岛，各自保留唯一名字 健吾 / 知里
      expect(out[3], contains('健吾'));
      expect(out[3], isNot(contains('堂岛')));
      expect(out[3], isNot(contains('堂島 健吾')));
      expect(out[4], contains('知里'));
      expect(out[4], isNot(contains('堂岛')));

      // 西式音译名中点拆分
      expect(out[5], containsAll(['艾莉丝', '格雷拉特']));
    });

    test('批量分层高亮、整理已有别名与批量删除', () async {
      const aid = '2505';
      final imported = await BookCharacters.importMany(
        aid,
        const [
          BookCharacter(id: '', aid: aid, name: '小佐内由纪', originalName: '小佐内ゆき', aliases: ['小佐内 ゆき'], role: CharacterRole.main),
          BookCharacter(id: '', aid: aid, name: '堂岛健吾', originalName: '堂島健吾', aliases: ['堂島 健吾'], role: CharacterRole.support),
          BookCharacter(id: '', aid: aid, name: '坂上', originalName: 'サカガミ', aliases: [], role: CharacterRole.support),
        ],
        shouldHighlight: (c) => c.role == CharacterRole.main,
      );
      expect(imported.length, 3);
      expect(BookCharacters.isHighlightActive(imported[0]), isTrue);
      expect(BookCharacters.isHighlightActive(imported[1]), isFalse);
      expect(BookCharacters.isHighlightActive(imported[2]), isFalse);

      // 一键整理已有词条：清除日文空格别名、补上常用中文称呼并同步刷新高亮正则
      final fixed = await BookCharacters.normalizeExisting(aid);
      expect(fixed, 2);
      final after = BookCharacters.of(aid);
      expect(after[0].aliases, containsAll(['小佐内', '由纪']));
      expect(after[0].aliases, isNot(contains('小佐内 ゆき')));
      final mainRule = ReplaceRules.all().singleWhere((r) => r.id == after[0].ruleId);
      expect(mainRule.pattern, contains('小佐内'));

      // 一键关闭全部高亮
      await BookCharacters.setHighlightForAll(aid, predicate: (_) => false);
      expect(BookCharacters.of(aid).every((c) => !BookCharacters.isHighlightActive(c)), isTrue);

      // 批量删除配角
      final delCount = await BookCharacters.deleteMany(aid, {after[1].id, after[2].id});
      expect(delCount, 2);
      expect(BookCharacters.of(aid).map((c) => c.name).toList(), ['小佐内由纪']);
    });

    test('batchUpdateCnSummaries：批量写入多条中文简介无写丢失，且不重复改写高亮规则', () async {
      const aid = '2099';
      final imported = await BookCharacters.importMany(
        aid,
        const [
          BookCharacter(id: 'b1', aid: aid, name: '角色甲', role: CharacterRole.main),
          BookCharacter(id: 'b2', aid: aid, name: '角色乙', role: CharacterRole.main),
          BookCharacter(id: 'b3', aid: aid, name: '角色丙', role: CharacterRole.support),
        ],
        enableHighlight: true,
      );
      expect(imported.length, 3);
      final rulesVerBefore = ReplaceRules.changes.value;
      final updated = await BookCharacters.batchUpdateCnSummaries(aid, const {
        'b1': '甲的萌娘百科中文简介',
        'b2': '乙的萌娘百科中文简介',
        'b3': '丙的萌娘百科中文简介',
      });
      expect(updated, 3);
      // 不重写高亮规则
      expect(ReplaceRules.changes.value, rulesVerBefore);
      final after = {for (final c in BookCharacters.of(aid)) c.id: c};
      expect(after['b1']!.cnSummary, '甲的萌娘百科中文简介');
      expect(after['b2']!.cnSummary, '乙的萌娘百科中文简介');
      expect(after['b3']!.cnSummary, '丙的萌娘百科中文简介');
      // activeHighlightRuleIds 批量查询准确
      final activeIds = BookCharacters.activeHighlightRuleIds();
      expect(after.values.every((c) => activeIds.contains(c.ruleId)), isTrue);

      // onlyIfEmpty=true 时不覆盖已有中文简介
      final skipped = await BookCharacters.batchUpdateCnSummaries(aid, const {'b1': '新简介不应覆盖'}, onlyIfEmpty: true);
      expect(skipped, 0);
      expect(BookCharacters.byId(aid, 'b1')!.cnSummary, '甲的萌娘百科中文简介');
    });
  });

  group('SyncMerge 增量合并 chars 与墓碑删除', () {
    test('按 id + ts 合并两端人物词典，遵循 ch:aid:id 墓碑删除并兼容 v3 快照', () async {
      const aid = '3001';
      final now = DateTime.now().millisecondsSinceEpoch;
      final localOld = BookCharacter(id: 'c1', aid: aid, name: '旧名', ts: now - 5000);
      final localNew = BookCharacter(id: 'c2', aid: aid, name: '本地更新版', ts: now - 1000);
      final localToBeDeleted = BookCharacter(id: 'c3', aid: aid, name: '将被远端删除', ts: now - 4000);
      await Hive.box('session').put('chars:$aid', [localOld.toMap(), localNew.toMap(), localToBeDeleted.toMap()]);

      // 本机 snapshot 携带 v:3 与 chars 字段
      final snap = SyncMerge.snapshot('devA');
      expect(snap['v'], 3);
      expect((snap['chars'] as Map)[aid], hasLength(3));

      final remote = <String, dynamic>{
        'v': 3,
        'device': 'devB',
        'at': now,
        'tomb': {'ch:$aid:c3': now - 2000},
        'chars': {
          aid: [
            BookCharacter(id: 'c1', aid: aid, name: '远端新名', aliases: const ['新别名'], ts: now - 2000).toMap(),
            BookCharacter(id: 'c2', aid: aid, name: '远端旧版', ts: now - 3000).toMap(),
            BookCharacter(id: 'c4', aid: aid, name: '远端新增角色', ts: now - 1500).toMap(),
          ],
        },
      };

      final merged = await SyncMerge.merge(remote, deviceId: 'devA');
      expect(merged, isTrue);

      final result = {for (final c in BookCharacters.of(aid)) c.id: c};
      expect(result.keys.toSet(), {'c1', 'c2', 'c4'}); // c3 被墓碑删除
      expect(result['c1']!.name, '远端新名'); // 远端 ts 更新，赢
      expect(result['c1']!.aliases, ['新别名']);
      expect(result['c2']!.name, '本地更新版'); // 本地 ts 更新，赢
      expect(result['c4']!.name, '远端新增角色'); // 新增合并进来
    });
  });

  testWidgets('showCharacterReaderSheet：防剧透折叠点击展开后可编辑保存笔记并触发搜索全书出场', (tester) async {
    const aid = '3009';
    late BookCharacter ch;
    await tester.runAsync(() async {
      await Volumes.saveCatalogue(aid, [
        CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: 'c1')]),
        CatVolume(title: '第三卷', chapters: [CatChapter(title: '第三章', cid: 'c3')]),
      ]);
      ch = await BookCharacters.upsert(
        const BookCharacter(
          id: '',
          aid: aid,
          name: '八奈见杏菜',
          originalName: '八奈見杏菜',
          aliases: ['老八'],
          role: CharacterRole.main,
          summary: '败犬女主一号。',
          spoilerVol: 3,
        ),
        enableHighlight: true,
        note: '第三卷重要伏笔',
      );
    });

    List<String>? searchedTerms;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showCharacterReaderSheet(
                  context,
                  aid: aid,
                  character: ch,
                  currentCid: 'c1',
                  palette: const ReaderPalette(Color(0xFFF6F1E7), Color(0xFF2B2A27)),
                  accent: Colors.blue,
                  onSearchAppearances: (terms) => searchedTerms = terms,
                  onOpenDictionary: () {},
                  onChanged: () {},
                ),
                child: const Text('打开角色浮窗'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开角色浮窗'));
    await tester.pumpAndSettle();

    expect(find.text('八奈见杏菜'), findsOneWidget);
    expect(find.text('别名：老八'), findsOneWidget);
    expect(find.textContaining('防剧透保护'), findsOneWidget);
    expect(find.text('第三卷重要伏笔'), findsNothing);

    // 点击展开防剧透笔记
    await tester.tap(find.textContaining('防剧透保护'));
    await tester.pumpAndSettle();
    expect(find.text('第三卷重要伏笔'), findsOneWidget);

    // 点击搜索全书出场
    await tester.tap(find.text('搜索全书出场'));
    await tester.pumpAndSettle();
    expect(searchedTerms, ['八奈见杏菜', '老八']);
  });

  group('BookCharacters 内存缓存与本地头像索引', () {
    test('BookCharacters.of(aid)：未改动时复用同一不可变列表实例，变更后立即刷新', () async {
      const aid = '4100';
      await BookCharacters.upsert(const BookCharacter(id: 'k1', aid: aid, name: '角色A'));
      final first = BookCharacters.of(aid);
      final second = BookCharacters.of(aid);
      expect(identical(first, second), isTrue);
      expect(() => first.add(const BookCharacter(id: 'x', aid: aid, name: '非法修改')), throwsUnsupportedError);

      await BookCharacters.upsert(const BookCharacter(id: 'k2', aid: aid, name: '角色B'));
      final third = BookCharacters.of(aid);
      expect(identical(first, third), isFalse);
      expect(third.length, 2);
    });

    test('本地头像目录索引：ensureAvatarDirLoaded 扫描建索引，增删同步维护且不回退 existsSync', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      BookCharacters.resetAvatarCacheForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => tmp.path,
      );
      addTearDown(() {
        BookCharacters.resetAvatarCacheForTest();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
      });

      final fileName = await BookCharacters.saveLocalAvatar('hero1', Uint8List.fromList([1, 2, 3, 4]));
      final resolved = BookCharacters.localAvatarFileSync(fileName);
      expect(resolved, isNotNull);
      expect(resolved!.existsSync(), isTrue);

      // 重置内存缓存后，在重新扫描前 localAvatarFileSync 必须返回 null（不走同步 existsSync）
      BookCharacters.resetAvatarCacheForTest();
      expect(BookCharacters.localAvatarFileSync(fileName), isNull);

      // 重新异步扫描后恢复命中
      await BookCharacters.ensureAvatarDirLoaded();
      expect(BookCharacters.localAvatarFileSync(fileName), isNotNull);

      // 删除后同步从索引与磁盘移除
      await BookCharacters.deleteLocalAvatar(fileName);
      expect(BookCharacters.localAvatarFileSync(fileName), isNull);
      expect(resolved.existsSync(), isFalse);
    });
  });
}
