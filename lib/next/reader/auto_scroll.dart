import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart';

import '../motion.dart';
import '../text.dart';
import 'reader_sheets.dart' show ReaderPalette;

/// 自动滚屏单帧步进结果。
enum AutoScrollStep { scrolled, reachedEnd, unavailable }

/// 阅读器自动滚屏 / 自动翻页控制器。
///
/// - 滚动模式（`mode == 0`）：通过 [Ticker] 按 [scrollSpeed]（px/s）匀速推进；滚到底部停顿片刻后自动衔接下一章。
/// - 翻页模式（`mode != 0`）：按 [turnSeconds]（秒/页）倒计时自动翻下一页，通过 [progress] 驱动底部极细倒计时进度条。
/// - 所有自动动作期间置位 [isStepping] / 保护窗口，避免翻页/滚屏回调误判为用户手动操作。
class ReaderAutoScrollController extends ChangeNotifier {
  ReaderAutoScrollController({
    this.createTicker,
    DateTime Function()? now,
    this.onScrollStep,
    this.onNextChapter,
    this.onTurnNext,
    this.onSpeedChanged,
    this.onTurnSecondsChanged,
    this.onReachedBookEnd,
    double initialSpeed = defaultScrollSpeed,
    int initialTurnSeconds = defaultTurnSeconds,
    int initialMode = 3,
  }) : _now = now ?? DateTime.now,
       _scrollSpeed = initialSpeed.clamp(minScrollSpeed, maxScrollSpeed).toDouble(),
       _turnSeconds = initialTurnSeconds.clamp(minTurnSeconds, maxTurnSeconds),
       _mode = initialMode;

  static const double minScrollSpeed = 20.0;
  static const double maxScrollSpeed = 220.0;
  static const double defaultScrollSpeed = 60.0;
  static const double scrollSpeedStep = 20.0;

  static const int minTurnSeconds = 3;
  static const int maxTurnSeconds = 30;
  static const int defaultTurnSeconds = 8;
  static const int turnSecondsStep = 1;

  static const Duration _chapterEndHold = Duration(milliseconds: 800);
  static const Duration _chapterSwitchCooldown = Duration(milliseconds: 700);
  static const Duration _stepGraceWindow = Duration(milliseconds: 650);

  final Ticker Function(TickerCallback onTick)? createTicker;
  final DateTime Function() _now;

  /// 滚动模式单帧推进 [deltaPx] 像素，返回本帧滚动结果。
  final AutoScrollStep Function(double deltaPx)? onScrollStep;

  /// 滚动模式到底部后切到下一章；有下一章返回 true，全书读完返回 false。
  final bool Function()? onNextChapter;

  /// 翻页模式到点翻下一页；成功翻页或切章返回 true，无法继续（全书末尾）返回 false。
  final bool Function()? onTurnNext;

  /// 滚屏速度变更回调（用于持久化到 ReaderPrefs）。
  final ValueChanged<double>? onSpeedChanged;

  /// 翻页间隔变更回调（用于持久化到 ReaderPrefs）。
  final ValueChanged<int>? onTurnSecondsChanged;

  /// 读到全书末尾自动停止时回调。
  final VoidCallback? onReachedBookEnd;

  /// 翻页模式下的倒计时进度（0.0 ~ 1.0），单独通过 ValueNotifier 驱动进度条避免整页重建。
  final progress = ValueNotifier<double>(0.0);

  Ticker? _ticker;
  Timer? _fallbackTimer;
  Duration _lastTick = Duration.zero;
  Duration _turnElapsed = Duration.zero;
  Duration _endHoldElapsed = Duration.zero;
  Duration _cooldownRemaining = Duration.zero;
  DateTime _lastAutoActionAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _active = false;
  bool _paused = false;
  bool _stepping = false;
  bool _disposed = false;
  int _mode;
  double _scrollSpeed;
  int _turnSeconds;

  bool get isActive => _active;
  bool get isPaused => _paused;
  bool get isRunning => _active && !_paused;
  bool get isScrollMode => _mode == 0;
  int get mode => _mode;
  double get scrollSpeed => _scrollSpeed;
  int get turnSeconds => _turnSeconds;

