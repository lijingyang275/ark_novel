import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_exceptions.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/custom_exception.dart';
import 'package:ark_novel/next/bangumi.dart';
import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options, Future<void>? cancelFuture) onFetch;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    return onFetch(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _gbk(String html, {int status = 200, Map<String, List<String>>? headers}) =>
    ResponseBody.fromBytes(const GbkCodec(allowInvalid: true).encode(html), status, headers: headers ?? const {});

void main() {
  group('Wenku8Client CF 协调与检测', () {
    test('统一检测 403 与 503 Cloudflare 挑战页，但普通 503 维护页与 nginx 403 仍按 HTTP 异常处理', () async {
      var step = 0;
      final adapter = _CallbackAdapter((options, _) async {
        step++;
        return switch (step) {
          1 => _gbk('<html><title>Just a moment...</title><div id="challenge-running"></div></html>', status: 503, headers: {'server': ['cloudflare'], 'cf-ray': ['abc']}),
          2 => _gbk('maintenance', status: 503),
          3 => _gbk('forbidden', status: 403, headers: {'server': ['nginx']}),
          4 => _gbk('<html><div class="cf-turnstile"></div></html>', status: 403, headers: {'server': ['cloudflare']}),
          _ => _gbk('blocked', status: 403, headers: {'server': ['cloudflare']}),
        };
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
      );

      await expectLater(client.getPage('https://www.wenku8.net/1', charsetParam: false), throwsA(isA<CloudflareChallengeException>()));
      await expectLater(client.getPage('https://www.wenku8.net/2', charsetParam: false), throwsA(isA<Wenku8HttpException>().having((e) => e.status, 'status', 503)));
      await expectLater(client.getPage('https://www.wenku8.net/3', charsetParam: false), throwsA(isA<Wenku8HttpException>().having((e) => e.status, 'status', 403)));
      await expectLater(client.getPage('https://www.wenku8.net/4', charsetParam: false), throwsA(isA<CloudflareChallengeException>()));
      await expectLater(client.getPage('https://www.wenku8.net/5', charsetParam: false), throwsA(isA<Cloudflare403Exception>()));
    });

    test('单域名单飞 CF 协调：并发 3 条请求撞 403 仅拉起 1 次 challengeFallback，其余直接走 Dio 重试成功', () async {
      var cleared = false;
      var fallbackCalls = 0;
      final adapter = _CallbackAdapter((options, _) async {
        if (!cleared) return _gbk('cf', status: 403, headers: {'server': ['cloudflare']});
        return _gbk('ok:${options.uri.path}');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
        challengeFallback: (url, {referer}) async {
          fallbackCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          cleared = true;
          return 'web:${Uri.parse(url).path}';
        },
      );

      final results = await Future.wait([
        client.getPage('https://www.wenku8.net/a', charsetParam: false),
        client.getPage('https://www.wenku8.net/b', charsetParam: false),
        client.getPage('https://www.wenku8.net/c', charsetParam: false),
      ]);

      expect(fallbackCalls, 1);
      expect(results[0], 'web:/a');
      expect(results[1], 'ok:/b');
      expect(results[2], 'ok:/c');
      // 只有 /a 撞了一次 403，/b 和 /c 在门控解除后直接成功
      expect(adapter.requests.length, 3);
    });

    test('CF 挑战失败进入冷却窗口，后续请求快速失败；clearChallengeCooldown 后立即放行', () async {
      var fallbackCalls = 0;
      final adapter = _CallbackAdapter((options, _) async => _gbk('cf', status: 403, headers: {'server': ['cloudflare']}));
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
        challengeCooldown: const Duration(seconds: 30),
        challengeFallback: (url, {referer}) async {
          fallbackCalls++;
          throw CloudflareChallengeException(requestOptions: RequestOptions(path: url));
        },
      );

      await expectLater(client.getPage('https://www.wenku8.net/1', charsetParam: false), throwsA(isA<CloudflareChallengeException>()));
      expect(fallbackCalls, 1);
      expect(adapter.requests.length, 1);

      // 冷却期内直接快速失败，不再请求网络也不再进 fallback
      await expectLater(client.getPage('https://www.wenku8.net/2', charsetParam: false), throwsA(isA<CloudflareChallengeException>()));
      expect(fallbackCalls, 1);
      expect(adapter.requests.length, 1);

      // 手动验证后清除冷却，允许再次尝试
      client.clearChallengeCooldown('www.wenku8.net');
      await expectLater(client.getPage('https://www.wenku8.net/3', charsetParam: false), throwsA(isA<CloudflareChallengeException>()));
      expect(fallbackCalls, 2);
      expect(adapter.requests.length, 2);
    });

    test('fallback 过盾后若返回登录页且 shouldRetryAfterFallback 为真，则用 Dio 重试一次', () async {
      var dioCalls = 0;
      var fallbackCalls = 0;
      final adapter = _CallbackAdapter((options, _) async {
        dioCalls++;
        if (dioCalls == 1) return _gbk('cf', status: 403, headers: {'server': ['cloudflare']});
        return _gbk('real-user-page');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.cc',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
        challengeFallback: (url, {referer}) async {
          fallbackCalls++;
          return '<form><input name="password" type="password"></form>';
        },
        shouldRetryAfterFallback: (html) => html.contains('name="password"'),
      );

      final html = await client.getPage('https://www.wenku8.cc/userdetail.php', charsetParam: false);
      expect(fallbackCalls, 1);
      expect(dioCalls, 2);
      expect(html, 'real-user-page');
    });

    test('跨域名 301 重定向后触发 CF 时按跳转后域名维护单飞门控并正确释放', () async {
      var cleared = false;
      var fallbackCalls = 0;
      String? fallbackUrl;
      final adapter = _CallbackAdapter((options, _) async {
        if (options.uri.host == 'www.wenku8.cc') {
          return _gbk('', status: 301, headers: {'location': ['https://www.wenku8.net${options.uri.path}']});
        }
        if (!cleared) return _gbk('cf', status: 403, headers: {'server': ['cloudflare']});
        return _gbk('ok:${options.uri.path}');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.cc',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
        challengeFallback: (url, {referer}) async {
          fallbackCalls++;
          fallbackUrl = url;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          cleared = true;
          return 'web:${Uri.parse(url).path}';
        },
      );

      final res = await Future.wait([
        client.getPage('https://www.wenku8.cc/a', charsetParam: false),
        client.getPage('https://www.wenku8.cc/b', charsetParam: false),
      ]);
      expect(fallbackCalls, 1);
      expect(fallbackUrl, 'https://www.wenku8.net/a');
      expect(res, ['web:/a', 'ok:/b']);
    });
  });

  group('Wenku8Client 去重、取消、429 与瞬态重试', () {
    test('相同 (url, referer) 的并发 GET 合并去重；单方取消不影响另一方', () async {
      final gate = Completer<void>();
      final adapter = _CallbackAdapter((options, _) async {
        await gate.future;
        return _gbk('page:${options.headers['Referer'] ?? 'none'}');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
      );

      final cancel1 = CancelToken();
      final f1 = client.getPage('https://www.wenku8.net/book/1.htm', charsetParam: false, referer: 'https://www.wenku8.net/', cancelToken: cancel1);
      final f2 = client.getPage('https://www.wenku8.net/book/1.htm', charsetParam: false, referer: 'https://www.wenku8.net/');
      final f3 = client.getPage('https://www.wenku8.net/book/1.htm', charsetParam: false, referer: 'https://www.wenku8.net/other');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel1.cancel('user left');
      await expectLater(f1, throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)));

      gate.complete();
      expect(await f2, 'page:https://www.wenku8.net/');
      expect(await f3, 'page:https://www.wenku8.net/other');
      // f1 和 f2 共享一次请求，f3 因为 referer 不同发了第 2 次
      expect(adapter.requests.length, 2);
    });

    test('CancelToken 排队时立即出队，在途取消立即释放节流槽位不死锁后续请求', () async {
      final firstStarted = Completer<void>();
      final firstBlocked = Completer<ResponseBody>();
      final adapter = _CallbackAdapter((options, cancelFuture) async {
        if (options.uri.path == '/1') {
          firstStarted.complete();
          cancelFuture?.then((_) {
            if (!firstBlocked.isCompleted) {
              firstBlocked.completeError(DioException.requestCancelled(requestOptions: options, reason: 'aborted'));
            }
          });
          return firstBlocked.future;
        }
        return _gbk('ok:${options.uri.path}');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
      );

      final c1 = CancelToken();
      final c2 = CancelToken();
      final f1 = client.getPage('https://www.wenku8.net/1', charsetParam: false, cancelToken: c1);
      await firstStarted.future;
      final f2 = client.getPage('https://www.wenku8.net/2', charsetParam: false, cancelToken: c2);
      final f3 = client.getPage('https://www.wenku8.net/3', charsetParam: false);

      // 取消排队中的 /2，它不应发给底层适配器
      c2.cancel('drop queued');
      await expectLater(f2, throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)));

      // 取消在途的 /1，应立即释放槽位让 /3 完成
      c1.cancel('abort active');
      await expectLater(f1, throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)));
      expect(await f3, 'ok:/3');
      expect(adapter.requests.map((r) => r.uri.path), ['/1', '/3']);
    });

    test('429 遵循 Retry-After / 退避并最多重试至成功', () async {
      var attempts = 0;
      final adapter = _CallbackAdapter((options, _) async {
        attempts++;
        if (attempts < 3) {
          return _gbk('slow down', status: 429);
        }
        return _gbk('recovered');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: const Duration(milliseconds: 20),
      );

      final html = await client.getPage('https://www.wenku8.net/p', charsetParam: false);
      expect(html, 'recovered');
      expect(attempts, 3);
    });

    test('幂等 GET 对 502/504 与 Cronet immediatelyRetryable 最多重试 1 次，绝不重试 404/403/非幂等请求', () async {
      var calls = 0;
      final adapter = _CallbackAdapter((options, _) async {
        calls++;
        if (options.uri.path == '/502') {
          return calls == 1 ? _gbk('bad gateway', status: 502) : _gbk('ok502');
        }
        if (options.uri.path == '/cronet') {
          if (calls == 1) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
              error: 'NetworkClientException: net::ERR_NETWORK_CHANGED, immediatelyRetryable=true',
            );
          }
          return _gbk('okCronet');
        }
        if (options.uri.path == '/404') return _gbk('not found', status: 404);
        if (options.uri.path == '/no-retry') return _gbk('bad gateway', status: 502);
        return _gbk('ok');
      });
      final client = Wenku8Client(
        baseUrl: () => 'https://www.wenku8.net',
        charset: () => CharsetType.gbk,
        headers: const {},
        dio: Dio()..httpClientAdapter = adapter,
        rateLimitPause: Duration.zero,
        transientRetryDelay: Duration.zero,
      );

      expect(await client.getPage('https://www.wenku8.net/502', charsetParam: false), 'ok502');
      expect(calls, 2);

      calls = 0;
      expect(await client.getPage('https://www.wenku8.net/cronet', charsetParam: false), 'okCronet');
      expect(calls, 2);

      calls = 0;
      await expectLater(client.getPage('https://www.wenku8.net/404', charsetParam: false), throwsA(isA<Wenku8HttpException>()));
      expect(calls, 1);

      calls = 0;
      await expectLater(client.getPage('https://www.wenku8.net/no-retry', charsetParam: false, retryTransient: false), throwsA(isA<Wenku8HttpException>()));
      expect(calls, 1);
    });
  });

  group('BangumiCovers 并发限流、429 退避与外传容错', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('ark_bgm_test_');
      Hive.init(tempDir.path);
      await Hive.openBox('session');
    });

    tearDownAll(() async {
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    setUp(() async {
      await Hive.box('session').clear();
    });

    test('全局并发上限最多 2 书 / 4 请求，429 自动退避重试，单条外传失败不丢弃主系列结果', () async {
      await Hive.box('session').put('lib:books', {
        for (var i = 1; i <= 4; i++) '$i': {'title': '测试轻小说$i', 'img': '', 'cats': const <String>[], 'done': false},
      });

      var active = 0;
      var maxActive = 0;
      var hit429Once = false;
      final adapter = _CallbackAdapter((options, _) async {
        active++;
        if (active > maxActive) maxActive = active;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          final path = options.uri.path;
          if (path.endsWith('/search/subjects')) {
            if (!hit429Once) {
              hit429Once = true;
              return ResponseBody.fromString('rate limited', 429, headers: {'content-type': ['text/plain']});
            }
            return ResponseBody.fromString(
              jsonEncode({
                'data': [
                  {'id': 100, 'name': 'Main', 'name_cn': '主系列', 'platform': '小说', 'series': true},
                ],
              }),
              200,
              headers: {'content-type': ['application/json']},
            );
          }
          if (path.endsWith('/subjects/100/subjects')) {
            return ResponseBody.fromString(
              jsonEncode([
                {'id': 101, 'name': '主系列 (1)', 'relation': '单行本', 'images': {'large': 'https://bgm/v1.jpg'}},
                {'id': 201, 'name': '失败外传', 'relation': '番外篇', 'type': 1},
                {'id': 202, 'name': '正常外传', 'relation': '番外篇', 'type': 1},
              ]),
              200,
              headers: {'content-type': ['application/json']},
            );
          }
          if (path.endsWith('/subjects/201')) {
            return ResponseBody.fromString('error', 500, headers: {'content-type': ['text/plain']});
          }
          if (path.endsWith('/subjects/202')) {
            return ResponseBody.fromString(
              jsonEncode({'id': 202, 'name': 'Extra OK', 'name_cn': '正常外传', 'platform': '小说', 'series': false, 'images': {'large': 'https://bgm/ex.jpg'}}),
              200,
              headers: {'content-type': ['application/json']},
            );
          }
          return ResponseBody.fromString('[]', 200, headers: {'content-type': ['application/json']});
        } finally {
          active--;
        }
      });

      final bgm = BangumiCovers(Dio()..httpClientAdapter = adapter, rateLimitBase: const Duration(milliseconds: 20));
      final results = await Future.wait([bgm.series('1'), bgm.series('2'), bgm.series('3'), bgm.series('4')]);

      expect(hit429Once, isTrue);
      expect(maxActive, lessThanOrEqualTo(4));
      for (final s in results) {
        expect(s, isNotNull);
        expect(s!.vols.length, 1);
        expect(s.vols.first.img, 'https://bgm/v1.jpg');
        expect(s.extras.length, 1);
        expect(s.extras.first.cn, '正常外传');
      }
    });
  });
}
