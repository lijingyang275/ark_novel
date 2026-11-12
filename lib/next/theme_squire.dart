import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'text.dart';

/// 「遗迹·晴空」主题的美术：全部用代码画的扁平插画（天空、两层云、科林斯石柱、断墙、芥末色三角旗），
/// 浅色是晴天，深色是黄昏（星星、月牙、石柱压暗）。另外有一套同风格的底部导航图标和旗形角标。
class RuinsColors {
  const RuinsColors._(this.sky, this.skyLow, this.cloudBack, this.cloud, this.cloudShade, this.stone, this.stoneLight, this.stoneShade, this.wall, this.mortar, this.flag, this.flagShade, this.pole, this.ink);

  final Color sky, skyLow, cloudBack, cloud, cloudShade, stone, stoneLight, stoneShade, wall, mortar, flag, flagShade, pole, ink;

  static const day = RuinsColors._(
    Color(0xFF7DB9B5), Color(0xFFA5D0C8), Color(0xFFD8CCD8), Color(0xFFF6EEE2), Color(0xFFE2D3D9), //
    Color(0xFFB0503A), Color(0xFFC96B4D), Color(0xFF8C3C2B), Color(0xFF8A4232), Color(0xFF6E3326),
    Color(0xFFE2A443), Color(0xFFC4862C), Color(0xFF5A3A22), Color(0xFF2B1E16),
  );
  static const dusk = RuinsColors._(
    Color(0xFF1D3545), Color(0xFF2E4B5A), Color(0xFF2F4A60), Color(0xFF52708A), Color(0xFF3C5770), //
    Color(0xFF6A3026), Color(0xFF7E3D2F), Color(0xFF4E2219), Color(0xFF4A231B), Color(0xFF3A1B15),
    Color(0xFFCC9236), Color(0xFFA9742A), Color(0xFF2E1E14), Color(0xFFF3EBDD),
  );

  static RuinsColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dusk : day;
}

/// 插画横幅。[animate] 时云慢慢飘、旗子轻轻摆（系统开了"减少动画"就不动）。
class RuinsScene extends StatefulWidget {
  const RuinsScene({super.key, this.animate = true, this.horizon = 0.84, this.ceiling = 0});

  final bool animate;

  /// 断墙顶在高度的哪个比例：越大石柱露得越多
  final double horizon;

  /// 石柱顶最高到哪个比例：顶栏上面压着标题和按钮时，把石柱压低让开
  final double ceiling;

  @override
  State<RuinsScene> createState() => _RuinsSceneState();
}

