import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/pages/stats_page.dart';
import 'package:ark_novel/next/stats.dart';

void main() {
  test('连续阅读天数：今天没读从昨天数，断一天就停', () {
    final now = DateTime(2026, 3, 10, 20);
    expect(readingStreak({'2026-03-10': 60, '2026-03-09': 60, '2026-03-08': 0, '2026-03-07': 60}, now), 2);
    expect(readingStreak({'2026-03-09': 60, '2026-03-08': 60}, now), 2);
    expect(readingStreak({'2026-03-08': 60}, now), 0);
    // 跨月
    expect(readingStreak({'2026-03-01': 60, '2026-02-28': 60}, DateTime(2026, 3, 1)), 2);
  });

  test('读一章平均多久：不到一分钟的章不算，不到两章返回 null', () {
    expect(secondsPerChapter([{'d1': 300}, {'d1': 200, 'd2': 100}, {'d1': 30}]), 300);
    expect(secondsPerChapter([{'d1': 300}, {'d1': 30}]), isNull);
  });

  test('阅读速度：字数除以时间，不到三章返回 null', () {
    expect(charsPerMinute([(6000, 600), (3000, 300), (4000, 400), (9999, 10)]), 600);
    expect(charsPerMinute([(6000, 600), (3000, 300)]), isNull);
  });

  test('时长格式化：59 分零几秒进位成 1 小时而非 60 分钟', () {
    expect(ReadingStats.formatDuration(0), '0 分钟');
    expect(ReadingStats.formatDuration(65), '2 分钟');
    expect(ReadingStats.formatDuration(3540), '59 分钟');
    expect(ReadingStats.formatDuration(3550), '1 小时 0 分');
    expect(ReadingStats.formatDuration(3550, compact: true), '1.0 小时');
  });
}
