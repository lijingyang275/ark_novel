import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 阅读器内置纸张纹理选项：0 无纹理、1 宣纸细纹、2 复古纸微噪点、3 淡雅笔记纸。
const kReaderBgTextures = <int, String>{
  0: '无纹理',
  1: '宣纸',
  2: '复古纸',
  3: '笔记纸',
};

/// 自定义阅读背景图存储键与备份子目录名。
const kReaderBgPathKey = 'reader_bg:path';
const kReaderBgDir = 'reader_bg';

/// 自定义阅读背景图片管理器：将选中的本地图片复制到 `ApplicationSupport/reader_bg/` 目录，随完整备份打包恢复。
class ReaderBgImageController extends Notifier<String?> {
  @override
  String? build() {
    final raw = Hive.box('session').get(kReaderBgPathKey) as String?;
    return raw == null || raw.isEmpty ? null : raw;
  }

  /// 弹出系统图片选择器并复制到 `ApplicationSupport/reader_bg/`；用户取消返回 false。
  Future<bool> pick() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    final src = file?.path;
    if (src == null || src.isEmpty) return false;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, kReaderBgDir));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final ext = p.extension(src);
    final dest = await File(src).copy(p.join(dir.path, 'bg_${DateTime.now().millisecondsSinceEpoch}${ext.isEmpty ? '.jpg' : ext}'));
    await Hive.box('session').put(kReaderBgPathKey, dest.path);
    state = dest.path;
    return true;
  }

  /// 清除自定义背景图并删掉本地副本，避免残留进后续备份。
  Future<void> clear() async {
    await Hive.box('session').delete(kReaderBgPathKey);
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, kReaderBgDir));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    state = null;
  }
}

final readerBgImageProvider = NotifierProvider<ReaderBgImageController, String?>(ReaderBgImageController.new);

/// 阅读器背景层：按主题底色 → 自定义背景图（带透明度与可读性柔和遮罩）→ 程序化纸张纹理叠放。
/// 包裹在 [RepaintBoundary] 内避免翻页、滚动或菜单动画反复重绘纹理。
class ReaderBackground extends StatelessWidget {
  const ReaderBackground({
    super.key,
    required this.baseColor,
    required this.fgColor,
    this.texture = 0,
    this.imagePath,
    this.imageOpacity = 0.35,
  });

  final Color baseColor;
  final Color fgColor;

  /// 0 无纹理、1 宣纸细纹、2 羊皮纸/牛皮纸微噪点、3 淡雅横线/方格笔记本纹
  final int texture;
  final String? imagePath;

  /// 自定义背景图浓度 0.05 ~ 0.85
  final double imageOpacity;

  bool get hasCustomLayer => texture != 0 || (imagePath != null && imagePath!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final hasImage = !kIsWeb && imagePath != null && imagePath!.isNotEmpty;
    if (!hasImage && texture == 0) return ColoredBox(color: baseColor);

    final isDark = ThemeData.estimateBrightnessForColor(baseColor) == Brightness.dark;
    final clampedOpacity = imageOpacity.clamp(0.05, 0.85);
    // 盖一层与当前主题底色同向的柔和遮罩，即使透明度拉到最高也确保正文清晰护眼
    final veilAlpha = isDark ? 0.22 : 0.14;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: baseColor),
          if (hasImage) ...[
            Opacity(
              opacity: clampedOpacity,
              child: Image.file(
                File(imagePath!),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            ColoredBox(color: baseColor.withValues(alpha: veilAlpha)),
          ],
          if (texture >= 1 && texture <= 3)
            CustomPaint(
              painter: _PaperTexturePainter(texture: texture, baseColor: baseColor, fgColor: fgColor, isDark: isDark),
            ),
        ],
      ),
    );
  }
}

class _PaperTexturePainter extends CustomPainter {
  const _PaperTexturePainter({
    required this.texture,
    required this.baseColor,
    required this.fgColor,
    required this.isDark,
  });

