import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, PlatformDispatcher, TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'cache.dart';
import 'diag_log.dart';
import 'fonts.dart';
import 'meta_cache.dart';
import 'session.dart';
import 'settings.dart';
import 'text.dart';

/// App 入口（lib/main.dart 只是转到这里）。
///
/// - 原生：`flutter run -t lib/next/main.dart`
/// - 网页预览：`flutter run -d web-server -t lib/next/main.dart`，并在同一台机器上运行 `tool/preview_proxy.dart`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHooks();
  registerFontLicenses();
  configureAppImageCache();
  await _bootstrap();
}

int _compactImageCacheDepth = 0;

/// 配置全局解码纹理缓存上限；Impeller（Metal/Vulkan）下每 1 MB 纹理连同 Mipmap 与堆对齐实际占约 1.6~1.8 MB 显存，
/// 需严格收紧上限，避免多标签浏览后累积上百 MB 图形内存。
void configureAppImageCache({bool compact = false}) {
  final mobile = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  final cache = PaintingBinding.instance.imageCache;
  if (compact) {
    cache.maximumSize = mobile ? 32 : 40;
    cache.maximumSizeBytes = (mobile ? 12 : 16) << 20;
  } else {
    cache.maximumSize = mobile ? 90 : 120;
    cache.maximumSizeBytes = (mobile ? 28 : 40) << 20;
  }
}

/// 清理所有已无可见控件监听的非活跃解码纹理（正在当前屏幕挂载的 `_liveImages` 不受影响）。
void evictInactiveImageCache() {
  PaintingBinding.instance.imageCache.clear();
}

/// 进入低水位图片缓存模式（支持阅读页与退后台引用计数叠加）。
void enterCompactImageCache() {
  if (++_compactImageCacheDepth == 1) {
    configureAppImageCache(compact: true);
    evictInactiveImageCache();
  }
}

/// 退出低水位图片缓存模式；全部紧凑场景退出后恢复常规上限。
void exitCompactImageCache() {
  if (_compactImageCacheDepth > 0 && --_compactImageCacheDepth == 0) {
    configureAppImageCache(compact: false);
  }
}

void _installErrorHooks() {
  final prevFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    DiagLog.record('flutter', details.exception, details.stack);
    prevFlutter?.call(details);
  };
  final prevPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    DiagLog.record('platform', error, stack);
    return prevPlatform?.call(error, stack) ?? false;
  };
}

Future<void> _bootstrap() async {
  final SessionStore store;
  try {
    // SessionStore.open(openMetaCache: false) 严格在所有 Hive.openBox 之前执行 Backup.apply，并打开核心 session Box；
    // 随后并发初始化可再生缓存与离线章节索引，缩短冷启动磁盘 I/O 等待。
    store = await SessionStore.open(openMetaCache: false);
    // 字体在后台按需加载（仅 r.font == 2 时读盘，见 FontStore.loadSaved）
    FontStore.loadSaved().ignore();
    await Future.wait<Object?>([MetaCache.open(), ChapterCache.open()]);
  } catch (e, st) {
    // 本地数据库打不开（文件损坏、磁盘满）：以前只会停在启动图，现在把原因显示出来并提供安全自愈
    debugPrint('启动失败：$e\n$st');
    DiagLog.record('bootstrap', e, st);
    runApp(StartupErrorApp(error: e, onRetry: _bootstrap, onClearCachesAndRetry: _clearRecoverableCachesAndRetry));
    return;
  }
  applyOrientation(OrientationController.saved);
  // 不用 Riverpod 默认的自动重试：失败的请求自己重复十次只会加快被 Cloudflare 限流
  runApp(ProviderScope(retry: (_, _) => null, overrides: [sessionStoreProvider.overrideWithValue(store)], child: const NextApp()));
}

/// 仅清理可再生缓存（元数据缓存、章节/网页缓存、卡住的恢复临时目录），绝不触碰用户 `session` 核心数据。
Future<void> _clearRecoverableCachesAndRetry() async {
  try {
    await Hive.close();
  } catch (_) {}
  for (final name in const [MetaCache.boxName, 'chapters', 'chapter_index', 'pages']) {
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {}
  }
  if (!kIsWeb) {
    try {
      final pending = Directory(p.join((await getApplicationSupportDirectory()).path, 'restore_pending'));
      if (await pending.exists()) await pending.delete(recursive: true);
    } catch (_) {}
  }
  await _bootstrap();
}

/// 启动失败时显示的页面：说明脱敏后的原因，提供复制诊断报告、清理可再生缓存自愈与重试入口。
class StartupErrorApp extends StatefulWidget {
  const StartupErrorApp({super.key, required this.error, this.onRetry, this.onClearCachesAndRetry});

  final Object error;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onClearCachesAndRetry;

  @override
  State<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<StartupErrorApp> {
  bool _busy = false;
  String? _status;

  Future<void> _runAction(Future<void> Function() action, String label) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _status = sanitizeDiagnosticText('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = DiagLog.dump(extraError: widget.error);
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Ark Novel 启动失败', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                const Text('本地数据打不开。可先尝试「重试启动」或「清理可再生缓存并重试」（不会删除书架、进度、书签与登录信息）；若仍失败，可复制脱敏诊断报告反馈给开发者。'),
                if (_status != null) ...[
                  const SizedBox(height: 10),
                  Text(_status!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (widget.onRetry != null)
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _runAction(widget.onRetry!, '正在重试启动'),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试启动'),
                      ),
                    if (widget.onClearCachesAndRetry != null)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _runAction(widget.onClearCachesAndRetry!, '正在清理可再生缓存'),
                        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                        label: const Text('清理缓存并重试'),
                      ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (mounted) setState(() => _status = '已复制脱敏诊断报告');
                      },
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('复制诊断报告'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0x14000000),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SingleChildScrollView(child: SelectableText(report, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 内置字体（SIL OFL 1.1）的许可文本：加进「关于 → 开源许可」，和各个依赖包的许可列在一起。
/// OFL 要求随字体一起分发许可文本，文件在 assets/licenses/。
void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in const [('霞鹜文楷 Lite（LXGW WenKai Lite）', 'LXGWWenKaiLite-OFL.txt'), ('思源宋体（Noto Serif SC）', 'NotoSerifSC-OFL.txt')]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString('assets/licenses/$file'));
    }
    yield LicenseEntryWithLineBreaks(['OpenCC 简繁词表'], await rootBundle.loadString('assets/licenses/OpenCC-Apache-2.0.txt'));
  });
}
