import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../cache.dart';
import '../local_books.dart';
import '../read_state.dart';
import '../routes.dart';
import '../stats.dart';
import '../text.dart';
import '../theme.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Vol, Volumes, volumeChangesProvider;
import '../widgets.dart';
import 'stats_page.dart' show charsPerMinute;

const _gold = Color(0xFFFFC53D);

/// 年度阅读榜单中的单本书条目。
class YearlyBookEntry {
  const YearlyBookEntry({
    required this.aid,
    required this.title,
    required this.author,
    required this.img,
    required this.seconds,
    this.days = 0,
  });

  final String aid;
  final String title;
  final String author;
  final String img;
  final int seconds;
  final int days;
}

/// 年度高分神作榜条目（当年读完或读过的 4~5 星卷/书）。
class YearlyRatedEntry {
  const YearlyRatedEntry({
    required this.aid,
    required this.title,
    this.volumeTitle,
    required this.img,
    required this.stars,
    this.volIndex,
  });

  final String aid;
  final String title;
  final String? volumeTitle;
  final String img;
  final int stars;
  final int? volIndex;
}

/// 年度最常读作者。
class YearlyAuthorEntry {
  const YearlyAuthorEntry({required this.author, required this.seconds, required this.bookCount});

  final String author;
  final int seconds;
  final int bookCount;
}

/// 年度阅读总结数据模型（纯值对象，由 [buildYearlySummary] 纯函数汇总生成）。
class YearlySummary {
  const YearlySummary({
    required this.year,
    required this.totalSeconds,
    required this.readingDays,
    required this.longestStreak,
    required this.volumesDone,
    required this.booksTouched,
    required this.estimatedChars,
    required this.monthlySeconds,
    required this.peakMonth,
    required this.peakMonthSeconds,
    required this.bestDayKey,
    required this.bestDaySeconds,
    required this.topBooks,
    required this.topAuthor,
    required this.topRated,
    required this.personaTitle,
    required this.personaSubtitle,
    required this.keywords,
  });

  final int year;
  final int totalSeconds;
  final int readingDays;
  final int longestStreak;
  final int volumesDone;
  final int booksTouched;
  final int estimatedChars;

  /// 1~12 月各月阅读秒数（固定长度 12，下标 0 对应 1 月）。
  final List<int> monthlySeconds;

  /// 最沉迷月份（1~12），无数据时为 null。
  final int? peakMonth;
  final int peakMonthSeconds;

  /// 单日最长阅读纪录（`yyyy-MM-dd`），无数据时为 null。
  final String? bestDayKey;
  final int bestDaySeconds;

  /// 当年阅读时长 Top 5 书。
  final List<YearlyBookEntry> topBooks;

  /// 当年最常读的作者（无作者信息时为 null）。
  final YearlyAuthorEntry? topAuthor;

  /// 当年 4~5 星高分卷/书。
  final List<YearlyRatedEntry> topRated;

  /// 趣味轻小说读者称号与说明、关键词。
  final String personaTitle;
  final String personaSubtitle;
  final List<String> keywords;

  bool get isEmpty => totalSeconds == 0 && volumesDone == 0 && booksTouched == 0;

  /// 从本机 Hive 统计与分卷数据实时汇总指定年份。
  static YearlySummary fromStore(int year) {
    final perDay = ReadingStats.perDay();
    final perBook = ReadingStats.perBook();
    final chapterBooks = ReadingStats.chapterBooks().toList();
    final chapterSecondsByBook = <String, Map<String, Map<String, int>>>{
      for (final aid in chapterBooks) aid: ReadingStats.chapterSeconds(aid),
    };
    final allAids = {...perBook.keys, ...chapterBooks};
    final fallbackBookDays = <String, List<String>>{
      for (final aid in allAids) aid: ReadingStats.bookDays(aid),
    };
    final doneVolumes = <(String, int, String, int)>[
      for (final e in Volumes.allDone()) (e.$1, e.$2, e.$3.title, e.$4),
    ];
    final hasCache = Hive.isBoxOpen('chapter_index');
    final cpm = charsPerMinute([
      for (final aid in chapterBooks)
        for (final e in chapterSecondsByBook[aid]!.entries)
          if (ReadState.isRead(aid, e.key))
            if ((isLocalAid(aid) ? LocalBooks.chapterLength(aid, e.key) : (hasCache ? ChapterCache.length(aid, e.key) : null)) case final n?)
              (n, e.value.values.fold(0, (a, b) => a + b)),
    ]);
    return buildYearlySummary(
      year: year,
      perDay: perDay,
      chapterSecondsByBook: chapterSecondsByBook,
      doneVolumes: doneVolumes,
      bookInfoOf: ReadingStats.info,
      bookRatingOf: ReadState.rating,
      volumeRatingOf: Volumes.rating,
      fallbackPerBook: perBook,
      fallbackBookDays: fallbackBookDays,
      charsPerMinute: cpm,
    );
  }
}

