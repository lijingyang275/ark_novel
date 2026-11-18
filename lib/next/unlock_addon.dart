import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';

/// 妙妙小工具运行期配置包模型、校验器与编解码器（完全站点无关，不含任何私有地址或关键字）。
class UnlockAddonConfig {
  UnlockAddonConfig({
    required this.schema,
    required this.name,
    required this.version,
    required this.description,
    required this.match,
    this.api,
    this.fullText,
  });

  static const int currentSchema = 1;

  final int schema;
  final String name;
  final String version;
  final String description;
  final UnlockMatchRule match;
  final UnlockApiRule? api;
  final UnlockFullTextRule? fullText;

  factory UnlockAddonConfig.fromJson(Map<String, dynamic> json) {
    final schema = _readInt(json['schema']);
    if (schema != currentSchema) {
      throw FormatException('不支持的配置版本：${json['schema']}（需要 schema=$currentSchema）');
    }
    final name = _readString(json['name']).trim();
    if (name.isEmpty) {
      throw const FormatException('配置缺少工具名称（name）');
    }
    final version = _readString(json['version'], fallback: '1.0.0').trim();
    final description = _readString(json['description']).trim();

    final matchMap = _readMap(json['match']);
    if (matchMap == null) {
      throw const FormatException('配置缺少触发条件（match）');
    }
    final match = UnlockMatchRule.fromJson(matchMap);

    final apiMap = _readMap(json['api']);
    final api = apiMap == null ? null : UnlockApiRule.fromJson(apiMap);

    final fullTextMap = _readMap(json['fullText']);
    final fullText = fullTextMap == null ? null : UnlockFullTextRule.fromJson(fullTextMap);

    if (api == null && fullText == null) {
      throw const FormatException('配置至少需要包含 api 或 fullText 其中一种通道');
    }

    return UnlockAddonConfig(
      schema: schema,
      name: name,
      version: version.isEmpty ? '1.0.0' : version,
      description: description,
      match: match,
      api: api,
      fullText: fullText,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'name': name,
    'version': version,
    if (description.isNotEmpty) 'description': description,
    'match': match.toJson(),
    if (api != null) 'api': api!.toJson(),
    if (fullText != null) 'fullText': fullText!.toJson(),
  };
}

class UnlockMatchRule {
  UnlockMatchRule({
    required this.requireNoImages,
    required this.maxTextLength,
    required this.equalsIgnoreCase,
    required this.containsAny,
    required this.regexPatterns,
  }) : _regexes = [for (final p in regexPatterns) _compileRegex(p, field: 'match.regexPatterns')];

  final bool requireNoImages;
  final int maxTextLength;
  final List<String> equalsIgnoreCase;
  final List<String> containsAny;
  final List<String> regexPatterns;
  final List<RegExp> _regexes;

  factory UnlockMatchRule.fromJson(Map<String, dynamic> json) {
    final equalsIgnoreCase = _readStringList(json['equalsIgnoreCase']);
    final containsAny = _readStringList(json['containsAny']);
    final regexPatterns = _readStringList(json['regexPatterns']);
    if (equalsIgnoreCase.isEmpty && containsAny.isEmpty && regexPatterns.isEmpty) {
      throw const FormatException('match 至少需要配置一项匹配条件');
    }
    return UnlockMatchRule(
      requireNoImages: _readBool(json['requireNoImages'], fallback: true),
      maxTextLength: _readInt(json['maxTextLength'], fallback: 120),
      equalsIgnoreCase: equalsIgnoreCase,
      containsAny: containsAny,
      regexPatterns: regexPatterns,
    );
  }

