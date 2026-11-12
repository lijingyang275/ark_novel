import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, debugPrint;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'cache.dart';
import 'fonts.dart';
import 'session.dart';
import 'settings.dart';
import 'text.dart';

/// App 入口（lib/main.dart 只是转到这里）。
///
/// - 原生：`flutter run -t lib/next/main.dart`
/// - 网页预览：`flutter run -d web-server -t lib/next/main.dart`，并在同一台机器上运行 `tool/preview_proxy.dart`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  // 解码好的封面多留一些（默认 100 MB），滑回去不用重新解码
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;
  final SessionStore store;
  try {
    store = await SessionStore.open();
    // 字体在后台加载，不挡着第一帧（阅读页用自选字体时会等它，见 FontStore.ready）
    FontStore.loadSaved().ignore();
    await ChapterCache.open();
  } catch (e, st) {
    // 本地数据库打不开（文件损坏、磁盘满）：以前只会停在启动图，现在把原因显示出来
    debugPrint('启动失败：$e\n$st');
    runApp(StartupErrorApp(error: e));
    return;
  }
  applyOrientation(OrientationController.saved);
  // 不用 Riverpod 默认的自动重试：失败的请求自己重复十次只会加快被 Cloudflare 限流
  runApp(ProviderScope(retry: (_, _) => null, overrides: [sessionStoreProvider.overrideWithValue(store)], child: const NextApp()));
}

/// 启动失败时显示的页面：说明原因，原文可以选中复制给开发者。
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ark Novel 启动失败', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text('本地数据打不开。可以先关掉 App 重新打开试试；还不行的话，把下面的信息发给开发者。'),
              const SizedBox(height: 16),
              Expanded(child: SingleChildScrollView(child: SelectableText('$error', style: const TextStyle(fontSize: 13)))),
            ],
          ),
        ),
      ),
    ),
  );
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
