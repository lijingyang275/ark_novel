import 'package:ark_novel/next/reader/auto_scroll.dart';
import 'package:ark_novel/next/reader/reader_bg.dart';
import 'package:ark_novel/next/reader/reader_body.dart' show readableHighlightColor;
import 'package:ark_novel/next/reader/reader_chrome.dart';
import 'package:ark_novel/next/reader/reader_sheets.dart' show ReaderPalette;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReaderAutoScrollController 状态切换与边界行为', () {
    test('滚屏模式：匀速推进、到底停顿后切下一章、无下一章自动停止', () {
      var now = DateTime(2026, 6, 1, 20, 0, 0);
      final scrolledPx = <double>[];
      var stepResult = AutoScrollStep.scrolled;
      var nextChapters = 0;
      var hasNextChapter = true;
      var reachedEndNotified = 0;

      final ctrl = ReaderAutoScrollController(
        now: () => now,
        initialMode: 0,
        initialSpeed: 100,
        onScrollStep: (px) {
          scrolledPx.add(px);
          return stepResult;
        },
        onNextChapter: () {
          nextChapters++;
          return hasNextChapter;
        },
        onReachedBookEnd: () => reachedEndNotified++,
      );
      addTearDown(ctrl.dispose);

      expect(ctrl.isActive, isFalse);
      expect(ctrl.isRunning, isFalse);

      // 启动后按 100 px/s 推进 0.1s -> 10 px
      ctrl.start(mode: 0);
      expect(ctrl.isActive, isTrue);
      expect(ctrl.isRunning, isTrue);
      ctrl.stepDelta(const Duration(milliseconds: 100));
      expect(scrolledPx.single, closeTo(10.0, 1e-6));
      expect(ctrl.isStepping, isTrue);

      // 到底部：未满 800ms 停顿前不切章
      stepResult = AutoScrollStep.reachedEnd;
      ctrl.stepDelta(const Duration(milliseconds: 400));
      expect(nextChapters, 0);
      // 满 800ms 后切到下一章并进入冷却
      ctrl.stepDelta(const Duration(milliseconds: 400));
      expect(nextChapters, 1);
      expect(ctrl.isRunning, isTrue);

      // 冷却期（700ms）内不继续滚屏
      final beforeCount = scrolledPx.length;
      stepResult = AutoScrollStep.scrolled;
      ctrl.stepDelta(const Duration(milliseconds: 300));
      expect(scrolledPx.length, beforeCount);
      ctrl.stepDelta(const Duration(milliseconds: 400));
      ctrl.stepDelta(const Duration(milliseconds: 100));
      expect(scrolledPx.length, beforeCount + 1);

      // 全书最后一章到底且无下一章：自动停止并触发 onReachedBookEnd
      stepResult = AutoScrollStep.reachedEnd;
      hasNextChapter = false;
      ctrl.stepDelta(const Duration(milliseconds: 800));
      expect(ctrl.isActive, isFalse);
      expect(ctrl.isRunning, isFalse);
      expect(reachedEndNotified, 1);
    });

    test('翻页模式：倒计时进度递增、到点自动翻页并重置、末尾自动停止', () {
      var turns = 0;
      var canTurn = true;
      var reachedEnd = 0;

      final ctrl = ReaderAutoScrollController(
        initialMode: 3,
        initialTurnSeconds: 5,
        onTurnNext: () {
          turns++;
          return canTurn;
        },
        onReachedBookEnd: () => reachedEnd++,
      );
      addTearDown(ctrl.dispose);

      ctrl.start(mode: 3);
      ctrl.stepDelta(const Duration(seconds: 2));
      expect(ctrl.progress.value, closeTo(0.4, 1e-6));
      expect(turns, 0);

      ctrl.stepDelta(const Duration(seconds: 3));
      expect(turns, 1);
      expect(ctrl.progress.value, 0.0);
      expect(ctrl.isRunning, isTrue);

      // 无法继续翻页时自动停止
      canTurn = false;
      ctrl.stepDelta(const Duration(seconds: 5));
      expect(turns, 2);
      expect(ctrl.isActive, isFalse);
      expect(reachedEnd, 1);
    });

    test('暂停 / 继续 / 用户交互暂停 / 速度边界与模式切换', () {
      final speeds = <double>[];
      final intervals = <int>[];
      final ctrl = ReaderAutoScrollController(
        initialMode: 0,
        initialSpeed: 20,
        initialTurnSeconds: 3,
        onSpeedChanged: speeds.add,
        onTurnSecondsChanged: intervals.add,
      );
      addTearDown(ctrl.dispose);

      // 滚屏速度下边界：不能再减速
      expect(ctrl.canSlower, isFalse);
      expect(ctrl.canFaster, isTrue);
      ctrl.slower();
      expect(ctrl.scrollSpeed, 20);
      expect(speeds, isEmpty);

      // 加速到上限并校验边界
      for (var i = 0; i < 20; i++) {
        ctrl.faster();
      }
      expect(ctrl.scrollSpeed, ReaderAutoScrollController.maxScrollSpeed);
      expect(ctrl.canFaster, isFalse);

      // 暂停 / 继续 / pauseByUser
      ctrl.start(mode: 0);
      ctrl.pauseByUser();
      expect(ctrl.isActive, isTrue);
      expect(ctrl.isPaused, isTrue);
      ctrl.togglePause();
      expect(ctrl.isPaused, isFalse);
      ctrl.togglePause();
      expect(ctrl.isPaused, isTrue);

      // 切到翻页模式：重置进度，faster 减少秒数、slower 增加秒数
      ctrl.syncPrefs(mode: 1, scrollSpeed: 60, turnSeconds: 3);
      expect(ctrl.isScrollMode, isFalse);
      expect(ctrl.canFaster, isFalse); // 已是最快 3 秒
      expect(ctrl.canSlower, isTrue);
      ctrl.faster();
      expect(ctrl.turnSeconds, 3);
      expect(intervals, isEmpty);

      ctrl.slower();
      expect(ctrl.turnSeconds, 4);
      expect(intervals, [4]);

      for (var i = 0; i < 40; i++) {
        ctrl.slower();
      }
      expect(ctrl.turnSeconds, ReaderAutoScrollController.maxTurnSeconds);
      expect(ctrl.canSlower, isFalse);

      ctrl.stop();
      expect(ctrl.isActive, isFalse);
      expect(ctrl.progress.value, 0.0);
    });

    testWidgets('ReaderAutoScrollBar 响应暂停/继续、调速与关闭', (t) async {
      final ctrl = ReaderAutoScrollController(initialMode: 3, initialTurnSeconds: 8);
      addTearDown(ctrl.dispose);
      ctrl.start(mode: 3);

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReaderAutoScrollBar(
                controller: ctrl,
                palette: const ReaderPalette(Color(0xFFF6F1E7), Color(0xFF2B2A27)),
                accent: Colors.teal,
              ),
            ),
          ),
        ),
      );

      expect(find.text('8 秒/页'), findsOneWidget);
      await t.tap(find.byTooltip('加速'));
      await t.pump();
      expect(find.text('7 秒/页'), findsOneWidget);

      await t.tap(find.byTooltip('暂停自动阅读'));
      await t.pump();
      expect(ctrl.isPaused, isTrue);
      expect(find.byTooltip('继续自动阅读'), findsOneWidget);

      await t.tap(find.byTooltip('关闭自动阅读'));
      await t.pump();
      expect(ctrl.isActive, isFalse);
    });
  });

  group('本卷剩余预计时间 ETA 与页眉页脚字段', () {
    test('按个人阅读速度或默认 500 字/分钟估算，数据不足优雅回退且永不为负', () {
      // 当前章 3000 字读到一半（剩 1500 字）+ 后面两章各 3000 字（已缓存）= 7500 字，按 500 字/分 = 15 分钟 = 900 秒
      final sec = estimateVolumeRemainingSeconds(
        currentChapterChars: 3000,
        currentChapterFraction: 0.5,
        remainingCids: const ['c2', 'c3'],
        cachedLengthOf: (cid) => 3000,
      );
      expect(sec, 900);
      expect(formatVolumeEta(sec), '本卷约剩 15 分钟');

      // 使用个人速度 600 字/分 -> 7500 字 = 12.5 分钟 = 750 秒 -> 四舍五入 13 分钟
      final secPersonal = estimateVolumeRemainingSeconds(
        currentChapterChars: 3000,
        currentChapterFraction: 0.5,
        remainingCids: const ['c2', 'c3'],
        cachedLengthOf: (cid) => 3000,
        personalCharsPerMinute: 600,
      );
      expect(secPersonal, 750);
      expect(formatVolumeEta(secPersonal), '本卷约剩 13 分钟');

      // 未缓存章节回退到单章均时（每章 600 秒）
      final secAvg = estimateVolumeRemainingSeconds(
        currentChapterChars: 2500,
        currentChapterFraction: 1.0,
        remainingCids: const ['c2', 'c3', 'c4'],
        cachedLengthOf: (_) => null,
        avgSecondsPerChapter: 600,
      );
      expect(secAvg, 1800);
      expect(formatVolumeEta(secAvg), '本卷约剩 30 分钟');

      // 超过 1 小时格式化
      expect(formatVolumeEta(4500), '本卷约剩 1 小时 15 分');
      expect(formatVolumeEta(3600), '本卷约剩 1 小时');
      expect(formatVolumeEta(25), '本卷约剩 <1 分钟');
      expect(formatVolumeEta(0), '本卷即将读完');

      // 数据完全不足（当前章无字且无缓存、无均时）：返回 null 并回退为本卷进度或空串
      final insufficient = estimateVolumeRemainingSeconds(
        currentChapterChars: 0,
        currentChapterFraction: 0,
        remainingCids: const ['c2'],
        cachedLengthOf: (_) => null,
      );
      expect(insufficient, isNull);
      expect(formatVolumeEta(null, fallbackVolumeProgress: 0.42), '本卷 42%');
      expect(formatVolumeEta(null), '');
    });

    testWidgets('ReaderBackground 内置 4 档纹理均可正常渲染并支持 evictTextureCache', (t) async {
      addTearDown(ReaderBackground.evictTextureCache);
      for (final texture in const [0, 1, 2, 3]) {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: ReaderBackground(
                  baseColor: const Color(0xFFF6F1E7),
                  fgColor: const Color(0xFF2B2A27),
                  texture: texture,
                ),
              ),
            ),
          ),
        );
        expect(t.takeException(), isNull, reason: 'texture=$texture');
      }
      ReaderBackground.evictTextureCache();
      await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(t.takeException(), isNull);
    });

    testWidgets('ReaderAutoTurnProgressBar 使用独立 RepaintBoundary + CustomPaint 绘制进度条', (t) async {
      final ctrl = ReaderAutoScrollController(initialMode: 3, initialTurnSeconds: 10);
      addTearDown(ctrl.dispose);
      ctrl.start(mode: 3);
      ctrl.stepDelta(const Duration(seconds: 4));

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ReaderAutoTurnProgressBar(
                controller: ctrl,
                palette: const ReaderPalette(Color(0xFFF6F1E7), Color(0xFF2B2A27)),
                accent: Colors.teal,
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.descendant(of: find.byType(ReaderAutoTurnProgressBar), matching: find.byType(CustomPaint)), findsOneWidget);
      expect(find.descendant(of: find.byType(ReaderAutoTurnProgressBar), matching: find.byType(FractionallySizedBox)), findsNothing);
      ctrl.stepDelta(const Duration(seconds: 2));
      await t.pump();
      ctrl.stop();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('ReaderChromeRow 正确渲染自定义字段组合', (t) async {
      final status = ValueNotifier<String>('21:30  电量 88%');
      addTearDown(status.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderChromeRow(
              leftField: ReaderChromeField.bookTitle,
              rightField: ReaderChromeField.volumeEta,
              style: const TextStyle(fontSize: 11),
              chapterTitle: '第一章',
              bookTitle: '狼与香辛料',
              status: status,
              pageProgress: '3/10 · 40%',
              volumeEta: '本卷约剩 25 分钟',
              volumeProgressText: '本卷 40%',
            ),
          ),
        ),
      );
      expect(find.text('狼与香辛料'), findsOneWidget);
      expect(find.text('本卷约剩 25 分钟'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
    });

    test('readableHighlightColor：浅色纸面压暗浅黄/黄绿，深色背景提亮深色字', () {
      const paleLime = Color(0xFFC0CA33);
      final onLight = readableHighlightColor(paleLime, darkSurface: false);
      expect(HSLColor.fromColor(onLight).lightness, lessThanOrEqualTo(0.35));

      const deepIndigo = Color(0xFF283593);
      final onDark = readableHighlightColor(deepIndigo, darkSurface: true);
      expect(HSLColor.fromColor(onDark).lightness, greaterThanOrEqualTo(0.67));
    });
  });
}