DateTime? _parseDayKey(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null || m < 1 || m > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, m, d);
  return dt.year == y && dt.month == m && dt.day == d ? dt : null;
}

/// 列出所有有阅读记录或完卷记录的年份（倒序排列）。
List<int> yearlyReportYears({
  required Map<String, int> perDay,
  required Iterable<(String, int, Vol, int)> allDone,
  int? fallbackYear,
}) {
  final years = <int>{};
  for (final e in perDay.entries) {
    if (e.value <= 0) continue;
    final dt = _parseDayKey(e.key);
    if (dt != null) years.add(dt.year);
  }
  for (final e in allDone) {
    years.add(DateTime.fromMillisecondsSinceEpoch(e.$4).year);
  }
  if (years.isEmpty && fallbackYear != null) years.add(fallbackYear);
  return years.toList()..sort((a, b) => b.compareTo(a));
}

/// 纯函数汇总年度阅读数据（无 Hive/Widget 依赖，便于单元测试）。
YearlySummary buildYearlySummary({
  required int year,
  required Map<String, int> perDay,
  required Map<String, Map<String, Map<String, int>>> chapterSecondsByBook,
  required List<(String aid, int volIndex, String volTitle, int doneAtMs)> doneVolumes,
  required ({String title, String author, String img}) Function(String aid) bookInfoOf,
  required int Function(String aid) bookRatingOf,
  required int Function(String aid, String volTitle) volumeRatingOf,
  Map<String, int> fallbackPerBook = const {},
  Map<String, List<String>> fallbackBookDays = const {},
  int? charsPerMinute,
}) {
  final prefix = '$year-';
  final monthly = List<int>.filled(12, 0);
  final activeDates = <DateTime>[];
  var totalSeconds = 0;
  String? bestDayKey;
  var bestDaySeconds = 0;

  final sortedDays = perDay.entries.where((e) => e.key.startsWith(prefix) && e.value > 0).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final e in sortedDays) {
    final dt = _parseDayKey(e.key);
    if (dt == null || dt.year != year) continue;
    totalSeconds += e.value;
    monthly[dt.month - 1] += e.value;
    activeDates.add(dt);
    if (e.value > bestDaySeconds) {
      bestDaySeconds = e.value;
      bestDayKey = e.key;
    }
  }

  // 计算该年内最长连续阅读天数（按日历递增，避免夏令时偏移）
  var longestStreak = 0;
  var curStreak = 0;
  DateTime? prevDate;
  for (final d in activeDates) {
    if (prevDate != null && DateTime(prevDate.year, prevDate.month, prevDate.day + 1) == d) {
      curStreak++;
    } else {
      curStreak = 1;
    }
    if (curStreak > longestStreak) longestStreak = curStreak;
    prevDate = d;
  }

  int? peakMonth;
  var peakMonthSeconds = 0;
  for (var m = 0; m < 12; m++) {
    if (monthly[m] > peakMonthSeconds) {
      peakMonthSeconds = monthly[m];
      peakMonth = m + 1;
    }
  }

  // 当年读完的卷
  final yearDone = doneVolumes.where((e) => DateTime.fromMillisecondsSinceEpoch(e.$4).year == year).toList();

  // 按章节秒数汇总当年每本书的阅读时长与天数
  final bookSec = <String, int>{};
  final bookDays = <String, Set<String>>{};
  for (final be in chapterSecondsByBook.entries) {
    var sec = 0;
    final days = <String>{};
    for (final ch in be.value.values) {
      for (final de in ch.entries) {
        if (!de.key.startsWith(prefix) || de.value <= 0) continue;
        sec += de.value;
        days.add(de.key);
      }
    }
    if (sec > 0) {
      bookSec[be.key] = sec;
      bookDays[be.key] = days;
    }
  }

  // 老数据回退：按章记时上线之前只有 bookDays 与 perBook，按该年天数占比估算
  final touchedAids = <String>{...bookSec.keys, for (final v in yearDone) v.$1};
  for (final e in fallbackBookDays.entries) {
    final allDays = e.value;
    final inYear = allDays.where((d) => d.startsWith(prefix)).toSet();
    if (inYear.isEmpty) continue;
    touchedAids.add(e.key);
    if (!bookSec.containsKey(e.key)) {
      final totalBook = fallbackPerBook[e.key] ?? 0;
      if (totalBook > 0 && allDays.isNotEmpty) {
        final est = (totalBook * inYear.length / allDays.length).round();
        if (est > 0) {
          bookSec[e.key] = est;
          bookDays[e.key] = inYear;
        }
      }
    }
  }
  // 若按章与按天都没有（极早期仅存在 perBook 且当年有完卷），用完卷书籍兜底
  if (bookSec.isEmpty && yearDone.isNotEmpty) {
    for (final aid in yearDone.map((v) => v.$1).toSet()) {
      final sec = fallbackPerBook[aid] ?? 0;
      if (sec > 0) bookSec[aid] = sec;
    }
  }

  final infoCache = <String, ({String title, String author, String img})>{};
  ({String title, String author, String img}) infoOf(String aid) => infoCache.putIfAbsent(aid, () => bookInfoOf(aid));

  final rankedAids = bookSec.keys.toList()
    ..sort((a, b) {
      final cmp = bookSec[b]!.compareTo(bookSec[a]!);
      if (cmp != 0) return cmp;
      final dCmp = (bookDays[b]?.length ?? 0).compareTo(bookDays[a]?.length ?? 0);
      return dCmp != 0 ? dCmp : a.compareTo(b);
    });

  final topBooks = <YearlyBookEntry>[
    for (final aid in rankedAids.take(5))
      () {
        final info = infoOf(aid);
        return YearlyBookEntry(
          aid: aid,
          title: info.title,
          author: info.author,
          img: info.img,
          seconds: bookSec[aid]!,
          days: bookDays[aid]?.length ?? 0,
        );
      }(),
  ];

  // 最常读作者（仅统计有作者名的书）
  final authorSec = <String, int>{};
  final authorBooks = <String, Set<String>>{};
  for (final aid in rankedAids) {
    final author = infoOf(aid).author.trim();
    if (author.isEmpty) continue;
    authorSec[author] = (authorSec[author] ?? 0) + bookSec[aid]!;
    (authorBooks[author] ??= <String>{}).add(aid);
  }
  YearlyAuthorEntry? topAuthor;
  if (authorSec.isNotEmpty) {
    final sortedAuthors = authorSec.keys.toList()
      ..sort((a, b) {
        final cmp = authorSec[b]!.compareTo(authorSec[a]!);
        if (cmp != 0) return cmp;
        final cCmp = authorBooks[b]!.length.compareTo(authorBooks[a]!.length);
        return cCmp != 0 ? cCmp : a.compareTo(b);
      });
    final best = sortedAuthors.first;
    topAuthor = YearlyAuthorEntry(author: best, seconds: authorSec[best]!, bookCount: authorBooks[best]!.length);
  }

  // 年度高分神作榜（当年读完的 4~5 星卷，及当年涉猎的 4~5 星书）
  final rated = <YearlyRatedEntry>[];
  final ratedBookIds = <String>{};
  for (final (aid, volIndex, volTitle, _) in yearDone) {
    final vStars = volumeRatingOf(aid, volTitle);
    if (vStars >= 4) {
      final info = infoOf(aid);
      rated.add(YearlyRatedEntry(aid: aid, title: info.title, volumeTitle: volTitle, img: info.img, stars: vStars, volIndex: volIndex));
      ratedBookIds.add(aid);
    }
  }
  for (final aid in touchedAids) {
    if (ratedBookIds.contains(aid)) continue;
    final bStars = bookRatingOf(aid);
    if (bStars >= 4) {
      final info = infoOf(aid);
      rated.add(YearlyRatedEntry(aid: aid, title: info.title, img: info.img, stars: bStars));
      ratedBookIds.add(aid);
    }
  }
  rated.sort((a, b) {
    final sCmp = b.stars.compareTo(a.stars);
    if (sCmp != 0) return sCmp;
    final tCmp = (bookSec[b.aid] ?? 0).compareTo(bookSec[a.aid] ?? 0);
    return tCmp != 0 ? tCmp : a.aid.compareTo(b.aid);
  });

  final cpm = (charsPerMinute != null && charsPerMinute >= 100 && charsPerMinute <= 5000) ? charsPerMinute : 500;
  final estimatedChars = (totalSeconds * cpm / 60).round();

  final (personaTitle, personaSubtitle, keywords) = _derivePersona(
    totalSeconds: totalSeconds,
    readingDays: activeDates.length,
    longestStreak: longestStreak,
    volumesDone: yearDone.length,
    booksTouched: touchedAids.length,
    peakMonth: peakMonth,
    bestDaySeconds: bestDaySeconds,
    topBooks: topBooks,
    topAuthor: topAuthor,
    topRatedCount: rated.length,
  );

  return YearlySummary(
    year: year,
    totalSeconds: totalSeconds,
    readingDays: activeDates.length,
    longestStreak: longestStreak,
    volumesDone: yearDone.length,
    booksTouched: touchedAids.length,
    estimatedChars: estimatedChars,
    monthlySeconds: List<int>.unmodifiable(monthly),
    peakMonth: peakMonth,
    peakMonthSeconds: peakMonthSeconds,
    bestDayKey: bestDayKey,
    bestDaySeconds: bestDaySeconds,
    topBooks: List<YearlyBookEntry>.unmodifiable(topBooks),
    topAuthor: topAuthor,
    topRated: List<YearlyRatedEntry>.unmodifiable(rated.take(8)),
    personaTitle: personaTitle,
    personaSubtitle: personaSubtitle,
    keywords: List<String>.unmodifiable(keywords),
  );
}