  /// 当前正由自动阅读触发滚动/翻页（含短动画保护窗口），用于区分用户手动交互。
  bool get isStepping => _stepping || (_active && _now().difference(_lastAutoActionAt) < _stepGraceWindow);

  bool get canFaster => isScrollMode ? _scrollSpeed < maxScrollSpeed - 0.1 : _turnSeconds > minTurnSeconds;
  bool get canSlower => isScrollMode ? _scrollSpeed > minScrollSpeed + 0.1 : _turnSeconds < maxTurnSeconds;

  String get speedLabel => isScrollMode ? '${_scrollSpeed.round()} px/s' : '$_turnSeconds 秒/页';
  String get shortSpeedLabel => isScrollMode ? '${_scrollSpeed.round()}' : '${_turnSeconds}s';

  /// 同步阅读器模式和持久化速度偏好。
  void syncPrefs({required int mode, required double scrollSpeed, required int turnSeconds}) {
    if (_disposed) return;
    final clampedSpeed = scrollSpeed.clamp(minScrollSpeed, maxScrollSpeed).toDouble();
    final clampedTurn = turnSeconds.clamp(minTurnSeconds, maxTurnSeconds);
    final modeChanged = _mode != mode;
    final changed = modeChanged || (_scrollSpeed - clampedSpeed).abs() > 0.01 || _turnSeconds != clampedTurn;
    _mode = mode;
    _scrollSpeed = clampedSpeed;
    _turnSeconds = clampedTurn;
    if (modeChanged) {
      _turnElapsed = Duration.zero;
      _endHoldElapsed = Duration.zero;
      _cooldownRemaining = Duration.zero;
      progress.value = 0;
    }
    if (changed) notifyListeners();
  }

  /// 开始自动阅读（若原本已暂停则恢复）。
  void start({int? mode}) {
    if (_disposed) return;
    if (mode != null && _mode != mode) {
      _mode = mode;
      _turnElapsed = Duration.zero;
      progress.value = 0;
    }
    if (_active && !_paused) return;
    _active = true;
    _paused = false;
    _endHoldElapsed = Duration.zero;
    _cooldownRemaining = Duration.zero;
    _startClock();
    notifyListeners();
  }

  /// 暂停（保留控制条，用户可随时点继续）。
  void pause() {
    if (_disposed || !_active || _paused) return;
    _paused = true;
    _stopClock();
    notifyListeners();
  }

  /// 从暂停恢复。
  void resume() {
    if (_disposed || !_active || !_paused) return;
    _paused = false;
    _endHoldElapsed = Duration.zero;
    _startClock();
    notifyListeners();
  }

  void togglePause() => _paused ? resume() : pause();

  /// 停止自动阅读并释放定时器/Ticker。
  void stop() {
    if (_disposed) return;
    final wasActive = _active;
    _active = false;
    _paused = false;
    _turnElapsed = Duration.zero;
    _endHoldElapsed = Duration.zero;
    _cooldownRemaining = Duration.zero;
    _stopClock();
    progress.value = 0;
    if (wasActive) notifyListeners();
  }

  /// 用户手动翻页/滑动或打开菜单时调用：仅在运行中暂停，不干扰自己的自动动作。
  void pauseByUser() {
    if (_disposed || !isRunning || _stepping) return;
    pause();
  }

  /// 章节切换后短暂缓冲，等新章节排版完成再继续倒计时/滚屏。
  void notifyChapterSwitched() {
    if (_disposed || !_active) return;
    _turnElapsed = Duration.zero;
    _endHoldElapsed = Duration.zero;
    _cooldownRemaining = _chapterSwitchCooldown;
    progress.value = 0;
  }

  /// 加速：滚屏模式提高像素速度，翻页模式缩短间隔秒数。
  void faster() {
    if (_disposed) return;
    if (isScrollMode) {
      final next = (_scrollSpeed + scrollSpeedStep).clamp(minScrollSpeed, maxScrollSpeed).toDouble();
      if ((next - _scrollSpeed).abs() < 0.01) return;
      _scrollSpeed = next;
      onSpeedChanged?.call(next);
    } else {
      final next = (_turnSeconds - turnSecondsStep).clamp(minTurnSeconds, maxTurnSeconds);
      if (next == _turnSeconds) return;
      _turnSeconds = next;
      _updateTurnProgress();
      onTurnSecondsChanged?.call(next);
    }
    notifyListeners();
  }

