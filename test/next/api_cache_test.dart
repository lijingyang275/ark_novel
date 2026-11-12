import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/common/charset_type.dart';
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
  late _Seq adapter;
  late Api api;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_test').path);
    await ChapterCache.open();
  });

  setUp(() {
    adapter = _Seq();
    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter);
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
}
