import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_parser.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/bookshelf.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/epub_codec.dart';
import 'package:ark_novel/next/export_book.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/library.dart';
import 'package:ark_novel/next/local_books.dart';
import 'package:ark_novel/next/pages/novel_page.dart';
import 'package:ark_novel/next/reader/reader_page.dart' show chapterProvider;
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/updates.dart';
import 'package:ark_novel/next/volume_covers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

Uint8List _png1x1() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

class _TrackingApi extends Api {
  _TrackingApi(this.client)
    : super(client, const Wenku8Urls('https://example.test', CharsetType.gbk), 'https://example.test', 'test');

  final Wenku8Client client;
  final added = <String>[];
  final removed = <String>[];
  final detailed = <String>[];
  final catalogued = <String>[];
  final chaptered = <String>[];
  List<BookshelfNovelInfo> remoteBooks = [];

  @override
  Future<Bookshelf> bookshelf(int classId, {bool fresh = false}) async => Bookshelf(classId: '$classId', list: classId == 0 ? remoteBooks : []);

  @override
  Future<void> addToBookshelf(String aid) async => added.add(aid);

  @override
  Future<void> removeFromBookshelf(String bid) async => removed.add(bid);

  @override
  Future<Wenku8NovelDetail> detail(String aid, {CancelToken? cancelToken}) async {
    detailed.add(aid);
    return Wenku8NovelDetail(
      title: 'online-$aid',
      author: 'a',
      status: '连载中',
      lastUpdate: '2026-11-23',
      imgUrl: '',
      introduce: '',
      tags: const [],
      heat: null,
      trending: null,
      isAnimated: false,
    );
  }

  @override
  Future<List<CatVolume>> catalogue(String aid, {bool fresh = false, CancelToken? cancelToken}) async {
    catalogued.add(aid);
    return [
      CatVolume(title: '第一卷', chapters: [CatChapter(title: '第一章', cid: '1')]),
    ];
  }

  @override
  Future<Content> chapter(String aid, String cid) async {
    chaptered.add('$aid:$cid');
    return Content(text: 'online', images: const []);
  }
}

class _FixedSession extends SessionController {
  _FixedSession(this._initial);

  final SessionState _initial;

  @override
  SessionState build() => _initial;
}

