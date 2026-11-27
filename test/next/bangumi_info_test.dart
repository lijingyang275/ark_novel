import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/bangumi.dart';
import 'package:ark_novel/next/widgets_bgm.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

class _MockBgmAdapter implements HttpClientAdapter {
  _MockBgmAdapter(this.handler);

  final (int status, Object body) Function(RequestOptions options) handler;
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add('${options.method} ${options.path}');
    final (status, body) = handler(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _AsyncMockBgmAdapter implements HttpClientAdapter {
  _AsyncMockBgmAdapter(this.handler);

  final Future<(int status, Object body)> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final (status, body) = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_bgm_info_test');
    Hive.init(tmp.path);
    await Hive.openBox('session');
  });

  tearDown(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('Bangumi 单卷匹配兜底与条目详情解析', () {
    test('pickBgmNovelHit：优先 series == true，无系列条目时兜底单卷小说', () {
      final mixed = [
        {'id': 1, 'platform': '漫画', 'series': true},
        {'id': 2, 'platform': '小说', 'series': false, 'name': '三日間の幸福'},
        {'id': 3, 'platform': '小说', 'series': true, 'name': '系列轻小说'},
      ];
      expect(pickBgmNovelHit(mixed)?['id'], 3);

      final singleOnly = [
        {'id': 10, 'platform': '漫画', 'series': true},
        {'id': 20, 'platform': '小说', 'series': false, 'name': '三日間の幸福', 'name_cn': '三日间的幸福'},
      ];
      expect(pickBgmNovelHit(singleOnly)?['id'], 20);
      expect(pickBgmNovelHit(const [{'id': 1, 'platform': '漫画', 'series': false}]), isNull);
    });

    test('BgmSubjectInfo.fromApi：解析评分、排名、发售日、前 8 热门标签与关联动画/漫画（过滤单行本）', () {
      final subj = {
        'id': 345678,
        'name': '負けヒロインが多すぎる!',
        'name_cn': '败犬女主太多了！',
        'date': '2021-07-21',
        'summary': '高中生温水和彦的青春喜剧。',
        'rating': {'score': 7.9, 'total': 1234, 'rank': 128},
        'tags': [
          for (var i = 1; i <= 10; i++) {'name': '标签$i', 'count': i * 10},
        ],
      };
      final rawRels = [
        {'id': 1001, 'name': 'Vol.1', 'name_cn': '', 'relation': '单行本', 'type': 1, 'images': {'medium': 'https://img/v1.jpg'}},
        {'id': 2001, 'name': 'Anime', 'name_cn': '败犬女主太多了！动画', 'relation': '动画', 'type': 2, 'images': {'medium': 'https://img/a1.jpg'}},
        {'id': 3001, 'name': 'Manga', 'name_cn': '败犬女主太多了！漫画', 'relation': '书籍', 'type': 1, 'images': {'large': 'https://img/m1.jpg'}},
        {'id': 2001, 'name': 'Anime Dup', 'name_cn': '重复动画', 'relation': '动画', 'type': 2, 'images': {'medium': 'https://img/a1.jpg'}},
        {'id': 4001, 'name': 'OST', 'name_cn': '原声集', 'relation': '原声集', 'type': 3, 'images': {'medium': 'https://img/ost.jpg'}},
      ];

      final info = BgmSubjectInfo.fromApi(subj, rawRels, fetchedAt: 1700000000000);
      expect(info.id, 345678);
      expect(info.name, '負けヒロインが多すぎる!');
      expect(info.nameCn, '败犬女主太多了！');
      expect(info.score, 7.9);
      expect(info.ratingTotal, 1234);
      expect(info.rank, 128);
      expect(info.date, '2021-07-21');
      expect(info.summary, '高中生温水和彦的青春喜剧。');
      // 按热度降序取前 8 个标签
      expect(info.tags.length, 8);
      expect(info.tags.first, '标签10');
      expect(info.tags.last, '标签3');
      // 保留动画（type == 2）与非单行本漫画（type == 1 && relation != '单行本'），并去重
      expect(info.relations.length, 2);
      expect(info.relations[0].id, 2001);
      expect(info.relations[0].displayName, '败犬女主太多了！动画');
      expect(info.relations[0].type, 2);
      expect(info.relations[1].id, 3001);
      expect(info.relations[1].img, 'https://img/m1.jpg');

      // 序列化往返一致
      final roundtrip = BgmSubjectInfo.fromMap(info.toMap());
      expect(roundtrip.id, info.id);
      expect(roundtrip.score, info.score);
      expect(roundtrip.tags, info.tags);
      expect(roundtrip.relations.length, 2);
      expect(roundtrip.relations[0].displayName, '败犬女主太多了！动画');
    });

    test('subjectInfo：单卷小说兜底命中、写 bgm_info 缓存且 7 天内直接复用缓存', () async {
      final adapter = _MockBgmAdapter((opt) {
        if (opt.path.endsWith('/search/subjects')) {
          return (
            200,
            {
              'data': [
                {
                  'id': 99999,
                  'platform': '小说',
                  'series': false,
                  'name': '三日間の幸福',
                  'name_cn': '三日间的幸福',
                  'images': {'large': 'https://lain.bgm.tv/pic/cover/l/mikka.jpg'},
                },
              ],
            },
          );
        }
        if (opt.path.endsWith('/subjects/99999/subjects')) {
          return (
            200,
            [
              {'id': 88888, 'name': '寿命を買い取ってもらった。', 'name_cn': '我以三天的幸福换取寿命', 'relation': '书籍', 'type': 1, 'images': {'medium': 'https://lain.bgm.tv/m.jpg'}},
            ],
          );
        }
        if (opt.path.endsWith('/subjects/99999')) {
          return (
            200,
            {
              'id': 99999,
              'name': '三日間の幸福',
              'name_cn': '三日间的幸福',
              'date': '2013-12-25',
              'summary': '以寿命换钱的故事。',
              'rating': {'score': 8.3, 'total': 4500, 'rank': 55},
              'tags': [{'name': '三秋缒', 'count': 500}, {'name': '治愈', 'count': 300}],
            },
          );
        }
        return (404, {});
      });

      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
      final info = await bgm.subjectInfo('777', fallbackTitle: '三日间的幸福');
      expect(info, isNotNull);
      expect(info!.id, 99999);
      expect(info.score, 8.3);
      expect(info.rank, 55);
      expect(info.relations.length, 1);

      // 本地缓存可直接秒出
      final saved = BangumiCovers.savedInfo('777');
      expect(saved?.id, 99999);
      expect(saved?.nameCn, '三日间的幸福');

      // 单卷小说自身封面作为第 1 卷保存进 bgm:777
      expect(BangumiCovers.saved('777')?.vols.single.img, 'https://lain.bgm.tv/pic/cover/l/mikka.jpg');

      // 7 天内再次请求不再发网络请求
      final reqCount = adapter.requests.length;
      final again = await bgm.subjectInfo('777', fallbackTitle: '三日间的幸福');
      expect(again?.id, 99999);
      expect(adapter.requests.length, reqCount);
    });

    test('series 与 subjectInfo 并发同一本书时单飞去重且复用 /subjects/{id}/subjects 关系响应', () async {
      await Hive.box('session').put('lib:books', {
        '778': {'aid': '778', 'title': '三日间的幸福', 'img': '', 'added': 1, 'cats': <String>[]},
      });
      final adapter = _MockBgmAdapter((opt) {
        if (opt.path.endsWith('/search/subjects')) {
          return (
            200,
            {
              'data': [
                {
                  'id': 99998,
                  'platform': '小说',
                  'series': true,
                  'name': '三日間の幸福',
                  'name_cn': '三日间的幸福',
                  'images': {'large': 'https://lain.bgm.tv/pic/cover/l/mikka.jpg'},
                },
              ],
            },
          );
        }
        if (opt.path.endsWith('/subjects/99998/subjects')) {
          return (
            200,
            [
              {'id': 1, 'name': '三日間の幸福 (1)', 'relation': '单行本', 'type': 1, 'images': {'large': 'https://lain.bgm.tv/v1.jpg'}},
              {'id': 2, 'name': 'Anime', 'name_cn': '动画', 'relation': '动画', 'type': 2, 'images': {'medium': 'https://lain.bgm.tv/a.jpg'}},
            ],
          );
        }
        if (opt.path.endsWith('/subjects/99998')) {
          return (
            200,
            {
              'id': 99998,
              'name': '三日間の幸福',
              'name_cn': '三日间的幸福',
              'date': '2013-12-25',
              'summary': '简介',
              'rating': {'score': 8.3, 'total': 4500, 'rank': 55},
              'tags': const <Map>[],
            },
          );
        }
        return (404, {});
      });

      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
      final results = await Future.wait<Object?>([
        bgm.series('778'),
        bgm.subjectInfo('778', fallbackTitle: '三日间的幸福'),
      ]);
      expect(results[0], isNotNull);
      expect((results[1] as BgmSubjectInfo?)?.id, 99998);
      // 搜索只发 1 次、关系接口也只发 1 次（被 _recentRelations 复用）
      expect(adapter.requests.where((r) => r.contains('/search/subjects')).length, 1);
      expect(adapter.requests.where((r) => r.contains('/subjects/99998/subjects')).length, 1);
    });

    test('满并发排队时交替调用 subjectInfo 与 series 不会发生信号量死锁', () async {
      await Hive.box('session').put('lib:books', {
        for (final id in ['801', '802', '803', '804']) id: {'aid': id, 'title': '轻小说$id', 'img': '', 'added': 1, 'cats': <String>[]},
      });
      final gate = Completer<void>();
      final adapter = _AsyncMockBgmAdapter((opt) async {
        final kw = (opt.data as Map?)?['keyword'] as String?;
        if (opt.path.endsWith('/search/subjects')) {
          if (kw == '轻小说801' || kw == '轻小说802') await gate.future;
          final numId = int.parse(kw!.replaceAll(RegExp('[^0-9]'), '')) + 10000;
          return (
            200,
            {
              'data': [
                {'id': numId, 'platform': '小说', 'series': true, 'name': kw, 'name_cn': kw, 'images': {'large': 'https://lain.bgm.tv/$numId.jpg'}},
              ],
            },
          );
        }
        if (opt.path.endsWith('/subjects')) {
          return (200, const <Map>[]);
        }
        final m = RegExp(r'/subjects/(\d+)$').firstMatch(opt.path);
        if (m != null) {
          final id = int.parse(m[1]!);
          return (200, {'id': id, 'name': '书$id', 'name_cn': '书$id', 'rating': {'score': 8.0, 'total': 100, 'rank': 10}, 'tags': const <Map>[]});
        }
        return (404, {});
      });

      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
      // 先占满 _bookSem 的 2 个槽位
      final f1 = bgm.series('801');
      final f2 = bgm.series('802');
      // 接着为 803、804 先调用 subjectInfo 再调用 series（旧实现会在这里形成 AB-BA 永久死锁）
      final info3 = bgm.subjectInfo('803');
      final info4 = bgm.subjectInfo('804');
      final s3 = bgm.series('803');
      final s4 = bgm.series('804');

      gate.complete();
      final all = await Future.wait<Object?>([f1, f2, info3, info4, s3, s4]).timeout(const Duration(seconds: 3));
      expect((all[2] as BgmSubjectInfo?)?.id, 10803);
      expect((all[3] as BgmSubjectInfo?)?.id, 10804);
      expect((all[4] as BgmSeries?)?.id, 10803);
      expect((all[5] as BgmSeries?)?.id, 10804);
    });

    test('本地无书名时，先发起的 series() 不会拖累带 fallbackTitle 的 subjectInfo() 写入负缓存', () async {
      final adapter = _MockBgmAdapter((opt) {
        if (opt.path.endsWith('/search/subjects')) {
          return (
            200,
            {
              'data': [
                {'id': 99997, 'platform': '小说', 'series': true, 'name': '未入架新书', 'name_cn': '未入架新书', 'images': {'large': 'https://lain.bgm.tv/new.jpg'}},
              ],
            },
          );
        }
        if (opt.path.endsWith('/subjects/99997/subjects')) return (200, const <Map>[]);
        if (opt.path.endsWith('/subjects/99997')) {
          return (200, {'id': 99997, 'name': '未入架新书', 'name_cn': '未入架新书', 'rating': {'score': 8.5, 'total': 200, 'rank': 20}, 'tags': const <Map>[]});
        }
        return (404, {});
      });

      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
      final results = await Future.wait<Object?>([
        bgm.series('901'),
        bgm.subjectInfo('901', fallbackTitle: '未入架新书'),
      ]);
      expect(results[0], isNull);
      expect((results[1] as BgmSubjectInfo?)?.id, 99997);
      expect(BangumiCovers.savedInfo('901')?.id, 99997);
    });
  });

  group('Bangumi 角色列表与 infobox 简体中文名/别名解析', () {
    test('BgmCharacter.parseInfobox：解析简体中文名、字符串与列表别名并跳过假名/罗马字', () {
      final parsed = BgmCharacter.parseInfobox([
        {'key': '简体中文名', 'value': '八奈见杏菜'},
        {
          'key': '别名',
          'value': [
            {'k': '纯假名', 'v': 'やなみ あんな'},
            {'k': '罗马字', 'v': 'Yanami Anna'},
            {'k': '昵称', 'v': '老八'},
            {'v': '杏菜'},
            {'v': '八奈见杏菜'}, // 与简体中文名重复，应自动去重
          ],
        },
      ]);
      expect(parsed.nameCn, '八奈见杏菜');
      expect(parsed.aliases, ['老八', '杏菜']);

      final strAlias = BgmCharacter.parseInfobox([
        {'key': '简体中文名', 'value': '温水和彦'},
        {'key': '别名', 'value': '温水、ぬっくん / 阿水'},
      ]);
      expect(strAlias.nameCn, '温水和彦');
      expect(strAlias.aliases, ['温水', 'ぬっくん', '阿水']);

      // 跳过日文名并单独提取带空格原名（供拆姓/名使用）
      final shoshiminInfobox = [
        {'key': '简体中文名', 'value': '小鸠常悟朗'},
        {
          'key': '别名',
          'value': [
            {'k': '日文名', 'v': '小鳩 常悟朗'},
            {'k': '纯假名', 'v': 'こばと じょうごろう'},
            {'k': '罗马字', 'v': 'Kobato Jōgorō'},
          ],
        },
      ];
      final parsedShoshimin = BgmCharacter.parseInfobox(shoshiminInfobox, originalName: '小鳩常悟朗');
      expect(parsedShoshimin.nameCn, '小鸠常悟朗');
      expect(parsedShoshimin.aliases, isEmpty);
      expect(BgmCharacter.extractSpacedName(shoshiminInfobox), '小鳩 常悟朗');
    });

    test('bgmCharacterAvatarUrl / bgmCharacterFullUrl：转换上半身特写与完整立绘地址', () {
      const medium = 'https://lain.bgm.tv/r/400/pic/crt/l/1a/22/150624_crt_suCuN.jpg?r=1724765521';
      const expectedAvatar = 'https://lain.bgm.tv/pic/crt/m/1a/22/150624_crt_suCuN.jpg?r=1724765521';
      const expectedFull = 'https://lain.bgm.tv/pic/crt/l/1a/22/150624_crt_suCuN.jpg?r=1724765521';
      expect(bgmCharacterAvatarUrl(medium), expectedAvatar);
      expect(bgmCharacterFullUrl(expectedAvatar), expectedFull);
      expect(bgmCharacterAvatarUrl('https://example.com/custom.png'), 'https://example.com/custom.png');
    });

    test('characters：小说角色少于 3 个时合并首个关联动画角色，且 enrichCharacters 拉取详情写回缓存', () async {
      final adapter = _MockBgmAdapter((opt) {
        if (opt.path.endsWith('/subjects/100/characters')) {
          return (
            200,
            [
              {'id': 1, 'name': '温水和彦', 'relation': '主角', 'images': {'medium': 'https://img/c1.jpg'}},
            ],
          );
        }
        if (opt.path.endsWith('/subjects/100/subjects')) {
          return (
            200,
            [
              {'id': 200, 'name': 'Anime', 'name_cn': '动画', 'relation': '动画', 'type': 2, 'images': {'medium': 'https://img/a.jpg'}},
            ],
          );
        }
        if (opt.path.endsWith('/subjects/200/characters')) {
          return (
            200,
            [
              {'id': 1, 'name': '温水和彦', 'relation': '主角', 'images': {'medium': 'https://img/c1.jpg'}},
              {'id': 2, 'name': '八奈見杏菜', 'relation': '主角', 'images': {'medium': 'https://img/c2.jpg'}},
              {'id': 3, 'name': '焼塩檸檬', 'relation': '配角', 'images': {'large': 'https://img/c3.jpg'}},
            ],
          );
        }
        if (opt.path.endsWith('/characters/2')) {
          return (
            200,
            {
              'id': 2,
              'name': '八奈見杏菜',
              'summary': '开朗的败犬女主。',
              'infobox': [
                {'key': '简体中文名', 'value': '八奈见杏菜'},
                {'key': '别名', 'value': [{'k': '昵称', 'v': '老八'}]},
              ],
            },
          );
        }
        if (opt.path.endsWith('/characters/1') || opt.path.endsWith('/characters/3')) {
          return (200, {'id': 1, 'name': '角色', 'summary': '', 'infobox': []});
        }
        return (404, {});
      });

      await Hive.box('session').put('bgm:500', {'id': 100, 'name': '测试', 'vols': [], 'x': [], 't': DateTime.now().millisecondsSinceEpoch});
      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
      final list = await bgm.characters('500');
      expect(list.map((c) => c.id).toList(), [1, 2, 3]);
      expect(list[2].img, 'https://img/c3.jpg');

      final enriched = await bgm.enrichCharacters('500', list);
      final anna = enriched.firstWhere((c) => c.id == 2);
      expect(anna.nameCn, '八奈见杏菜');
      expect(anna.aliases, ['老八']);
      expect(anna.summary, '开朗的败犬女主。');
      expect(anna.enriched, isTrue);

      // 缓存已更新
      final cached = BangumiCovers.savedCharacters('500');
      expect(cached?.firstWhere((c) => c.id == 2).nameCn, '八奈见杏菜');
    });
  });

  group('Backup 排除 bgm_* 缓存并兼容 char_avatar 目录', () {
    test('新导出排除 bgm_info:* / bgm_chars:*，打包并恢复 char_avatar，旧备份无该目录也可恢复', () async {
      final support = p.join(tmp.path, 'support');
      final zip = p.join(tmp.path, 'bk.zip');
      final box = Hive.box('session');
      await box.putAll({
        'palette': 1,
        'bgm_info:10': {'id': 1, 't': 100},
        'bgm_chars:10': {'t': 100, 'list': []},
        'chars:10': [{'id': 'c1', 'aid': '10', 'name': '杏菜', 'localAvatar': 'c1.png', 'ts': 10}],
      });
      await Directory(p.join(support, 'char_avatar')).create(recursive: true);
      await File(p.join(support, 'char_avatar', 'c1.png')).writeAsString('pngdata');

      final rawJson = Backup.make();
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      final exportedBox = decoded['box'] as Map<String, dynamic>;
      expect(exportedBox.containsKey('bgm_info:10'), isFalse);
      expect(exportedBox.containsKey('bgm_chars:10'), isFalse);
      expect(exportedBox.containsKey('chars:10'), isTrue);

      await Backup.pack(zip, rawJson, support);
      await File(p.join(support, 'char_avatar', 'c1.png')).delete();
      await box.clear();
      await box.close();

      await Backup.unpack(zip, support);
      await Backup.apply(support);
      final restored = await Hive.openBox('session');
      expect((restored.get('chars:10') as List).length, 1);
      expect(File(p.join(support, 'char_avatar', 'c1.png')).readAsStringSync(), 'pngdata');

      // 旧备份不含 char_avatar 目录也能正常恢复
      await restored.close();
      final oldZip = p.join(tmp.path, 'old.zip');
      final encoder = ZipFileEncoder()..create(oldZip);
      encoder.addArchiveFile(ArchiveFile.string('data.json', '{"backup":3,"box":{"palette":4}}'));
      await encoder.close();

      await Backup.unpack(oldZip, support);
      await Backup.apply(support);
      final restoredOld = await Hive.openBox('session');
      expect(restoredOld.get('palette'), 4);
      expect(File(p.join(support, 'char_avatar', 'c1.png')).existsSync(), isFalse);
    });
  });

  testWidgets('BangumiInfoCard：有缓存直接秒出并展示评分、原名、标签与关联作品', (tester) async {
    final info = BgmSubjectInfo(
      id: 345678,
      name: '負けヒロインが多すぎる!',
      nameCn: '败犬女主太多了！',
      score: 7.9,
      ratingTotal: 1234,
      rank: 128,
      date: '2021-07-21',
      summary: '简介',
      tags: const ['校园', '恋爱'],
      relations: const [
        BgmRelation(id: 2001, name: 'Anime', nameCn: '败犬女主太多了！动画', relation: '动画', type: 2, img: ''),
      ],
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await tester.runAsync(() => Hive.box('session').put('bgm_info:888', info.toMap()));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: BangumiInfoCard(aid: '888', title: '败犬女主太多了！')),
        ),
      ),
    );