(String, String, List<String>) _derivePersona({
  required int totalSeconds,
  required int readingDays,
  required int longestStreak,
  required int volumesDone,
  required int booksTouched,
  required int? peakMonth,
  required int bestDaySeconds,
  required List<YearlyBookEntry> topBooks,
  required YearlyAuthorEntry? topAuthor,
  required int topRatedCount,
}) {
  if (totalSeconds == 0 && volumesDone == 0) {
    return ('蓄势待发的旅人', '翻开新的一页，今年的故事正等你启程', const ['静待开卷']);
  }

  final String title;
  final String subtitle;
  if (totalSeconds >= 300 * 3600 || volumesDone >= 50) {
    title = '异世界大贤者';
    subtitle = '你的阅读量足以建起一座私人轻小说档案馆';
  } else if (longestStreak >= 30) {
    title = '契约不灭的朝圣者';
    subtitle = '连续 $longestStreak 天未曾中断，阅读早已融入日常';
  } else if (bestDaySeconds >= 5 * 3600) {
    title = '一气呵成的通宵骑士';
    subtitle = '遇上好故事就绝不松手，单日最高狂读 ${ReadingStats.formatDuration(bestDaySeconds)}';
  } else if (volumesDone >= 20) {
    title = '轻小说资深收藏家';
    subtitle = '全年通关 $volumesDone 卷，在无数世界里留下足迹';
  } else if (booksTouched >= 12) {
    title = '穿梭万界的漫游者';
    subtitle = '一年翻阅 $booksTouched 部作品，好奇心永不停歇';
  } else if (topBooks.isNotEmpty && totalSeconds > 0 && topBooks.first.seconds / totalSeconds >= 0.45) {
    title = '专一深情的忠实读者';
    subtitle = '偏爱长情陪伴，把最多时光献给了《${topBooks.first.title}》';
  } else if (totalSeconds >= 50 * 3600) {
    title = '稳步前行的冒险者';
    subtitle = '在字里行间稳扎稳打，积攒了厚实的阅读旅程';
  } else {
    title = '与文字相伴的旅人';
    subtitle = '每一次翻页，都是忙里偷闲的一小段异世界时光';
  }

  final keywords = <String>[
    if (longestStreak >= 7) '连读 $longestStreak 天',
    if (peakMonth != null) '$peakMonth月最沉迷',
    if (volumesDone >= 5) '通关 $volumesDone 卷',
    if (bestDaySeconds >= 2 * 3600) '单日高能',
    if (topRatedCount >= 2) '神作鉴赏家',
    if (topAuthor != null) '偏爱 ${topAuthor.author}',
  ];
  if (keywords.isEmpty) {
    keywords.add(readingDays > 0 ? '打卡 $readingDays 天' : '读完 $volumesDone 卷');
  }
  return (title, subtitle, keywords.take(4).toList());
}

