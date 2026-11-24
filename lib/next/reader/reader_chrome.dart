import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' as material show Text;
import 'package:flutter/material.dart' hide Text;
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../cache.dart';
import '../local_books.dart';
import '../pages/stats_page.dart' show charsPerMinute, secondsPerChapter;
import '../read_state.dart';
import '../stats.dart';
import '../text.dart';
import '../volumes.dart';

/// 阅读器页眉 / 页脚字段编码。
class ReaderChromeField {
  const ReaderChromeField._();

  static const int empty = 0;
  static const int chapterTitle = 1;
  static const int bookTitle = 2;
  static const int timeAndBattery = 3;
  static const int pageOrProgress = 4;
  static const int volumeEta = 5;
  static const int volumeProgress = 6;

  static const int minValue = 0;
  static const int maxValue = 6;

  static const Map<int, String> labels = {
    empty: '留空',
    chapterTitle: '章节名',
    bookTitle: '书名',
    timeAndBattery: '时间与电量',
    pageOrProgress: '页码/进度',
    volumeEta: '本卷剩余时间',
    volumeProgress: '本卷进度',
  };
}

/// 阅读器页眉/页脚配置（传入 [PagedBody] / 滚动模式页眉页脚）。
/// 默认配置 `(headerLeft: 1, headerRight: 0, footerLeft: 3, footerRight: 4)` 与既有体验完全一致。
class ReaderChromeConfig {
  const ReaderChromeConfig({
    this.headerLeft = ReaderChromeField.chapterTitle,
    this.headerRight = ReaderChromeField.empty,
    this.footerLeft = ReaderChromeField.timeAndBattery,
    this.footerRight = ReaderChromeField.pageOrProgress,
    this.bookTitle = '',
    this.volumeEta,
  });

  final int headerLeft;
  final int headerRight;
  final int footerLeft;
  final int footerRight;
  final String bookTitle;

  /// 根据本章进度比例（0~1）返回格式化的「本卷剩余预计时间」文本；数据不足时返回 null。
  final String? Function(double chapterFraction)? volumeEta;

  bool get hasHeader => headerLeft != ReaderChromeField.empty || headerRight != ReaderChromeField.empty;
  bool get hasFooter => footerLeft != ReaderChromeField.empty || footerRight != ReaderChromeField.empty;

  /// 用于缓存键比较（忽略闭包实例差异，仅比较字段配置和书名）。
  int get layoutSignature => Object.hash(headerLeft, headerRight, footerLeft, footerRight, bookTitle);
}

/// 纯函数：估算本卷剩余阅读时间（秒）。
///
/// - 优先按个人阅读速度 [personalCharsPerMinute]（合理范围 100~5000 字/分钟，否则回退 500 字/分钟）
///   计算当前章剩余字数 + 后续已缓存章节字数；
/// - 后续未缓存章节优先用 [avgSecondsPerChapter]（本书或全局单章均时），其次用本卷已知章节平均字数折算；
/// - 数据完全不足无法估算时返回 null（绝不返回负数或乱码）。
int? estimateVolumeRemainingSeconds({
  required int currentChapterChars,
  required double currentChapterFraction,
  required List<String> remainingCids,
  required int? Function(String cid) cachedLengthOf,
  int? personalCharsPerMinute,
  int? avgSecondsPerChapter,
}) {
  final cpm = (personalCharsPerMinute != null && personalCharsPerMinute >= 100 && personalCharsPerMinute <= 5000) ? personalCharsPerMinute : 500;
  final frac = currentChapterFraction.clamp(0.0, 1.0);
  final safeCurChars = currentChapterChars < 0 ? 0 : currentChapterChars;

  final curRemChars = ((1.0 - frac) * safeCurChars).round();
  final curSec = curRemChars > 0 ? (curRemChars * 60 / cpm).round() : 0;

  var cachedCharsSum = 0;
  var cachedCount = 0;
  var uncachedCount = 0;
  for (final cid in remainingCids) {
    final len = cachedLengthOf(cid);
    if (len != null && len > 0) {
      cachedCharsSum += len;
      cachedCount++;
    } else {
      uncachedCount++;
    }
  }

  final cachedSec = cachedCharsSum > 0 ? (cachedCharsSum * 60 / cpm).round() : 0;

  var uncachedSec = 0;
  if (uncachedCount > 0) {
    if (avgSecondsPerChapter != null && avgSecondsPerChapter > 0) {
      uncachedSec = uncachedCount * avgSecondsPerChapter;
    } else {
      final knownChars = cachedCharsSum + (safeCurChars >= 200 ? safeCurChars : 0);
      final knownCount = cachedCount + (safeCurChars >= 200 ? 1 : 0);
      if (knownCount == 0 || knownChars <= 0) return null;
      final avgChars = knownChars / knownCount;
      uncachedSec = (uncachedCount * avgChars * 60 / cpm).round();
    }
  } else if (safeCurChars == 0 && cachedCount == 0) {
    return null;
  }

  final total = curSec + cachedSec + uncachedSec;
  return total < 0 ? 0 : total;
}

/// 格式化本卷剩余预计时间；当 [remainingSeconds] 为 null（数据不足）时优雅回退为本卷进度或空串。
String formatVolumeEta(int? remainingSeconds, {double? fallbackVolumeProgress}) {
  if (remainingSeconds == null) {
    if (fallbackVolumeProgress == null) return '';
    return '本卷 ${(fallbackVolumeProgress.clamp(0.0, 1.0) * 100).floor()}%';
  }
  if (remainingSeconds <= 0) return '本卷即将读完';
  if (remainingSeconds < 60) return '本卷约剩 <1 分钟';
  final mins = (remainingSeconds + 30) ~/ 60;
  if (mins < 60) return '本卷约剩 $mins 分钟';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '本卷约剩 $h 小时' : '本卷约剩 $h 小时 $m 分';
}