  final int texture;
  final Color baseColor;
  final Color fgColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    switch (texture) {
      case 1:
        _paintRicePaper(canvas, size);
      case 2:
        _paintParchment(canvas, size);
      case 3:
        _paintNotebook(canvas, size);
    }
  }

  /// 宣纸细纹：大半径径向柔光云纹（边缘完全透明，无任何硬边色块）+ 纤细自然的纸浆纤维。
  void _paintRicePaper(Canvas canvas, Size size) {
    final rng = math.Random(1024);
    final minSide = math.min(size.width, size.height);
    for (var i = 0; i < 10; i++) {
      final cx = rng.nextDouble() * size.width;
      final cy = rng.nextDouble() * size.height;
      final radius = minSide * (0.28 + rng.nextDouble() * 0.36);
      final bright = i.isEven;
      final color = bright ? Colors.white : fgColor;
      final peak = bright ? (isDark ? 0.018 : 0.06) : (isDark ? 0.025 : 0.016);
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);
      final wash = Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: peak), color.withValues(alpha: peak * 0.35), Colors.transparent],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);
      canvas.drawRect(rect, wash);
    }

    final fiberPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final count = ((size.width * size.height) / 3600).round().clamp(80, 240);
    for (var i = 0; i < count; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final len = 8 + rng.nextDouble() * 26;
      final angle = (rng.nextDouble() - 0.5) * 0.65 + (i % 5 == 0 ? math.pi / 2 : 0);
      final dx = math.cos(angle) * len;
      final dy = math.sin(angle) * len;
      fiberPaint
        ..strokeWidth = 0.45 + rng.nextDouble() * 0.55
        ..color = (i % 3 == 0 ? Colors.white : fgColor).withValues(alpha: i % 3 == 0 ? (isDark ? 0.028 : 0.075) : (isDark ? 0.04 : 0.026));
      final ctrl = Offset(x + dx * 0.5 + (rng.nextDouble() - 0.5) * 3.5, y + dy * 0.5 + (rng.nextDouble() - 0.5) * 3.5);
      final path = Path()
        ..moveTo(x, y)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, x + dx, y + dy);
      canvas.drawPath(path, fiberPaint);
    }
  }

  /// 羊皮纸/牛皮纸微噪点：温和边缘复古晕影 + 细腻随机颗粒微点。
  void _paintParchment(Canvas canvas, Size size) {
    final warmTint = isDark ? const Color(0xFF9B7B54) : const Color(0xFF7B5B35);
    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.92,
        colors: [Colors.transparent, warmTint.withValues(alpha: isDark ? 0.05 : 0.075)],
        stops: const [0.55, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);

    final rng = math.Random(2048);
    final speckPaint = Paint()..style = PaintingStyle.fill;
    final dots = ((size.width * size.height) / 1400).round().clamp(180, 520);
    for (var i = 0; i < dots; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final r = 0.45 + rng.nextDouble() * 1.1;
      final light = i % 4 == 0;
      speckPaint.color = (light ? Colors.white : warmTint).withValues(alpha: light ? (isDark ? 0.025 : 0.07) : (isDark ? 0.06 : 0.055));
      canvas.drawCircle(Offset(x, y), r, speckPaint);
    }
  }

  /// 淡雅横线 / 方格笔记本纹：柔和细线网格 + 极淡左侧装订参考线。
  void _paintNotebook(Canvas canvas, Size size) {
    const step = 28.0;
    final hPaint = Paint()
      ..color = fgColor.withValues(alpha: isDark ? 0.065 : 0.055)
      ..strokeWidth = 0.7;
    final vPaint = Paint()
      ..color = fgColor.withValues(alpha: isDark ? 0.032 : 0.028)
      ..strokeWidth = 0.5;

    for (var y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), hPaint);
    }
    for (var x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), vPaint);
    }

    // 淡雅竖向装订线：单页竖屏偏左一格，双页宽屏不额外加左红线以免左右页不对称
    if (size.width < 720) {
      final marginX = math.min(24.0, size.width * 0.06);
      final marginPaint = Paint()
        ..color = (isDark ? const Color(0xFFD98A7C) : const Color(0xFFC25E4E)).withValues(alpha: isDark ? 0.10 : 0.08)
        ..strokeWidth = 0.85;
      canvas.drawLine(Offset(marginX, 0), Offset(marginX, size.height), marginPaint);
    }
  }

  @override
  bool shouldRepaint(_PaperTexturePainter old) => old.texture != texture || old.baseColor != baseColor || old.fgColor != fgColor || old.isDark != isDark;
}
