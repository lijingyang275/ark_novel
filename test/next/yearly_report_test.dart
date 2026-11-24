import 'dart:io';

import 'package:ark_novel/next/app_prefs.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/pages/yearly_report_page.dart';
import 'package:ark_novel/next/session.dart';
import 'package:ark_novel/next/stats.dart';
import 'package:ark_novel/next/volumes.dart' show Vol;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  group('readingGoalProgress 阅读目标百分比与边界值', () {
    test('未开启、零值与负值返回 0% 且未达标', () {
      expect(readingGoalProgress(30, 0), (ratio: 0.0, percent: 0, reached: false));
      expect(readingGoalProgress(30, -10), (ratio: 0.0, percent: 0, reached: false));
      expect(readingGoalProgress(0, 30), (ratio: 0.0, percent: 0, reached: false));
      expect(readingGoalProgress(-5, 30), (ratio: 0.0, percent: 0, reached: false));
    });

    test('正常进度向下取整，达标前不提前进位到 100%，超额后封顶 1.0 / 100%', () {
      expect(readingGoalProgress(15, 30), (ratio: 0.5, percent: 50, reached: false));
      // 差 1 分钟未达标：96% 而非 100%
      final almost = readingGoalProgress(29, 30);
      expect(almost.percent, 96);
      expect(almost.reached, isFalse);
      expect(almost.ratio, closeTo(29 / 30, 1e-6));

      // 恰好达标与超额达标
      expect(readingGoalProgress(30, 30), (ratio: 1.0, percent: 100, reached: true));
      expect(readingGoalProgress(75, 30), (ratio: 1.0, percent: 100, reached: true));
    });
  });

  group('YearlySummary 年度阅读聚合纯函数', () {
    final infos = <String, ({String title, String author, String img})>{
      '1': (title: '狼与香辛料', author: '支仓冻砂', img: ''),
      '2': (title: '青春猪头少年', author: '鸭志田一', img: ''),
      '3': (title: '樱花庄的宠物女孩', author: '鸭志田一', img: ''),
      '4': (title: '冰菓', author: '米泽穗信', img: ''),
      '5': (title: '无职转生', author: '理不尽な孫の手', img: ''),
      '6': (title: '间谍教室', author: '竹町', img: ''),
    };
    ({String title, String author, String img}) infoOf(String aid) => infos[aid] ?? (title: '书 $aid', author: '', img: '');

    test('空数据时返回全零指标与温和默认称号', () {
      final s = buildYearlySummary(
        year: 2026,
        perDay: const {},
        chapterSecondsByBook: const {},
        doneVolumes: const [],
        bookInfoOf: infoOf,
        bookRatingOf: (_) => 0,
        volumeRatingOf: (_, _) => 0,
      );
      expect(s.isEmpty, isTrue);
      expect(s.totalSeconds, 0);
      expect(s.readingDays, 0);
      expect(s.longestStreak, 0);
      expect(s.volumesDone, 0);
      expect(s.booksTouched, 0);
      expect(s.estimatedChars, 0);
      expect(s.monthlySeconds, List.filled(12, 0));
      expect(s.peakMonth, isNull);
      expect(s.bestDayKey, isNull);
      expect(s.topBooks, isEmpty);
      expect(s.topAuthor, isNull);
      expect(s.topRated, isEmpty);
      expect(s.personaTitle, isNotEmpty);
    });

    test('单年聚合：最长连签（含跨月/闰年）、最沉迷月份、单日纪录、Top 5 书、最常读作者与高分榜', () {
      final perDay = <String, int>{
        // 第一段连签：2 天
        '2024-01-10': 1200,
        '2024-01-11': 1800,
        // 第二段连签：跨越闰年 2 月 29 日，共 4 天
        '2024-02-27': 900,
        '2024-02-28': 1500,
        '2024-02-29': 3600,
        '2024-03-01': 2400,
        // 8 月高产（峰值月与单日纪录）
        '2024-08-15': 10800,
        '2024-08-20': 7200,
      };
      final ch = <String, Map<String, Map<String, int>>>{
        '1': {'c1': {'2024-08-15': 6000, '2024-08-20': 2000}}, // 8000s 支仓冻砂
        '2': {'c1': {'2024-02-29': 3600, '2024-03-01': 2400}}, // 6000s 鸭志田一
        '3': {'c1': {'2024-08-15': 4800, '2024-08-20': 1200}}, // 6000s 鸭志田一 -> 合计 12000s，胜过支仓冻砂
        '4': {'c1': {'2024-01-10': 1200, '2024-01-11': 1800}}, // 3000s
        '5': {'c1': {'2024-02-27': 900, '2024-02-28': 1500}}, // 2400s
        '6': {'c1': {'2024-08-20': 4000}}, // 4000s（排第 4，把 '5' 挤出 Top 5）
      };
      final done = <(String, int, String, int)>[
        ('1', 0, '第一卷', DateTime(2024, 8, 16).millisecondsSinceEpoch),
        ('2', 0, '第一卷', DateTime(2024, 3, 2).millisecondsSinceEpoch),
        ('4', 0, '第一卷', DateTime(2024, 1, 12).millisecondsSinceEpoch),
      ];

      final s = buildYearlySummary(
        year: 2024,
        perDay: perDay,
        chapterSecondsByBook: ch,
        doneVolumes: done,
        bookInfoOf: infoOf,
        bookRatingOf: (aid) => aid == '3' ? 4 : (aid == '4' ? 3 : 0),
        volumeRatingOf: (aid, vol) => aid == '1' ? 5 : (aid == '2' ? 4 : 0),
        charsPerMinute: 600,
      );

      expect(s.isEmpty, isFalse);
      expect(s.totalSeconds, 1200 + 1800 + 900 + 1500 + 3600 + 2400 + 10800 + 7200);
      expect(s.readingDays, 8);
      expect(s.longestStreak, 4);
      expect(s.volumesDone, 3);
      expect(s.booksTouched, 6);
      expect(s.estimatedChars, (s.totalSeconds * 600 / 60).round());
      expect(s.peakMonth, 8);
      expect(s.peakMonthSeconds, 18000);
      expect(s.monthlySeconds[0], 3000);
      expect(s.monthlySeconds[1], 6000);
      expect(s.monthlySeconds[2], 2400);
      expect(s.monthlySeconds[7], 18000);
      expect(s.bestDayKey, '2024-08-15');
      expect(s.bestDaySeconds, 10800);

      // Top 5 书按时长排序（6 本中只保留前 5）
      expect(s.topBooks.map((b) => b.aid).toList(), ['1', '2', '3', '6', '4']);
      // 最常读作者按同作者多本书累加
      expect(s.topAuthor?.author, '鸭志田一');
      expect(s.topAuthor?.bookCount, 2);
      expect(s.topAuthor?.seconds, 12000);

      // 高分榜：'1' 卷 5 星、'2' 卷 4 星、'3' 书 4 星；'4' 只有 3 星不入选
      expect(s.topRated.map((e) => (e.aid, e.stars, e.volumeTitle)).toList(), [
        ('1', 5, '第一卷'),
        ('2', 4, '第一卷'),
        ('3', 4, null),
      ]);
    });

    test('跨年隔离与老数据比例回退 + 可选年份排序', () {
      final perDay = {
        '2024-12-31': 3600,
        '2025-01-01': 1800,
        '2025-06-15': 3600,
        '2026-02-01': 900,
      };
      final done = [
        ('1', 0, '第一卷', DateTime(2025, 6, 15).millisecondsSinceEpoch),
        ('2', 0, '第一卷', DateTime(2026, 2, 1).millisecondsSinceEpoch),
      ];
      final years = yearlyReportYears(
        perDay: perDay,
        allDone: [for (final d in done) (d.$1, d.$2, Vol(d.$3, const ['1'], null), d.$4)],
      );
      expect(years, [2026, 2025, 2024]);

      // 2025 年无 chapterSecondsByBook，走 fallbackBookDays / fallbackPerBook 比例回退
      final s2025 = buildYearlySummary(
        year: 2025,
        perDay: perDay,
        chapterSecondsByBook: const {},
        doneVolumes: done,
        bookInfoOf: infoOf,
        bookRatingOf: (_) => 0,
        volumeRatingOf: (_, _) => 0,
        fallbackPerBook: const {'1': 9000},
        fallbackBookDays: const {'1': ['2024-12-31', '2025-01-01', '2025-06-15']},
      );
      expect(s2025.totalSeconds, 5400);
      expect(s2025.readingDays, 2);
      expect(s2025.longestStreak, 1); // 2024-12-31 不算进 2025 连签
      expect(s2025.volumesDone, 1);
      expect(s2025.topBooks.single.aid, '1');
      // 3 天中有 2 天在 2025 -> 9000 * 2 / 3 = 6000
      expect(s2025.topBooks.single.seconds, 6000);
    });
  });

  group('StatsPage 目标入口与 YearlyReportPage 界面冒烟测试', () {
    late Directory dir;
    late SessionStore store;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('ark_yearly_ui_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dir.path,
      );
      store = await SessionStore.open();
      await ChapterCache.open();
    });

    tearDownAll(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('StatsPage 展示每日目标环、年度目标进度条与年度报告入口，YearlyReportPage 正常渲染与切年', (t) async {
      final now = DateTime.now();
      final todayKey = ReadingStats.dayKey(now);
      final prevYearKey = '${now.year - 1}-05-10';
      await t.runAsync(() async {
        final box = Hive.box('session');
        await box.clear();
        await box.put('vols:10', [
          {'t': '第一卷', 'c': ['1'], 'i': null},
        ]);
        await box.put('vdone:10', {'第一卷': now.millisecondsSinceEpoch});
        await box.put('vrate:10', {'第一卷': 5});
        await box.put('stats:meta', {
          '10': {'t': '狼与香辛料', 'a': '支仓冻砂', 'i': ''},
        });
        await box.put('stats:day', {todayKey: 1800, prevYearKey: 3600});
        await box.put('stats:book', {'10': 5400});
        await box.put('stats:ch:10', {
          '1': {todayKey: 1800, prevYearKey: 3600},
        });
        await AppPrefs.write(P.statsDailyGoal, 60);
        await AppPrefs.write(P.statsYearlyVolGoal, 10);
      });

      await t.pumpWidget(
        ProviderScope(
          overrides: [sessionStoreProvider.overrideWithValue(store)],
          child: const MaterialApp(home: StatsPage()),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('30/60 分'), findsOneWidget);
      expect(find.text('年度报告'), findsOneWidget);
      expect(find.text('${now.year} 年度阅读报告'), findsOneWidget);

      await t.scrollUntilVisible(find.text('年度目标进度 1 / 10 卷'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('年度目标进度 1 / 10 卷'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);

      // 渲染 YearlyReportPage 并切换年份
      await t.pumpWidget(
        ProviderScope(
          overrides: [sessionStoreProvider.overrideWithValue(store)],
          child: MaterialApp(home: YearlyReportPage(year: now.year)),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      expect(find.text('${now.year} 年度报告'), findsOneWidget);
      expect(find.text('年度沉浸 Top 5'), findsOneWidget);
      expect(find.text('年度高分神作榜'), findsOneWidget);
      expect(find.byTooltip('保存为图片并分享'), findsOneWidget);

      // 点击年份 chip 切换到去年
      await t.tap(find.text('${now.year - 1} 年'));
      await t.pump();
      expect(find.text('${now.year - 1} 年度报告'), findsOneWidget);
    });
  });
}
