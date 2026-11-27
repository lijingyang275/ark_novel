import 'dart:collection';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;

/// 内存环形脱敏诊断日志：最多保留最近 200 条记录，严格剔除 Cookie、密码、令牌和本机用户名路径，
/// 供启动失败页与同步诊断面板复制反馈问题。
class DiagLog {
  DiagLog._();

  static const maxEntries = 200;
  static final _entries = Queue<String>();

  static List<String> get entries => List<String>.unmodifiable(_entries);

  static void clear() => _entries.clear();

  static void info(String tag, String message) {
    _append('I', tag, sanitizeDiagnosticText(message));
  }

  static void record(String source, Object error, [StackTrace? st]) {
    final detail = st == null ? '$error' : '$error\n${_trimStack(st)}';
    _append('E', source, sanitizeDiagnosticText(detail));
  }

  static void _append(String level, String tag, String body) {
    final now = DateTime.now().toIso8601String();
    _entries.addLast('[$now] [$level/$tag] $body');
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  static String _trimStack(StackTrace st) {
    final lines = st.toString().trimRight().split('\n');
    return lines.take(8).join('\n');
  }

  /// 导出可安全分享的脱敏诊断文本。
  static String dump({Object? extraError, Map<String, Object?>? meta}) {
    final buf = StringBuffer()
      ..writeln('Ark Novel Diagnostic Report')
      ..writeln('Platform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}')
      ..writeln('Time: ${DateTime.now().toIso8601String()}');
    if (meta != null && meta.isNotEmpty) {
      for (final e in meta.entries) {
        buf.writeln('${e.key}: ${sanitizeDiagnosticText('${e.value ?? ''}')}');
      }
    }
    if (extraError != null) {
      buf
        ..writeln('')
        ..writeln('Error:')
        ..writeln(sanitizeDiagnosticText('$extraError'));
    }
    if (_entries.isNotEmpty) {
      buf
        ..writeln('')
        ..writeln('Recent Logs (${_entries.length}):');
      for (final line in _entries) {
        buf.writeln(line);
      }
    }
    return buf.toString().trimRight();
  }
}

final _reUrlCreds = RegExp(r'(https?://)([^/\s:@]+):([^/\s@]+)@', caseSensitive: false);
final _reAuthHeader = RegExp(r'(authorization\s*[:=]\s*)(?:basic|bearer)\s+[^\s,;]+', caseSensitive: false);
final _reCookiePair = RegExp(r'\b(jieqiUserInfo|jieqiVisitInfo|cf_clearance|PHPSESSID|cookie|savedPass|sync:pass|password|passwd|token)\s*[:=]\s*[^\s;,&"]+', caseSensitive: false);
final _reMacHome = RegExp(r'/Users/[^/\s]+');
final _reLinuxHome = RegExp(r'/home/[^/\s]+');
final _reWinHome = RegExp(r'[A-Za-z]:\\Users\\[^\\\s]+');

/// 对诊断文本执行严格脱敏，确保不会泄露文库 Cookie、WebDAV 密码、鉴权头或本机用户名。
String sanitizeDiagnosticText(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAllMapped(_reUrlCreds, (m) => '${m[1]}***:***@')
      .replaceAllMapped(_reAuthHeader, (m) => '${m[1]}[REDACTED]')
      .replaceAllMapped(_reCookiePair, (m) => '${m[1]}=[REDACTED]')
      .replaceAll(_reMacHome, '/Users/<redacted>')
      .replaceAll(_reLinuxHome, '/home/<redacted>')
      .replaceAll(_reWinHome, r'<drive>:\Users\<redacted>');
}
