import 'package:flutter/material.dart' hide Text;
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'bookmarks.dart';
import 'cache.dart';
import 'motion.dart';
import 'read_state.dart';
import 'text.dart';

/// 章节列表左右滑能做的事（Mihon 的"章节滑动操作"）。
enum SwipeAct {
  off('关闭'),
  read('标记已读 / 未读'),
  bookmark('书签'),
  cache('缓存本章');

  const SwipeAct(this.label);

  final String label;
}

/// 右滑、左滑各自的动作，默认右滑标已读、左滑加书签（和 Mihon 一样）。
class SwipePrefs {
  const SwipePrefs(this.right, this.left);

  final SwipeAct right;
  final SwipeAct left;
}

class SwipePrefsController extends Notifier<SwipePrefs> {
  Box get _box => Hive.box('session');

  SwipeAct _get(String key, SwipeAct fallback) {
    final i = _box.get(key) as int?;
    return i == null || i < 0 || i >= SwipeAct.values.length ? fallback : SwipeAct.values[i];
  }

  @override
  SwipePrefs build() => SwipePrefs(_get('swipeRight', SwipeAct.read), _get('swipeLeft', SwipeAct.bookmark));

  void set({SwipeAct? right, SwipeAct? left}) {
    final next = SwipePrefs(right ?? state.right, left ?? state.left);
    _box.putAll({'swipeRight': next.right.index, 'swipeLeft': next.left.index});
    state = next;
  }
}

final swipePrefsProvider = NotifierProvider<SwipePrefsController, SwipePrefs>(SwipePrefsController.new);

/// 越过这么远松手才执行（逻辑像素），没越过松手就只弹回去
const _kTrigger = 72.0;

/// 拖出这么远才定下这次往哪边滑：按下时手指抖一下不会露出另一边
const _kDecide = 8.0;

/// 给一行章节加上左右滑：跟着手指拖开，露出后面的动作；越过 [_kTrigger] 时背景变实色、震一下，
/// 这时松手执行动作。不管执行没执行，松手都从当前位置直接弹回原位（不像 [Dismissible] 先甩到屏幕边上再回来）。
/// 状态变了调 [onChanged] 让外面刷新。[onCache] 为空时"缓存"这个动作不可用（滑了没反应）。
class ChapterSwipe extends ConsumerStatefulWidget {
  const ChapterSwipe({super.key, required this.aid, required this.book, required this.cid, required this.title, required this.child, this.onChanged, this.onCache, this.enabled = true, this.backdrop});

  final String aid;
  final String book;
  final String cid;
  final String title;
  final Widget child;
  final VoidCallback? onChanged;
  final VoidCallback? onCache;
  final bool enabled;

  /// 行本身的底色：滑开时盖住后面的彩色背景（行是透明的会透出来）。默认取页面底色。
  final Color? backdrop;

  @override
  ConsumerState<ChapterSwipe> createState() => _ChapterSwipeState();
}

class _ChapterSwipeState extends ConsumerState<ChapterSwipe> with SingleTickerProviderStateMixin {
  late final _dx = AnimationController.unbounded(vsync: this); // 行现在往右挪了多少（负数往左）
  double _drag = 0; // 手指实际拖了多远：越过触发点后行跟得慢一点，有阻力感
  bool _armed = false; // 已经越过触发点，松手就执行
  int _side = 0; // 这次拖动往哪边：1 右、-1 左、0 还没定；定了就不会滑到另一边
  int _springGen = 0;
  // 拖动开始时两边的样子：松手执行后弹回的那一下，图标不要变成反过来的动作
  (IconData, String, Color)? _rightLook, _leftLook;

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  String get _aid => widget.aid;
  String get _cid => widget.cid;

  // 和 Mihon 一样：同一个动作一种颜色，做 / 撤销只换图标（文字只给读屏用）
  (IconData, String, Color) _look(SwipeAct a, ColorScheme s) => switch (a) {
    SwipeAct.read => ReadState.isRead(_aid, _cid) ? (Icons.remove_done, '标为未读', const Color(0xFF2E9E5B)) : (Icons.done_all, '标为已读', const Color(0xFF2E9E5B)),
    SwipeAct.bookmark =>
      Bookmarks.has(_aid, _cid, 0) ? (Icons.bookmark_remove_outlined, '取消书签', const Color(0xFFE59A1F)) : (Icons.bookmark_add_outlined, '加书签', const Color(0xFFE59A1F)),
    SwipeAct.cache => ChapterCache.has(_aid, _cid) ? (Icons.download_done, '已缓存', s.primary) : (Icons.download_outlined, '缓存本章', s.primary),
    SwipeAct.off => (Icons.block, '', Colors.transparent),
  };

