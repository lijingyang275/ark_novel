import 'dart:io';

import 'package:ark_novel/next/unlock_addon.dart';

/// 通用扩展包打包脚本：校验配置 JSON 并生成 `.arktool` 文件与 `arktool://v1/...` 剪贴板口令。
///
/// 用法：
/// `dart run tool/pack_addon.dart <config.json> [out.arktool]`
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    stdout.writeln('用法: dart run tool/pack_addon.dart <config.json> [out.arktool]');
    exit(args.isEmpty ? 64 : 0);
  }

  final inPath = args[0];
  final inFile = File(inPath);
  if (!inFile.existsSync()) {
    stderr.writeln('找不到输入文件: $inPath');
    exit(66);
  }

  final rawText = inFile.readAsStringSync();
  final UnlockAddonConfig config;
  try {
    config = UnlockAddonCodec.decodeText(rawText);
  } catch (e) {
    stderr.writeln('配置校验失败: $e');
    exit(65);
  }

  final token = UnlockAddonCodec.encodeToken(config.toJson());
  final outPath = args.length >= 2 ? args[1] : _defaultOutPath(inPath);
  File(outPath).writeAsStringSync('$token\n');

  stdout.writeln('打包成功: ${config.name} v${config.version}');
  stdout.writeln('已写入文件: $outPath');
  stdout.writeln('');
  stdout.writeln('分享口令（可直接复制发给他人）:');
  stdout.writeln(token);
}

String _defaultOutPath(String inPath) {
  if (inPath.toLowerCase().endsWith('.json')) {
    return '${inPath.substring(0, inPath.length - 5)}.arktool';
  }
  return '$inPath.arktool';
}
