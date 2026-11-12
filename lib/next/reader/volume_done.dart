import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HapticFeedback;

import '../cover_color.dart';
import '../theme_doodle.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../text.dart';

enum VolumeDoneAction { next, shelf, stay }

/// 读完一卷时弹出的庆祝卡片：封面带着光晕浮上来，下面是这一卷用了几天、多久、多少字，顺手打星，
/// 再选「下一卷」或「回书架」。关掉（点空白、返回键）算 [VolumeDoneAction.stay]。
Future<VolumeDoneAction> showVolumeDone(BuildContext context, {required String aid, required Vol vol, required int index, required String cover, required bool hasNext}) async {
  HapticFeedback.heavyImpact();
  final r = await showGeneralDialog<VolumeDoneAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black.withValues(alpha: 0.82),
    transitionDuration: const Duration(milliseconds: 520),
    pageBuilder: (context, _, _) => _VolumeDoneCard(aid: aid, vol: vol, index: index, cover: cover, hasNext: hasNext),
    transitionBuilder: (context, a, _, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.6)), child: child),
  );
  return r ?? VolumeDoneAction.stay;
}

class _VolumeDoneCard extends StatefulWidget {
  const _VolumeDoneCard({required this.aid, required this.vol, required this.index, required this.cover, required this.hasNext});

  final String aid;
  final Vol vol;
  final int index;
  final String cover;
  final bool hasNext;

  @override
  State<_VolumeDoneCard> createState() => _VolumeDoneCardState();
}

class _VolumeDoneCardState extends State<_VolumeDoneCard> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..forward();
  late int _rating = Volumes.rating(widget.aid, widget.vol.title);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Animation<double> _at(double from, double to, [Curve curve = Curves.easeOutCubic]) => CurvedAnimation(parent: _c, curve: Interval(from, to, curve: curve));

  /// 依次浮上来：每一块晚一点出现
  Widget _rise(double from, Widget child) {
    final a = _at(from, (from + 0.35).clamp(0, 1));
    return FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aid = widget.aid, v = widget.vol;
    final glow = savedCoverColor(widget.cover) ?? kNeutralCoverColor;
    final t = Volumes.time(aid, v);
    final chars = Volumes.readChars(aid, v);
    final minutes = (t.seconds / 60).ceil();
    const muted = TextStyle(color: Colors.white60, fontSize: 12);
    Widget stat(String value, String label) => Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(label, style: muted),
        ],
      ),
    );

    final coverIn = _at(0, 0.55, Curves.easeOutBack);
    final art = CharacterArt.of(context);
    final cheerIn = _at(0.35, 0.8, Curves.easeOutBack);
    return SafeArea(
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 封面：从小放大、稍微转正，背后一圈封面色的光
                  AnimatedBuilder(
                    animation: _c,
                    builder: (context, child) => Transform.scale(
                      scale: 0.6 + 0.4 * coverIn.value,
                      child: Transform.rotate(angle: (1 - coverIn.value) * -0.12, child: Opacity(opacity: coverIn.value.clamp(0, 1), child: child)),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                      width: 150,
                      height: 150 / 0.7,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(color: Color.lerp(glow, Colors.white, 0.35)!.withValues(alpha: 0.55), blurRadius: 60, spreadRadius: 8),
                          const BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 8)),
                        ],
                      ),
                      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: NetImage(widget.cover)),
                    ),
                        if (art != null)
                          Positioned(
                            right: -78,
                            bottom: -22,
                            child: AnimatedBuilder(
                              animation: cheerIn,
                              builder: (context, child) => Opacity(
                                opacity: cheerIn.value.clamp(0, 1),
                                child: Transform.translate(offset: Offset(0, 30 * (1 - cheerIn.value)), child: Transform.scale(scale: 0.7 + 0.3 * cheerIn.value, child: child)),
                              ),
                              child: Image.asset(art.cheer, width: 120, height: 120),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _rise(0.3, const Text('读完了', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 4))),
                  const SizedBox(height: 6),
                  _rise(0.35, Text(v.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 15))),
                  const SizedBox(height: 24),
                  _rise(
                    0.45,
                    Row(
                      children: [
                        stat(t.days.isEmpty ? '-' : '${t.days.length}', '天'),
                        stat(minutes == 0 ? '-' : (minutes >= 60 ? (minutes / 60).toStringAsFixed(1) : '$minutes'), minutes >= 60 ? '小时' : '分钟'),
                        stat(chars == 0 ? '-' : (chars >= 10000 ? (chars / 10000).toStringAsFixed(1) : '$chars'), chars >= 10000 ? '万字' : '字'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _rise(
                    0.55,
                    Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 1; i <= 5; i++)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  HapticFeedback.selectionClick();
                                  setState(() => _rating = _rating == i ? 0 : i);
                                  await Volumes.setRating(aid, v.title, _rating);
                                },
                                icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFFFFC53D), size: 32),
                              ),
                          ],
                        ),
                        Text(_rating == 0 ? '给这一卷打个分' : '已记下 $_rating 星', style: muted),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _rise(0.6, const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.auto_stories_rounded, size: 14, color: Colors.white54), SizedBox(width: 4), Text('已放进书籍墙', style: muted)])),
                  const SizedBox(height: 24),
                  _rise(
                    0.65,
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                            onPressed: () => Navigator.pop(context, VolumeDoneAction.shelf),
                            child: const Text('回书架'),
                          ),
                        ),
                        if (widget.hasNext) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                              onPressed: () => Navigator.pop(context, VolumeDoneAction.next),
                              child: const Text('下一卷'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