  Future<void> _run(SwipeAct a) async {
    switch (a) {
      case SwipeAct.read:
        await ReadState.setRead(_aid, [_cid], !ReadState.isRead(_aid, _cid));
      case SwipeAct.bookmark:
        final added = await Bookmarks.toggle(_aid, widget.book, _cid, widget.title, 0, '（章首书签）');
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(added ? '已添加书签：${widget.title}' : '已移除书签'), duration: const Duration(seconds: 2)));
        }
      case SwipeAct.cache:
        if (!ChapterCache.has(_aid, _cid)) widget.onCache?.call();
      case SwipeAct.off:
        return;
    }
    widget.onChanged?.call();
  }

  /// 越过触发点后只跟手指的 40%
  static double _resist(double d) => d.abs() <= _kTrigger ? d : d.sign * (_kTrigger + (d.abs() - _kTrigger) * 0.4);

  void _start(SwipeAct right, SwipeAct left, ColorScheme scheme) {
    _springGen++;
    _dx.stop();
    // 上一下还没弹回去就又拖：离原位还远就接着原来那边，快回到原位了就重新定方向
    _drag = _dx.value.abs() < _kDecide ? 0 : _dx.value;
    _dx.value = _drag;
    _side = _drag.sign.toInt();
    _rightLook = _look(right, scheme);
    _leftLook = _look(left, scheme);
  }

  void _update(double delta, SwipeAct right, SwipeAct left) {
    _drag += delta;
    // 关掉的那一边拖不动
    if (right == SwipeAct.off && _drag > 0) _drag = 0;
    if (left == SwipeAct.off && _drag < 0) _drag = 0;
    if (_side == 0) {
      if (_drag.abs() < _kDecide) return;
      _side = _drag.sign.toInt();
      _drag -= _side * _kDecide; // 从 0 开始跟手，不跳一下
    }
    if (_drag * _side < 0) _drag = 0; // 往回拖最多回到原位
    _dx.value = _resist(_drag);
    final armed = _drag.abs() >= _kTrigger;
    if (armed != _armed) {
      if (armed) HapticFeedback.lightImpact();
      setState(() => _armed = armed);
    }
  }

  void _end(SwipeAct right, SwipeAct left, [double velocity = 0]) {
    final act = _armed ? (_drag > 0 ? right : left) : null;
    _armed = false;
    _drag = 0;
    _side = 0;
    if (AppMotion.reduce(context)) {
      _springGen++;
      _dx.value = 0;
    } else {
      // 用临界阻尼弹簧承接松手速度自然弹回原位，中途再次拖动可无缝打断
      final gen = ++_springGen;
      final v = velocity.clamp(-1400.0, 1400.0);
      _dx.animateWith(SpringSimulation(AppMotion.smoothSpring, _dx.value, 0, v, tolerance: AppMotion.pixelTolerance)).then((_) {
        if (mounted && gen == _springGen && _dx.value != 0) _dx.value = 0;
      });
    }
    if (act != null) _run(act);
  }

  Widget _bg((IconData, String, Color) look, Alignment align) {
    final (icon, label, color) = look;
    final d = AppMotion.dur(context, AppMotion.instant);
    return AnimatedContainer(
      duration: d,
      curve: AppMotion.curve,
      color: _armed ? color : color.withValues(alpha: 0.42),
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: AnimatedScale(
        scale: _armed ? 1.06 : 0.85,
        duration: d,
        curve: AppMotion.snappy,
        child: AnimatedOpacity(
          opacity: _armed ? 1 : 0.7,
          duration: d,
          curve: AppMotion.curve,
          child: Icon(icon, color: Colors.white, semanticLabel: label),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(swipePrefsProvider);
    final scheme = Theme.of(context).colorScheme;
    final canCache = widget.onCache != null;
    final right = p.right == SwipeAct.cache && !canCache ? SwipeAct.off : p.right;
    final left = p.left == SwipeAct.cache && !canCache ? SwipeAct.off : p.left;
    if (!widget.enabled || (right == SwipeAct.off && left == SwipeAct.off)) return widget.child;
    final backdrop = widget.backdrop ?? Scaffold.maybeOf(context)?.widget.backgroundColor ?? scheme.surface;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _start(right, left, scheme),
      onHorizontalDragUpdate: (d) => _update(d.primaryDelta ?? 0, right, left),
      onHorizontalDragEnd: (d) => _end(right, left, d.velocity.pixelsPerSecond.dx),
      onHorizontalDragCancel: () => _end(SwipeAct.off, SwipeAct.off),
      child: AnimatedBuilder(
        animation: _dx,
        // 点按高亮默认画在外面的 Material 上，不跟着行挪、也不被裁剪，滑开时会从左边露出一块灰；让它画在行自己身上
        child: Material(type: MaterialType.transparency, child: widget.child),
        builder: (context, child) {
          final dx = _dx.value;
          // 结构一直不变（行里的状态不丢），只在滑开时才叠背景、垫底色：平时透明，页面背景渐变时不会和它错开
          return ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: dx == 0
                      ? const SizedBox.shrink()
                      : dx > 0
                      ? _bg(_rightLook ?? _look(right, scheme), Alignment.centerLeft)
                      : _bg(_leftLook ?? _look(left, scheme), Alignment.centerRight),
                ),
                Transform.translate(offset: Offset(dx, 0), child: ColoredBox(color: dx == 0 ? Colors.transparent : backdrop, child: child)),
              ],
            ),
          );
        },
      ),
    );
  }
}