  /// 减速：滚屏模式降低像素速度，翻页模式延长间隔秒数。
  void slower() {
    if (_disposed) return;
    if (isScrollMode) {
      final next = (_scrollSpeed - scrollSpeedStep).clamp(minScrollSpeed, maxScrollSpeed).toDouble();
      if ((next - _scrollSpeed).abs() < 0.01) return;
      _scrollSpeed = next;
      onSpeedChanged?.call(next);
    } else {
      final next = (_turnSeconds + turnSecondsStep).clamp(minTurnSeconds, maxTurnSeconds);
      if (next == _turnSeconds) return;
      _turnSeconds = next;
      _updateTurnProgress();
      onTurnSecondsChanged?.call(next);
    }
    notifyListeners();
  }

  void _startClock() {
    _stopClock();
    _lastTick = Duration.zero;
    if (createTicker != null) {
      _ticker = createTicker!(_onTicker)..start();
    } else {
      const step = Duration(milliseconds: 50);
      _fallbackTimer = Timer.periodic(step, (_) => stepDelta(step));
    }
  }

  void _stopClock() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _lastTick = Duration.zero;
  }

  void _onTicker(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? Duration.zero : elapsed - _lastTick;
    _lastTick = elapsed;
    if (dt <= Duration.zero) return;
    // 单帧卡顿保护：最多按 100ms 步进，防止后台切回或掉帧瞬间跳屏
    final clamped = dt.inMilliseconds > 100 ? const Duration(milliseconds: 100) : dt;
    stepDelta(clamped);
  }

  /// 推进一个时间增量 [dt]（公开以便单测精确驱动状态机，不依赖真实时钟）。
  @visibleForTesting
  void stepDelta(Duration dt) {
    if (_disposed || !isRunning || dt <= Duration.zero) return;
    if (_cooldownRemaining > Duration.zero) {
      if (dt <= _cooldownRemaining) {
        _cooldownRemaining -= dt;
        return;
      }
      dt -= _cooldownRemaining;
      _cooldownRemaining = Duration.zero;
    }

    if (isScrollMode) {
      _stepScroll(dt);
    } else {
      _stepPaged(dt);
    }
  }

  void _stepScroll(Duration dt) {
    final deltaPx = _scrollSpeed * (dt.inMicroseconds / Duration.microsecondsPerSecond);
    if (deltaPx <= 0) return;
    AutoScrollStep result;
    _stepping = true;
    try {
      result = onScrollStep?.call(deltaPx) ?? AutoScrollStep.unavailable;
    } finally {
      _stepping = false;
    }
    switch (result) {
      case AutoScrollStep.scrolled:
        _lastAutoActionAt = _now();
        _endHoldElapsed = Duration.zero;
      case AutoScrollStep.unavailable:
        _endHoldElapsed = Duration.zero;
      case AutoScrollStep.reachedEnd:
        _endHoldElapsed += dt;
        if (_endHoldElapsed < _chapterEndHold) return;
        _endHoldElapsed = Duration.zero;
        _stepping = true;
        final advanced = onNextChapter?.call() ?? false;
        _stepping = false;
        if (advanced) {
          _lastAutoActionAt = _now();
          _cooldownRemaining = _chapterSwitchCooldown;
        } else {
          stop();
          onReachedBookEnd?.call();
        }
    }
  }

  void _stepPaged(Duration dt) {
    _turnElapsed += dt;
    final target = Duration(seconds: _turnSeconds);
    if (_turnElapsed < target) {
      _updateTurnProgress();
      return;
    }
    _turnElapsed = Duration.zero;
    progress.value = 0;
    _stepping = true;
    final turned = onTurnNext?.call() ?? false;
    _stepping = false;
    if (turned) {
      _lastAutoActionAt = _now();
    } else {
      stop();
      onReachedBookEnd?.call();
    }
  }

  void _updateTurnProgress() {
    final targetUs = _turnSeconds * Duration.microsecondsPerSecond;
    progress.value = targetUs <= 0 ? 0.0 : (_turnElapsed.inMicroseconds / targetUs).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopClock();
    progress.dispose();
    super.dispose();
  }
}

