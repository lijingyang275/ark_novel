import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'net_stub.dart' if (dart.library.io) 'net_io.dart';

/// 结构化同步异常：替代直接 `throw '字符串'`，便于调用方按类型与状态码区分处理。
class SyncException implements Exception {
  const SyncException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}

/// 拆分并校验 WebDAV 同步子目录路径段（不允许 `..` 目录穿越）。
List<String> splitWebDavFolder(String folder) {
  final segs = folder.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty && s != '.').toList();
  if (segs.any((s) => s == '..')) throw const FormatException('同步文件夹名称不能包含 ..');
  return segs.isEmpty ? const ['ArkNovel'] : segs;
}

String _decodeHref(String s) {
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s;
  }
}

/// 目录里所有 `*.json` 的文件名（从 WebDAV PROPFIND XML 响应里提取 href）。
List<String> parseWebDavListing(String xml) => [
  for (final m in RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>', caseSensitive: false).allMatches(xml))
    if (_decodeHref(m.group(1)!) case final href when href.endsWith('.json') && !href.endsWith('/')) href.split('/').last,
];

/// 按本地 [SessionStore] 保存的代理与系统网络栈配置构建适配器，让 WebDAV 同步同样走用户配置的代理/原生网络栈。
HttpClientAdapter? webDavAdapterFromSessionBox() {
  if (kIsWeb || !Hive.isBoxOpen('session')) return null;
  final box = Hive.box('session');
  final proxy = (box.get('proxy') as String?) ?? '';
  final nativeNet = (box.get('nativeNet') as bool?) ?? true;
  HttpClientAdapter io() => IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..findProxy = (_) => proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy',
  );
  if (!nativeNet || proxy.isNotEmpty) return io();
  try {
    return nativeAdapter(io) ?? io();
  } catch (_) {
    // 单元测试（无原生 cupertino/cronet FFI 动态库）或受限环境自动回落到 Dart IO 适配器
    return io();
  }
}

/// 可注入 [Dio] 的轻量 WebDAV 客户端（GET / PUT / PROPFIND / MKCOL）。
/// 单次同步复用同一个 [Dio] 实例完成目录校验、列表、下载与上传，测试时可直接注入 mock [Dio]。
class WebDavClient {
  WebDavClient({
    required this.baseUrl,
    required this.folder,
    required this.user,
    required this.password,
    Dio? dio,
    HttpClientAdapter? adapter,
  }) : _ownsDio = dio == null,
       _dio = dio ?? _createDio(user, password, adapter: adapter ?? webDavAdapterFromSessionBox());

  final String baseUrl;
  final String folder;
  final String user;
  final String password;
  final Dio _dio;
  final bool _ownsDio;

  static Dio _createDio(String user, String password, {HttpClientAdapter? adapter}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    if (adapter != null) dio.httpClientAdapter = adapter;
    return dio;
  }

  String get normalizedBase => baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';

  List<String> get folderSegments => splitWebDavFolder(folder);

  String get dirUrl => '$normalizedBase${folderSegments.map(Uri.encodeComponent).join('/')}/';

  static void ensureOk(Response<dynamic> r, String what) {
    final code = r.statusCode ?? 0;
    if (code == 401) throw SyncException('$what：用户名或应用密码不对（坚果云要用"第三方应用密码"，不是登录密码）', statusCode: 401);
    if (code == 403) throw SyncException('$what被拒绝（HTTP 403），请检查账号权限或应用密码权限', statusCode: 403);
    if (code == 404) throw SyncException('$what失败：同步地址不存在（HTTP 404），请检查 WebDAV 根地址是否正确', statusCode: 404);
    if (code == 409) throw SyncException('$what失败：上级目录不存在或路径冲突（HTTP 409）', statusCode: 409);
    if (code >= 400) throw SyncException('$what失败（HTTP $code）', statusCode: code);
  }

  /// 测试连接并确保目标同步目录存在：目录不存在时逐级 `MKCOL` 创建。
  Future<void> ensureDirectory() async {
    final r = await _dio.request<dynamic>(dirUrl, options: Options(method: 'PROPFIND', headers: {'Depth': '0'}));
    if (r.statusCode == 404) {
      var cur = normalizedBase;
      for (final seg in folderSegments) {
        cur = '$cur${Uri.encodeComponent(seg)}/';
        final check = await _dio.request<dynamic>(cur, options: Options(method: 'PROPFIND', headers: {'Depth': '0'}));
        if (check.statusCode == 404) {
          ensureOk(await _dio.request<dynamic>(cur, options: Options(method: 'MKCOL')), '创建同步文件夹');
        } else {
          ensureOk(check, '连接');
        }
      }
    } else {
      ensureOk(r, '连接');
    }
  }

  /// 列出同步目录中的所有 `*.json` 文件名。
  Future<List<String>> listJsonFiles() async {
    final r = await _dio.request<String>(dirUrl, options: Options(method: 'PROPFIND', headers: {'Depth': '1'}, responseType: ResponseType.plain));
    ensureOk(r, '读取目录');
    return parseWebDavListing(r.data ?? '');
  }

  /// 读取纯文本文件；[allowNotFound] 为 true 时 HTTP 404 返回 null。
  Future<String?> getText(String fileName, {required String what, bool allowNotFound = false}) async {
    final r = await _dio.get<String>('$dirUrl${Uri.encodeComponent(fileName)}', options: Options(responseType: ResponseType.plain));
    if (allowNotFound && r.statusCode == 404) return null;
    ensureOk(r, what);
    return r.data ?? '';
  }

  /// 上传 JSON 文本文件。
  Future<void> putJson(String fileName, String body, {String what = '上传'}) async {
    final r = await _dio.put<dynamic>(
      '$dirUrl${Uri.encodeComponent(fileName)}',
      data: body,
      options: Options(contentType: 'application/json; charset=utf-8'),
    );
    ensureOk(r, what);
  }

  /// 下载二进制文件（如头像）。
  Future<List<int>> getBytes(String fileName, {String what = '下载'}) async {
    final r = await _dio.get<List<int>>('$dirUrl${Uri.encodeComponent(fileName)}', options: Options(responseType: ResponseType.bytes));
    ensureOk(r, what);
    return r.data ?? const [];
  }

  /// 上传二进制文件（如头像）。
  Future<void> putBytes(String fileName, Uint8List bytes, {String what = '上传'}) async {
    final r = await _dio.put<dynamic>(
      '$dirUrl${Uri.encodeComponent(fileName)}',
      data: Stream.fromIterable([bytes]),
      options: Options(contentType: 'application/octet-stream', headers: {Headers.contentLengthHeader: bytes.length}),
    );
    ensureOk(r, what);
  }

  /// 关闭内部自建的 [Dio]；由外部注入的 [Dio] 不在此处关闭。
  void close() {
    if (_ownsDio) _dio.close();
  }
}
