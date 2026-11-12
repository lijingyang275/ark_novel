import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/data/wenku8/wenku8_parser.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/bookshelf.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/session.dart';

class _Session extends SessionController {
  @override
  SessionState build() => const SessionLoggedOut();

  void set(SessionState value) => state = value;
}

class _Api extends Api {
  _Api(this.client) : super(client, Wenku8Urls('https://example.test', CharsetType.gbk), 'https://example.test', 'test');

  final Wenku8Client client;
  final adds = <String>[];
  final removes = <String>[];
  final shelves = <int>[];
  List<BookshelfNovelInfo> books = [];
  Exception? addError;
  Exception? removeError;
  Future<void> Function()? onShelf;

  @override
  Future<Bookshelf> bookshelf(int classId, {bool fresh = false}) async {
    shelves.add(classId);
    await onShelf?.call();
    return Bookshelf(classId: '$classId', list: classId == 0 ? books : []);
  }

  @override
  Future<void> addToBookshelf(String aid) async {
    adds.add(aid);
    if (addError != null) throw addError!;
  }

  @override
  Future<void> removeFromBookshelf(String bid) async {
    removes.add(bid);
    if (removeError != null) throw removeError!;
  }
}

void main() {
  late Directory tmp;
  late Box box;
  late ProviderContainer container;
  late _Api api;
  late SessionLoggedIn loggedIn;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ark_library_mutations');
    Hive.init(tmp.path);
    box = await Hive.openBox('session');
    api = _Api(Wenku8Client(baseUrl: () => 'https://example.test', charset: () => CharsetType.gbk, headers: const {}));
    container = ProviderContainer(overrides: [sessionProvider.overrideWith(_Session.new), apiProvider.overrideWithValue(api)]);
    loggedIn = SessionLoggedIn(Wenku8Parser.userInfo(File('test/data/wenku8/fixtures/user_info.html').readAsStringSync()));
  });

  tearDown(() async {
    container.dispose();
    api.client.dio.close(force: true);
    await Hive.close();
    await tmp.delete(recursive: true);
    LibraryStore.removedElsewhere.value = const [];
  });

  LibraryController library() => container.read(libraryProvider.notifier);
  void login() => (container.read(sessionProvider.notifier) as _Session).set(loggedIn);
  BookshelfNovelInfo remote(String aid, String bid) => BookshelfNovelInfo(aid: aid, bid: bid, url: '', title: aid, img: '');

  test('同时移出和加入：新书、队列和墓碑都保留', () async {
    await box.put('lib:books', {'1': const LibBook(aid: '1', title: 'one', img: '').toMap()});
    final controller = library();
    await Future.wait([
      controller.remove(['1']),
      controller.add('2', 'two', ''),
    ]);
    expect(controller.state.books.keys, ['2']);
    expect((box.get('lib:books') as Map).keys, ['2']);
    expect((box.get('lib:ops') as Map)['2'], {'op': 'add'});
    expect((box.get('sync:tomb') as Map).containsKey('lib:1'), isTrue);
  });

  test('加入尚未落盘就移出：本地操作抵消，不重新排加入', () async {
    final controller = library();
    await Future.wait([
      controller.add('1', 'one', ''),
      controller.remove(['1']),
    ]);
    expect(controller.state.books, isEmpty);
    expect(box.get('lib:ops'), isEmpty);
  });

  test('加回尚未落盘就移出：旧的加回操作不覆盖新删除', () async {
    final controller = library();
    await Future.wait([
      controller.restore([const LibBook(aid: '1', title: 'one', img: '')]),
      controller.remove(['1']),
    ]);
    expect(controller.state.books, isEmpty);
    expect(box.get('lib:ops'), isEmpty);
  });

  test('删除分类期间新增分类和改名：都保留，不写回旧书籍状态', () async {
    await box.putAll({
      'lib:books': {
        '1': const LibBook(aid: '1', title: 'one', img: '', cats: ['old']).toMap(),
      },
      'lib:cats': [
        {'id': 'old', 'name': 'old'},
      ],
    });
    final controller = library();
    await Future.wait([controller.deleteCategory('old'), controller.addCategory('new'), controller.rename('1', 'renamed')]);
    expect(controller.state.books['1']!.cats, isEmpty);
    expect(controller.state.books['1']!.name, 'renamed');
    expect(controller.state.cats.single.name, 'new');
    expect(((box.get('lib:books') as Map)['1'] as Map)['name'], 'renamed');
  });

  test('换账号：忽略旧对账时间，保留本地书，旧 bid 和旧队列不发给新账号', () async {
    await box.putAll({
      'lib:imported': 'previous-user',
      'lib:sync': DateTime.now().millisecondsSinceEpoch,
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '', bid: 'previous-bid', name: 'local name').toMap()},
      'lib:ops': {
        'gone': {'op': 'remove', 'bid': 'previous-bid'},
        'pending': {'op': 'add'},
      },
    });
    api.books = [remote('2', 'current-bid')];
    login();
    expect(await library().sync(details: false), isNull);
    final books = library().state.books;
    expect(books.keys.toSet(), {'1', '2'});
    expect(books['1']!.bid, isNull);
    expect(books['1']!.name, 'local name');
    expect(books['2']!.bid, 'current-bid');
    expect(box.get('sync:tomb'), isNull);
    expect(api.adds, isEmpty);
    expect(api.removes, isEmpty);
    expect(box.get('lib:ops'), isEmpty);
    expect(box.get('lib:imported'), loggedIn.user.uid);
  });

  test('WebDAV 写入后尚未重建 provider：本地改名和分类排序不覆盖已合并数据', () async {
    await box.put('lib:books', {'1': const LibBook(aid: '1', title: 'one', img: '').toMap()});
    final controller = library();
    // 模拟同步已提交 Hive，但界面的 Sync.changes 监听还没通知这个实例。
    await box.putAll({
      'lib:books': {
        '1': const LibBook(aid: '1', title: 'one', img: '', cats: ['remote-cat']).toMap(),
        '2': const LibBook(aid: '2', title: 'remote', img: '').toMap(),
      },
      'lib:cats': [
        {'id': 'remote-cat', 'name': 'remote'},
      ],
    });
    await controller.rename('1', 'renamed');
    await controller.reorderCategories([]);
    expect(controller.state.books.keys.toSet(), {'1', '2'});
    expect(controller.state.books['1']!.cats, ['remote-cat']);
    expect(controller.state.books['1']!.name, 'renamed');
    expect(controller.state.cats.single.id, 'remote-cat');
  });

  test('未完成新账号对账时立即移出：不推送旧账号的 bid', () async {
    await box.putAll({
      'lib:imported': 'previous-user',
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '', bid: 'previous-bid').toMap()},
    });
    login();
    await library().remove(['1']);
    expect(api.removes, isEmpty);
  });

  test('换号后、首次对账前排的操作：属于新账号，对账时照常推送', () async {
    await box.putAll({
      'lib:imported': 'previous-user',
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '', bid: 'previous-bid').toMap()},
      'lib:ops': {
        'old': {'op': 'add'},
      },
    });
    api.books = [remote('1', 'current-bid')];
    login();
    await library().remove(['1']);
    await library().add('2', 'two', '');
    expect(api.removes, isEmpty); // 对账前不推送
    expect(await library().sync(details: false), isNull);
    expect(api.removes, ['current-bid']);
    expect(api.adds, ['2']);
    expect(library().state.books.keys, ['2']);
    expect(box.get('lib:ops'), isEmpty);
  });

  test('同账号对账仍会移出网站已删的书并记墓碑', () async {
    await box.putAll({
      'lib:imported': loggedIn.user.uid,
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '', bid: 'bid1').toMap()},
    });
    api.books = [remote('2', 'bid2')];
    login();
    expect(await library().sync(force: true, details: false), isNull);
    expect(library().state.books.keys, ['2']);
    expect((box.get('sync:tomb') as Map).containsKey('lib:1'), isTrue);
  });

  test('拉书架期间退出登录：停止后续请求，不提交旧账号的对账结果', () async {
    await box.putAll({
      'lib:imported': loggedIn.user.uid,
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '', bid: 'bid1').toMap()},
    });
    api.books = [remote('2', 'bid2')];
    api.onShelf = () async => (container.read(sessionProvider.notifier) as _Session).set(const SessionLoggedOut());
    login();
    expect(await library().sync(force: true, details: false), isNull);
    expect(api.shelves, [0]);
    expect((box.get('lib:books') as Map).keys, ['1']);
    expect(box.get('sync:tomb'), isNull);
  });

  test('移出被网站拒绝：保留队列、提示错误、不把网站旧书带回来', () async {
    await box.putAll({
      'lib:imported': loggedIn.user.uid,
      'lib:books': {},
      'lib:ops': {
        '1': {'op': 'remove', 'bid': 'bid1'},
      },
    });
    api.books = [remote('1', 'bid1')];
    api.removeError = const Wenku8ActionRejectedException('请稍后再试');
    login();
    expect(await library().sync(force: true, details: false), contains('请稍后再试'));
    expect(library().state.books, isEmpty);
    expect((box.get('lib:ops') as Map)['1'], {'op': 'remove', 'bid': 'bid1'});
  });

  test('加入结果未确认：保留队列；明确书架已满才放弃加入', () async {
    await box.putAll({
      'lib:imported': loggedIn.user.uid,
      'lib:books': {'1': const LibBook(aid: '1', title: 'one', img: '').toMap()},
      'lib:ops': {
        '1': {'op': 'add'},
      },
    });
    api.addError = const Wenku8UnexpectedPageException('登录已失效');
    login();
    expect(await library().sync(force: true, details: false), contains('登录已失效'));
    expect((box.get('lib:ops') as Map)['1'], {'op': 'add'});
    api.addError = const Wenku8ActionRejectedException('书架已满');
    expect(await library().sync(force: true, details: false), isNull);
    expect(box.get('lib:ops'), isEmpty);
    expect(library().state.books.keys, ['1']);
  });

  test('游客的本地加入操作：首次登录仍推送到自己的书架', () async {
    await library().add('1', 'one', '');
    login();
    expect(await library().sync(details: false), isNull);
    expect(api.adds, ['1']);
    expect(box.get('lib:ops'), isEmpty);
    expect(library().state.books.keys, ['1']);
  });
}
