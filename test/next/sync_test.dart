import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/bookmarks.dart';
import 'package:ark_novel/next/history.dart';
import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ark_novel/next/sync.dart';
import 'package:ark_novel/next/volumes.dart';

void main() {
  late Box box;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_sync_test').path);
    box = await Hive.openBox('session');
  });

  setUp(() => box.clear());

  statsDeleteTests(() => box);

  Map<String, dynamic> remote({Map<String, dynamic> extra = const {}}) => {
    'v': 1,
    'device': 'other',
    'progress': {},
    'history': [],
    'bookmarks': [],
    'read': {},
    'readchars': {},
    'rating': {},
    'rules': [],
    'notes': {},
    'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
    ...extra,
  };

  test('进度：新的赢；书签、已读章节、备注取并集，本机的备注优先', () async {
    await box.put('progress:1', ['a', 10, 1000]);
    await box.put('progress:2', ['x', 5, 9000]);
    await box.put('read:1', ['a']);
    await box.put('notes:1', {'r1': '本机备注'});
    await Sync.merge(remote(extra: {
      'progress': {'1': ['b', 99, 2000], '2': ['y', 1, 100]},
      'read': {'1': ['b']},
      'bookmarks': [
        {'aid': '1', 'book': 'B', 'cid': 'b', 'chapter': 'c', 'offset': 5, 'excerpt': 'e', 'time': 1},
      ],
      'notes': {'1': {'r1': '对方备注', 'r2': '新备注'}},
    }));
    expect(box.get('progress:1'), ['b', 99, 2000]);
    expect(box.get('progress:2'), ['x', 5, 9000]);
    expect((box.get('read:1') as List).toSet(), {'a', 'b'});
    expect((box.get('bookmarks') as List).length, 1);
    expect(box.get('notes:1'), {'r1': '本机备注', 'r2': '新备注'});
  });

  test('重复合并同一份数据结果不变', () async {
    final r = remote(extra: {
      'history': [
        {'aid': '1', 'title': 'T', 'img': '', 'cid': 'a', 'chapter': 'c', 'time': 5},
      ],
      'rules': [
        {'p': 'x', 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': 'h1'},
      ],
    });
    await Sync.merge(r);
    await Sync.merge(r);
    expect((box.get('history2') as List).length, 1);
    expect((box.get('rules') as List).length, 1);
  });

  test('其他设备的统计单独存放，显示时相加，本机继续累加不会带上对方的数', () async {
    await box.put('stats:day', {'2026-10-20': 60});
    await Sync.merge(remote(extra: {
      'stats': {'day': {'2026-10-20': 100}, 'book': {'1': 100}, 'chapters': 3, 'meta': {}, 'days': {'1': ['2026-10-20']}},
    }));
    expect(ReadingStats.perDay()['2026-10-20'], 160);
    expect(ReadingStats.chapters, 3);
    await ReadingStats.addSeconds('1', 30);
    expect(box.get('stats:day'), {ReadingStats.dayKey(DateTime.now()): 30, '2026-10-20': 60}.map((k, v) => MapEntry(k, v)));
    expect(Sync.snapshot()['stats']['day'], isNot(contains('160')));
  });

  test('删除靠墓碑同步：对方删了本机也删，本机删了不会被对方带回来，删除后重新添加的保留', () async {
    Map<String, Object> mark(int offset, int time) => {'aid': '1', 'book': 'B', 'cid': 'c', 'chapter': 'c', 'offset': offset, 'excerpt': 'e', 'time': time};
    Map<String, Object> rule(String id, int ts, {String p = 'x'}) => {'p': p, 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': id, 'ts': ts};
    final now = DateTime.now().millisecondsSinceEpoch;

    // 对方删了：本机的旧书签、旧规则被删
    await box.put('bookmarks', [mark(100, 10), mark(500, now + 10000)]);
    await box.put('rules', [rule('a', 5), rule('b', 5)]);
    await Sync.merge(remote(extra: {
      'tomb': {'b:1:c:100': now, 'b:1:c:500': now, 'r:a': now},
    }));
    expect((box.get('bookmarks') as List).map((e) => e['offset']), [500]); // 删除之后又加的书签留下
    expect((box.get('rules') as List).map((e) => e['id']), ['b']);

    // 本机删了：对方的旧数据带不回来
    await Bookmarks.remove(Bookmarks.all().single);
    await ReplaceRules.save([]);
    await Sync.merge(remote(extra: {
      'bookmarks': [mark(500, 20)],
      'rules': [rule('b', 5)],
    }));
    expect(box.get('bookmarks'), isEmpty);
    expect(box.get('rules'), isEmpty);
  });

  test('对方删了的书：只看加入时间，删除之后改名、阅读都照样移出；删除之后读过的记下来提示，推到过网站的排队从网站移出', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, Object?> book(String aid, {String? bid, int ts = 0}) => {'aid': aid, 'title': 't$aid', 'img': '', 'added': 100, 'cats': <String>[], 'bid': bid, 'done': false, 'name': null, 'ts': ts};
    LibraryStore.removedElsewhere.value = const [];
    await box.put('lib:books', {'1': book('1', bid: 'b1'), '2': book('2'), '3': book('3', ts: now + 5000), '9': book('9')});
    await box.put('progress:1', ['c', 0, now + 1000]); // 删除之后读过
    await box.put('progress:2', ['c', 0, 50]); // 删除之前读的
    final tomb = {'lib:1': now, 'lib:2': now, 'lib:3': now, 'lib:4': now};
    await Sync.merge(remote(extra: {'cats': [], 'books': {'4': book('4', bid: 'x')..['ts'] = now + 5000}, 'tomb': tomb}));

    expect((box.get('lib:books') as Map).keys, ['9']); // 对方删除之后改名的（3、4）也不回来
    expect(box.get('lib:ops'), {'1': {'op': 'remove', 'bid': 'b1'}}); // 2 没推到过网站，不用管
    expect(LibraryStore.removedElsewhere.value.map((b) => b.aid), ['1']);

    // 加回书架：加入时间比墓碑新，再合并同一份墓碑也不删
    final back = restoredBook(LibraryStore.removedElsewhere.value.single, {}, now + 2000);
    await box.put('lib:books', {'1': back.toMap()});
    await Sync.merge(remote(extra: {'cats': [], 'books': {}, 'tomb': tomb}));
    expect((box.get('lib:books') as Map).keys, ['1']);
    LibraryStore.removedElsewhere.value = const [];
  });

  test('对方的快照没有统计也能合并', () async {
    await Sync.merge(remote()..remove('stats'));
    expect(box.get('sync:stats:other'), '{}');
  });

  test('规则改动按修改时间：对方改得新就用对方的', () async {
    await ReplaceRules.save([const ReplaceRule(pattern: 'old', replacement: '', id: 'r1', kind: RuleKind.highlight)]);
    final at = (box.get('rules') as List).single['ts'] as int;
    expect(at, greaterThan(0));
    await Sync.merge(remote(extra: {
      'rules': [
        {'p': 'new', 'r': '', 'e': true, 'k': 1, 'c': 1, 'n': '', 'a': '', 'id': 'r1', 'ts': at + 5},
      ],
    }));
    expect((box.get('rules') as List).single['p'], 'new');
    // 没改动的规则再保存一次，修改时间不变
    await ReplaceRules.save(ReplaceRules.all());
    expect((box.get('rules') as List).single['ts'], at + 5);
  });

  test('其他设备的统计更新后不会读到旧的解码结果', () async {
    Map<String, dynamic> stats(int n) => {'stats': {'day': {}, 'book': {}, 'chapters': n, 'meta': {}, 'days': {}}};
    await Sync.merge(remote(extra: stats(1)));
    expect(ReadingStats.chapters, 1);
    await Sync.merge(remote(extra: stats(2)));
    expect(ReadingStats.chapters, 2);
  });

  test('解析 PROPFIND 返回的文件名', () {
    const xml = '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/ArkNovel/</d:href></d:response><d:response><d:href>/dav/ArkNovel/sub.json/</d:href></d:response><d:response><d:href>/dav/ArkNovel/d1%20a.json</d:href></d:response><d:response><d:href>/dav/ArkNovel/bad%ZZ.json</d:href></d:response></d:multistatus>';
    expect(Sync.parseListing(xml), ['d1 a.json', 'bad%ZZ.json']);
  });

  test('分卷评分、按章统计与读完状态跟随同步更新', () async {
    await box.put('vols:1', [
      {'t': '第一卷', 'c': ['c1', 'c2'], 'i': null},
    ]);
    await box.put('read:1', ['c1']);
    await box.put('vrate:1', {'第一卷': 3});
    await box.put('stats:ch:1', {
      'c1': {'2026-10-20': 40},
    });
    await Sync.merge(remote(extra: {
      'read': {'1': ['c2']},
      'vrate': {
        '1': {'第一卷': 5, '第二卷': 4},
      },
      'stats': {
        'day': {},
        'book': {},
        'chapters': 0,
        'meta': {},
        'days': {},
        'ch': {
          '1': {
            'c1': {'2026-10-20': 25},
            'c2': {'2026-10-21': 50},
          },
        },
      },
    }));
    expect(Volumes.done('1').containsKey('第一卷'), isTrue);
    expect(Volumes.rating('1', '第一卷'), 3); // 本机已评的不被覆盖
    expect(Volumes.rating('1', '第二卷'), 4);
    expect(ReadingStats.chapterSeconds('1')['c1']?['2026-10-20'], 65);
    expect(ReadingStats.chapterSeconds('1')['c2']?['2026-10-21'], 50);
  });

  test('WebDAV 全流程：自动建文件夹、上传本机快照、读取并合并别的设备', () async {
    final files = <String, String>{};
    var folderMade = false;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final path = Uri.decodeFull(req.uri.path);
      final body = await utf8.decoder.bind(req).join();
      final res = req.response;
      if (req.headers.value('authorization') != 'Basic ${base64Encode(utf8.encode('me:secret'))}') {
        res.statusCode = 401;
      } else if (req.method == 'PROPFIND' && path == '/dav/ArkNovel/') {
        if (!folderMade) {
          res.statusCode = 404;
        } else {
          res.statusCode = 207;
          res.write('<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/ArkNovel/</d:href></d:response>${[for (final k in files.keys) '<d:response><d:href>/dav/ArkNovel/$k</d:href></d:response>'].join()}</d:multistatus>');
        }
      } else if (req.method == 'MKCOL') {
        folderMade = true;
        res.statusCode = 201;
      } else if (req.method == 'PUT') {
        files[path.split('/').last] = body;
        res.statusCode = 201;
      } else if (req.method == 'GET' && files.containsKey(path.split('/').last)) {
        res.write(files[path.split('/').last]);
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    folderMade = false;
    files['other.json'] = jsonEncode(remote(extra: {
      'progress': {'7': ['c', 3, 5000]},
    }));
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'secret', folder: 'ArkNovel');
    await box.put('progress:1', ['a', 1, 100]);

    expect(await Sync.run(), 1);
    expect(box.get('progress:7'), ['c', 3, 5000]);
    expect(files.keys.where((k) => k != 'other.json').length, 1);
    expect(jsonDecode(files['${Sync.deviceId}.json']!)['progress']['1'], ['a', 1, 100]);

    // 有一个文件坏了：跳过它并报出来，别的设备照样合并
    files['broken.json'] = 'not json';
    files['other.json'] = jsonEncode(remote(extra: {
      'progress': {'8': ['d', 4, 6000]},
    }));
    await expectLater(Sync.run(), throwsA(allOf(contains('已合并 1 台'), contains('broken.json'))));
    expect(box.get('progress:8'), ['d', 4, 6000]);
    files.remove('broken.json');

    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'wrong', folder: 'ArkNovel');
    await expectLater(Sync.run(), throwsA(contains('应用密码')));
    await server.close(force: true);
  });

  test('书架分类（含同名分类合并）、书籍改名、裁剪封面、更新列表与可选设置同步', () async {
    await box.put('lib:cats', [
      {'id': 'c_local', 'name': '在追', 'ts': 100},
    ]);
    await box.put('lib:books', {
      '1': {'aid': '1', 'title': '原名', 'img': 'i1', 'added': 100, 'cats': <String>[], 'bid': 'b1', 'done': false, 'name': null, 'ts': 100},
    });
    await box.put('vcover2:1', {'第一卷': 'https://example.com/auto.jpg'});

    await Sync.merge(remote(extra: {
      'cats': [
        {'id': 'c_remote', 'name': '在追', 'ts': 200},
        {'id': 'c_new', 'name': '養肥', 'ts': 200},
      ],
      'books': {
        '1': {'aid': '1', 'title': '原名', 'img': 'i1', 'added': 100, 'cats': ['c_remote'], 'bid': 'b2', 'done': true, 'name': '自定义译名', 'ts': 300},
      },
      'vcover': {
        '1': {'第一卷': 'https://example.com/manual.jpg#crop=0.5,0,0.5,1'},
      },
      'vpick': {
        '1': ['第一卷'],
      },
      'updates': {
        'feed': [
          {'aid': '1', 'title': '原名', 'img': 'i1', 'chapter': '新章节', 'cid': 'c9', 'time': 500},
        ],
        'known': {'1': 15},
        'seen': 400,
        'at': {'1': 500},
      },
      'appearance': {
        'ts': 999,
        'themeMode': 2,
        'palette': 3,
      },
    }));

    final cats = (box.get('lib:cats') as List).cast<Map>();
    expect(cats.map((c) => c['name']), ['在追', '養肥']); // 同名"在追"不重复建
    final b1 = (box.get('lib:books') as Map)['1'] as Map;
    expect(b1['name'], '自定义译名');
    expect(b1['cats'], ['c_local']); // 远端 c_remote 自动映射到本机同名的 c_local
    expect(b1['bid'], 'b1'); // 本机 bid 保留
    expect(Volumes.cover('1', '第一卷'), 'https://example.com/manual.jpg#crop=0.5,0,0.5,1'); // 手动裁剪封面覆盖自动封面
    expect((box.get('updates') as List).length, 1);
    expect((box.get('updates:known') as Map)['1'], 15);
    expect(box.get('themeMode'), isNull); // 默认不同步外观与主题
  });

  test('同名分类统一 id 后，删除和改名能跨设备对上', () async {
    await box.put('lib:cats', [
      {'id': 'c_z', 'name': '在追', 'ts': 100},
    ]);
    await box.put('lib:books', {
      '1': {'aid': '1', 'title': 't', 'img': '', 'added': 1, 'cats': ['c_z'], 'bid': null, 'done': false, 'name': null, 'ts': 1},
    });
    await box.put('shelfOrder:lib:c_z', ['1']);
    await box.put('shelfTabOrder', ['c_z']);
    await box.put('p.${P.hiddenTabs}', ['c_z']);
    final other = {'cats': [{'id': 'c_a', 'name': '在追', 'ts': 100}], 'books': {}};
    await Sync.merge(remote(extra: other));
    expect((box.get('lib:cats') as List).map((c) => c['id']), ['c_a']);
    expect((box.get('lib:books') as Map)['1']['cats'], ['c_a']);
    expect(box.get('shelfOrder:lib:c_a'), ['1']);
    expect(box.get('shelfOrder:lib:c_z'), isNull);
    expect(box.get('shelfTabOrder'), ['c_a']);
    expect(box.get('p.${P.hiddenTabs}'), ['c_a']);

    // 另一台改名：id 相同，按时间取新的，不会变成两个
    await Sync.merge(remote(extra: {'cats': [{'id': 'c_a', 'name': '追番', 'ts': 200}], 'books': {}}));
    expect((box.get('lib:cats') as List).map((c) => c['name']), ['追番']);

    // 另一台删除：不复活
    await Sync.merge(remote(extra: {'cats': [], 'books': {}, 'tomb': {'cat:c_a': DateTime.now().millisecondsSinceEpoch}}));
    expect(box.get('lib:cats'), isEmpty);
    await Sync.merge(remote(extra: other));
    expect(box.get('lib:cats'), isEmpty);
  });

  test('可选设置：只有这组改过才更新时间，时间相同不互相覆盖', () async {
    await AppPrefs.write(P.lock, true);
    await AppPrefs.write(P.lastTab, 'x');
    await AppPrefs.write(P.colsPortrait, 3);
    await AppPrefs.write(P.syncShelfPrefs, true);
    expect(box.get('sync:prefsTs'), isNull);
    await box.put('p.${P.resumeBar}', true);
    await Sync.merge(remote(extra: {'shelfPrefs': {'ts': 0, 'p': {'p.${P.resumeBar}': false}}}));
    expect(box.get('p.${P.resumeBar}'), isTrue);

    await Sync.merge(remote(extra: {'shelfPrefs': {'ts': 5, 'p': {'p.${P.resumeBar}': false, 'p.${P.lastTab}': 'y'}}}));
    expect(box.get('p.${P.resumeBar}'), isFalse);
    expect(box.get('p.${P.lastTab}'), 'x');
    await AppPrefs.write(P.resumeBar, true);
    expect(box.get('sync:prefsTs') as int, greaterThan(5));
  });

  test('恢复自动封面能跨设备生效，之后重新挑的不受影响', () async {
    await box.put('vcover2:1', {'一': 'mine'});
    await box.put('vpick:1', ['一']);
    await box.put('vpickTs:1', {'一': 100});
    final picked = {'vcover': {'1': {'一': 'theirs'}}, 'vpick': {'1': ['一']}, 'vpickTs': {'1': {'一': 50}}};

    // 手动对手动：时间新的赢
    await Sync.merge(remote(extra: picked));
    expect(Volumes.cover('1', '一'), 'mine');

    // 另一台恢复了自动封面：本机的手动封面也去掉
    final at = DateTime.now().millisecondsSinceEpoch;
    await Sync.merge(remote(extra: {'vcover': {'1': <String, String>{}}, 'vpick': {'1': <String>[]}, 'tomb': {'vcover:1:一': at}}));
    expect(Volumes.cover('1', '一'), isNull);

    // 还没收到恢复的设备传来旧封面：不写回
    await Sync.merge(remote(extra: picked));
    expect(Volumes.cover('1', '一'), isNull);

    // 恢复之后又挑了新的：生效
    await Sync.merge(remote(extra: {'vcover': {'1': {'一': 'new'}}, 'vpick': {'1': ['一']}, 'vpickTs': {'1': {'一': at + 1000}}}));
    expect(Volumes.cover('1', '一'), 'new');
  });

  test('头像单独传文件：快照不带图片，没变不重传，对方新的才下载', () async {
    final files = <String, String>{};
    final puts = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final name = Uri.decodeFull(req.uri.path).split('/').last;
      final body = await utf8.decoder.bind(req).join();
      final res = req.response;
      if (req.method == 'PROPFIND') {
        res.statusCode = 207;
        res.write('<d:multistatus xmlns:d="DAV:">${[for (final k in files.keys) '<d:response><d:href>/dav/A/$k</d:href></d:response>'].join()}</d:multistatus>');
      } else if (req.method == 'PUT') {
        files[name] = body;
        puts.add(name);
        res.statusCode = 201;
      } else if (files.containsKey(name)) {
        res.write(files[name]);
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    final tmp = Directory.systemTemp.createTempSync('ark_avatar_test');
    await box.put('avatar', (File('${tmp.path}/a.png')..writeAsStringSync('mine')).path);
    await box.put('avatar:ts', 5);
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'x', folder: 'A');

    await Sync.run();
    final mine = '${Sync.deviceId}.avatar';
    expect(files[mine], 'mine');
    final snap = jsonDecode(files['${Sync.deviceId}.json']!) as Map;
    expect((snap['avatar'] as Map)['file'], mine);
    expect((snap['avatar'] as Map).containsKey('data'), isFalse);

    puts.clear();
    files['o.avatar'] = 'theirs';
    files['o.json'] = jsonEncode(remote(extra: {'avatar': {'ts': 9, 'ext': '/../../evil.png', 'file': 'o.avatar'}}));
    await Sync.run();
    expect(puts, isNot(contains(mine)));
    expect(box.get('avatar:ts'), 9);
    expect(File(box.get('avatar') as String).readAsStringSync(), 'theirs');
    expect(box.get('avatar') as String, endsWith('.png'));
    expect(box.get('avatar') as String, isNot(contains('evil')));
    await server.close(force: true);
  });

  test('可选设置只收自己这组的键，值的类型要和本机一致', () async {
    await AppPrefs.write(P.syncReaderPrefs, true);
    await AppPrefs.write(P.syncAppearance, true);
    await box.putAll({'sync:url': 'https://mine.example/dav/', 'cookie': 'mine', 'r.fontSize': 18.0, 'r.theme': 5});
    await Sync.merge(remote(extra: {
      'readerPrefs': {
        'ts': 10,
        'r': {'r.fontSize': 20, 'r.theme': 'x', 'r.dual': false, 'sync:url': 'https://evil.example/', 'cookie': 'evil'},
        'volumeDone': {'bad': 1},
      },
      'appearance': {
        'ts': 10,
        'themeMode': 9,
        'palette': 2,
        'p': {'p.ui.pureBlack': false, 'proxy': '1.2.3.4:80', 'lib:books': {}},
      },
    }));
    expect(box.get('sync:url'), 'https://mine.example/dav/');
    expect(box.get('cookie'), 'mine');
    expect(box.get('proxy'), isNull);
    expect(box.get('lib:books'), isNull);
    expect(box.get('r.fontSize'), 20.0); // 整数也收，存成小数
    expect(box.get('r.theme'), 5); // 类型不对的不收
    expect(box.get('r.dual'), false);
    expect(box.get('p.${P.volumeDone}'), isNull);
    expect(box.get('themeMode'), isNull); // 超出范围
    expect(box.get('palette'), 2);
    expect(box.get('p.ui.pureBlack'), false);
  });

  test('删除、清空阅读历史会同步，之后又读的留下', () async {
    Map<String, Object> h(String aid, int time) => {'aid': aid, 'title': 'T', 'img': '', 'cid': 'c', 'chapter': 'c', 'time': time};
    final now = DateTime.now().millisecondsSinceEpoch;
    await box.put('history2', [h('1', now - 1000), h('2', now - 1000)]);
    await ReadingHistory.remove('1');
    await Sync.merge(remote(extra: {'history': [h('1', now - 2000), h('2', now - 2000)]}));
    expect((box.get('history2') as List).map((e) => e['aid']), ['2']);

    await ReadingHistory.clear();
    await Sync.merge(remote(extra: {'history': [h('2', now - 2000), h('3', now + 60000)]}));
    expect((box.get('history2') as List).map((e) => e['aid']), ['3']);

    // 对方删的，本机也删
    await box.delete('sync:tomb');
    await box.put('history2', [h('4', now - 1000)]);
    await Sync.merge(remote(extra: {'tomb': {'h:4': now}}));
    expect(box.get('history2'), isEmpty);
  });

  test('新设备也按固定类型和范围校验阅读、书架设置，不接收未知键', () async {
    await AppPrefs.write(P.syncReaderPrefs, true);
    await AppPrefs.write(P.syncShelfPrefs, true);
    await Sync.merge(remote(extra: {
      'readerPrefs': {'ts': 10, 'r': {'r.fontSize': 20, 'r.theme': 'bad', 'r.mode': 100, 'r.prefetch': -1, 'r.dim': 2, 'r.dual': false, 'r.unknown': 'x'}},
      'shelfPrefs': {'ts': 10, 'p': {'p.${P.hiddenTabs}': 'bad'}, 'shelfOpts': {'sort': 'bad', 'reverse': 'bad', 'display': 99, 'unread': 1}},
    }));
    expect(box.get('r.fontSize'), 20.0);
    for (final key in ['r.theme', 'r.mode', 'r.prefetch', 'r.dim', 'r.unknown', 'p.${P.hiddenTabs}']) {
      expect(box.get(key), isNull, reason: key);
    }
    expect(box.get('r.dual'), false);
    expect(box.get('shelfOpts'), {'unread': 1});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(readerPrefsProvider).theme, 5);
  });

  test('统计格式不对或快照身份无效：整份拒绝，不持久化错误或改动其他数据', () async {
    await box.put('progress:1', ['local', 0, 1]);
    for (final stats in [
      {'chapters': 'bad'}, {'chapters': -1}, {'day': {'2026-01-01': 'bad'}}, {'meta': {'1': {'t': 7}}},
      {'days': {'1': [7]}}, {'ch': {'1': {'c': {'2026-01-01': 'bad'}}}},
    ]) {
      await expectLater(Sync.merge(remote(extra: {'progress': {'1': ['remote', 0, 2]}, 'stats': stats})), throwsFormatException);
      expect(box.get('progress:1'), ['local', 0, 1]);
      expect(box.get('sync:stats:other'), isNull);
    }
    for (final extra in [
      {'v': 4}, {'device': '../bad'}, {'device': ''}, {'at': 'bad'}, {'v': 3},
    ]) {
      await expectLater(Sync.merge(remote(extra: extra)), throwsFormatException);
    }
  });

  test('本机超过 90 天没同步：联网和上传之前停止，旧数据不改成新快照', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((req) async {
      requests.add(req.method);
      await req.response.close();
    });
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'test', pass: 'test', folder: 'ArkNovel');
    final old = DateTime.now().subtract(const Duration(days: 100)).millisecondsSinceEpoch;
    await box.putAll({'sync:last': old, 'lib:books': {'1': const LibBook(aid: '1', title: 'old', img: '', added: 1).toMap()}});
    await expectLater(Sync.run(), throwsA(isA<LocalSyncExpiredException>()));
    expect(requests, isEmpty);
    expect(Sync.lastSync, old);
    expect((box.get('lib:books') as Map).keys, ['1']);
  });

  test('本机同步时间缺失或换回旧目录：检查云端本机文件，过期时不覆盖；新目录仍可同步', () async {
    final old = DateTime.now().subtract(const Duration(days: 100)).millisecondsSinceEpoch;
    final requests = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      requests.add(req.method);
      await req.drain<void>();
      if (req.method == 'PROPFIND') {
        req.response.statusCode = 207;
        req.response.write('<d:multistatus xmlns:d="DAV:"></d:multistatus>');
      } else if (req.method == 'GET' && req.uri.path.contains('/Old/')) {
        req.response.write(jsonEncode(remote(extra: {'device': Sync.deviceId, 'at': old})));
      } else if (req.method == 'GET') {
        req.response.statusCode = 404;
      } else {
        req.response.statusCode = 201;
      }
      await req.response.close();
    });
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'test', pass: 'test', folder: 'Old');
    await expectLater(Sync.run(), throwsA(isA<LocalSyncExpiredException>()));
    expect(requests, isNot(contains('PUT')));
    expect(Sync.lastSync, 0);
    await box.putAll({'sync:last': old, 'sync:avatarUp': 7});
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'test', pass: 'changed', folder: 'Old');
    expect(Sync.lastSync, old); // 仅改密码不能绕过过期检查
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'test', pass: 'test', folder: 'New');
    expect(Sync.lastSync, 0);
    expect(box.get('sync:avatarUp'), isNull);
    expect(await Sync.run(), 0);
    expect(requests, contains('PUT'));
  });

  test('超过 90 天没更新的快照不合并，免得删掉的东西复活', () async {
    final old = DateTime.now().subtract(const Duration(days: 91)).millisecondsSinceEpoch;
    await expectLater(Sync.merge(remote(extra: {'at': old, 'progress': {'1': ['a', 1, 5]}})), throwsA(isA<StaleSnapshotException>()));
    expect(box.get('progress:1'), isNull);
    await expectLater(Sync.importBackup(jsonEncode(remote(extra: {'at': old}))), throwsA(isA<StaleSnapshotException>()));
    await Sync.merge(remote(extra: {'at': DateTime.now().millisecondsSinceEpoch, 'progress': {'1': ['a', 1, 5]}}));
    expect(box.get('progress:1'), ['a', 1, 5]);
  });

  test('对方数据格式不对的条目只跳过那一条；本机旧格式的进度也能比较', () async {
    await box.put('progress:1', ['a', 10]); // 旧版本没有时间
    await Sync.merge(remote(extra: {
      'progress': {'1': ['b', 5, 100], '2': ['x', 1], '3': 'bad', '4': ['y', 2.5, 100]},
      'vols': {
        '1': [{'t': '第一卷', 'c': ['c1'], 'i': null}],
        '2': [{'t': 1, 'c': 'x'}],
      },
    }));
    expect(box.get('progress:1'), ['b', 5, 100]);
    expect(box.get('progress:2'), isNull);
    expect(box.get('progress:3'), isNull);
    expect(box.get('progress:4'), isNull);
    expect(Volumes.of('1').single.title, '第一卷');
    expect(box.get('vols:2'), isNull);
    expect(Volumes.of('2'), isEmpty);
  });

  test('WebDAV：超过 90 天没同步的设备跳过并说明，其他照常', () async {
    final files = <String, String>{
      'old.json': jsonEncode(remote(extra: {'device': 'old', 'at': DateTime.now().subtract(const Duration(days: 100)).millisecondsSinceEpoch, 'progress': {'5': ['a', 1, 5]}})),
      'new.json': jsonEncode(remote(extra: {'device': 'new', 'progress': {'6': ['b', 1, 5]}})),
    };
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final name = Uri.decodeFull(req.uri.path).split('/').last;
      final body = await utf8.decoder.bind(req).join();
      final res = req.response;
      if (req.method == 'PROPFIND') {
        res.statusCode = 207;
        res.write('<d:multistatus xmlns:d="DAV:">${[for (final k in files.keys) '<d:response><d:href>/dav/ArkNovel/$k</d:href></d:response>'].join()}</d:multistatus>');
      } else if (req.method == 'PUT') {
        files[name] = body;
        res.statusCode = 201;
      } else if (req.method == 'GET' && files.containsKey(name)) {
        res.write(files[name]);
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    await Sync.save(url: 'http://127.0.0.1:${server.port}/dav/', user: 'me', pass: 'p', folder: 'ArkNovel');
    expect(await Sync.run(), 1);
    expect(Sync.lastSkipped, ['old.json']);
    expect(Sync.skippedNote, contains('old.json'));
    expect(box.get('progress:5'), isNull);
    expect(box.get('progress:6'), ['b', 1, 5]);
    await server.close(force: true);
  });
}