class _RuinsSceneState extends State<RuinsScene> with SingleTickerProviderStateMixin {
  late final _t = AnimationController(vsync: this, duration: const Duration(seconds: 90));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    still ? _t.stop() : _t.repeat();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _ScenePainter(RuinsColors.of(context), _t, Theme.of(context).brightness == Brightness.dark, widget.horizon, widget.ceiling), size: Size.infinite),
  );
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.c, this.t, this.dark, this.horizon, this.ceiling) : super(repaint: t);

  final RuinsColors c;
  final Animation<double> t;
  final bool dark;
  final double horizon, ceiling;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.clipRect(Offset.zero & size);
    final p = Paint()..isAntiAlias = true;

    // 天空：上深下浅两段，接缝藏在远云后面
    canvas.drawRect(Offset.zero & size, p..color = c.sky);
    canvas.drawRect(Rect.fromLTWH(0, h * 0.45, w, h), p..color = c.skyLow);

    if (dark) {
      final rnd = math.Random(7);
      p.color = const Color(0xFFF3E3B5);
      for (var i = 0; i < 26; i++) {
        canvas.drawCircle(Offset(rnd.nextDouble() * w, rnd.nextDouble() * h * 0.5), rnd.nextDouble() * 0.9 + 0.4, p);
      }
      // 月牙：亮圆上叠一个天空色的圆
      final m = Offset(w * 0.86, h * 0.2);
      canvas.drawCircle(m, h * 0.075, p);
      canvas.drawCircle(m + Offset(h * 0.035, -h * 0.02), h * 0.07, p..color = c.sky);
    } else {
      canvas.drawCircle(Offset(w * 0.84, h * 0.2), h * 0.08, p..color = const Color(0xFFFBF3E2));
      // 两三只飞鸟
      final bird = Paint()
        ..color = c.ink.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      for (final (x, y, s) in [(0.62, 0.16, 5.0), (0.67, 0.12, 4.0), (0.58, 0.22, 3.5)]) {
        final o = Offset(w * x, h * y);
        canvas.drawPath(Path()..moveTo(o.dx - s, o.dy - s * 0.4)..quadraticBezierTo(o.dx - s * 0.4, o.dy - s * 0.6, o.dx, o.dy)..quadraticBezierTo(o.dx + s * 0.4, o.dy - s * 0.6, o.dx + s, o.dy - s * 0.4), bird);
      }
    }

    final drift = t.value * w;
    // 远处一层淡紫的云，飘得慢；近处奶油色的云带一层偏紫的阴影，飘得快一点
    _cloudBand(canvas, size, h * 0.6, h * 0.17, c.cloudBack, c.cloudBack, drift * 0.35, 3);
    _cloudBand(canvas, size, h * 0.46, h * 0.15, c.cloud, c.cloudShade, drift * 0.7, 11);

    // 石柱：两边高的、左中一根断柱（旗子插在上面）、右中一根矮一点的
    final ground = h * horizon;
    final cw = math.min(h * 0.19, w * 0.085);
    double top(double f) => h * (ceiling + f * (1 - ceiling)); // 有 ceiling 时整体压低，高低错落还在
    final brokenTop = top(0.5);
    for (final (x, f, broken) in [(0.07, 0.08, false), (0.3, 0.5, true), (0.72, 0.16, false), (0.94, 0.04, false)]) {
      _column(canvas, Offset(w * x, top(f)), ground + 2, cw, broken);
    }

    // 三角旗：杆子斜插在断柱顶上，长长的旗面往右下垂，随时间轻轻摆
    final from = Offset(w * 0.3 - cw * 0.2, brokenTop + cw * 0.4);
    final to = Offset(w * 0.47, math.max(brokenTop - h * 0.34, h * 0.06));
    if (ceiling == 0) _pennant(canvas, from, to, t.value, h); // 顶栏上有按钮时不画旗子，免得挡住

    // 断墙：一排石块，顶上一道亮色压顶
    final p2 = Paint();
    canvas.drawRect(Rect.fromLTWH(0, ground, w, h - ground), p2..color = c.wall);
    canvas.drawRect(Rect.fromLTWH(0, ground, w, 3), p2..color = c.stoneLight);
    final line = Paint()
      ..color = c.mortar
      ..strokeWidth = 1.2;
    final bh = h - ground;
    final bw = math.max(bh * 2.2, 28.0);
    for (var x = bw * 0.4; x < w; x += bw) {
      canvas.drawLine(Offset(x, ground + 3), Offset(x, h), line);
    }
  }

  /// 一排起伏的云：底边平，顶上一串大小不一的圆，阴影层整体往右下偏一点；横向循环平移。
  void _cloudBand(Canvas canvas, Size size, double base, double r, Color fill, Color shade, double dx, int seed) {
    final w = size.width;
    final rnd = math.Random(seed);
    final bumps = <(double, double, double)>[];
    var x = 0.0;
    while (x < w * 2) {
      final rr = r * (0.55 + rnd.nextDouble() * 0.6);
      bumps.add((x, base - rr * (0.2 + rnd.nextDouble() * 0.5), rr));
      x += rr * 1.25;
    }
    final period = x;
    Path band(double ox, double oy) {
      final path = Path()..addRect(Rect.fromLTWH(-10, base + oy - r * 0.2, w + 20, r * 0.75));
      for (final (bx, by, br) in bumps) {
        for (final k in [-1, 0, 1]) {
          final cx = (bx - dx % period) + k * period + ox;
          if (cx + br < -10 || cx - br > w + 10) continue;
          path.addOval(Rect.fromCircle(center: Offset(cx, by + oy), radius: br));
          // 下沿也鼓出一点，云才是一团一团的
          path.addOval(Rect.fromCircle(center: Offset(cx + br * 0.5, base + oy + r * 0.5), radius: br * 0.5));
        }
      }
      return path;
    }

    final p = Paint()..isAntiAlias = true;
    if (shade != fill) canvas.drawPath(band(3, 5), p..color = shade);
    canvas.drawPath(band(0, 0), p..color = fill);
  }

  /// 科林斯柱：基座两级、柱身带竖槽（左亮右暗）、柱头一圈涡卷。[broken] 时柱顶是斜着断开的、没有柱头。
  void _column(Canvas canvas, Offset top, double bottom, double width, bool broken) {
    final p = Paint()..isAntiAlias = true;
    final shaft = width * 0.72;
    final left = top.dx - shaft / 2;
    final capH = width * 0.55;
    final shaftTop = broken ? top.dy : top.dy + capH;
    final body = Path();
    if (broken) {
      body
        ..moveTo(left, shaftTop + width * 0.25)
        ..lineTo(left + shaft * 0.3, shaftTop + width * 0.05)
        ..lineTo(left + shaft * 0.55, shaftTop + width * 0.2)
        ..lineTo(left + shaft, shaftTop - width * 0.05)
        ..lineTo(left + shaft, bottom)
        ..lineTo(left, bottom)
        ..close();
    } else {
      body.addRect(Rect.fromLTRB(left, shaftTop, left + shaft, bottom));
    }
    canvas.drawPath(body, p..color = c.stone);
    canvas.save();
    canvas.clipPath(body);
    canvas.drawRect(Rect.fromLTRB(left, shaftTop - width, left + shaft * 0.22, bottom), p..color = c.stoneLight);
    canvas.drawRect(Rect.fromLTRB(left + shaft * 0.74, shaftTop - width, left + shaft, bottom), p..color = c.stoneShade);
    final flute = Paint()
      ..color = c.stoneShade.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (final f in [0.38, 0.56]) {
      canvas.drawLine(Offset(left + shaft * f, shaftTop - width), Offset(left + shaft * f, bottom), flute);
    }
    // 柱身中段一道石块接缝
    canvas.drawLine(Offset(left, (shaftTop + bottom) / 2), Offset(left + shaft, (shaftTop + bottom) / 2), Paint()..color = c.stoneShade..strokeWidth = 1.2);
    canvas.restore();

    if (!broken) {
      // 柱头：上宽下窄的梯形 + 顶板 + 两侧涡卷 + 中间一排叶子
      final y = top.dy;
      canvas.drawRect(Rect.fromLTWH(top.dx - width * 0.62, y, width * 1.24, capH * 0.22), p..color = c.stoneShade);
      final cap = Path()
        ..moveTo(top.dx - width * 0.55, y + capH * 0.22)
        ..lineTo(top.dx + width * 0.55, y + capH * 0.22)
        ..lineTo(top.dx + shaft / 2, y + capH)
        ..lineTo(top.dx - shaft / 2, y + capH)
        ..close();
      canvas.drawPath(cap, p..color = c.stone);
      for (final s in [-1, 1]) {
        canvas.drawCircle(Offset(top.dx + s * width * 0.48, y + capH * 0.42), width * 0.12, p..color = c.stoneLight);
        canvas.drawCircle(Offset(top.dx + s * width * 0.48, y + capH * 0.42), width * 0.05, p..color = c.stoneShade);
      }
      final leaf = Paint()..color = c.stoneShade.withValues(alpha: 0.7);
      for (final f in [-0.22, 0.0, 0.22]) {
        final lx = top.dx + f * width;
        canvas.drawPath(Path()..moveTo(lx - width * 0.08, y + capH)..quadraticBezierTo(lx, y + capH * 0.35, lx + width * 0.08, y + capH)..close(), leaf);
      }
    }
  }

  void _pennant(Canvas canvas, Offset from, Offset to, double t, double h) {
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = c.pole
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    // 旗面挂在杆子上面那 45%，旗尾往右下拖得很长
    final a = Offset.lerp(from, to, 0.55)!;
    final wave = math.sin(t * math.pi * 2 * 30);
    final tail = to + Offset(h * 0.95, h * 0.5 + wave * h * 0.03);
    final flag = Path()
      ..moveTo(to.dx, to.dy)
      ..cubicTo(to.dx + h * 0.35, to.dy + h * 0.02 + wave * 3, tail.dx - h * 0.35, tail.dy - h * 0.18, tail.dx, tail.dy)
      ..cubicTo(tail.dx - h * 0.4, tail.dy - h * 0.02, a.dx + h * 0.3, a.dy + h * 0.06 - wave * 3, a.dx, a.dy)
      ..close();
    canvas.drawPath(flag, Paint()..color = c.flag);
    // 两道折痕阴影，让旗子有布料感
    final crease = Paint()
      ..color = c.flagShade
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    for (final k in [0.35, 0.6]) {
      final s0 = Offset.lerp(a, to, k)!;
      canvas.drawPath(Path()..moveTo(s0.dx, s0.dy)..quadraticBezierTo(s0.dx + h * 0.3, s0.dy + h * 0.12, tail.dx - h * 0.25 * k, tail.dy - h * 0.08), crease);
    }
    canvas.drawCircle(to, 2.6, Paint()..color = c.pole);
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.c != c || old.dark != dark || old.horizon != horizon || old.ceiling != ceiling;
}

