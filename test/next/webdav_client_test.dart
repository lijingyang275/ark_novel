import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ark_novel/next/sync.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

class _RecordedReq {
  _RecordedReq(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Uint8List body;
}

class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.handler);

  final Future<ResponseBody> Function(_RecordedReq req) handler;
  final requests = <_RecordedReq>[];
  var closed = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        chunks.addAll(chunk);
      }
    }
    final req = _RecordedReq(options.method, options.uri, Map<String, dynamic>.from(options.headers), Uint8List.fromList(chunks));
    requests.add(req);
    return handler(req);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

ResponseBody _resp(int status, {String body = '', List<int>? bytes, String contentType = 'text/plain; charset=utf-8'}) => ResponseBody.fromBytes(
  bytes ?? utf8.encode(body),
  status,
  headers: {Headers.contentTypeHeader: [contentType]},
);

void main() {
  late Directory tmp;
  late Box box;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('ark_webdav_client_test');
    Hive.init(tmp.path);
    box = await Hive.openBox('session');
  });

  setUp(() => box.clear());

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Dio mockDio(_MockAdapter adapter) => Dio(BaseOptions(validateStatus: (s) => s != null && s < 500))..httpClientAdapter = adapter;

  test('WebDavClient.ensureDirectory 404 时逐级 MKCOL 创建嵌套目录，且不关闭外部注入 Dio', () async {
    final created = <String>{};
    final adapter = _MockAdapter((req) async {
      final path = req.uri.path;
      if (req.method == 'PROPFIND') {
        return created.contains(path) ? _resp(207) : _resp(404);
      }
      if (req.method == 'MKCOL') {
        created.add(path);
        return _resp(201);
      }
      return _resp(405);
    });
    final dio = mockDio(adapter);
    final client = WebDavClient(baseUrl: 'https://dav.example.com/dav', folder: 'ArkNovel/Sub', user: 'u', password: 'p', dio: dio);
    await client.ensureDirectory();
    client.close();

    expect(created, {'/dav/ArkNovel/', '/dav/ArkNovel/Sub/'});
    expect(adapter.closed, isFalse); // 外部注入 Dio 不被 client.close 关闭
  });

  test('WebDavClient HTTP 错误抛出结构化 SyncException 并携带 statusCode', () async {
    for (final (code, snippet) in const [
      (401, '用户名或应用密码不对'),
      (403, 'HTTP 403'),
      (404, 'HTTP 404'),
      (409, 'HTTP 409'),
    ]) {
      final adapter = _MockAdapter((_) async => _resp(code));
      final client = WebDavClient(baseUrl: 'https://dav.example.com/dav/', folder: 'ArkNovel', user: 'u', password: 'p', dio: mockDio(adapter));
      await expectLater(
        () => client.listJsonFiles(),
        throwsA(isA<SyncException>().having((e) => e.statusCode, 'statusCode', code).having((e) => e.message, 'message', contains(snippet))),
      );
    }
  });

  test('Sync.run 注入 mock Dio：单次复用同一 Dio 完成目录校验、合并有效快照、跳过损坏与过期快照并上传本机', () async {
    await box.putAll({
      'sync:url': 'https://dav.example.com/dav/',
      'sync:user': 'alice',
      'sync:folder': 'ArkNovel',
      'sync:device': 'dLocal',
      'progress:1': ['c1', 10, 1000],
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    final staleAt = now - const Duration(days: 120).inMilliseconds;
    final files = <String, Uint8List>{
      'dOther.json': Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 3,
        'device': 'dOther',
        'at': now,
        'progress': {'1': ['c2', 55, 2000], '2': ['c9', 3, 1500]},
        'history': [],
        'bookmarks': [],
        'read': {},
        'readchars': {},
        'rating': {},
        'rules': [],
        'notes': {},
        'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
      }))),
      'dStale.json': Uint8List.fromList(utf8.encode(jsonEncode({'v': 3, 'device': 'dStale', 'at': staleAt}))),
      'dBroken.json': Uint8List.fromList(utf8.encode('{not-valid-json')),
    };

    final adapter = _MockAdapter((req) async {
      final name = Uri.decodeComponent(req.uri.pathSegments.where((s) => s.isNotEmpty).last);
      if (req.method == 'PROPFIND') {
        if (req.headers['Depth'] == '0') return _resp(207);
        final xml = [
          '<d:multistatus>',
          for (final f in files.keys) '<d:response><d:href>/dav/ArkNovel/$f</d:href></d:response>',
          '</d:multistatus>',
        ].join();
        return _resp(207, body: xml, contentType: 'application/xml');
      }
      if (req.method == 'GET') {
        final data = files[name];
        return data == null ? _resp(404) : _resp(200, bytes: data);
      }
      if (req.method == 'PUT') {
        files[name] = req.body;
        return _resp(201);
      }
      return _resp(405);
    });
    final dio = mockDio(adapter);

    // 有一个损坏文件 dBroken.json：合并完 dOther.json 并上传 dLocal.json 后抛 SyncException 提示跳过的损坏文件
    await expectLater(
      () => Sync.run(dio: dio),
      throwsA(isA<SyncException>().having((e) => e.message, 'message', allOf(contains('已合并 1 台设备'), contains('dBroken.json')))),
    );
    expect(adapter.closed, isFalse);
    // 直接 PROPFIND Depth: 1 省去 Depth: 0 的 1 次 RTT
    expect(adapter.requests.where((r) => r.method == 'PROPFIND' && r.headers['Depth'] == '0').length, 0);
    expect(adapter.requests.where((r) => r.method == 'PROPFIND' && r.headers['Depth'] == '1').length, 1);
    expect(Sync.lastSkipped, ['dStale.json']);
    expect(box.get('progress:1'), ['c2', 55, 2000]);
    expect(box.get('progress:2'), ['c9', 3, 1500]);
    expect(files.containsKey('dLocal.json'), isTrue);
    final uploaded = jsonDecode(utf8.decode(files['dLocal.json']!)) as Map<String, dynamic>;
    expect((uploaded['progress'] as Map)['2'], ['c9', 3, 1500]);
  });

  test('Sync.run 注入 mock Dio 支持推送本机头像与拉取远端更新头像', () async {
    final avatarFile = File(p.join(tmp.path, 'local_avatar.png'))..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
    final now = DateTime.now().millisecondsSinceEpoch;
    await box.putAll({
      'sync:url': 'https://dav.example.com/dav/',
      'sync:user': 'alice',
      'sync:folder': 'ArkNovel',
      'sync:device': 'dLocal',
      'avatar': avatarFile.path,
      'avatar:ts': now - 5000,
    });
    final remoteAvatarBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 9, 8, 7, 6]);
    final files = <String, Uint8List>{
      'dRemote.json': Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 3,
        'device': 'dRemote',
        'at': now,
        'avatar': {'ts': now, 'ext': '.png', 'file': 'dRemote.avatar'},
        'progress': {},
        'history': [],
        'bookmarks': [],
        'read': {},
        'readchars': {},
        'rating': {},
        'rules': [],
        'notes': {},
        'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
      }))),
      'dRemote.avatar': remoteAvatarBytes,
    };

    final adapter = _MockAdapter((req) async {
      final name = Uri.decodeComponent(req.uri.pathSegments.where((s) => s.isNotEmpty).last);
      if (req.method == 'PROPFIND') {
        if (req.headers['Depth'] == '0') return _resp(207);
        final xml = '<d:multistatus><d:response><d:href>/dav/ArkNovel/dRemote.json</d:href></d:response></d:multistatus>';
        return _resp(207, body: xml, contentType: 'application/xml');
      }
      if (req.method == 'GET') {
        final data = files[name];
        return data == null ? _resp(404) : _resp(200, bytes: data);
      }
      if (req.method == 'PUT') {
        files[name] = req.body;
        return _resp(201);
      }
      return _resp(405);
    });

    final merged = await Sync.run(dio: mockDio(adapter));
    expect(merged, 1);
    expect(box.get('avatar:ts'), now);
    expect(box.get('sync:avatarFile'), 'dRemote.avatar');
    final savedAvatarPath = box.get('avatar') as String;
    expect(File(savedAvatarPath).readAsBytesSync(), remoteAvatarBytes);
    // 已拉取对方最新头像并记为 sync:avatarUp == now，不重复上传本机旧头像
    expect(files.containsKey('dLocal.avatar'), isFalse);
  });

  test('WebDavClient 解析 ETag/LastModified/ContentLength、复用外部 adapter 不关闭，且 Sync 按 ETag 跳过未变化文件与冗余 PUT', () async {
    await box.putAll({
      'sync:url': 'https://dav.example.com/dav/',
      'sync:user': 'alice',
      'sync:folder': 'ArkNovel',
      'sync:device': 'dLocal',
      'progress:1': ['c1', 10, 1000],
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    var etag = '"v1"';
    final files = <String, Uint8List>{
      'dOther.json': Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 3,
        'device': 'dOther',
        'at': now,
        'progress': {'2': ['c2', 20, 2000]},
        'history': [],
        'bookmarks': [],
        'read': {},
        'readchars': {},
        'rating': {},
        'rules': [],
        'notes': {},
        'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
      }))),
    };

    final adapter = _MockAdapter((req) async {
      final name = Uri.decodeComponent(req.uri.pathSegments.where((s) => s.isNotEmpty).last);
      if (req.method == 'PROPFIND') {
        final xml = [
          '<d:multistatus xmlns:d="DAV:">',
          for (final entry in files.entries)
            '<d:response><d:href>/dav/ArkNovel/${entry.key}</d:href><d:propstat><d:prop>'
                '<d:getetag>${entry.key == 'dOther.json' ? etag : '"own"'}</d:getetag>'
                '<d:getlastmodified>Thu, 26 Nov 2026 00:00:00 GMT</d:getlastmodified>'
                '<d:getcontentlength>${entry.value.length}</d:getcontentlength>'
                '</d:prop></d:propstat></d:response>',
          '</d:multistatus>',
        ].join();
        return _resp(207, body: xml, contentType: 'application/xml');
      }
      if (req.method == 'GET') {
        final data = files[name];
        return data == null ? _resp(404) : _resp(200, bytes: data);
      }
      if (req.method == 'PUT') {
        files[name] = req.body;
        return _resp(201);
      }
      return _resp(405);
    });

    // 通过 adapter 参数注入（非 dio）：WebDavClient.close 不得关闭外部共享适配器
    expect(await Sync.run(adapter: adapter), 1);
    expect(adapter.closed, isFalse);
    expect(box.get('progress:2'), ['c2', 20, 2000]);
    expect(adapter.requests.where((r) => r.method == 'GET' && r.uri.path.endsWith('dOther.json')).length, 1);
    expect(adapter.requests.where((r) => r.method == 'PUT').length, 1);

    // ETag 未变 + 本机内容未变 + skipUnchangedUpload: true（自动同步模式）：跳过 dOther.json 的 GET 和本机的冗余 PUT
    adapter.requests.clear();
    expect(await Sync.run(adapter: adapter, skipUnchangedUpload: true), 0);
    expect(adapter.requests.where((r) => r.method == 'GET').length, 0);
    expect(adapter.requests.where((r) => r.method == 'PUT').length, 0);

    // 远端 ETag 变化后立即重新 GET 并合并
    etag = '"v2"';
    files['dOther.json'] = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 3,
      'device': 'dOther',
      'at': now + 1000,
      'progress': {'3': ['c3', 30, 3000]},
      'history': [],
      'bookmarks': [],
      'read': {},
      'readchars': {},
      'rating': {},
      'rules': [],
      'notes': {},
      'stats': {'day': {}, 'book': {}, 'chapters': 0, 'meta': {}, 'days': {}},
    })));
    adapter.requests.clear();
    expect(await Sync.run(adapter: adapter, skipUnchangedUpload: true), 1);
    expect(adapter.requests.where((r) => r.method == 'GET' && r.uri.path.endsWith('dOther.json')).length, 1);
    expect(box.get('progress:3'), ['c3', 30, 3000]);
    // 合并后本机快照内容发生变化，应正常 PUT
    expect(adapter.requests.where((r) => r.method == 'PUT').length, 1);

    // 本机 ETag 缓存绝不污染 session 或 Sync.snapshot()
    expect(box.keys.whereType<String>().any((k) => k.contains('etag')), isFalse);
    expect(Sync.snapshot().containsKey('etags'), isFalse);
  });
}
