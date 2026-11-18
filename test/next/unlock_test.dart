import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/data/wenku8/wenku8_client.dart';
import 'package:ark_novel/data/wenku8/wenku8_urls.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/common/charset_type.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/pages/settings_page.dart';
import 'package:ark_novel/next/unlock.dart';
import 'package:ark_novel/next/unlock_addon.dart';

class _Site implements HttpClientAdapter {
  _Site(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(const GbkCodec(allowInvalid: true).encode('<html><body><div id="content">$body</div></body></html>'), 200);

  @override
  void close({bool force = false}) {}
}

class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options, String bodyText) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        chunks.addAll(chunk);
      }
    }
    return handler(options, utf8.decode(chunks, allowMalformed: true));
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _sampleAddonJson({bool withApi = true, bool withFullText = true}) => {
  'schema': 1,
  'name': '测试扩展包',
  'version': '1.2.3',
  'description': '用于验证运行期导入与执行引擎',
  'match': {
    'requireNoImages': true,
    'maxTextLength': 60,
    'equalsIgnoreCase': ['null'],
    'containsAny': ['RESTRICTED_PLACEHOLDER'],
  },
  if (withApi)
    'api': {
      'label': '优先使用示例接口',
      'endpoints': ['https://relay.example.invalid/api', 'https://api.example.invalid/api'],
      'method': 'POST',
      'contentType': 'application/x-www-form-urlencoded',
      'headers': {'User-Agent': 'TestAgent/1.0'},
      'bodyTemplate': 'payload={{base64(aid={{aid}}&cid={{cid}})}}&ts={{timestamp_ms}}',
      'responseCharset': 'utf-8',
      'errorIfStartsWith': ['<!doctype', '<html'],
      'errorIfContains': ['bad request'],
      'shortErrorMaxLength': 200,
      'shortErrorStartsWith': ['welcome'],
      'imagePattern': r'\[\[img\]\](.*?)\[\[/img\]\]',
      'separatorPattern': r'^[★☆◆◇\s]+$',
      'footerContainsAny': ['example.invalid'],
      'test': {
        'bodyTemplate': 'payload={{base64(do=list&aid={{aid}})}}',
        'acceptContainsAny': ['<volume'],
      },
    },
  if (withFullText)
    'fullText': {
      'urlTemplates': ['https://dl1.example.invalid/book/{{aid_div_1000}}/{{aid}}.txt', 'https://dl2.example.invalid/book/{{aid}}.txt'],
      'charset': 'gbk',
      'decodeEntities': true,
      'errorIfStartsWith': ['<!doctype', '<html'],
      'titlePattern': r'^<([^<>\n]+)>$',
      'separatorPattern': r'^[★☆◆◇\s]+$',
      'bannerContainsAny': ['dl.example.invalid'],
      'lockedMessage': '本章无法从整本文本中获取。',
    },
};