/// 自动阅读悬浮胶囊控制条（减速 / 暂停·继续 / 加速 / 关闭），自动跟随阅读器配色 [ReaderPalette]。
class ReaderAutoScrollBar extends StatelessWidget {
  const ReaderAutoScrollBar({
    super.key,
    required this.controller,
    required this.palette,
    required this.accent,
    this.embedded = false,
  });

  final ReaderAutoScrollController controller;
  final ReaderPalette palette;
  final Color accent;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final bg = embedded ? Color.alphaBlend(palette.fg.withValues(alpha: 0.05), palette.bg) : Color.alphaBlend(palette.fg.withValues(alpha: 0.09), palette.bg);
    final fg = palette.fg;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final paused = controller.isPaused;
        final content = Row(
          mainAxisSize: embedded ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: hz(context, '减速'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.remove_rounded, size: 20, color: controller.canSlower ? fg : fg.withValues(alpha: 0.3)),
              onPressed: controller.canSlower ? controller.slower : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AppCrossfade(
                duration: AppMotion.instant,
                child: Text(
                  controller.speedLabel,
                  key: ValueKey(controller.speedLabel),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg.withValues(alpha: 0.85), fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
            IconButton(
              tooltip: hz(context, paused ? '继续自动阅读' : '暂停自动阅读'),
              visualDensity: VisualDensity.compact,
              icon: AppIconSwap(
                child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, key: ValueKey(paused), size: 24, color: accent),
              ),
              onPressed: controller.togglePause,
            ),
            IconButton(
              tooltip: hz(context, '加速'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.add_rounded, size: 20, color: controller.canFaster ? fg : fg.withValues(alpha: 0.3)),
              onPressed: controller.canFaster ? controller.faster : null,
            ),
            IconButton(
              tooltip: hz(context, '关闭自动阅读'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 20, color: fg.withValues(alpha: 0.8)),
              onPressed: controller.stop,
            ),
          ],
        );
        if (embedded) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: bg,
              border: Border(bottom: BorderSide(color: fg.withValues(alpha: 0.1))),
            ),
            child: content,
          );
        }
        return Material(
          color: bg,
          elevation: 2,
          shadowColor: Colors.black26,
          shape: StadiumBorder(side: BorderSide(color: fg.withValues(alpha: 0.16))),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: content),
        );
      },
    );
  }
}

/// 翻页模式自动翻页时贴在底部的极细柔和倒计时进度条：
/// 使用独立 [RepaintBoundary] + `CustomPaint(repaint: progress)` 直画，每帧零 Layout 与零 Widget 重建。
class ReaderAutoTurnProgressBar extends StatelessWidget {
  const ReaderAutoTurnProgressBar({
    super.key,
    required this.controller,
    required this.palette,
    required this.accent,
  });

  final ReaderAutoScrollController controller;
  final ReaderPalette palette;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final show = controller.isActive && !controller.isScrollMode;
        final barColor = accent.withValues(alpha: controller.isPaused ? 0.28 : 0.55);
        final trackColor = palette.fg.withValues(alpha: 0.08);
        return AppReveal(
          visible: show,
          offset: Offset.zero,
          beginScale: 1.0,
          duration: AppMotion.fast,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: SizedBox(
                height: 2.5,
                width: double.infinity,
                child: CustomPaint(
                  painter: _AutoTurnBarPainter(
                    progress: controller.progress,
                    barColor: barColor,
                    trackColor: trackColor,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AutoTurnBarPainter extends CustomPainter {
  _AutoTurnBarPainter({
    required this.progress,
    required this.barColor,
    required this.trackColor,
  }) : super(repaint: progress);

  final ValueListenable<double> progress;
  final Color barColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = trackColor);
    final factor = progress.value.clamp(0.0, 1.0);
    if (factor > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width * factor, size.height), Paint()..color = barColor);
    }
  }

  @override
  bool shouldRepaint(_AutoTurnBarPainter old) => old.progress != progress || old.barColor != barColor || old.trackColor != trackColor;
}