  bool matches(String text, List<String> images) {
    if (requireNoImages && images.isNotEmpty) return false;
    final trimmed = text.trim();
    if (maxTextLength > 0 && trimmed.length > maxTextLength) return false;
    final lower = trimmed.toLowerCase();
    for (final item in equalsIgnoreCase) {
      if (lower == item.toLowerCase()) return true;
    }
    for (final item in containsAny) {
      if (item.isNotEmpty && trimmed.contains(item)) return true;
    }
    for (final re in _regexes) {
      if (re.hasMatch(trimmed)) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
    'requireNoImages': requireNoImages,
    'maxTextLength': maxTextLength,
    if (equalsIgnoreCase.isNotEmpty) 'equalsIgnoreCase': equalsIgnoreCase,
    if (containsAny.isNotEmpty) 'containsAny': containsAny,
    if (regexPatterns.isNotEmpty) 'regexPatterns': regexPatterns,
  };
}

class UnlockApiTestRule {
  UnlockApiTestRule({
    required this.bodyTemplate,
    required this.queryTemplate,
    required this.acceptContainsAny,
  });

  final String bodyTemplate;
  final String queryTemplate;
  final List<String> acceptContainsAny;

  factory UnlockApiTestRule.fromJson(Map<String, dynamic> json) => UnlockApiTestRule(
    bodyTemplate: _readString(json['bodyTemplate']),
    queryTemplate: _readString(json['queryTemplate']),
    acceptContainsAny: _readStringList(json['acceptContainsAny']),
  );

  Map<String, dynamic> toJson() => {
    if (bodyTemplate.isNotEmpty) 'bodyTemplate': bodyTemplate,
    if (queryTemplate.isNotEmpty) 'queryTemplate': queryTemplate,
    if (acceptContainsAny.isNotEmpty) 'acceptContainsAny': acceptContainsAny,
  };
}

class UnlockApiRule {
  UnlockApiRule({
    this.label,
    this.description,
    required this.endpoints,
    required this.method,
    required this.headers,
    this.contentType,
    required this.bodyTemplate,
    this.queryTemplate,
    required this.responseCharset,
    required this.errorIfStartsWith,
    required this.errorIfContains,
    required this.shortErrorMaxLength,
    required this.shortErrorStartsWith,
    this.imagePattern,
    this.separatorPattern,
    required this.footerContainsAny,
    required this.emptyMessage,
    this.test,
  }) : imageRegex = imagePattern == null || imagePattern.isEmpty ? null : _compileRegex(imagePattern, dotAll: true, field: 'api.imagePattern'),
       separatorRegex = separatorPattern == null || separatorPattern.isEmpty ? null : _compileRegex(separatorPattern, field: 'api.separatorPattern');

  final String? label;
  final String? description;
  final List<String> endpoints;
  final String method;
  final Map<String, String> headers;
  final String? contentType;
  final String bodyTemplate;
  final String? queryTemplate;
  final String responseCharset;
  final List<String> errorIfStartsWith;
  final List<String> errorIfContains;
  final int shortErrorMaxLength;
  final List<String> shortErrorStartsWith;
  final String? imagePattern;
  final RegExp? imageRegex;
  final String? separatorPattern;
  final RegExp? separatorRegex;
  final List<String> footerContainsAny;
  final String emptyMessage;
  final UnlockApiTestRule? test;

  factory UnlockApiRule.fromJson(Map<String, dynamic> json) {
    final endpoints = _readStringList(json['endpoints']);
    if (endpoints.isEmpty) {
      throw const FormatException('api.endpoints 不能为空');
    }
    for (final ep in endpoints) {
      final uri = Uri.tryParse(ep);
      if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        throw FormatException('api.endpoints 包含无效地址：$ep');
      }
    }
    final method = _readString(json['method'], fallback: 'POST').trim().toUpperCase();
    if (method != 'POST' && method != 'GET') {
      throw FormatException('api.method 不支持：$method（仅支持 GET / POST）');
    }
    final testMap = _readMap(json['test']);
    final label = _readString(json['label']).trim();
    final description = _readString(json['description']).trim();
    final contentType = _readString(json['contentType']).trim();
    final queryTemplate = _readString(json['queryTemplate']);
    final imagePattern = _readString(json['imagePattern']);
    final separatorPattern = _readString(json['separatorPattern']);

