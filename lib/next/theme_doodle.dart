import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'theme.dart';
import 'text.dart';

/// 角色主题（杏菜 / 知花 / 天爱星）的蜡笔涂鸦美术：插画来自 assets/theme/`art`_*.webp，
/// 装饰线和小图案用代码画成抖动、重描的蜡笔笔触。普通配色下这些都返回 null / 不出现。
class CharacterArt extends ThemeExtension<CharacterArt> {
  const CharacterArt(this.art, this.secondary, this.accentLight, this.accentDark);

  /// 图片前缀：anna / chika / amane
  final String art;
  final Color secondary;

  /// 发色：阅读器按正文背景深浅挑一个给章节标题用
  final Color accentLight, accentDark;

  static CharacterArt? of(BuildContext context) => Theme.of(context).extension<CharacterArt>();

  /// 空状态、出错、读完一卷用的插画
  String get empty => 'assets/theme/${art}_empty.webp';
  String get error => 'assets/theme/${art}_error.webp';
  String get cheer => 'assets/theme/${art}_cheer.webp';
  String get banner => 'assets/theme/${art}_banner.webp';

  /// 每个角色的小图案：杏菜·汽水是气泡，知花·草莓牛奶是草莓，天爱星·薄荷会长是薄荷叶
  Motif get motif => switch (art) {
    'chika' => Motif.strawberry,
    'amane' => Motif.mint,
    _ => Motif.bubbles,
  };

  @override
  CharacterArt copyWith() => this;

  @override
  CharacterArt lerp(CharacterArt? other, double t) => t < 0.5 || other == null ? this : other;
}

enum Motif { bubbles, strawberry, mint }

/// 草莓蒂和薄荷叶用固定的绿色，不跟主题色走
const _leafGreen = Color(0xFF4FA36B);

/// 蜡笔笔触：同一条路径错开一点描三遍，透明度递减，看起来像油画棒压出来的颗粒边
void crayon(Canvas canvas, Path path, Color color, double width, {int seed = 0}) {
  final rnd = math.Random(seed);
  for (var i = 0; i < 3; i++) {
    final dx = (rnd.nextDouble() - 0.5) * width * 0.6, dy = (rnd.nextDouble() - 0.5) * width * 0.6;
    canvas.drawPath(
      path.shift(Offset(dx, dy)),
      Paint()
        ..color = color.withValues(alpha: color.a * (i == 0 ? 0.9 : 0.45))
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * (i == 0 ? 1 : 0.7)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }
}

/// 一条手抖的波浪线
Path wobbleLine(Offset from, double length, {double amp = 1.6, int seed = 0}) {
  final rnd = math.Random(seed);
  final p = Path()..moveTo(from.dx, from.dy);
  const step = 7.0;
  for (var x = step; x <= length; x += step) {
    p.quadraticBezierTo(from.dx + x - step / 2, from.dy + (rnd.nextDouble() - 0.5) * amp * 2, from.dx + x, from.dy + (rnd.nextDouble() - 0.5) * amp);
  }
  return p;
}

/// 在 [c] 处画一个 [motif]，大小约 [s]
void drawMotif(Canvas canvas, Motif motif, Offset c, double s, Color main, Color accent, {int seed = 0}) {
  final w = math.max(1.2, s * 0.12);
  switch (motif) {
    case Motif.bubbles:
      for (final (dx, dy, r) in [(0.0, 0.0, 0.42), (0.5, -0.45, 0.24), (0.1, -0.85, 0.14)]) {
        final o = c + Offset(dx * s, dy * s);
        crayon(canvas, Path()..addOval(Rect.fromCircle(center: o, radius: r * s)), main, w, seed: seed++);
        canvas.drawCircle(o + Offset(-r * s * 0.35, -r * s * 0.35), r * s * 0.18, Paint()..color = accent.withValues(alpha: 0.8));
      }
    case Motif.strawberry:
      final body = Path()
        ..moveTo(c.dx - s * 0.42, c.dy - s * 0.18)
        ..quadraticBezierTo(c.dx - s * 0.45, c.dy + s * 0.25, c.dx, c.dy + s * 0.5)
        ..quadraticBezierTo(c.dx + s * 0.45, c.dy + s * 0.25, c.dx + s * 0.42, c.dy - s * 0.18)
        ..quadraticBezierTo(c.dx, c.dy - s * 0.38, c.dx - s * 0.42, c.dy - s * 0.18);
      canvas.drawPath(body, Paint()..color = main.withValues(alpha: 0.55));
      crayon(canvas, body, main, w, seed: seed);
      for (final (dx, dy) in [(-0.18, 0.0), (0.16, 0.02), (0.0, 0.22), (-0.05, -0.12)]) {
        canvas.drawCircle(c + Offset(dx * s, dy * s), s * 0.035, Paint()..color = Colors.white.withValues(alpha: 0.9));
      }
      final leaf = Path()
        ..moveTo(c.dx - s * 0.3, c.dy - s * 0.26)
        ..lineTo(c.dx, c.dy - s * 0.42)
        ..lineTo(c.dx + s * 0.3, c.dy - s * 0.26)
        ..moveTo(c.dx, c.dy - s * 0.42)
        ..lineTo(c.dx + s * 0.06, c.dy - s * 0.58);
      crayon(canvas, leaf, _leafGreen, w, seed: seed + 1);
    case Motif.mint:
      for (final (ang, len) in [(-0.6, 0.55), (0.5, 0.45)]) {
        final tip = c + Offset(math.sin(ang) * len * s, -math.cos(ang) * len * s);
        final n = Offset(math.cos(ang), math.sin(ang)) * s * 0.18;
        final mid = Offset.lerp(c, tip, 0.5)!;
        final leaf = Path()
          ..moveTo(c.dx, c.dy)
          ..quadraticBezierTo(mid.dx + n.dx, mid.dy + n.dy, tip.dx, tip.dy)
          ..quadraticBezierTo(mid.dx - n.dx, mid.dy - n.dy, c.dx, c.dy);
        final green = _leafGreen.withValues(alpha: main.a);
        canvas.drawPath(leaf, Paint()..color = green.withValues(alpha: green.a * 0.45));
        crayon(canvas, leaf, green, w, seed: seed++);
        crayon(canvas, Path()..moveTo(c.dx, c.dy)..lineTo(mid.dx, mid.dy), green, w * 0.7, seed: seed++);
      }
      crayon(canvas, Path()..moveTo(c.dx, c.dy)..lineTo(c.dx - s * 0.05, c.dy + s * 0.35), _leafGreen.withValues(alpha: main.a), w, seed: seed);
  }
}

/// 章节标题下面的装饰：一道蜡笔波浪线，末尾一个角色小图案。画在标题原有的留白里，不占高度。
class DoodleRule extends StatelessWidget {
  const DoodleRule({super.key, required this.motif, required this.line, required this.accent, this.width = 140});

  final Motif motif;
  final Color line;
  final Color accent;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(width, 12), painter: _RulePainter(motif, line, accent));
}