/// 阅读器缓存的阅读速度快照（避免每次翻页遍历统计数据）。
class ReaderPaceSnapshot {
  const ReaderPaceSnapshot({this.charsPerMin, this.globalSecPerChapter});

  final int? charsPerMin;
  final int? globalSecPerChapter;

  static ReaderPaceSnapshot capture() {
    if (!Hive.isBoxOpen('session')) return const ReaderPaceSnapshot();
    final books = ReadingStats.chapterBooks().toList();
    final secPerCh = secondsPerChapter(books.expand((a) => ReadingStats.chapterSeconds(a).values));
    final hasCache = Hive.isBoxOpen('chapter_index');
    final cpm = charsPerMinute([
      for (final aid in books)
        for (final e in ReadingStats.chapterSeconds(aid).entries)
          if (ReadState.isRead(aid, e.key))
            if ((isLocalAid(aid) ? LocalBooks.chapterLength(aid, e.key) : (hasCache ? ChapterCache.length(aid, e.key) : null)) case final n?)
              (n, e.value.values.fold(0, (a, b) => a + b)),
    ]);
    return ReaderPaceSnapshot(charsPerMin: cpm, globalSecPerChapter: secPerCh);
  }
}

/// 计算指定书籍当前章节所在卷的剩余预计时间文案。
String resolveVolumeEtaText({
  required String aid,
  required String cid,
  required int currentChapterChars,
  required double chapterFraction,
  required double? volumeProgress,
  required ReaderPaceSnapshot pace,
}) {
  if (!Hive.isBoxOpen('session')) return formatVolumeEta(null, fallbackVolumeProgress: volumeProgress);
  final vols = Volumes.of(aid);
  final vol = vols.where((v) => v.cids.contains(cid)).firstOrNull;
  if (vol == null) return formatVolumeEta(null, fallbackVolumeProgress: volumeProgress);

  final textCids = vol.textCids.toList();
  final idx = textCids.indexOf(cid);
  final read = ReadState.readView(aid);
  // 取当前章之后的正文章节（若当前章是插图章则取本卷未读正文章节）
  final remainingCids = idx >= 0 ? textCids.skip(idx + 1).toList() : textCids.where((c) => c != cid && !read.contains(c)).toList();

  final bookSecPerCh = secondsPerChapter(ReadingStats.chapterSeconds(aid).values) ?? pace.globalSecPerChapter;
  final local = isLocalAid(aid);
  final hasCache = Hive.isBoxOpen('chapter_index');
  final sec = estimateVolumeRemainingSeconds(
    currentChapterChars: currentChapterChars,
    currentChapterFraction: chapterFraction,
    remainingCids: remainingCids,
    cachedLengthOf: (c) => local ? LocalBooks.chapterLength(aid, c) : (hasCache ? ChapterCache.length(aid, c) : null),
    personalCharsPerMinute: pace.charsPerMin,
    avgSecondsPerChapter: bookSecPerCh,
  );
  return formatVolumeEta(sec, fallbackVolumeProgress: volumeProgress);
}

/// 可自定义的页眉 / 页脚单行组件（支持左右两个字段槽位）。
///
/// 章节名与书名使用 `material.Text` 绕开界面繁简转换（保持正文设置一致）；
/// 时间、电量、进度与剩余时间走应用 [Text] 以跟随界面繁简。
class ReaderChromeRow extends StatelessWidget {
  const ReaderChromeRow({
    super.key,
    required this.leftField,
    required this.rightField,
    required this.style,
    this.chapterTitle = '',
    this.bookTitle = '',
    this.status,
    this.pageProgress = '',
    this.volumeEta = '',
    this.volumeProgressText = '',
  });

  final int leftField;
  final int rightField;
  final TextStyle style;
  final String chapterTitle;
  final String bookTitle;
  final ValueListenable<String>? status;
  final String pageProgress;
  final String volumeEta;
  final String volumeProgressText;

  Widget? _buildSlot(int field, {required TextAlign align}) {
    switch (field) {
      case ReaderChromeField.empty:
        return null;
      case ReaderChromeField.chapterTitle:
        if (chapterTitle.isEmpty) return null;
        return material.Text(chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style);
      case ReaderChromeField.bookTitle:
        if (bookTitle.isEmpty) return null;
        return material.Text(bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style);
      case ReaderChromeField.timeAndBattery:
        if (status == null) return null;
        return ValueListenableBuilder<String>(
          valueListenable: status!,
          builder: (_, v, _) => Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style),
        );
      case ReaderChromeField.pageOrProgress:
        if (pageProgress.isEmpty) return null;
        return Text(pageProgress, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style);
      case ReaderChromeField.volumeEta:
        if (volumeEta.isEmpty) return null;
        return Text(volumeEta, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style);
      case ReaderChromeField.volumeProgress:
        if (volumeProgressText.isEmpty) return null;
        return Text(volumeProgressText, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = _buildSlot(leftField, align: TextAlign.start);
    final right = _buildSlot(rightField, align: TextAlign.end);
    if (left == null && right == null) return const SizedBox.shrink();
    return Row(
      children: [
        if (left != null) Expanded(child: Align(alignment: Alignment.centerLeft, child: left)) else const Spacer(),
        if (left != null && right != null) const SizedBox(width: 12),
        if (right != null) Flexible(child: Align(alignment: Alignment.centerRight, child: right)),
      ],
    );
  }
}