    return UnlockApiRule(
      label: label.isEmpty ? null : label,
      description: description.isEmpty ? null : description,
      endpoints: endpoints,
      method: method,
      headers: _readStringMap(json['headers']),
      contentType: contentType.isEmpty ? null : contentType,
      bodyTemplate: _readString(json['bodyTemplate']),
      queryTemplate: queryTemplate.isEmpty ? null : queryTemplate,
      responseCharset: normalizeCharsetName(_readString(json['responseCharset'], fallback: 'utf-8')),
      errorIfStartsWith: _readStringList(json['errorIfStartsWith']),
      errorIfContains: _readStringList(json['errorIfContains']),
      shortErrorMaxLength: _readInt(json['shortErrorMaxLength'], fallback: 200),
      shortErrorStartsWith: _readStringList(json['shortErrorStartsWith']),
      imagePattern: imagePattern.isEmpty ? null : imagePattern,
      separatorPattern: separatorPattern.isEmpty ? null : separatorPattern,
      footerContainsAny: _readStringList(json['footerContainsAny']),
      emptyMessage: _readString(json['emptyMessage'], fallback: '备用接口没有返回正文内容'),
      test: testMap == null ? null : UnlockApiTestRule.fromJson(testMap),
    );
  }

  bool isFailureResponse(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return true;
    final head = trimmed.length > 600 ? trimmed.substring(0, 600) : trimmed;
    final lower = head.toLowerCase();
    for (final prefix in errorIfStartsWith) {
      if (prefix.isNotEmpty && lower.startsWith(prefix.toLowerCase())) return true;
    }
    for (final part in errorIfContains) {
      if (part.isNotEmpty && lower.contains(part.toLowerCase())) return true;
    }
    if (shortErrorMaxLength > 0 && trimmed.length <= shortErrorMaxLength) {
      for (final prefix in shortErrorStartsWith) {
        if (prefix.isNotEmpty && lower.startsWith(prefix.toLowerCase())) return true;
      }
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
    if (label != null) 'label': label,
    if (description != null) 'description': description,
    'endpoints': endpoints,
    'method': method,
    if (headers.isNotEmpty) 'headers': headers,
    if (contentType != null) 'contentType': contentType,
    if (bodyTemplate.isNotEmpty) 'bodyTemplate': bodyTemplate,
    if (queryTemplate != null) 'queryTemplate': queryTemplate,
    'responseCharset': responseCharset,
    if (errorIfStartsWith.isNotEmpty) 'errorIfStartsWith': errorIfStartsWith,
    if (errorIfContains.isNotEmpty) 'errorIfContains': errorIfContains,
    'shortErrorMaxLength': shortErrorMaxLength,
    if (shortErrorStartsWith.isNotEmpty) 'shortErrorStartsWith': shortErrorStartsWith,
    if (imagePattern != null) 'imagePattern': imagePattern,
    if (separatorPattern != null) 'separatorPattern': separatorPattern,
    if (footerContainsAny.isNotEmpty) 'footerContainsAny': footerContainsAny,
    'emptyMessage': emptyMessage,
    if (test != null) 'test': test!.toJson(),
  };
}

class UnlockFullTextRule {
  UnlockFullTextRule({
    required this.urlTemplates,
    required this.headers,
    required this.charset,
    required this.decodeEntities,
    required this.errorIfStartsWith,
    this.titlePattern,
    this.separatorPattern,
    required this.bannerContainsAny,
    required this.lockedMessage,
    required this.mismatchMessage,
  }) : titleRegex = titlePattern == null || titlePattern.isEmpty ? null : _compileRegex(titlePattern, multiLine: true, field: 'fullText.titlePattern'),
       separatorRegex = separatorPattern == null || separatorPattern.isEmpty ? null : _compileRegex(separatorPattern, field: 'fullText.separatorPattern');