/// 底部导航图标：0 发现（折叠地图）、1 书架（石柱）、2 更新（三角旗）、3 我的（骑士头盔）。
/// 选中时是填色的小插画，没选中是线条。
class RuinsNavIcon extends StatelessWidget {
  const RuinsNavIcon(this.index, {super.key, required this.selected});

  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: selected ? 1.1 : 1,
      duration: const Duration(milliseconds: 160),
      child: CustomPaint(size: const Size(26, 26), painter: _NavPainter(index, selected, scheme.primary, scheme.secondary, scheme.onSurfaceVariant, scheme.surface)),
    );
  }
}

class _NavPainter extends CustomPainter {
  _NavPainter(this.i, this.on, this.accent, this.gold, this.idle, this.bg);

  final int i;
  final bool on;
  final Color accent, gold, idle, bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final line = Paint()
      ..color = on ? accent : idle
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = accent.withValues(alpha: 0.18);
    final gp = Paint()..color = gold;
    switch (i) {
      case 0: // 折叠地图 + 虚线路线 + 终点
        final map = Path()
          ..moveTo(3, 6)
          ..lineTo(9, 4)
          ..lineTo(15, 6)
          ..lineTo(21, 4)
          ..lineTo(21, 18)
          ..lineTo(15, 20)
          ..lineTo(9, 18)
          ..lineTo(3, 20)
          ..close();
        if (on) {
          canvas.drawPath(map, Paint()..color = bg);
          canvas.drawPath(Path()..moveTo(9, 4)..lineTo(15, 6)..lineTo(15, 20)..lineTo(9, 18)..close(), gp);
        }
        canvas.drawPath(map, line);
        canvas.drawLine(const Offset(9, 4), const Offset(9, 18), line);
        canvas.drawLine(const Offset(15, 6), const Offset(15, 20), line);
        if (on) canvas.drawCircle(const Offset(18, 10), 1.8, Paint()..color = accent);
      case 1: // 石柱
        if (on) {
          canvas.drawRect(const Rect.fromLTRB(7.5, 7, 16.5, 18), fill..color = accent);
          canvas.drawRect(const Rect.fromLTRB(7.5, 7, 9.5, 18), Paint()..color = Color.lerp(accent, Colors.white, 0.3)!);
          canvas.drawRect(const Rect.fromLTRB(4.5, 4, 19.5, 6.5), gp);
          canvas.drawRect(const Rect.fromLTRB(4.5, 18.5, 19.5, 21), gp);
        } else {
          canvas.drawRect(const Rect.fromLTRB(4.5, 4, 19.5, 6.5), line);
          canvas.drawRect(const Rect.fromLTRB(7.5, 6.5, 16.5, 18.5), line);
          canvas.drawRect(const Rect.fromLTRB(4.5, 18.5, 19.5, 21), line);
          canvas.drawLine(const Offset(12, 9), const Offset(12, 16), line);
        }
      case 2: // 旗杆 + 燕尾旗
        final flag = Path()
          ..moveTo(7, 4.5)
          ..lineTo(20, 4.5)
          ..lineTo(16.5, 8.5)
          ..lineTo(20, 12.5)
          ..lineTo(7, 12.5)
          ..close();
        if (on) canvas.drawPath(flag, gp);
        canvas.drawPath(flag, line..color = on ? accent : idle);
        canvas.drawLine(const Offset(6, 3), const Offset(6, 21), line..strokeWidth = 2);
      case 3: // 骑士头盔：圆顶、面甲一道缝、顶上一撮羽饰
        final helm = Path()
          ..moveTo(5.5, 20.5)
          ..lineTo(5.5, 12)
          ..quadraticBezierTo(5.5, 5.5, 12, 5.5)
          ..quadraticBezierTo(18.5, 5.5, 18.5, 12)
          ..lineTo(18.5, 20.5)
          ..close();
        final plume = Path()
          ..moveTo(12, 5.5)
          ..quadraticBezierTo(13, 1.5, 18.5, 2)
          ..quadraticBezierTo(15.5, 3.5, 15, 6);
        if (on) {
          canvas.drawPath(plume, gp);
          canvas.drawPath(helm, Paint()..color = accent);
          canvas.drawRect(const Rect.fromLTRB(7.5, 11, 16.5, 13), Paint()..color = bg);
          canvas.drawLine(const Offset(12, 14.5), const Offset(12, 19), Paint()..color = bg..strokeWidth = 1.4);
        } else {
          canvas.drawPath(plume, line);
          canvas.drawPath(helm, line);
          canvas.drawLine(const Offset(8, 12), const Offset(16, 12), line);
        }
    }
  }

  @override
  bool shouldRepaint(_NavPainter old) => old.on != on || old.accent != accent || old.idle != idle || old.i != i;
}

