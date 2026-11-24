import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../common/image_url_helper.dart';
import '../data/wenku8/wenku8_parser.dart';
import '../models/cat_volume.dart';
import '../models/content.dart';
import 'app_prefs.dart';
import 'cache.dart';
import 'history.dart';
import 'incognito.dart';
import 'library.dart';
import 'session.dart';
import 'unlock_addon.dart';

export 'unlock_addon.dart' show UnlockAddonCodec, UnlockAddonConfig;

/// 受限章节无法读取时抛出的异常（如未导入扩展包，或插图章节在整本文本中无正文）。[message] 直接展示给读者。
class ChapterLockedException implements Exception {
  const ChapterLockedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地扩展配置存储：读自 `Hive.box('session')`，并与配置内容同步缓存，避免每次判重都重复反序列化。
class UnlockAddonStore {
  const UnlockAddonStore._();

  static const String storageKey = 'unlock:addon';

  static String? _lastRaw;
  static UnlockAddonConfig? _lastConfig;

  static UnlockAddonConfig? get current {
    if (!Hive.isBoxOpen('session')) return null;
    final raw = Hive.box('session').get(storageKey);
    if (raw is! String || raw.isEmpty) {
      _lastRaw = null;
      _lastConfig = null;
      return null;
    }
    if (identical(raw, _lastRaw) || raw == _lastRaw) return _lastConfig;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final config = UnlockAddonConfig.fromJson(map);
      _lastRaw = raw;
      _lastConfig = config;
      return config;
    } catch (_) {
      _lastRaw = raw;
      _lastConfig = null;
      return null;
    }
  }

  static Future<void> save(UnlockAddonConfig config) async {
    final raw = jsonEncode(config.toJson());
    await Hive.box('session').put(storageKey, raw);
    _lastRaw = raw;
    _lastConfig = config;
  }

  static Future<void> clear() async {
    if (Hive.isBoxOpen('session')) {
      await Hive.box('session').delete(storageKey);
    }
    _lastRaw = null;
    _lastConfig = null;
  }
}

class UnlockAddonNotifier extends Notifier<UnlockAddonConfig?> {
  @override
  UnlockAddonConfig? build() => UnlockAddonStore.current;

  Future<UnlockAddonConfig> importText(String raw) async {
    final config = UnlockAddonCodec.decodeText(raw);
    await UnlockAddonStore.save(config);
    state = config;
    return config;
  }

  Future<UnlockAddonConfig> importBytes(Uint8List bytes) async {
    final config = UnlockAddonCodec.decodeBytes(bytes);
    await UnlockAddonStore.save(config);
    state = config;
    return config;
  }

  Future<void> remove() async {
    await UnlockAddonStore.clear();
    state = null;
  }
}

final unlockAddonProvider = NotifierProvider<UnlockAddonNotifier, UnlockAddonConfig?>(UnlockAddonNotifier.new);

bool get hasUnlockAddon => UnlockAddonStore.current != null;

bool isLockedContent(Content c) => UnlockAddonStore.current?.match.matches(c.text, c.images) ?? false;

/// 通用运行期扩展执行引擎：根据已导入的 [UnlockAddonConfig]，依次尝试备用 HTTP 接口与整本文本拆章缓存。
class UnlockService {
  UnlockService(this._ref, {this.apiDioBuilder, this.txtDioBuilder});

  final Ref _ref;
  final Dio Function()? apiDioBuilder;
  final Dio Function()? txtDioBuilder;
  final _importing = <String, Future<void>>{};
  Dio? _apiDio;
  Dio? _txtDio;

  static Box get _box => Hive.box('session');

  bool get enabled => hasUnlockAddon && AppPrefs.read(P.unlock, true);

  bool get apiEnabled => AppPrefs.read(P.unlockApi, true);

  Dio _getApiDio() => _apiDio ??= _createApiDio();

  Dio _getTxtDio() => _txtDio ??= _createTxtDio();

  void dispose() {
    _apiDio?.close();
    _apiDio = null;
    _txtDio?.close();
    _txtDio = null;
  }