  final List<String> urlTemplates;
  final Map<String, String> headers;
  final String charset;
  final bool decodeEntities;
  final List<String> errorIfStartsWith;
  final String? titlePattern;
  final RegExp? titleRegex;
  final String? separatorPattern;
  final RegExp? separatorRegex;
  final List<String> bannerContainsAny;
  final String lockedMessage;
  final String mismatchMessage;

  factory UnlockFullTextRule.fromJson(Map<String, dynamic> json) {
    final urls = _readStringList(json['urlTemplates']);
    if (urls.isEmpty) {
      throw const FormatException('fullText.urlTemplates 不能为空');
    }
    final titlePattern = _readString(json['titlePattern']);
    final separatorPattern = _readString(json['separatorPattern']);
    return UnlockFullTextRule(
      urlTemplates: urls,
      headers: _readStringMap(json['headers']),
      charset: normalizeCharsetName(_readString(json['charset'], fallback: 'utf-8')),
      decodeEntities: _readBool(json['decodeEntities'], fallback: true),
      errorIfStartsWith: _readStringList(json['errorIfStartsWith']),
      titlePattern: titlePattern.isEmpty ? null : titlePattern,
      separatorPattern: separatorPattern.isEmpty ? null : separatorPattern,
      bannerContainsAny: _readStringList(json['bannerContainsAny']),
      lockedMessage: _readString(json['lockedMessage'], fallback: '本章暂无法通过当前扩展工具获取正文。'),
      mismatchMessage: _readString(json['mismatchMessage'], fallback: '整本文本与网站目录未能匹配，取不到正文。'),
    );
  }

  Map<String, dynamic> toJson() => {
    'urlTemplates': urlTemplates,
    if (headers.isNotEmpty) 'headers': headers,
    'charset': charset,
    'decodeEntities': decodeEntities,
    if (errorIfStartsWith.isNotEmpty) 'errorIfStartsWith': errorIfStartsWith,
    if (titlePattern != null) 'titlePattern': titlePattern,
    if (separatorPattern != null) 'separatorPattern': separatorPattern,
    if (bannerContainsAny.isNotEmpty) 'bannerContainsAny': bannerContainsAny,
    'lockedMessage': lockedMessage,
    'mismatchMessage': mismatchMessage,
  };
}

/// 编解码工具：支持 `arktool://v1/<base64url(gzip(json))>` 单行口令与 `.arktool` / `.json` 文件。
class UnlockAddonCodec {
  const UnlockAddonCodec._();

  static const String tokenPrefix = 'arktool://v1/';
  static const int maxBytes = 2 * 1024 * 1024;

  static String encodeToken(Map<String, dynamic> json) {
    final config = UnlockAddonConfig.fromJson(json);
    final raw = utf8.encode(jsonEncode(config.toJson()));
    final gz = GZipEncoder().encode(raw);
    final b64 = base64UrlEncode(gz).replaceAll('=', '');
    return '$tokenPrefix$b64';
  }

  static UnlockAddonConfig decodeText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('内容为空');
    }
    if (trimmed.toLowerCase().startsWith(tokenPrefix)) {
      final body = trimmed.substring(tokenPrefix.length).replaceAll(RegExp(r'\s+'), '');
      if (body.isEmpty) {
        throw const FormatException('口令内容为空');
      }
      final padded = _padBase64(body);
      List<int> compressed;
      try {
        compressed = base64Url.decode(padded);
      } catch (_) {
        try {
          compressed = base64.decode(padded);
        } catch (_) {
          throw const FormatException('口令格式损坏（Base64 解码失败）');
        }
      }
      final List<int> plainBytes;
      try {
        plainBytes = GZipDecoder().decodeBytes(compressed);
      } catch (_) {
        throw const FormatException('口令格式损坏（解压失败）');
      }
      return _parseJsonText(utf8.decode(plainBytes));
    }
    return _parseJsonText(trimmed);
  }

