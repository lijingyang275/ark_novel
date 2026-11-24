import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:home_widget/home_widget.dart';
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

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> push(VolumeCoverQueue covers, ImageStore images, AppPalette palette, ThemeMode mode) async {
    if (!supported) return;
    try {
      final books = [
        for (final h in ReadingHistory.all().take(4))
          if (splitCrop(covers.bookCover(h.aid, h.img)) case (:final url, :final crop)) // 和书架上同一张封面，手动裁过的按裁剪框裁
            {'aid': h.aid, 'cid': h.cid, 'cover': await _coverPath(images, url), if (crop != null) 'crop': [crop.left, crop.top, crop.width, crop.height]},
      ];
      await Future.wait([
        HomeWidget.saveWidgetData('books', jsonEncode(books)),
        HomeWidget.saveWidgetData('mode', switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', ThemeMode.system => 'system' }),
        HomeWidget.saveWidgetData('bgLight', _hex(palette.cardLight)),
        HomeWidget.saveWidgetData('bgDark', _hex(palette.cardDark)),
        HomeWidget.saveWidgetData('accentLight', _hex(palette.accentLight)),
        HomeWidget.saveWidgetData('accentDark', _hex(palette.accentDark)),
        HomeWidget.saveWidgetData('subLight', _hex(AppColors.inkSoft)),
        HomeWidget.saveWidgetData('subDark', _hex(AppColors.paperSoft)),
        HomeWidget.saveWidgetData('icon', palette.art == null ? null : await _icon(palette.art!)),
      ]);
      await HomeWidget.updateWidget(qualifiedAndroidName: 'io.github.chenshi221.ark_novel.ReadingWidget');
    } catch (_) {} // 小组件更新失败不影响 App
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
    Uri(host: 'reader', pathSegments: [final aid, final cid]) => Routes.reader(aid, cid),
    Uri(host: 'updates') => Routes.updates,
    Uri(host: 'shelf') => Routes.bookshelf,
    _ => null,
  };
}