  Dio _createApiDio() {
    if (apiDioBuilder != null) return apiDioBuilder!();
    final store = _ref.read(sessionStoreProvider);
    return Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 30)))
      ..httpClientAdapter = store.adapter();
  }

  Dio _createTxtDio() {
    if (txtDioBuilder != null) return txtDioBuilder!();
    final store = _ref.read(sessionStoreProvider);
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.stream,
        // 拆短建连/收响应头超时（总计 30s），避免黑洞节点卡死 135s；正文流下载超时在流读取阶段单独控制
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 18),
        headers: {'Accept': '*/*'},
      ),
    )..httpClientAdapter = store.adapter();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers.putIfAbsent('User-Agent', () => store.userAgent);
          handler.next(options);
        },
      ),
    );
    return dio;
  }

  Future<Content> chapter(String aid, String cid, Future<List<CatVolume>> Function() catalogue) async {
    final addon = UnlockAddonStore.current;
    if (addon == null) {
      throw const ChapterLockedException('尚未导入妙妙小工具扩展包。');
    }

    if (addon.api != null && apiEnabled) {
      try {
        return await _fetchFromApi(addon.api!, aid, cid);
      } catch (e) {
        if (addon.fullText == null) {
          if (e is ChapterLockedException) rethrow;
          throw ChapterLockedException('$e');
        }
      }
    }

    final fullText = addon.fullText;
    if (fullText == null) {
      throw const ChapterLockedException('当前扩展包未配置可用的正文通道。');
    }

    Future<Content?> cached() async {
      final c = await ChapterCache.get(aid, cid);
      if (c == null) return null;
      return addon.match.matches(c.text, c.images) ? null : c;
    }

    final done = await cached();
    if (done != null) return done;

    final seen = _box.get('unlock:txt:$aid') as Map?;
    final had = (seen?['m'] as List?)?.contains(cid) ?? false;
    final known = (seen?['a'] as List?)?.contains(cid) ?? false;
    final lastTs = (seen?['ts'] as int?) ?? 0;
    final stale = DateTime.now().millisecondsSinceEpoch - lastTs > const Duration(minutes: 30).inMilliseconds;
    if (had || !known || stale) {
      await (_importing[aid] ??= _importFullText(fullText, aid, catalogue).whenComplete(() {
        _importing.remove(aid);
      }));
      final c = await cached();
      if (c != null) return c;
    }
    throw ChapterLockedException(fullText.lockedMessage);
  }

  Future<Content> _fetchFromApi(UnlockApiRule rule, String aid, String cid) async {
    final vars = {'aid': aid, 'cid': cid};
    final raw = await _requestApi(
      rule,
      body: renderAddonTemplate(rule.bodyTemplate, vars),
      query: rule.queryTemplate == null ? null : renderAddonTemplate(rule.queryTemplate!, vars),
      accept: (value) => value.trim().isNotEmpty,
    );
    return parseApiChapter(rule, raw);
  }

  Future<String> _requestApi(
    UnlockApiRule rule, {
    required String body,
    String? query,
    bool Function(String text)? accept,
  }) async {
    final dio = _getApiDio();
    final failures = <String>[];
    for (final endpoint in rule.endpoints) {
      try {
        final targetUrl = query == null || query.isEmpty ? endpoint : (endpoint.contains('?') ? '$endpoint&$query' : '$endpoint?$query');
        final options = Options(
          responseType: ResponseType.bytes,
          contentType: rule.contentType,
          headers: {'Accept': '*/*', ...rule.headers},
        );
        final Response<dynamic> response;
        if (rule.method == 'GET') {
          response = await dio.get<dynamic>(targetUrl, options: options);
        } else {
          response = await dio.post<dynamic>(targetUrl, data: body.isEmpty ? null : body, options: options);
        }
        final text = _decodeResponseText(response.data, rule.responseCharset);
        if (rule.isFailureResponse(text)) {
          failures.add('$endpoint: 返回了错误页');
          continue;
        }
        if (accept != null && !accept(text)) {
          failures.add('$endpoint: 返回内容格式不对');
          continue;
        }
        return text;
      } on DioException catch (e) {
        failures.add('$endpoint: ${_describeDioException(e)}');
      } catch (e) {
        failures.add('$endpoint: $e');
      }
    }
    throw ChapterLockedException('备用接口不可用（${failures.length} 个端点都失败了）：${failures.join('；')}');
  }

  Future<String> testApi() async {
    final api = UnlockAddonStore.current?.api;
    if (api == null) return '当前扩展包未配置备用接口。';
    final testRule = api.test;
    final vars = {'aid': '1', 'cid': '1'};
    final body = renderAddonTemplate((testRule != null && testRule.bodyTemplate.isNotEmpty) ? testRule.bodyTemplate : api.bodyTemplate, vars);
    final querySource = (testRule != null && testRule.queryTemplate.isNotEmpty) ? testRule.queryTemplate : (api.queryTemplate ?? '');
    final query = querySource.isEmpty ? null : renderAddonTemplate(querySource, vars);
    final accepts = testRule?.acceptContainsAny ?? const [];

    final dio = _getApiDio();
    final results = <String>[];
    var ok = false;
    for (final endpoint in api.endpoints) {
      final host = Uri.tryParse(endpoint)?.host ?? endpoint;
      try {
        final targetUrl = query == null || query.isEmpty ? endpoint : (endpoint.contains('?') ? '$endpoint&$query' : '$endpoint?$query');
        final options = Options(
          responseType: ResponseType.bytes,
          contentType: api.contentType,
          headers: {'Accept': '*/*', ...api.headers},
        );
        final response = api.method == 'GET'
            ? await dio.get<dynamic>(targetUrl, options: options)
            : await dio.post<dynamic>(targetUrl, data: body.isEmpty ? null : body, options: options);
        final text = _decodeResponseText(response.data, api.responseCharset);
        if (api.isFailureResponse(text)) {
          results.add('$host：返回了错误页');
          continue;
        }
        if (accepts.isNotEmpty) {
          final lower = text.toLowerCase();
          if (!accepts.any((item) => lower.contains(item.toLowerCase()))) {
            results.add('$host：返回内容格式不对');
            continue;
          }
        }
        ok = true;
        results.add('$host：可用');
      } on DioException catch (e) {
        results.add('$host：${_describeDioException(e)}');
      } catch (e) {
        results.add('$host：$e');
      }
    }
    return '${ok ? '接口测试成功' : '接口测试失败'}（${results.join('；')}）';
  }

  Future<void> _importFullText(UnlockFullTextRule rule, String aid, Future<List<CatVolume>> Function() catalogue) async {
    final cat = await catalogue();
    final all = [for (final v in cat) ...v.chapters];
    final tickets = {for (final c in all) c.cid: ChapterCache.ticket(aid, c.cid)};
    final bookTicket = ChapterCache.ticket(aid, '').$1;
    final bytes = await _fetchFullTextBytes(rule, aid);
    final (texts, title) = await compute(_splitFullTextTask, (
      bytes: bytes,
      catalogue: cat,
      charset: rule.charset,
      decodeEntities: rule.decodeEntities,
      titlePattern: rule.titlePattern,
      separatorPattern: rule.separatorPattern,
      bannerContainsAny: rule.bannerContainsAny,
    ));
    if (texts.isEmpty) {
      throw ChapterLockedException(rule.mismatchMessage);
    }
    if (ChapterCache.ticket(aid, '').$1 != bookTicket) return;
    final matchRule = UnlockAddonStore.current?.match;
    for (final MapEntry(key: cid, value: text) in texts.entries) {
      final ticket = tickets[cid] ?? ChapterCache.ticket(aid, cid);
      final old = await ChapterCache.get(aid, cid);
      final oldLocked = old != null && (matchRule?.matches(old.text, old.images) ?? false);
      if (old == null || oldLocked) {
        await ChapterCache.put(aid, cid, Content(text: text, images: const []), ticket: ticket);
      }
    }
    // 仅当用户已经手动开启过该书的离线缓存（meta 已存在）时才刷新 meta；单章在线试读不把整本书塞进「离线缓存」列表，也不阻止自动清理
    if (!Incognito.on && ChapterCache.offline(aid) && all.isNotEmpty) {
      final book = LibraryStore.get(aid);
      final seen = ReadingHistory.all().where((e) => e.aid == aid).firstOrNull;
      final name = (book?['title'] as String?) ?? seen?.title ?? title ?? aid;
      final img = [book?['img'] as String?, seen?.img].whereType<String>().where((e) => e.isNotEmpty).firstOrNull ?? Wenku8Parser.coverUrl(aid);
      await ChapterCache.setMeta(aid, name, all.length, img, all.first.cid);
    }
    await _box.put('unlock:txt:$aid', {'m': texts.keys.toList(), 'a': [for (final c in all) c.cid], 'ts': DateTime.now().millisecondsSinceEpoch});
  }

  Future<Uint8List> _fetchFullTextBytes(UnlockFullTextRule rule, String aid) async {
    final dio = _getTxtDio();
    Object? lastError;
    for (var i = 0; i < rule.urlTemplates.length; i++) {
      final url = renderAddonTemplate(rule.urlTemplates[i], {'aid': aid, 'node': '${i + 1}'});
      try {
        final response = await dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: rule.headers.isEmpty ? null : rule.headers,
          ),
        );
        final body = response.data;
        if (body == null) {
          lastError = ChapterLockedException('节点 ${i + 1} 返回空内容');
          continue;
        }
        final builder = BytesBuilder(copy: false);
        await body.stream.timeout(const Duration(seconds: 30)).forEach(builder.add).timeout(const Duration(seconds: 120));
        final data = builder.takeBytes();
        if (data.isEmpty) {
          lastError = ChapterLockedException('节点 ${i + 1} 返回空内容');
          continue;
        }
        final head = String.fromCharCodes(data.take(128)).trimLeft().toLowerCase();
        if (rule.errorIfStartsWith.any((p) => p.isNotEmpty && head.startsWith(p.toLowerCase()))) {
          lastError = ChapterLockedException('节点 ${i + 1} 返回了错误页');
          continue;
        }
        return data;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const ChapterLockedException('整本文本下载失败');
  }

  static Content parseApiChapter(UnlockApiRule rule, String rawText) {
    final images = <String>[];
    final withoutImages = rule.imageRegex == null
        ? rawText
        : rawText.replaceAllMapped(rule.imageRegex!, (match) {
            final src = match.groupCount >= 1 ? (match.group(1) ?? '') : (match.group(0) ?? '');
            final url = ImageUrlHelper.normalize(src);
            if (url.isNotEmpty) images.add(url);
            return '';
          });

    final paragraphs = <String>[];
    for (final line in withoutImages.split(RegExp(r'\r\n|\r|\n'))) {
      final value = line.trim();
      if (value.isEmpty) continue;
      if (rule.separatorRegex != null && rule.separatorRegex!.hasMatch(value)) continue;
      paragraphs.add(value);
    }

    while (paragraphs.isNotEmpty && _matchesAnyLower(paragraphs.last, rule.footerContainsAny)) {
      paragraphs.removeLast();
    }

    final body = paragraphs.join('\n');
    if (body.isEmpty && images.isEmpty) {
      throw ChapterLockedException(rule.emptyMessage);
    }
    return Content(text: body, images: images);
  }
}