void main() {
  late ProviderContainer c;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('ark_unlock_runtime_test').path);
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  setUp(() async {
    await Hive.box('session').clear();
    c = ProviderContainer();
  });

  tearDown(() => c.dispose());

  test('未导入扩展包时状态为关闭，正常章节不触发回退', () async {
    final s = c.read(unlockServiceProvider);
    expect(hasUnlockAddon, isFalse);
    expect(s.enabled, isFalse);
    expect(isLockedContent(Content(text: 'RESTRICTED_PLACEHOLDER', images: const [])), isFalse);

    const base = 'https://www.wenku8.net';
    final client = Wenku8Client(baseUrl: () => base, charset: () => CharsetType.gbk, headers: const {}, dio: Dio()..httpClientAdapter = _Site('正常正文'));
    final api = Api(client, Wenku8Urls(base, CharsetType.gbk), base, 'u1', unlock: s);
    expect((await api.chapter('15', '2')).text, '正常正文');
  });

  test('口令与文件编解码支持单行、换行口令、原始 JSON 与 Gzip 字节，并能拒绝非法配置', () {
    final json = _sampleAddonJson();
    final token = UnlockAddonCodec.encodeToken(json);
    expect(token.startsWith(UnlockAddonCodec.tokenPrefix), isTrue);

    // 模拟微信/邮件转发折行
    final wrapped = '${token.substring(0, 20)}\n  ${token.substring(20)}';
    final fromToken = UnlockAddonCodec.decodeText(wrapped);
    expect(fromToken.name, '测试扩展包');
    expect(fromToken.api?.endpoints.length, 2);

    final fromRawJson = UnlockAddonCodec.decodeText(jsonEncode(json));
    expect(fromRawJson.version, '1.2.3');

    final gzBytes = Uint8List.fromList(GZipEncoder().encode(utf8.encode(jsonEncode(json))));
    final fromGz = UnlockAddonCodec.decodeBytes(gzBytes);
    expect(fromGz.fullText?.charset, 'gbk');

    expect(() => UnlockAddonCodec.decodeText('not-a-token'), throwsFormatException);
    expect(() => UnlockAddonCodec.decodeText(jsonEncode({'schema': 2, 'name': 'x'})), throwsFormatException);
    expect(
      () => UnlockAddonCodec.decodeText(
        jsonEncode({
          'schema': 1,
          'name': 'bad-regex',
          'match': {'regexPatterns': ['[']},
          'fullText': {
            'urlTemplates': ['https://example.invalid/{{aid}}.txt'],
          },
        }),
      ),
      throwsFormatException,
    );
  });

  test('模板渲染正确替换变量及 nested base64', () {
    final rendered = renderAddonTemplate(
      'https://dl.example.invalid/{{aid_div_1000}}/{{aid}}?q={{base64(aid={{aid}}&cid={{cid}})}}',
      {'aid': '2345', 'cid': '89'},
    );
    final expectedB64 = base64Encode(utf8.encode('aid=2345&cid=89'));
    expect(rendered, 'https://dl.example.invalid/2/2345?q=$expectedB64');
  });

  test('导入后支持受限判定、API 多端点回退、图片提取及 testApi，且不进入公开备份', () async {
    await c.read(unlockAddonProvider.notifier).importText(UnlockAddonCodec.encodeToken(_sampleAddonJson()));
    expect(hasUnlockAddon, isTrue);
    expect(isLockedContent(Content(text: 'RESTRICTED_PLACEHOLDER', images: const [])), isTrue);
    expect(isLockedContent(Content(text: 'null', images: const [])), isTrue);
    expect(isLockedContent(Content(text: 'RESTRICTED_PLACEHOLDER', images: const ['https://img.example.invalid/1.jpg'])), isFalse);

    // 不进 Backup.make()
    final backupJson = jsonDecode(Backup.make()) as Map<String, dynamic>;
    final boxMap = backupJson['box'] as Map<String, dynamic>;
    expect(boxMap.containsKey(UnlockAddonStore.storageKey), isFalse);

    final adapter = _MockAdapter((options, bodyText) async {
      if (options.uri.host == 'relay.example.invalid') {
        return ResponseBody.fromString('Welcome to proxy', 200);
      }
      if (bodyText.contains(base64Encode(utf8.encode('do=list&aid=1')))) {
        return ResponseBody.fromString('<volume vid="1">第一卷</volume>', 200);
      }
      return ResponseBody.fromString(
        '第一段\r\n★☆★☆\r\n[[img]]//pic.example.invalid/a.jpg[[/img]]\r\n第二段\r\n来自 example.invalid',
        200,
      );
    });

    final service = UnlockService(c.read(unlockServiceProviderRefProbeProvider), apiDioBuilder: () => Dio()..httpClientAdapter = adapter);
    final chapter = await service.chapter('10', '20', () async => const []);
    expect(chapter.text, '第一段\n第二段');
    expect(chapter.images, ['https://pic.example.invalid/a.jpg']);

    final testMsg = await service.testApi();
    expect(testMsg, contains('接口测试成功'));
    expect(testMsg, contains('relay.example.invalid：返回了错误页'));
    expect(testMsg, contains('api.example.invalid：可用'));
  });

  test('API 失败时自动回退整本文本下载、GBK 解码与按目录拆章，插图缺章给出配置提示', () async {
    await c.read(unlockAddonProvider.notifier).importText(UnlockAddonCodec.encodeToken(_sampleAddonJson()));

    final txtContent = [
      '<示例小说>',
      'dl.example.invalid 顶部广告',
      '第一卷 第一章 开始',
      '  第一段内容&#8231;测试。',
      '★☆★☆',
      '  第二段内容。',
      '第一卷 插图',
    ].join('\r\n');
    final gbkBytes = Uint8List.fromList(const GbkCodec(allowInvalid: true).encode(txtContent));

    final apiAdapter = _MockAdapter((_, _) async => ResponseBody.fromString('<html>error</html>', 200));
    final txtAdapter = _MockAdapter((options, _) async {
      if (options.uri.host == 'dl1.example.invalid') {
        return ResponseBody.fromString('<!doctype html><html>404</html>', 404);
      }
      return ResponseBody.fromBytes(gbkBytes, 200);
    });

    final service = UnlockService(
      c.read(unlockServiceProviderRefProbeProvider),
      apiDioBuilder: () => Dio()..httpClientAdapter = apiAdapter,
      txtDioBuilder: () => Dio()..httpClientAdapter = txtAdapter,
    );

    final cat = [
      CatVolume(
        title: '第一卷',
        chapters: [CatChapter(title: '第一章 开始', cid: '101'), CatChapter(title: '插图', cid: '102')],
      ),
    ];

    final got = await service.chapter('1234', '101', () async => cat);
    expect(got.text, '第一段内容‧测试。\n第二段内容。');
    expect(txtAdapter.requests.first.uri.toString(), 'https://dl1.example.invalid/book/1/1234.txt');
    expect(txtAdapter.requests[1].uri.toString(), 'https://dl2.example.invalid/book/1234.txt');

    await expectLater(
      service.chapter('1234', '102', () async => cat),
      throwsA(isA<ChapterLockedException>().having((e) => e.message, 'message', '本章无法从整本文本中获取。')),
    );
  });

  testWidgets('设置页正确展示未导入、导入后与移除后的妙妙小工具界面', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: SettingsSectionPage(section: SettingsSection.unlock)),
      ),
    );
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('从剪贴板导入口令'), findsOneWidget);
    expect(find.text('chenshi22150@gmail.com'), findsOneWidget);

    await tester.runAsync(() => c.read(unlockAddonProvider.notifier).importText(UnlockAddonCodec.encodeToken(_sampleAddonJson())));
    await tester.pumpAndSettle();

    expect(find.text('测试扩展包 · v1.2.3'), findsOneWidget);
    expect(find.text('启用妙妙小工具'), findsOneWidget);
    expect(find.text('优先使用示例接口'), findsOneWidget);
    expect(find.text('测试备用接口'), findsOneWidget);
    expect(find.text('移除当前工具'), findsOneWidget);

    await tester.runAsync(() => c.read(unlockAddonProvider.notifier).remove());
    await tester.pumpAndSettle();
    expect(find.text('从文件导入'), findsOneWidget);
  });
}

final unlockServiceProviderRefProbeProvider = Provider<Ref>((ref) => ref);