  static UnlockAddonConfig decodeBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('文件为空');
    }
    if (bytes.length > maxBytes) {
      throw const FormatException('文件过大（超过 2 MB）');
    }
    if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      final List<int> plainBytes;
      try {
        plainBytes = GZipDecoder().decodeBytes(bytes);
      } catch (_) {
        throw const FormatException('文件解压失败');
      }
      return decodeText(utf8.decode(plainBytes));
    }
    return decodeText(utf8.decode(bytes));
  }

  static UnlockAddonConfig _parseJsonText(String text) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const FormatException('无法识别的格式（需要合法的 JSON 或 arktool:// 口令）');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('配置根节点必须是 JSON 对象');
    }
    return UnlockAddonConfig.fromJson(decoded);
  }

  static String _padBase64(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + ('=' * (4 - mod));
  }
}

/// 模板渲染：先替换 `{{key}}` 变量，再处理 `{{base64(...)}}` / `{{base64url(...)}}` / `{{url(...)}}` 转换。
String renderAddonTemplate(String template, Map<String, String> vars) {
  if (template.isEmpty) return '';
  final aid = vars['aid'] ?? '';
  final aidNum = int.tryParse(aid);
  final now = DateTime.now();
  final resolved = <String, String>{
    'timestamp_ms': '${now.millisecondsSinceEpoch}',
    'timestamp_s': '${now.millisecondsSinceEpoch ~/ 1000}',
    if (aidNum != null) 'aid_div_1000': '${aidNum ~/ 1000}',
    ...vars,
  };

  var out = template.replaceAllMapped(RegExp(r'\{\{([a-zA-Z0-9_]+)\}\}'), (m) => resolved[m[1]!] ?? m[0]!);
  out = out.replaceAllMapped(RegExp(r'\{\{(base64|base64url|url)\((.*?)\)\}\}', dotAll: true), (m) {
    final fn = m[1]!;
    final arg = m[2]!;
    return switch (fn) {
      'base64' => base64Encode(utf8.encode(arg)),
      'base64url' => base64UrlEncode(utf8.encode(arg)).replaceAll('=', ''),
      'url' => Uri.encodeComponent(arg),
      _ => m[0]!,
    };
  });
  return out;
}

String normalizeCharsetName(String raw) {
  final lower = raw.trim().toLowerCase();
  return switch (lower) {
    'gbk' || 'gb2312' || 'gb18030' => 'gbk',
    'big5' || 'big5-hkscs' => 'big5',
    _ => 'utf-8',
  };
}

String decodeBytesWithCharset(Uint8List bytes, String charset) => switch (normalizeCharsetName(charset)) {
  'gbk' => const GbkCodec(allowInvalid: true).decode(bytes),
  'big5' => const Big5Codec(allowInvalid: true).decode(bytes),
  _ => utf8.decode(bytes, allowMalformed: true),
};

RegExp _compileRegex(String pattern, {bool dotAll = false, bool multiLine = false, required String field}) {
  try {
    return RegExp(pattern, dotAll: dotAll, multiLine: multiLine);
  } on FormatException catch (e) {
    throw FormatException('$field 正则语法有误（$pattern）：${e.message}');
  }
}

Map<String, dynamic>? _readMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
  return null;
}

String _readString(Object? raw, {String fallback = ''}) => raw is String ? raw : fallback;

int _readInt(Object? raw, {int fallback = 0}) => raw is int ? raw : (raw is num ? raw.toInt() : fallback);

bool _readBool(Object? raw, {bool fallback = false}) => raw is bool ? raw : fallback;

List<String> _readStringList(Object? raw) {
  if (raw is! List) return const [];
  return [for (final item in raw) if (item is String && item.isNotEmpty) item];
}

Map<String, String> _readStringMap(Object? raw) {
  final map = _readMap(raw);
  if (map == null) return const {};
  return {for (final entry in map.entries) if (entry.value != null) entry.key: '${entry.value}'};
}