typedef _SplitArgs = ({
  Uint8List bytes,
  List<CatVolume> catalogue,
  String charset,
  bool decodeEntities,
  String? titlePattern,
  String? separatorPattern,
  List<String> bannerContainsAny,
});

(Map<String, String>, String?) _splitFullTextTask(_SplitArgs args) => splitFullTextByCatalogue(
  args.bytes,
  args.catalogue,
  charset: args.charset,
  decodeEntities: args.decodeEntities,
  titlePattern: args.titlePattern,
  separatorPattern: args.separatorPattern,
  bannerContainsAny: args.bannerContainsAny,
);

/// 通用整本文本解码并按目录拆章：供后台 isolate 与单测复用。
(Map<String, String>, String?) splitFullTextByCatalogue(
  Uint8List bytes,
  List<CatVolume> catalogue, {
  String charset = 'utf-8',
  bool decodeEntities = true,
  String? titlePattern,
  String? separatorPattern,
  List<String> bannerContainsAny = const [],
}) {
  var text = decodeBytesWithCharset(bytes, charset);
  if (decodeEntities) text = decodeNumericEntities(text);

  final heads = <String, List<String>>{};
  for (final v in catalogue) {
    for (final c in v.chapters) {
      (heads[_normalizeHeadingKey('${v.title} ${c.title}')] ??= []).add(c.cid);
    }
  }

  final sepRegex = separatorPattern == null || separatorPattern.isEmpty ? null : RegExp(separatorPattern);
  final texts = <String, String>{};
  final paragraphs = <String>[];
  String? cid;
  void flush() {
    if (cid != null && paragraphs.isNotEmpty) texts[cid] = paragraphs.join('\n');
    paragraphs.clear();
  }

  for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (line == line.trimLeft()) {
      final hits = heads[_normalizeHeadingKey(t)];
      if (hits != null && hits.isNotEmpty) {
        flush();
        cid = hits.length > 1 ? hits.removeAt(0) : hits.first;
        continue;
      }
      if (_matchesAnyLower(t, bannerContainsAny)) continue;
    }
    if (cid == null) continue;
    if (sepRegex != null && sepRegex.hasMatch(t)) continue;
    paragraphs.add(t);
  }
  flush();

  String? title;
  if (titlePattern != null && titlePattern.isNotEmpty) {
    final m = RegExp(titlePattern, multiLine: true).firstMatch(text);
    if (m != null && m.groupCount >= 1) title = m.group(1)?.trim();
  }
  return (texts, title);
}

