import 'package:flutter/foundation.dart';

/// 网页预览版访问 wenku8 要经过服务器上的转发程序（tool/preview_proxy.dart），
/// 因为浏览器不允许网页直接读取别的网站。默认认为它和网页在同一台机器的 8091 端口，
/// 也可以用 `--dart-define=WENKU8_PROXY=http://host:port` 指定。
const String _proxyOverride = String.fromEnvironment('WENKU8_PROXY');

bool get isWebPreview => kIsWeb;

/// 桌面端（Mac / Windows / Linux）：侧栏、密度、默认值这些按桌面习惯来；测试里默认是安卓，不受影响。
bool get isDesktop => !kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);

/// 深色时默认用纯黑：手机 OLED 省电；电脑屏幕上纯黑太刺眼，默认用深灰。
bool get pureBlackDefault => !isDesktop;

String get previewProxyBase {
  if (_proxyOverride.isNotEmpty) return _proxyOverride;
  final s = Uri.base.replace(port: 8091, path: '', query: null, fragment: null).toString();
  return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

/// 网页版里图片也要经过转发程序，否则会被浏览器的跨域限制挡住。
String displayImageUrl(String url) => isWebPreview && url.isNotEmpty ? '$previewProxyBase/__image?url=${Uri.encodeQueryComponent(url)}' : url;
