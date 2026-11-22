import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'image_cache.dart';

/// 从封面像素（RGBA）算阅读报告的背景色，像豆瓣那样：取整体色调，压低饱和度、调暗，白字看得清。
/// 饱和的像素权重大一些，免得大片白底把颜色冲淡成灰。
Color tintFrom(Uint8List rgba) {
  var r = 0.0, g = 0.0, b = 0.0, w = 0.0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final pr = rgba[i] / 255, pg = rgba[i + 1] / 255, pb = rgba[i + 2] / 255;
    final weight = 0.15 + (math.max(pr, math.max(pg, pb)) - math.min(pr, math.min(pg, pb)));
    r += pr * weight;
    g += pg * weight;
    b += pb * weight;
    w += weight;
  }
  if (w == 0) return const Color(0xFF4A4A4A);
  final hsl = HSLColor.fromColor(Color.fromARGB(255, (r / w * 255).round(), (g / w * 255).round(), (b / w * 255).round()));
  return hsl.withSaturation(hsl.saturation.clamp(0.12, 0.35)).withLightness(0.38).toColor();
}

/// 封面背景色，按地址存在本机，算过一次就不再解码。
/// 从 [w]×[h] 的 RGBA 像素里取出 [crop]（0~1 比例）那一块
Uint8List cropRgba(Uint8List rgba, int w, int h, Rect crop) {
  final x0 = (crop.left * w).floor().clamp(0, w - 1), y0 = (crop.top * h).floor().clamp(0, h - 1);
  final x1 = (crop.right * w).ceil().clamp(x0 + 1, w), y1 = (crop.bottom * h).ceil().clamp(y0 + 1, h);
  return Uint8List.fromList([for (var y = y0; y < y1; y++) ...rgba.sublist((y * w + x0) * 4, (y * w + x1) * 4)]);
}

/// 封面颜色还没算出来时的背景
const kNeutralCoverColor = Color(0xFF3A3A3E);

/// 算过的封面颜色（同步读，没算过为 null）
Color? savedCoverColor(String url) {
  final v = (Hive.box('session').get('ccolor') as Map?)?[url] as int?;
  return v == null ? null : Color(v);
}

// autoDispose：书架、报告页没在显示的封面不常驻内存（算过的颜色存在本地，再用时 [savedCoverColor] 直接给）
final coverColorProvider = FutureProvider.autoDispose.family<Color, String>((ref, url) async {
  final box = Hive.box('session');
  final saved = savedCoverColor(url);
  if (saved != null) return saved;
  final crop = splitCrop(url).crop;
  final bytes = await ref.read(imageStoreProvider).load(url);
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: crop == null ? 24 : 64);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final (w, h) = (image.width, image.height);
  image.dispose();
  codec.dispose();
  final rgba = data!.buffer.asUint8List();
  final color = tintFrom(crop == null ? rgba : cropRgba(rgba, w, h, crop));
  final prev = Map<String, Object?>.from((box.get('ccolor') as Map?) ?? const {});
  prev.remove(url);
  while (prev.length >= 400) {
    prev.remove(prev.keys.first);
  }
  prev[url] = color.toARGB32();
  await box.put('ccolor', prev);
  return color;
});