/// 封面角上挂的燕尾小旗，代替圆形数字角标
class PennantBadge extends StatelessWidget {
  const PennantBadge(this.text, {super.key, required this.color, required this.textColor});

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PennantPainter(color),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(5, 3, 5, 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 12),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, height: 1.2, fontWeight: FontWeight.w700, color: textColor)),
      ),
    ),
  );
}

class _PennantPainter extends CustomPainter {
  _PennantPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(w / 2, h - 6)
      ..lineTo(0, h)
      ..close();
    canvas.drawShadow(path, Colors.black, 1.5, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PennantPainter old) => old.color != color;
}

/// 章节标题下面的装饰线：一道细线，末端一面小三角旗
class PennantRule extends StatelessWidget {
  const PennantRule({super.key, required this.line, required this.flag, this.width = 120});

  final Color line;
  final Color flag;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(width, 10), painter: _RulePainter(line, flag));
}

class _RulePainter extends CustomPainter {
  _RulePainter(this.line, this.flag);

  final Color line, flag;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2, w = size.width;
    canvas.drawLine(Offset(0, y), Offset(w - 16, y), Paint()..color = line..strokeWidth = 1.4);
    canvas.drawCircle(Offset(w - 16, y), 2, Paint()..color = line);
    canvas.drawPath(Path()..moveTo(w - 16, y - 5)..lineTo(w, y)..lineTo(w - 16, y + 5)..close(), Paint()..color = flag);
  }

  @override
  bool shouldRepaint(_RulePainter old) => old.line != line || old.flag != flag;
}