    expect(find.text('Bangumi'), findsOneWidget);
    expect(find.text('7.9'), findsOneWidget);
    expect(find.textContaining('1234 人评价'), findsOneWidget);
    expect(find.textContaining('#128'), findsOneWidget);
    expect(find.textContaining('負けヒロインが多すぎる!'), findsOneWidget);
    expect(find.text('校园'), findsOneWidget);
    expect(find.text('动画 · 败犬女主太多了！动画'), findsOneWidget);
    expect(find.text('在 Bangumi 查看'), findsOneWidget);
  });

  test('BangumiCovers：bgm:\$aid 30 天 stale-while-revalidate 立即返回旧缓存并后台刷新；forceRefresh 不复用非强刷任务', () async {
    final oldTs = DateTime.now().subtract(const Duration(days: 35)).millisecondsSinceEpoch;
    await Hive.box('session').put('bgm:601', {
      'id': 3001,
      'name': '旧系列名',
      'vols': [{'n': 'Vol.1', 'i': 'https://lain.bgm.tv/old1.jpg'}],
      'x': <Map>[],
      't': oldTs,
    });
    final revalidated = Completer<void>();
    final adapter = _MockBgmAdapter((opt) {
      if (opt.path.endsWith('/subjects/3001/subjects')) {
        if (!revalidated.isCompleted) revalidated.complete();
        return (
          200,
          [
            {'id': 1, 'name': 'Vol.1', 'relation': '单行本', 'type': 1, 'images': {'large': 'https://lain.bgm.tv/old1.jpg'}},
            {'id': 2, 'name': 'Vol.2', 'relation': '单行本', 'type': 1, 'images': {'large': 'https://lain.bgm.tv/new2.jpg'}},
          ],
        );
      }
      return (404, {});
    });
    final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter);
    // 立即返回旧缓存（1 卷），同时后台静默刷新为 2 卷
    final first = await bgm.series('601');
    expect(first?.vols.length, 1);
    await revalidated.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(BangumiCovers.saved('601')?.vols.length, 2);

    // forceRefresh: true 不复用非 forceRefresh 的在途角色拉取任务
    var charCalls = 0;
    final gate = Completer<void>();
    final asyncAdapter = _AsyncMockBgmAdapter((opt) async {
      if (opt.path.endsWith('/subjects/3001/characters')) {
        final call = ++charCalls;
        if (call == 1) await gate.future;
        return (
          200,
          [
            {'id': call, 'name': '角色$call', 'relation': '主角', 'images': {'medium': 'https://img/c$call.jpg'}},
            {'id': call + 10, 'name': '角色B', 'relation': '配角', 'images': {'medium': ''}},
            {'id': call + 20, 'name': '角色C', 'relation': '配角', 'images': {'medium': ''}},
          ],
        );
      }
      return (200, const <Map>[]);
    });
    final bgm2 = BangumiCovers(Dio()..httpClientAdapter = asyncAdapter);
    final normalF = bgm2.characters('601');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final forced = await bgm2.characters('601', forceRefresh: true);
    expect(forced.first.id, 2);
    gate.complete();
    await normalF;
    expect(charCalls, 2);
  });
}