void statsDeleteTests(Box Function() box) {
  test('删一本书的统计：本机、已同步的都去掉，其他书不动；再合并不会回来，删之后又读的留下', () async {
    final b = box();
    await b.put('stats:day', {'2026-01-01': 100, '2026-01-02': 50});
    await b.put('stats:book', {'1': 90, '2': 60});
    await b.put('stats:days:1', ['2026-01-01']);
    await b.put('stats:ch:1', {'c': {'2026-01-01': 90}});
    await b.put('stats:meta', {'1': {'t': 'a'}, '2': {'t': 'b'}});
    final other = {'day': {'2026-01-01': 30}, 'book': {'1': 30}, 'chapters': 1, 'meta': {'1': {'t': 'a'}}, 'days': {'1': ['2026-01-01']}, 'ch': {'1': {'c': {'2026-01-01': 30}}}};
    await b.put('sync:stats:other', jsonEncode(other));

    await ReadingStats.deleteBook('1');
    expect(ReadingStats.perBook(), {'2': 60});
    expect(ReadingStats.perDay(), {'2026-01-01': 10, '2026-01-02': 50});
    expect(ReadingStats.bookDays('1'), isEmpty);
    expect(ReadingStats.chapterSeconds('1'), isEmpty);

    Map<String, dynamic> snapshot(Map stats) => {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'stats': stats};
    await Sync.merge(snapshot(other));
    expect(ReadingStats.perBook(), {'2': 60});

    final later = ReadingStats.dayKey(DateTime.now().add(const Duration(days: 1)));
    await Sync.merge(snapshot({'day': {later: 5}, 'book': {'1': 5}, 'chapters': 1, 'meta': {}, 'days': {'1': [later]}, 'ch': {}}));
    expect(ReadingStats.perBook()['1'], 5);
  });

  test('别的设备删的书：本机只删删除那天及之前的，之后几天读的留下', () async {
    final b = box();
    // 用最近的日期：墓碑超过 90 天会被清掉
    final now = DateTime.now();
    final d1 = ReadingStats.dayKey(now.subtract(const Duration(days: 3)));
    final d3 = ReadingStats.dayKey(now.subtract(const Duration(days: 1)));
    final noon = now.subtract(const Duration(days: 2));
    final tomb = DateTime(noon.year, noon.month, noon.day, 12).millisecondsSinceEpoch;
    await b.put('stats:day', {d1: 40, d3: 70});
    await b.put('stats:book', {'1': 90, '2': 20});
    await b.put('stats:days:1', [d1, d3]);
    await b.put('stats:ch:1', {'c': {d1: 30, d3: 60}});
    final snap = {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'tomb': {'stats:1': tomb}, 'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}, 'ch': {}}};
    await Sync.merge(snap);
    expect(ReadingStats.bookDays('1'), [d3]);
    expect(ReadingStats.chapterSeconds('1'), {'c': {d3: 60}});
    expect(ReadingStats.perBook(), {'1': 60, '2': 20});
    expect(ReadingStats.perDay(), {d1: 10, d3: 70});
    expect((b.get('stats:purged') as Map)['1'], tomb);
  });

  test('删除那天：最后一次读在删除之后就整天留下，否则去掉', () {
    final tomb = DateTime(2026, 1, 2, 12).millisecondsSinceEpoch;
    Map<String, dynamic> stats(int last) => {
      'day': {'2026-01-02': 50},
      'book': {'1': 50},
      'meta': {'1': {'t': 'a'}},
      'days': {'1': ['2026-01-02']},
      'ch': {'1': {'c': {'2026-01-02': 50}}},
      'last': {'1': last},
    };
    final after = stats(tomb + 1000);
    ReadingStats.stripBook(after, '1', before: tomb);
    expect(after['book'], {'1': 50});
    expect(after['days'], {'1': ['2026-01-02']});

    final before = stats(tomb - 1000);
    ReadingStats.stripBook(before, '1', before: tomb);
    expect(before['book'], isEmpty);
    expect(before['day'], isEmpty);
    expect(before['meta'], isEmpty);
    expect(before['ch'], isEmpty);
  });

  test('别的设备删的书：本机只删一次，之后又读的不再被删', () async {
    final b = box();
    await b.put('stats:book', {'1': 90});
    await b.put('stats:days:1', ['2026-01-01']);
    final tomb = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> snapshot() => {'v': 1, 'device': 'other', 'progress': {}, 'history': [], 'bookmarks': [], 'read': {}, 'readchars': {}, 'rating': {}, 'rules': [], 'notes': {}, 'tomb': {'stats:1': tomb}, 'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}, 'ch': {}}};
    await Sync.merge(snapshot());
    expect(ReadingStats.perBook(), isEmpty);
    await ReadingStats.addSeconds('1', 10);
    await Sync.merge(snapshot());
    expect(ReadingStats.perBook()['1'], 10);
  });
}