class _RulePainter extends CustomPainter {
  _RulePainter(this.motif, this.line, this.accent);

  final Motif motif;
  final Color line, accent;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    crayon(canvas, wobbleLine(Offset(0, y), size.width - 20, amp: 1.2, seed: 3), line.withValues(alpha: 0.75), 1.8, seed: 3);
    drawMotif(canvas, motif, Offset(size.width - 8, y), motif == Motif.mint ? 15 : 12, line, accent, seed: 5);
  }

  @override
  bool shouldRepaint(_RulePainter old) => old.motif != motif || old.line != line || old.accent != accent;
}

/// 「我的」页顶上的横幅：卡片底色上撒几个蜡笔小图案和几道随手的线，右边站着角色。
class DoodleBanner extends StatelessWidget {
  const DoodleBanner({super.key, required this.art, this.height = 132});

  final CharacterArt art;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _BannerPainter(art.motif, Color.alphaBlend(scheme.primary.withValues(alpha: 0.09), scheme.surface), scheme.primary, art.secondary))),
            // 半身像底部贴着横幅下沿，上面稍微出血一点
            Positioned(right: 4, bottom: -height * 0.06, height: height * 1.12, child: Image.asset(art.banner, fit: BoxFit.contain)),
          ],
        ),
      ),
    );
  }
}

class _BannerPainter extends CustomPainter {
  _BannerPainter(this.motif, this.bg, this.main, this.accent);

  final Motif motif;
  final Color bg, main, accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final w = size.width, h = size.height;
    // 左半边撒图案（右边留给人物），位置固定，不随重绘跳动
    const spots = [(0.06, 0.22, 16.0), (0.24, 0.12, 11.0), (0.42, 0.3, 14.0), (0.14, 0.5, 9.0), (0.55, 0.14, 10.0), (0.33, 0.55, 8.0)];
    for (final (i, (x, y, s)) in spots.indexed) {
      // 气泡两种颜色交替；草莓和薄荷叶只用本色，大小交替
      final color = motif == Motif.bubbles && i.isOdd ? accent : main;
      final size = motif == Motif.mint ? s * 1.5 : (motif == Motif.strawberry ? s * 1.2 : s);
      drawMotif(canvas, motif, Offset(x * w, y * h), size, color.withValues(alpha: 0.55), accent.withValues(alpha: 0.6), seed: i * 7);
    }
    // 底下两道随手的波浪线
    crayon(canvas, wobbleLine(Offset(-4, h * 0.86), w * 0.7, amp: 2.4, seed: 11), main.withValues(alpha: 0.28), 6, seed: 11);
    crayon(canvas, wobbleLine(Offset(w * 0.1, h * 0.95), w * 0.5, amp: 2, seed: 17), accent.withValues(alpha: 0.32), 4, seed: 17);
  }

  @override
  bool shouldRepaint(_BannerPainter old) => old.motif != motif || old.bg != bg || old.main != main || old.accent != accent;
}

/// 书架未读 / 缓存角标：蜡笔描一圈的小圆，里面写数字
class DoodleBadge extends StatelessWidget {
  const DoodleBadge(this.text, {super.key, required this.color, required this.textColor});

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BadgePainter(color),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 8),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, height: 1.3, fontWeight: FontWeight.w700, color: textColor)),
      ),
    ),
  );
}

class _BadgePainter extends CustomPainter {
  _BadgePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.85));
    crayon(canvas, Path()..addRRect(r.inflate(0.6)), Color.lerp(color, Colors.black, 0.35)!, 1.3, seed: size.width.round());
  }

  @override
  bool shouldRepaint(_BadgePainter old) => old.color != color;
}

/// 角色主题的 [CharacterArt]；普通配色返回 null
CharacterArt? characterArtOf(AppPalette palette) => palette.art == null ? null : CharacterArt(palette.art!, palette.secondary ?? palette.accentLight, palette.accentLight, palette.accentDark);
