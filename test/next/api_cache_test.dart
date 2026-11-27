import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:hive_ce/hive.dart';

/// 按顺序返回预设响应的假适配器（状态码 + 页面）。
class _Seq implements HttpClientAdapter {
  final List<(int, String)> responses = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final (status, html) = responses.removeAt(0);
    return ResponseBody.fromBytes(const GbkCodec(allowInvalid: true).encode(html), status);
  }

  @override
  void close({bool force = false}) {}
}

String fixture(String name) => File('test/data/wenku8/fixtures/$name').readAsStringSync();

void main() {
  late Directory tempDir;
  late _Seq adapter;
  late Api api;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ark_test');
    Hive.init(tempDir.path);
    await ChapterCache.open();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    adapter = _Seq();
    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: Duration.zero);
    api = Api(client, Wenku8Urls(base, CharsetType.gbk), base, 'guest');
  });

  test('联网成功后写备份；之后遇到 522 用备份顶替', () async {
    adapter.responses.addAll([(200, fixture('catalogue.html')), (522, '<html>Connection timed out</html>')]);
    final first = await api.catalogue('1001');
    final second = await api.catalogue('1001');
    expect(second.map((v) => v.title), first.map((v) => v.title));
  });

  test('登录页、错误页这类解析失败的页面不会覆盖备份，也不冒充备份', () async {
    adapter.responses.addAll([(200, fixture('catalogue.html')), (200, '<html><body>请登录</body></html>'), (522, 'x')]);
    final good = await api.catalogue('1002');
    await expectLater(api.catalogue('1002'), throwsA(isA<Wenku8UnexpectedPageException>()));
    // 备份还是原来那份：断网时仍能拿到
    final again = await api.catalogue('1002');
    expect(again.map((v) => v.title), good.map((v) => v.title));
  });

  test('没有备份时，5xx 直接报网络问题', () async {
    adapter.responses.add((503, 'maintenance'));
    await expectLater(api.catalogue('1003'), throwsA(isA<Wenku8HttpException>()));
  });

  test('空目录当失败处理，不会被当成"这本书一章都没有"', () async {
    adapter.responses.add((200, '<html><body><div id="content"></div></body></html>'));
    await expectLater(api.catalogue('1004'), throwsA(isA<Wenku8UnexpectedPageException>()));
  });

  test('加入、移出书架：业务错误页不冒充成功', () async {
    adapter.responses.addAll([(200, fixture('error.html')), (200, fixture('error.html'))]);
    await expectLater(api.removeFromBookshelf('1'), throwsA(isA<Wenku8ActionRejectedException>()));
    await expectLater(api.addToBookshelf('1'), throwsA(isA<Wenku8ActionRejectedException>()));
  });

  test('直接返回登录表单：提交和移出书架都不能当成功', () async {
    const login = '<html><form action="/login.php"><input name="username"><input name="password"></form></html>';
    adapter.responses.addAll([(200, login), (200, login)]);
    await expectLater(api.sendComment('1', 'title', 'body'), throwsA(isA<Wenku8UnexpectedPageException>()));
    await expectLater(api.removeFromBookshelf('1'), throwsA(isA<Wenku8UnexpectedPageException>()));
  });

  test('发评论：返回错误页时抛出，让界面保留输入', () async {
    adapter.responses.add((200, fixture('error.html')));
    await expectLater(api.sendComment('1', '标题', 'A&B+C'), throwsA(isA<Wenku8UnexpectedPageException>()));
  });

  test('加入书架遇到要求登录的错误页：抛登录失效而非业务拒绝，避免离线队列丢弃', () async {
    const loginErr = '<div class="blocktitle">出现错误！</div><div class="blockcontent">对不起，您需要登录后才能访问本页！</div>';
    adapter.responses.add((200, loginErr));
    await expectLater(api.addToBookshelf('1'), throwsA(isA<Wenku8LoginRequiredException>()));
  });

  test('搜索无结果页面返回空列表而非解析异常', () async {
    adapter.responses.add((200, '<html><body><div id="content"><table class="grid"></table></div></body></html>'));
    final res = await api.search('不存在的书名xyz', byAuthor: false, page: 1);
    expect(res.items, isEmpty);
    expect(res.maxPage, 0);
  });

  test('_cached 遇 Cloudflare 异常即使回落旧缓存也会触发 onCloudflare 通知', () async {
    var cfNotified = 0;
    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: Duration.zero);
    final trackedApi = Api(client, Wenku8Urls(base, CharsetType.gbk), base, 'guest', onCloudflare: () => cfNotified++);

    adapter.responses.addAll([(200, fixture('catalogue.html')), (403, '<html>blocked by cf</html>')]);
    final first = await trackedApi.catalogue('2001');
    final second = await trackedApi.catalogue('2001');
    expect(second.map((v) => v.title), first.map((v) => v.title));
    expect(cfNotified, 1);
  });

  test('search() 遇 CF 异常与 429 不做二次 5.2s 自动重试，异常搜索页记录 lastFailedHtml', () async {
    var cfNotified = 0;
    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: Duration.zero);
    final trackedApi = Api(client, Wenku8Urls(base, CharsetType.gbk), base, 'guest', onCloudflare: () => cfNotified++);

    // 403 CF：立即上抛，不消耗第二条响应也不等 5.2s
    adapter.responses.addAll([(403, 'cf'), (200, '<html><body><div id="content"></div></body></html>')]);
    final sw = Stopwatch()..start();
    await expectLater(trackedApi.search('cf_test', byAuthor: false, page: 1), throwsA(isA<Cloudflare403Exception>()));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(adapter.responses.length, 1);
    expect(cfNotified, 1);

    // 429：Wenku8Client 内试 3 次后立即上抛，search 不再等 5.2s 重跑
    adapter.responses.clear();
    adapter.responses.addAll([(429, 'rate'), (429, 'rate'), (429, 'rate'), (200, 'should_not_be_called')]);
    final api2 = Api(
      Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: Duration.zero),
      Wenku8Urls(base, CharsetType.gbk),
      base,
      'guest',
    );
    await expectLater(api2.search('rate_test', byAuthor: false, page: 1), throwsA(isA<Wenku8HttpException>()));
    expect(adapter.responses.length, 1);

    // 异常搜索页：同步写入实例 lastFailedSearchHtml 与兼容顶层 lastFailedHtml
    adapter.responses.clear();
    adapter.responses.add((200, '<html><title>Weird</title><body>unexpected</body></html>'));
    final api3 = Api(
      Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter, rateLimitPause: Duration.zero),
      Wenku8Urls(base, CharsetType.gbk),
      base,
      'guest',
    );
    await expectLater(api3.search('weird', byAuthor: false, page: 1), throwsA(isA<Wenku8UnexpectedPageException>()));
    expect(api3.lastFailedSearchHtml, contains('Weird'));
    expect(lastFailedHtml, contains('Weird'));
  });

  test('Api.search 在 5.2s 冷却等待中被 cancelToken 取消时立即退出且不推进 _lastSearch', () async {
    adapter.responses.addAll([
      (200, '<html><body><div id="content"><table class="grid"></table></div></body></html>'),
      (200, '<html><body><div id="content"><table class="grid"></table></div></body></html>'),
    ]);
    // 第一次搜索立刻执行，进入 5.2s 冷却期
    await api.search('first', byAuthor: false, page: 1);
    expect(api.isSearchCoolingDown, isTrue);

    // 第二次搜索处于冷却等待期，100ms 后取消应立即退出（远小于 5.2s）
    final token = CancelToken();
    Future<void>.delayed(const Duration(milliseconds: 80), () => token.cancel('user_cancelled'));
    final sw = Stopwatch()..start();
    await expectLater(api.search('second', byAuthor: false, page: 1, cancelToken: token), throwsA(isA<DioException>()));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    // 响应未被消耗
    expect(adapter.responses.length, 1);
  });

  test('ranking/category/completed 5 分钟内存 LRU 缓存与 fresh: true 强刷；大 HTML 走 compute 异步解析', () async {
    final listHtml = fixture('catalogue.html').replaceFirst('<table class="css">', '<div id="content"><a href="/book/1001.htm" title="测试书">测试书</a></div><table class="css">');
    adapter.responses.addAll([(200, listHtml), (200, listHtml)]);
    final r1 = await api.ranking('allvisit', 1);
    final r2 = await api.ranking('allvisit', 1);
    expect(r2.items.length, r1.items.length);
    // 第二次命中内存 LRU 缓存，不消耗第二条网络响应
    expect(adapter.responses.length, 1);

    // fetchRanking(fresh: true) 强制走网络刷新
    await api.fetchRanking('allvisit', 1, fresh: true);
    expect(adapter.responses, isEmpty);

    // > 16 KB 大目录 HTML 走 compute 异步解析正常返回
    final bigPadding = '<!-- ${'x' * 20000} -->';
    adapter.responses.add((200, '$bigPadding${fixture('catalogue.html')}'));
    final bigCat = await api.catalogue('9999', fresh: true);
    expect(bigCat, isNotEmpty);
  });
}