/// 年度阅读总结页（Wrapped）：杂志风长图视觉，支持切换年份与保存长图分享。
class YearlyReportPage extends ConsumerStatefulWidget {
  const YearlyReportPage({super.key, this.year});

  final int? year;

  @override
  ConsumerState<YearlyReportPage> createState() => _YearlyReportPageState();
}

class _YearlyReportPageState extends ConsumerState<YearlyReportPage> {
  final _shot = GlobalKey();
  late int _year;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    final years = _availableYears();
    _year = widget.year ?? years.first;
  }

  List<int> _availableYears() => yearlyReportYears(
    perDay: ReadingStats.perDay(),
    allDone: Volumes.allDone(),
    fallbackYear: widget.year ?? DateTime.now().year,
  );

  Future<void> _share(int year) async {
    try {
      setState(() => _capturing = true);
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final file = File('${(await getTemporaryDirectory()).path}/ark_yearly_report_$year.png');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: '$year 年度阅读报告 · Ark Novel'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享失败：$e')));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(volumeChangesProvider);
    final years = _availableYears();
    if (!years.contains(_year)) _year = years.first;
    final summary = YearlySummary.fromStore(_year);
    final queue = ref.read(volumeCoverQueueProvider);
    String coverOf(String aid, String img) => queue.bookCover(aid, img.isNotEmpty ? img : Wenku8Parser.coverUrl(aid));

    final primary = Theme.of(context).colorScheme.primary;
    // 以深邃的杂志印刷暗调为底，融入当前主题强调色，保证白色与烫金排版在任意主题下都通透高级
    final bgTop = Color.lerp(const Color(0xFF141926), primary, 0.24)!;
    final bgMid = Color.lerp(const Color(0xFF1A1E2E), primary, 0.14)!;
    final bgBottom = const Color(0xFF0F131E);

    const white70 = TextStyle(color: Colors.white70, fontSize: 12.5);
    Widget tileHead(IconData icon, String label) => Row(
      children: [
        Icon(icon, size: 15, color: Colors.white70),
        const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: white70)),
      ],
    );

    final content = Padding(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 64, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 杂志风 Hero 抬头
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _gold.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'ARK NOVEL · YEAR IN READING',
                  style: TextStyle(color: _gold, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${summary.year}',
                style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w800, height: 1.0, fontFamilyFallback: kSerifFallback),
              ),
              const SizedBox(width: 10),
              const Text(
                '年度阅读报告',
                style: TextStyle(color: Colors.white70, fontSize: 20, fontWeight: FontWeight.w600, fontFamilyFallback: kSerifFallback),
              ),
            ],
          ),
          if (!_capturing && years.length > 1) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final y in years)
                  ChoiceChip(
                    label: Text('$y 年'),
                    selected: y == _year,
                    showCheckmark: false,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    selectedColor: _gold.withValues(alpha: 0.24),
                    labelStyle: TextStyle(color: y == _year ? _gold : Colors.white70, fontSize: 12.5, fontWeight: y == _year ? FontWeight.w700 : null),
                    side: BorderSide(color: y == _year ? _gold.withValues(alpha: 0.65) : Colors.white.withValues(alpha: 0.16)),
                    onSelected: (_) => setState(() => _year = y),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          // 读者称号卡
          _GlassCard(
            accentBorder: _gold.withValues(alpha: 0.35),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded, size: 16, color: _gold),
                    const SizedBox(width: 6),
                    const Text('年度读者称号', style: TextStyle(color: _gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  summary.personaTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700, fontFamilyFallback: kSerifFallback),
                ),
                const SizedBox(height: 6),
                Text(summary.personaSubtitle, style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5)),
                if (summary.keywords.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final kw in summary.keywords)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                          ),
                          child: Text('# $kw', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (summary.isEmpty) ...[
            const SizedBox(height: 24),
            const _GlassCard(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    Icon(Icons.menu_book_outlined, size: 36, color: Colors.white54),
                    SizedBox(height: 10),
                    Text('这一年还没有阅读记录', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text('读几章书之后，这里会记录下你的年度故事。', style: TextStyle(color: Colors.white60, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            // 核心 6 项指标网格
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _MetricTile(header: tileHead(Icons.hourglass_bottom_rounded, '年度总时长'), value: _amount(_durationParts(summary.totalSeconds)))),
                  const SizedBox(width: 10),
                  Expanded(child: _MetricTile(header: tileHead(Icons.auto_stories_outlined, '读完卷数'), value: _amount([('${summary.volumesDone}', ' 卷')]))),
                ],
              ),
            ),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _MetricTile(header: tileHead(Icons.calendar_month_outlined, '阅读天数'), value: _amount([('${summary.readingDays}', ' 天')]))),
                  const SizedBox(width: 10),
                  Expanded(child: _MetricTile(header: tileHead(Icons.local_fire_department_rounded, '最长连读'), value: _amount([('${summary.longestStreak}', ' 天')]))),
                ],
              ),
            ),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _MetricTile(header: tileHead(Icons.collections_bookmark_outlined, '涉及作品'), value: _amount([('${summary.booksTouched}', ' 本')]))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricTile(
                      header: tileHead(Icons.text_fields_rounded, '估算字数'),
                      value: _amount(
                        summary.estimatedChars >= 10000
                            ? [((summary.estimatedChars / 10000).toStringAsFixed(1), ' 万字')]
                            : [('${summary.estimatedChars}', ' 字')],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 12 个月阅读分布 + 峰值纪录
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bar_chart_rounded, size: 17, color: _gold),
                      const SizedBox(width: 6),
                      const Expanded(child: Text('月度阅读节律', style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700))),
                      if (summary.peakMonth != null)
                        Text('${summary.peakMonth}月巅峰', style: const TextStyle(color: _gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _MonthlyChart(monthlySeconds: summary.monthlySeconds, peakMonth: summary.peakMonth),
                  if (summary.peakMonth != null || summary.bestDayKey != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (summary.peakMonth != null)
                            Text(
                              '最沉迷的月份：${summary.peakMonth} 月 · 共 ${ReadingStats.formatDuration(summary.peakMonthSeconds)}',
                              style: const TextStyle(color: Colors.white, fontSize: 12.5),
                            ),
                          if (summary.bestDayKey != null) ...[
                            if (summary.peakMonth != null) const SizedBox(height: 4),
                            Text(
                              '单日最长纪录：${_formatDayLabel(summary.bestDayKey!)} · ${ReadingStats.formatDuration(summary.bestDaySeconds)}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 年度最久 Top 5 书 & 最常读作者
            if (summary.topBooks.isNotEmpty) ...[
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.emoji_events_outlined, size: 17, color: _gold),
                        SizedBox(width: 6),
                        Text('年度沉浸 Top 5', style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final (i, book) in summary.topBooks.indexed)
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: _capturing ? null : () => context.push(Routes.report(book.aid)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    color: i == 0 ? _gold : Colors.white60,
                                    fontSize: i == 0 ? 18 : 14,
                                    fontWeight: FontWeight.w800,
                                    fontFamilyFallback: kSerifFallback,
                                  ),
                                ),
                              ),
                              SizedBox(width: 36, height: 50, child: CoverImage(coverOf(book.aid, book.img), thumbnail: true, decodeSize: const Size(36, 50))),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            book.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          ReadingStats.formatDuration(book.seconds),
                                          style: TextStyle(color: i == 0 ? _gold : Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                    if (book.author.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                                    ],
                                    const SizedBox(height: 5),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(
                                        value: summary.topBooks.first.seconds > 0 ? book.seconds / summary.topBooks.first.seconds : 0,
                                        minHeight: 4,
                                        color: i == 0 ? _gold : Colors.white70,
                                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (summary.topAuthor case final a?) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _gold.withValues(alpha: 0.28)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.edit_note_rounded, size: 18, color: _gold),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '年度最常读作者：${a.author}（${a.bookCount} 部 · ${ReadingStats.formatDuration(a.seconds)}）',
                                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            // 年度高分神作榜
            if (summary.topRated.isNotEmpty) ...[
              const SizedBox(height: 12),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.star_rounded, size: 18, color: _gold),
                        SizedBox(width: 6),
                        Text('年度高分神作榜', style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    for (final item in summary.topRated)
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: _capturing ? null : () => context.push(Routes.report(item.aid, vol: item.volIndex)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              SizedBox(width: 32, height: 44, child: CoverImage(coverOf(item.aid, item.img), thumbnail: true, decodeSize: const Size(32, 44))),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.volumeTitle == null ? item.title : '${item.title} · ${item.volumeTitle}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        for (var s = 0; s < item.stars; s++) const Icon(Icons.star_rounded, size: 14, color: _gold),
                                        const SizedBox(width: 6),
                                        Text(item.stars == 5 ? '神作必读' : '值得一读', style: const TextStyle(color: Colors.white60, fontSize: 11.5)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 26),
          const Text('该年度阅读报告由 Ark Novel 统计生成', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgBottom,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          systemOverlayStyle: SystemUiOverlayStyle.light,
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: years.length > 1
              ? PopupMenuButton<int>(
                  tooltip: hz(context, '切换年份'),
                  initialValue: _year,
                  onSelected: (y) => setState(() => _year = y),
                  itemBuilder: (_) => [for (final y in years) PopupMenuItem(value: y, child: Text('$y 年'))],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$_year 年度报告', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                      const Icon(Icons.arrow_drop_down_rounded, color: Colors.white70),
                    ],
                  ),
                )
              : Text('$_year 年度报告'),
          actions: [
            IconButton(
              tooltip: hz(context, '保存为图片并分享'),
              icon: const Icon(Icons.ios_share),
              onPressed: () => _share(_year),
            ),
          ],
        ),
        body: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: RepaintBoundary(
                key: _shot,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [bgTop, bgMid, bgBottom],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDayLabel(String key) {
  final dt = _parseDayKey(key);
  return dt == null ? key : '${dt.month} 月 ${dt.day} 日';
}

const _bigStyle = TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w700);

List<(String, String)> _durationParts(int s) {
  if (s <= 0) return [('0', ' 分')];
  final mins = (s + 59) ~/ 60;
  if (mins >= 60) {
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? [('$h', ' 时')] : [('$h', ' 时 '), ('$m', ' 分')];
  }
  return [('$mins', ' 分')];
}

Widget _amount(List<(String, String)> parts) => Text.rich(
  TextSpan(
    children: [
      for (final (n, u) in parts) ...[
        TextSpan(text: n, style: _bigStyle),
        TextSpan(text: u, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    ],
  ),
);

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.accentBorder});

  final Widget child;
  final Color? accentBorder;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: accentBorder ?? Colors.white.withValues(alpha: 0.12)),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 14, offset: const Offset(0, 6))],
    ),
    child: child,
  );
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.header, required this.value});

  final Widget header;
  final Widget value;

  @override
  Widget build(BuildContext context) => _GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 10),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: value),
      ],
    ),
  );
}

class _MonthlyChart extends StatelessWidget {
  const _MonthlyChart({required this.monthlySeconds, required this.peakMonth});

  final List<int> monthlySeconds;
  final int? peakMonth;

  @override
  Widget build(BuildContext context) {
    final maxSec = monthlySeconds.fold(1, math.max);
    return SizedBox(
      height: 92,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var m = 0; m < 12; m++)
            Expanded(
              child: Semantics(
                label: '${m + 1}月 ${ReadingStats.formatDuration(monthlySeconds[m])}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: monthlySeconds[m] <= 0 ? 3.0 : math.max(5.0, 66.0 * monthlySeconds[m] / maxSec),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: peakMonth == m + 1
                            ? _gold
                            : (monthlySeconds[m] > 0 ? Colors.white.withValues(alpha: 0.58) : Colors.white.withValues(alpha: 0.14)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${m + 1}',
                      style: TextStyle(
                        color: peakMonth == m + 1 ? _gold : Colors.white60,
                        fontSize: 10.5,
                        fontWeight: peakMonth == m + 1 ? FontWeight.w700 : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
