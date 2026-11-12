import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/custom_exception.dart';

/// 按请求路径返回预设响应的假适配器，并记录请求过的地址
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, ResponseBody Function()> routes;
  final List<Uri> requested = [];
  final List<String> methods = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requested.add(options.uri);
    methods.add(options.method);
    return routes[options.uri.path]!();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _redirect(String location) => ResponseBody.fromBytes(
  const [],
  302,
  headers: {
    'location': [location],
  },
);

ResponseBody _page(List<int> bytes) => ResponseBody.fromBytes(bytes, 200);

Wenku8Client _client(_FakeAdapter adapter) =>
    Wenku8Client(baseUrl: () => 'https://www.wenku8.net', charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = adapter);

void main() {
  test('跟随多次重定向（相对、以 / 开头、绝对地址），并按 GBK 解码最终页面', () async {
    final adapter = _FakeAdapter({
      '/a.php': () => _redirect('b.php'),
      '/b.php': () => _redirect('/c.php'),
      '/c.php': () => _redirect('https://www.wenku8.net/login.php'),
      '/login.php': () => _page([0xB5, 0xC7, 0xC2, 0xBC]), // "登录"
    });

    final html = await _client(adapter).getPage('https://www.wenku8.net/a.php');

    expect(html, '登录');
    expect(adapter.requested.map((u) => u.path), ['/a.php', '/b.php', '/c.php', '/login.php']);
    expect(adapter.requested.first.query, '&charset=gbk');
  });

  test('POST 跳到登录页（包括间接跳转）不能报告提交成功，也不重发请求体', () async {
    final adapter = _FakeAdapter({
      '/submit.php': () => _redirect('/result.php'),
      '/result.php': () => _redirect('/login.php'),
    });
    await expectLater(_client(adapter).postForm('https://www.wenku8.net/submit.php', 'body=test'), throwsA(isA<Wenku8UnexpectedPageException>()));
    expect(adapter.methods, ['POST', 'GET']);
    expect(adapter.requested.map((u) => u.path), ['/submit.php', '/result.php']);
  });

  test('POST 成功后用 GET 读取 303 结果页，正常返回解码结果', () async {
    final adapter = _FakeAdapter({
      '/submit.php': () => ResponseBody.fromBytes(const [], 303, headers: {'location': ['/result.php']}),
      '/result.php': () => _page([0xB5, 0xC7, 0xC2, 0xBC]),
    });
    expect(await _client(adapter).postForm('https://www.wenku8.net/submit.php', 'body=test'), '登录');
    expect(adapter.methods, ['POST', 'GET']);
  });

  test('POST 的重定向循环、缺少目标、307/308 均按结果未确认处理', () async {
    for (final status in [302, 307, 308]) {
      final adapter = _FakeAdapter({
        '/submit.php': () => ResponseBody.fromBytes(const [], status, headers: status == 302 ? {} : {'location': ['/result.php']}),
      });
      await expectLater(_client(adapter).postForm('https://www.wenku8.net/submit.php', 'body=test'), throwsA(isA<Wenku8UnexpectedPageException>()));
      expect(adapter.methods, ['POST']);
    }
    final loop = _FakeAdapter({'/submit.php': () => _redirect('/submit.php')});
    await expectLater(_client(loop).postForm('https://www.wenku8.net/submit.php', 'body=test'), throwsA(isA<Wenku8UnexpectedPageException>()));
    expect(loop.methods, ['POST', 'GET', 'GET', 'GET', 'GET', 'GET']);
  });

  test('charsetParam: false 时 GBK 不带 charset 参数、繁体仍带；referer 会发出去', () async {
    final adapter = _FakeAdapter({'/a.php': () => _page([0xB5, 0xC7])});
    final headers = <Map<String, dynamic>>[];
    final gbk = _client(adapter)..dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      headers.add(o.headers);
      h.next(o);
    }));
    await gbk.getPage('https://www.wenku8.net/a.php?id=1', charsetParam: false, referer: 'https://www.wenku8.net/book/1.htm');
    expect(adapter.requested.single.query, 'id=1');
    expect(headers.single['Referer'], 'https://www.wenku8.net/book/1.htm');

    final big5Adapter = _FakeAdapter({'/a.php': () => _page([0xA7, 0xDA])});
    final big5 = Wenku8Client(baseUrl: () => 'https://www.wenku8.net', charset: () => CharsetType.big5Hkscs, headers: const {}, dio: Dio()..httpClientAdapter = big5Adapter);
    await big5.getPage('https://www.wenku8.net/a.php?id=1', charsetParam: false);
    expect(big5Adapter.requested.single.query, 'id=1&charset=big5');
  });

  test('HTTP 429 给出"请求太频繁"的提示', () {
    expect(const Wenku8HttpException(429).message, contains('太频繁'));
    expect(const Wenku8HttpException(522).message, contains('522'));
  });

  test('重定向死循环时最多跟随 5 次', () async {
    final adapter = _FakeAdapter({'/loop.php': () => _redirect('loop.php')});
    await expectLater(_client(adapter).getPage('https://www.wenku8.net/loop.php'), completes);
    expect(adapter.requested, hasLength(6));
  });

  test('403 识别为 Cloudflare 拦截', () async {
    final adapter = _FakeAdapter({'/x.php': () => ResponseBody.fromBytes(const [], 403)});
    await expectLater(_client(adapter).getPage('https://www.wenku8.net/x.php'), throwsA(isA<Cloudflare403Exception>()));
  });

  test('带 cf-mitigated: challenge 的 403 识别为需要验证', () async {
    final adapter = _FakeAdapter({
      '/x.php': () => ResponseBody.fromBytes(const [], 403, headers: {
            'cf-mitigated': ['challenge'],
          }),
    });
    await expectLater(_client(adapter).getPage('https://www.wenku8.net/x.php'), throwsA(isA<CloudflareChallengeException>()));
  });

  test('被验证拦下时改用备用方式取页面，带上原地址和来源页', () async {
    final adapter = _FakeAdapter({
      '/x.php': () => ResponseBody.fromBytes(const [], 403, headers: {
            'cf-mitigated': ['challenge'],
          }),
    });
    final calls = <String>[];
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.net',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()..httpClientAdapter = adapter,
      challengeFallback: (url, {referer}) async {
        calls.add('$url|$referer');
        return '<html>ok</html>';
      },
    );
    expect(await client.getPage('https://www.wenku8.net/x.php?id=1', charsetParam: false, referer: 'https://www.wenku8.net/r'), '<html>ok</html>');
    expect(calls, ['https://www.wenku8.net/x.php?id=1|https://www.wenku8.net/r']);
  });

  test('直接 403 拒绝时也改用备用方式取页面', () async {
    final client = Wenku8Client(
      baseUrl: () => 'https://www.wenku8.net',
      charset: () => CharsetType.gbk,
      headers: const {},
      dio: Dio()..httpClientAdapter = _FakeAdapter({'/x.php': () => ResponseBody.fromBytes(const [], 403)}),
      challengeFallback: (url, {referer}) async => 'ok',
    );
    expect(await client.getPage('https://www.wenku8.net/x.php', charsetParam: false), 'ok');
  });

  test('恢复 cookie 时值里带逗号也不会报错', () async {
    final client = _client(_FakeAdapter({}));
    await client.restoreCookie('jieqiUserInfo=abc;jieqiRecentRead=1792527353,1792527401,1792527434', ['https://www.wenku8.net']);
  });

  test('恢复 cookie 时名字不合法的只跳过那一个', () async {
    final client = _client(_FakeAdapter({}));
    await client.restoreCookie('a b=1; ok=2', ['https://www.wenku8.net']);
    expect(await client.exportCookies('https://www.wenku8.net'), {'ok': '2'});
  });
}