void main() {
  late Directory tempDir;
  late Directory supportDir;
  late Directory localBooksDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('ark_local_books_test_');
    supportDir = Directory(p.join(tempDir.path, 'support'))..createSync(recursive: true);
    localBooksDir = Directory(p.join(supportDir.path, 'local_books'))..createSync(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => supportDir.path,
    );
    LocalBooks.rootProvider = () async => localBooksDir;

    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  setUp(() async {
    LocalBooks.clearMemoryCache();
    await Hive.box('session').clear();
    if (localBooksDir.existsSync()) localBooksDir.deleteSync(recursive: true);
    localBooksDir.createSync(recursive: true);
  });

  tearDownAll(() async {
    LocalBooks.rootProvider = null;
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('标识与 localimg:// 路径解析（含冒号 aid 与防路径穿越）', () {
    expect(isLocalAid('local:1732345678901_a1b2'), isTrue);
    expect(isLocalAid('1234'), isFalse);

    const uri = 'localimg://local:1732345678901_a1b2/cover.jpg#crop=0.1,0.1,0.8,0.8';
    expect(isLocalImageUrl(uri), isTrue);
    final parsed = parseLocalImageUrl(uri);
    expect(parsed, isNotNull);
    expect(parsed!.aid, 'local:1732345678901_a1b2');
    expect(parsed.fileName, 'cover.jpg');

    expect(parseLocalImageUrl('localimg://local:123/../secret.txt'), isNull);
    expect(parseLocalImageUrl('localimg://1234/cover.jpg'), isNull);
    expect(isLocalImageUrl('https://img.wenku8.com/1.jpg'), isFalse);
  });

  test('LocalBooks 持久化读写、删除，以及与 ChapterCache / ImageStore / Backup 完全隔离', () async {
    final cover = _png1x1();
    final epubBytes = EpubBuilder.build(
      title: '本地测试轻小说',
      author: '本地作者',
      description: '一本用于测试独立存储隔离的 EPUB。',
      coverBytes: cover,
      volumes: [
        EpubVolumeData(
          title: '第一卷',
          chapters: [
            EpubChapterData(title: '第一章', text: '本地第一章正文。', images: [(name: 'p1.png', bytes: cover)]),
            const EpubChapterData(title: '第二章', text: '本地第二章正文。'),
          ],
        ),
      ],
    );

    final meta = await LocalBooks.importBytes(epubBytes, fileName: 'sample.epub');
    expect(isLocalAid(meta.aid), isTrue);
    expect(meta.format, 'epub');
    expect(meta.coverUrl, startsWith('localimg://${meta.aid}/cover.'));
    expect(await LocalBooks.exists(meta.aid), isTrue);

    // 清空内存缓存，验证纯磁盘重新读取
    LocalBooks.clearMemoryCache();
    final novel = await LocalBooks.loadNovel(meta.aid);
    expect(novel.detail.title, '本地测试轻小说');
    expect(novel.detail.author, '本地作者');
    expect(novel.detail.status, '本地 EPUB');
    expect(novel.catalogue.single.chapters.length, 2);

    final c1Cid = novel.catalogue.single.chapters.first.cid;
    final c1 = await LocalBooks.loadChapter(meta.aid, c1Cid);
    expect(c1.text, '本地第一章正文。');
    expect(c1.images.length, 1);
    expect(c1.images.first, startsWith('localimg://${meta.aid}/'));

    // ChapterCache 拒绝存入本地书，且 clearAuto 不会误删本地书
    expect(await ChapterCache.put(meta.aid, c1Cid, c1), isFalse);
    expect(ChapterCache.count(meta.aid), 0);
    await ChapterCache.put('999', '1', Content(text: '在线自动缓存', images: const []));
    expect(await ChapterCache.clearAuto(), 1);
    expect(await LocalBooks.exists(meta.aid), isTrue);
    expect((await LocalBooks.loadChapter(meta.aid, c1Cid)).text, '本地第一章正文。');

    // ImageStore 直接读 localimg:// 进内存，绝不写进 imgcache/，clearDisk 不删 local_books/
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final imgStore = container.read(imageStoreProvider);
    final loadedCover = await imgStore.load(meta.coverUrl);
    expect(loadedCover, equals(cover));
    final imgCacheDir = Directory(p.join(supportDir.path, 'imgcache'));
    if (imgCacheDir.existsSync()) {
      expect(imgCacheDir.listSync(), isEmpty);
    }
    final localPath = await imgStore.path(meta.coverUrl);
    expect(File(localPath).existsSync(), isTrue);
    expect(p.isWithin(localBooksDir.path, localPath), isTrue);
    await imgStore.clearDisk();
    expect(await LocalBooks.readImageBytes(meta.coverUrl), equals(cover));

    // 默认备份不打包 local_books/ 文件，但保留书架条目
    await Hive.box('session').put('lib:books', {
      meta.aid: LibBook(aid: meta.aid, title: meta.title, img: meta.coverUrl).toMap(),
    });
    final backupZip = p.join(tempDir.path, 'backup.zip');
    await Backup.pack(backupZip, Backup.make(), supportDir.path);
    final input = InputFileStream(backupZip);
    final entries = ZipDecoder().decodeStream(input).files;
    expect(entries.map((e) => e.name), ['data.json']);
    final dataJson = utf8.decode(entries.single.content as List<int>);
    await input.close();
    expect(dataJson, contains(meta.aid));

    // 删除本地书后，loadNovel 返回友好提示异常
    await LocalBooks.delete(meta.aid);
    expect(await LocalBooks.exists(meta.aid), isFalse);
    await expectLater(
      LocalBooks.loadNovel(meta.aid),
      throwsA(isA<LocalBookMissingException>().having((e) => e.toString(), 'message', '该本地书籍的文件不在此设备上，请在本机重新导入')),
    );
  });

  test('reconcile / LibraryController / UpdateController / VolumeCoverQueue 对 local: 书的完整隔离', () async {
    const localAid = 'local:1732345678901_abcd';
    const localBook = LibBook(aid: localAid, title: '我的本地书', img: 'localimg://$localAid/cover.png');
    const remoteSynced = LibBook(aid: '100', title: '在线书A', img: '', bid: 'bid100');

    // 1. reconcile 永远保留 local: 书（即使远端列表非空且不含它）
    final reconciled = reconcile(
      {localAid: localBook, '100': remoteSynced},
      {'200': (bid: 'bid200', title: '远端新书', img: '', shelf: 0)},
      const {},
      now: 1000,
    );
    expect(reconciled.containsKey(localAid), isTrue);
    expect(reconciled.containsKey('100'), isFalse);
    expect(reconciled.containsKey('200'), isTrue);

    // 2. LibraryController add/remove/sync/prefetchDetails 不向 wenku8 推 local: 书
    final client = Wenku8Client(baseUrl: () => 'https://example.test', charset: () => CharsetType.gbk, headers: const {});
    addTearDown(() => client.dio.close(force: true));
    final api = _TrackingApi(client);
    final user = Wenku8Parser.userInfo(File('test/data/wenku8/fixtures/user_info.html').readAsStringSync());
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(() => _FixedSession(SessionLoggedIn(user))),
      ],
    );
    addTearDown(container.dispose);

    final lib = container.read(libraryProvider.notifier);
    await lib.add(localAid, '我的本地书', 'localimg://$localAid/cover.png');
    await lib.add('300', '在线书B', '');
    expect((Hive.box('session').get('lib:ops') as Map?)?.containsKey(localAid), isFalse);
    expect((Hive.box('session').get('lib:ops') as Map?)?.containsKey('300'), isTrue);

    api.remoteBooks = [BookshelfNovelInfo(aid: '300', bid: 'bid300', url: '', title: '在线书B', img: '')];
    expect(await lib.sync(force: true, details: false, shelfDelay: Duration.zero), isNull);
    expect(api.added, isNot(contains(localAid)));
    expect(container.read(libraryProvider).books.containsKey(localAid), isTrue);

    await lib.prefetchDetails();
    expect(api.detailed, isNot(contains(localAid)));

    // 3. UpdateController 跳过 local: 书
    await container.read(updateProvider.notifier).refresh(force: true);
    expect(api.catalogued, isNot(contains(localAid)));
    expect(api.catalogued, contains('300'));

    // 4. VolumeCoverQueue 跳过 local: 书
    await container.read(volumeCoverQueueProvider).prefetchAll([localAid]);
    expect(api.chaptered, isEmpty);

    // 5. remove local: 书不写入 lib:ops，不请求远端移出
    await lib.remove([localAid]);
    expect(api.removed, isEmpty);
    expect((Hive.box('session').get('lib:ops') as Map?)?.containsKey(localAid), isFalse);
  });

  test('ExportBook 支持导出在线已缓存书籍（含按选中章节过滤）与本地导入书籍为 EPUB / TXT', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final imgStore = container.read(imageStoreProvider);

    // 在线书：只缓存 2 章中的第 1 章
    const onlineAid = '8888';
    await ChapterCache.put(onlineAid, 'c1', Content(text: '在线已缓存第一章内容。', images: const []));
    final onlineNovel = NovelPage(
      const Wenku8NovelDetail(
        title: '在线/导出:测试*',
        author: '网文作者',
        status: '连载中',
        lastUpdate: '2026-11-23',
        imgUrl: '',
        introduce: '简介内容',
        tags: [],
        heat: null,
        trending: null,
        isAnimated: false,
      ),
      [
        CatVolume(
          title: '第一卷',
          chapters: [
            CatChapter(title: '第一章', cid: 'c1'),
            CatChapter(title: '第二章（未缓存）', cid: 'c2'),
          ],
        ),
      ],
    );

    final epubRes = await ExportBook.buildBytes(
      aid: onlineAid,
      novel: onlineNovel,
      format: ExportFormat.epub,
      imageStore: imgStore,
    );
    expect(epubRes.fileName, '在线_导出_测试_.epub');
    expect(epubRes.chapterCount, 1);
    final parsedOnline = EpubParser.parseBytes(epubRes.bytes);
    expect(parsedOnline.volumes.single.chapters.single.title, '第一章');
    expect(parsedOnline.volumes.single.chapters.single.text, '在线已缓存第一章内容。');

    // 本地书导出 TXT 并指定单章
    final meta = await LocalBooks.saveParsed(
      const ParsedBook(
        title: '本地待导出书',
        author: '本地作家',
        description: '本地简介',
        volumes: [
          EpubVolumeData(
            title: '第一卷',
            chapters: [
              EpubChapterData(title: '第一章', text: '甲内容'),
              EpubChapterData(title: '第二章', text: '乙内容'),
            ],
          ),
        ],
      ),
      format: 'txt',
    );
    final localNovel = await LocalBooks.loadNovel(meta.aid);
    final secondCid = localNovel.catalogue.single.chapters[1].cid;
    final txtRes = await ExportBook.buildBytes(
      aid: meta.aid,
      novel: localNovel,
      format: ExportFormat.txt,
      imageStore: imgStore,
      onlyCids: {secondCid},
    );
    expect(txtRes.chapterCount, 1);
    expect(txtRes.fileName, '本地待导出书.txt');
    final txtStr = utf8.decode(txtRes.bytes);
    expect(txtStr, contains('第二章'));
    expect(txtStr, contains('乙内容'));
    expect(txtStr, isNot(contains('甲内容')));
  });

  test('novelProvider 与 chapterProvider 读取本地书秒开且零网络调用', () async {
    final meta = await LocalBooks.saveParsed(
      const ParsedBook(
        title: '本地轻小说 Provider 测试',
        author: '本地作者',
        description: '本地简介测试。',
        volumes: [
          EpubVolumeData(
            title: '第一卷',
            chapters: [EpubChapterData(title: '第一章', text: '本地正文第一行。\n本地正文第二行。')],
          ),
        ],
      ),
      format: 'epub',
    );
    final client = Wenku8Client(baseUrl: () => 'https://example.test', charset: () => CharsetType.gbk, headers: const {});
    addTearDown(() => client.dio.close(force: true));
    final api = _TrackingApi(client);
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    final novelSub = container.listen(novelProvider(meta.aid), (_, _) {});
    addTearDown(novelSub.close);
    final novel = await container.read(novelProvider(meta.aid).future);
    expect(novel.detail.title, '本地轻小说 Provider 测试');
    expect(novel.detail.status, '本地 EPUB');
    final cid = novel.catalogue.single.chapters.single.cid;
    final chapterSub = container.listen(chapterProvider((meta.aid, cid)), (_, _) {});
    addTearDown(chapterSub.close);
    final chapter = await container.read(chapterProvider((meta.aid, cid)).future);
    expect(chapter.text, contains('本地正文第一行。'));
    expect(chapter.text, contains('本地正文第二行。'));
    expect(ChapterCache.count(meta.aid), 0);
    expect(api.detailed, isEmpty);
    expect(api.catalogued, isEmpty);
    expect(api.chaptered, isEmpty);
  });

  testWidgets('NovelPageView 本地书展示本地标签与导出按钮，隐藏文库专属按钮且零网络请求', (tester) async {
    late LocalBookMeta meta;
    late NovelPage page;
    await tester.runAsync(() async {
      meta = await LocalBooks.saveParsed(
        const ParsedBook(
          title: '本地轻小说详情测试',
          author: '本地作者',
          description: '本地简介测试。',
          volumes: [
            EpubVolumeData(
              title: '第一卷',
              chapters: [EpubChapterData(title: '第一章', text: '正文')],
            ),
          ],
        ),
        format: 'epub',
      );
      page = await LocalBooks.loadNovel(meta.aid);
    });

    final client = Wenku8Client(baseUrl: () => 'https://example.test', charset: () => CharsetType.gbk, headers: const {});
    addTearDown(() => client.dio.close(force: true));
    final api = _TrackingApi(client);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(api),
          novelProvider(meta.aid).overrideWith((ref) => Stream.value(page)),
        ],
        child: MaterialApp(home: NovelPageView(aid: meta.aid)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地轻小说详情测试'), findsAtLeastNWidgets(1));
    expect(find.text('本地 EPUB'), findsOneWidget);
    expect(find.text('分卷'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    expect(find.text('推荐'), findsNothing);
    expect(find.text('书评'), findsNothing);
    expect(find.text('网页'), findsNothing);
    expect(find.text('缓存全本'), findsNothing);
    expect(api.detailed, isEmpty);
    expect(api.catalogued, isEmpty);
  });
}
