import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'history.dart';
import 'image_cache.dart';
import 'routes.dart';
import 'theme.dart';
import 'volume_covers.dart';

/// 安卓桌面小组件「继续阅读」（原生部分是 android/.../ReadingWidget.kt）：最近读的 4 本封面，颜色跟着 App 的配色。
/// 小组件自己不跑 Dart，App 里数据变了就把要显示的写一份给它。
class ReadingWidget {
  ReadingWidget._();

  static const _channel = MethodChannel('ark/widget');
  static StreamController<Uri>? _clickController;
  static bool _handlerRegistered = false;

  @visibleForTesting
  static bool? supportedOverride;

  static bool get supported => supportedOverride ?? (!kIsWeb && Platform.isAndroid);

  static Future<void> push(VolumeCoverQueue covers, ImageStore images, AppPalette palette, ThemeMode mode) async {
    if (!supported) return;
    try {
      final books = [
        for (final h in ReadingHistory.latest(limit: 4))
          if (splitCrop(covers.bookCover(h.aid, h.img)) case (:final url, :final crop)) // 和书架上同一张封面，手动裁过的按裁剪框裁
            {'aid': h.aid, 'cid': h.cid, 'cover': await _coverPath(images, url), if (crop != null) 'crop': [crop.left, crop.top, crop.width, crop.height]},
      ];
      await _channel.invokeMethod<void>('saveAll', <String, String?>{
        'books': jsonEncode(books),
        'mode': switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
        'bgLight': _hex(palette.cardLight),
        'bgDark': _hex(palette.cardDark),
        'accentLight': _hex(palette.accentLight),
        'accentDark': _hex(palette.accentDark),
        'subLight': _hex(AppColors.inkSoft),
        'subDark': _hex(AppColors.paperSoft),
        'icon': palette.art == null ? null : await _icon(palette.art!),
      });
      await _channel.invokeMethod<void>('updateWidget');
    } catch (_) {} // 小组件更新失败不影响 App
  }

  /// 读取冷启动（或 Activity 重建）时由桌面小组件带入的初始链接；读取后原生侧会清空防止重复触发。
  static Future<Uri?> initialUri() async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMethod<String>('getInitialUri');
      if (raw == null || raw.isEmpty) return null;
      return Uri.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// App 在后台/前台运行期间点击桌面小组件触发的链接流。
  static Stream<Uri> get clicked {
    if (!supported) return const Stream.empty();
    _clickController ??= StreamController<Uri>.broadcast(onListen: _ensureHandler, onCancel: _clearHandler);
    return _clickController!.stream;
  }

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onWidgetClick') throw MissingPluginException();
      final raw = call.arguments as String?;
      final uri = raw == null || raw.isEmpty ? null : Uri.tryParse(raw);
      if (uri != null) _clickController?.add(uri);
    });
  }

  static void _clearHandler() {
    if (!_handlerRegistered) return;
    _handlerRegistered = false;
    _channel.setMethodCallHandler(null);
  }

  static Future<String> _coverPath(ImageStore images, String url) => url.isEmpty ? Future.value('') : images.path(url).catchError((_) => '');

  static String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

  /// 角色主题：标题前放书架导航图标那张角色图。资源在安装包里，原生那边读不到，拷一份到 App 目录
  static Future<String> _icon(String art) async {
    final f = File(p.join((await getApplicationSupportDirectory()).path, 'widget_$art.webp'));
    if (!await f.exists()) await f.writeAsBytes((await rootBundle.load('assets/theme/${art}_1.webp')).buffer.asUint8List());
    return f.path;
  }

  /// 点小组件打开的链接 → App 里的路由：ark://reader/aid/cid、ark://updates、ark://shelf
  static String? route(Uri? uri) => switch (uri) {
    Uri(scheme: 'ark', host: 'reader', pathSegments: [final aid, final cid]) => Routes.reader(aid, cid),
    Uri(scheme: 'ark', host: 'updates') => Routes.updates,
    Uri(scheme: 'ark', host: 'shelf') => Routes.bookshelf,
    _ => null,
  };
}