final _numericEntityPattern = RegExp(r'&#([xX][0-9a-fA-F]+|\d+);');

String decodeNumericEntities(String s) => s.replaceAllMapped(_numericEntityPattern, (m) {
  final v = m[1]!;
  final code = (v.startsWith('x') || v.startsWith('X')) ? int.tryParse(v.substring(1), radix: 16) : int.tryParse(v);
  return code == null || code < 0 || code > 0x10FFFF ? m[0]! : String.fromCharCode(code);
});

String _normalizeHeadingKey(String s) => decodeNumericEntities(s)
    .replaceAllMapped(RegExp('[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '');

bool _matchesAnyLower(String line, List<String> needles) {
  if (needles.isEmpty) return false;
  final lower = line.toLowerCase();
  return needles.any((n) => n.isNotEmpty && lower.contains(n.toLowerCase()));
}

String _decodeResponseText(dynamic data, String charset) {
  final List<int> bytes;
  if (data is List<int>) {
    bytes = data;
  } else if (data is String) {
    bytes = utf8.encode(data);
  } else {
    bytes = data == null ? const [] : utf8.encode('$data');
  }
  final uint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final text = decodeBytesWithCharset(uint8, charset);
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

String _describeDioException(DioException error) {
  final status = error.response?.statusCode;
  if (status != null) return 'HTTP $status';
  return switch (error.type) {
    DioExceptionType.connectionTimeout => '连接超时',
    DioExceptionType.sendTimeout => '发送超时',
    DioExceptionType.receiveTimeout => '接收超时',
    DioExceptionType.transformTimeout => '处理超时',
    DioExceptionType.badCertificate => '证书错误',
    DioExceptionType.badResponse => '响应异常',
    DioExceptionType.cancel => '请求已取消',
    DioExceptionType.connectionError => '网络连接失败',
    _ => '网络错误',
  };
}

final unlockServiceProvider = Provider<UnlockService>((ref) {
  try {
    ref.watch(proxyProvider);
    ref.watch(nativeNetProvider);
  } catch (e) {
    // 部分纯单测未覆盖 sessionStoreProvider，跳过代理监听以便照常构造服务对象
    if (e is! UnimplementedError && !e.toString().contains('UnimplementedError')) rethrow;
  }
  final service = UnlockService(ref);
  ref.onDispose(service.dispose);
  return service;
});
