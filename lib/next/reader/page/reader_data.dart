part of '../reader_page.dart';

/// 每个非空行当一段：去掉网页里零散的空白，统一首行缩进两个全角空格；全角英文、数字转半角。
/// 复用 `book_search.dart` 中的共享实现，确保阅读器与书内全文搜索偏移完全一致。
String formatChapter(String raw) => formatChapterText(raw);

/// 将暖色 / 灰度 / 反色滤镜合成为单个 4×5 颜色矩阵（全关闭时返回 null），避免叠加多层全屏 `ColorFiltered` saveLayer。
List<double>? combineReaderColorMatrix({required double warm, required bool grayscale, required bool invert}) {
  if (warm <= 0 && !grayscale && !invert) return null;
  var m = <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
  List<double> mul(List<double> b, List<double> a) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        out[r * 5 + c] = b[r * 5] * a[c] + b[r * 5 + 1] * a[5 + c] + b[r * 5 + 2] * a[10 + c] + b[r * 5 + 3] * a[15 + c];
      }
      out[r * 5 + 4] = b[r * 5 + 4] + b[r * 5] * a[4] + b[r * 5 + 1] * a[9] + b[r * 5 + 2] * a[14] + b[r * 5 + 3] * a[19];
    }
    return out;
  }

  if (warm > 0) {
    m = mul([1, 0, 0, 0, 0, 0, 1 - 0.6 * warm, 0, 0, 0, 0, 0, 1 - 1.4 * warm, 0, 0, 0, 0, 0, 1, 0], m);
  }
  if (grayscale) {
    m = mul(const [0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0, 0, 0, 1, 0], m);
  }
  if (invert) {
    m = mul(const [-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0], m);
  }
  return m;
}

/// 纯文字暖色护眼直算颜色（与 `combineReaderColorMatrix(warm: warm, grayscale: false, invert: false)` 数学等价）：
/// `R' = R, G' = G * (1 - 0.6 * warm), B' = B * (1 - 1.4 * warm)`。
Color applyReaderWarmColor(Color c, double warm) {
  if (warm <= 0) return c;
  return Color.from(
    alpha: c.a,
    red: c.r,
    green: (c.g * (1 - 0.6 * warm)).clamp(0.0, 1.0),
    blue: (c.b * (1 - 1.4 * warm)).clamp(0.0, 1.0),
  );
}

/// 滚轮 / macOS 触控板惯性防连翻过滤器：
/// 1. 同一手势内累计位移达到阈值才触发一次翻页，避免微小抖动误触；
/// 2. 触发后进入单次手势锁：只要事件间隔小于 [gestureGap]、方向不变且未出现明显的新一轮加速峰值，
///    持续 1~2 秒的惯性衰减流全部去重吞掉，保证单次双指轻滑最多翻 1 页；
/// 3. 离散鼠标滚轮（事件间隔超过 [gestureGap]）或方向反转时立即解锁，保留干脆的滚轮翻页手感。
class ScrollWheelTurnFilter {
  ScrollWheelTurnFilter({
    this.threshold = 28.0,
    this.gestureGap = const Duration(milliseconds: 140),
    this.cooldown = const Duration(milliseconds: 220),
  });

  final double threshold;
  final Duration gestureGap;
  final Duration cooldown;

  DateTime _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTurnAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _accum = 0;
  int _dir = 0;
  bool _locked = false;
  double _minAfterTurn = double.infinity;

  /// 输入一次滚动增量（[delta] > 0 下一页，< 0 上一页）与时间戳 [now]；
  /// 返回 1（下一页）、-1（上一页）或 0（忽略/继续累计）。
  int feed(double delta, DateTime now, {PointerDeviceKind kind = PointerDeviceKind.mouse}) {
    if (delta == 0) return 0;
    final dir = delta > 0 ? 1 : -1;
    final abs = delta.abs();
    final gap = now.difference(_lastEventAt);
    _lastEventAt = now;

    if (gap >= gestureGap || dir != _dir) {
      _locked = false;
      _accum = 0;
      _dir = dir;
      _minAfterTurn = double.infinity;
    }

    if (_locked) {
      if (abs < _minAfterTurn) {
        _minAfterTurn = abs;
      } else if (now.difference(_lastTurnAt) >= cooldown && _minAfterTurn <= 6 && abs >= _minAfterTurn * 3 + 18) {
        _locked = false;
        _accum = 0;
        _minAfterTurn = double.infinity;
      } else {
        return 0;
      }
    }

    if (now.difference(_lastTurnAt) < cooldown) return 0;

    _accum += abs;
    final effectiveThreshold = kind == PointerDeviceKind.trackpad ? threshold : (gap >= gestureGap ? math.min(threshold, 16.0) : threshold);
    if (_accum < effectiveThreshold) return 0;

    _locked = true;
    _accum = 0;
    _lastTurnAt = now;
    _minAfterTurn = abs;
    return dir;
  }

  void reset() {
    _locked = false;
    _accum = 0;
    _dir = 0;
    _minAfterTurn = double.infinity;
  }
}

/// 联网取单章原文（支持 [CancelToken] 在切章/退出阅读器时立即取消在途或排队请求）。
Future<Content> _fetchChapterRaw(
  Wenku8Client client,
  Wenku8Urls urls,
  UnlockService unlock,
  Future<List<CatVolume>> Function(CancelToken? cancel) catalogue,
  String aid,
  String cid, {
  CancelToken? cancelToken,
  bool allowChallengeFallback = true,
  VoidCallback? onCloudflare,
}) async {
  try {
    final html = await client.getPage(
      urls.chapterContent(aid, cid),
      charsetParam: false,
      referer: urls.catalogue(aid),
      cancelToken: cancelToken,
      allowChallengeFallback: allowChallengeFallback,
    );
    final content = Wenku8Parser.chapterContent(html);
    if (!isLockedContent(content) || !unlock.enabled) return content;
    return await unlock.chapter(aid, cid, () => catalogue(cancelToken));
  } catch (e) {
    if (isCloudflare(e)) onCloudflare?.call();
    rethrow;
  }
}

const _maxKeptChapters = 4;
const _chapterKeepAliveDuration = Duration(seconds: 90);
final _keptChapters = <(String, String), ({Object link, VoidCallback close, Timer timer})>{};
final _silentPrefetchKeys = <(String, String), int>{};

/// 后台静默预热章节进内存 `chapterProvider`（禁用 Cloudflare 过盾弹窗，供常规及无痕预取复用）。
Future<Chapter> prefetchChapterSilent(WidgetRef ref, String aid, String cid) async {
  final key = (aid, cid);
  _silentPrefetchKeys[key] = (_silentPrefetchKeys[key] ?? 0) + 1;
  try {
    return await ref.read(chapterProvider(key).future);
  } finally {
    final left = (_silentPrefetchKeys[key] ?? 1) - 1;
    if (left <= 0) {
      _silentPrefetchKeys.remove(key);
    } else {
      _silentPrefetchKeys[key] = left;
    }
  }
}

/// 收缩章节内存保活队列：[clearAll] 为 true（如内存压力告警）时关闭全部保活章节；
/// 为 false（如退出阅读器）时仅保留最新 1 章，其余立即关闭释放。
void trimReaderChapterCache({bool clearAll = false}) {
  final keep = clearAll ? 0 : 1;
  final toClose = <({Object link, VoidCallback close, Timer timer})>[];
  while (_keptChapters.length > keep) {
    final oldestKey = _keptChapters.keys.first;
    toClose.add(_keptChapters.remove(oldestKey)!);
  }
  for (final entry in toClose) {
    entry.timer.cancel();
    entry.close();
  }
}

/// 章节：先查离线缓存，再联网（支持切章/退出自动取消在途请求）；套用替换规则、统一缩进后算出高亮位置。
/// 读过的章节在内存里最多同时保活 4 章、每章 90 秒（预加载的下一章、来回翻章都不用重新取），超限或到期自动释放。
final chapterProvider = FutureProvider.autoDispose.family<Chapter, (String, String)>((ref, key) async {
  final cancel = CancelToken();
  Object? linkToken;
  Timer? timer;
  ref.onDispose(() {
    timer?.cancel();
    final cur = _keptChapters[key];
    if (cur != null && identical(cur.link, linkToken)) {
      _keptChapters.remove(key);
    }
    if (!cancel.isCancelled) cancel.cancel('chapter disposed');
  });
  final hantOn = ref.watch(readerPrefsProvider.select((p) => p.hant));
  ref.watch(replaceRulesChangesProvider);
  Content? raw = await ChapterCache.get(key.$1, key.$2);
  if (raw != null && isLockedContent(raw)) raw = null; // 以前存下的「因版权问题…」，重新取
  if (raw == null) {
    final ticket = ChapterCache.ticket(key.$1, key.$2);
    final allowChallenge = (_silentPrefetchKeys[key] ?? 0) == 0;
    try {
      raw = await _fetchChapterRaw(
        ref.read(wenku8ClientProvider),
        ref.read(wenku8UrlsProvider),
        ref.read(unlockServiceProvider),
        (c) => ref.read(apiProvider).catalogue(key.$1, cancelToken: c),
        key.$1,
        key.$2,
        cancelToken: cancel,
        allowChallengeFallback: allowChallenge,
        onCloudflare: allowChallenge ? () => ref.read(sessionProvider.notifier).markNeedsVerify() : null,
      );
    } on ChapterLockedException catch (e) {
      // 受限书里取不到的章（多半是插图）：给一句说明照常往后翻；不存缓存，下次还会再试
      final text = formatChapter(e.message);
      return Chapter(text: text, images: const [], marks: ReplaceRules.marks(text, null, key.$1), locked: true);
    }
    if (Wenku8Parser.isCopyrightLockedText(raw.text) && raw.images.isEmpty) {
      final text = formatChapter(raw.text);
      return Chapter(text: text, images: const [], marks: ReplaceRules.marks(text, null, key.$1), locked: true);
    }
    // 读过的章节顺手存下来，断网也能再看；写失败不影响阅读。取的这会儿刚好清了缓存、或者开启了无痕阅读时不写回去
    if (!Incognito.on) {
      try {
        await ChapterCache.put(key.$1, key.$2, raw, ticket: ticket);
      } catch (_) {}
    }
  }
  // 请求完成后加入有界保活队列（上限 4 章、每章 90 秒）：加载中若用户切章或退出，autoDispose 会立刻触发上面的 CancelToken 取消网络请求
  if (!cancel.isCancelled) {
    final prev = _keptChapters.remove(key);
    if (prev != null) {
      prev.timer.cancel();
      prev.close();
    }
    final link = ref.keepAlive();
    linkToken = link;
    final keptTimer = Timer(_chapterKeepAliveDuration, () {
      final cur = _keptChapters[key];
      if (cur != null && identical(cur.link, link)) {
        _keptChapters.remove(key);
      }
      link.close();
    });
    timer = keptTimer;
    _keptChapters[key] = (link: link, close: link.close, timer: keptTimer);
    while (_keptChapters.length > _maxKeptChapters) {
      final oldestKey = _keptChapters.keys.first;
      final oldest = _keptChapters.remove(oldestKey)!;
      oldest.timer.cancel();
      oldest.close();
    }
  }
  // 繁体：先转正文，规则也转成繁体再套，简体、繁体下做的替换和高亮都能匹配上
  final hant = hantOn ? await Hant.load() : null;
  final rules = hant == null ? null : [for (final r in ReplaceRules.allView()) r.copyWith(pattern: hant.convert(r.pattern), replacement: hant.convert(r.replacement))];
  final text = formatChapter(ReplaceRules.apply(hant?.convert(raw.text) ?? raw.text, rules));
  return Chapter(text: text, images: raw.images, marks: ReplaceRules.marks(text, rules, key.$1));
});

/// 书签在本章第几屏：按现在的阅读设置（字号、行距、边距、字体、双页）重新排版算出来，所以改了设置页码也跟着对。
/// 返回 (第几屏从 1 起, 共几屏)；滚动模式、没缓存过的章节返回 null（不为了算页码去联网）。
///
/// 同样的书签和版面返回同一个 Future：书签列表在可拖动的弹窗里，拖动时每帧都重建，不能每帧都重新整章排版。
Future<(int, int)?> bookmarkPage(WidgetRef ref, BuildContext context, String aid, String cid, String title, int offset) {
  final prefs = ref.read(readerPrefsProvider);
  final len = ChapterCache.length(aid, cid);
  if (prefs.mode == 0 || len == null) return Future.value();
  final size = MediaQuery.sizeOf(context);
  final view = MediaQuery.viewPaddingOf(context);
  final key = (aid, cid, title, offset, prefs, size, view, PagedBody.lastLayout, len);
  final hit = _bookmarkPages.remove(key);
  final future = hit ?? _bookmarkPage(ref, aid, cid, title, offset, prefs, size, view);
  _bookmarkPages[key] = future;
  if (_bookmarkPages.length > 32) _bookmarkPages.remove(_bookmarkPages.keys.first);
  return future;
}

final _bookmarkPages = <Object, Future<(int, int)?>>{};
Future<void> _bookmarkPaginateQueue = Future<void>.value();
int _bookmarkQueueDepth = 0;

/// 内存压力告警时清空书签页码、共享分页、纹理与章节保活缓存，释放非活跃章节内存。
void clearReaderBookmarkCaches() {
  _bookmarkPages.clear();
  PaginateCache.clear();
  ReaderBackground.evictTextureCache();
  clearVolumeEtaCache();
  trimReaderChapterCache(clearAll: true);
}

Future<List<int>> _enqueueBookmarkPaginate({
  required String text,
  required TextStyle style,
  required Size box,
  required String title,
  required double paragraphSpacing,
}) {
  final cached = PaginateCache.peek(
    text: text,
    style: style,
    size: box,
    title: title,
    paragraphSpacing: paragraphSpacing,
  );
  if (cached != null) return Future<List<int>>.value(cached);

  final completer = Completer<List<int>>();
  final shouldYield = _bookmarkQueueDepth > 0;
  _bookmarkQueueDepth++;
  _bookmarkPaginateQueue = _bookmarkPaginateQueue.then((_) async {
    if (shouldYield) await Future<void>.delayed(Duration.zero);
    try {
      final head = PaginateCache.headingHeightCached(title, style, box.width);
      final starts = PaginateCache.paginateCached(
        text: text,
        style: style,
        size: box,
        title: title,
        firstTop: head,
        paragraphSpacing: paragraphSpacing,
        strut: readerStrut(style),
      );
      completer.complete(starts);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _bookmarkQueueDepth--;
    }
  });
  return completer.future;
}

Future<(int, int)?> _bookmarkPage(WidgetRef ref, String aid, String cid, String title, int offset, ReaderPrefs prefs, Size size, EdgeInsets view) async {
  final c = await ref.read(chapterProvider((aid, cid)).future);
  final f = FontStore.resolve(prefs.font);
  final style = readerStyle(prefs, const Color(0xFF000000), family: f.family, fallback: f.fallback);
  // 这次运行里排过版就直接用正文实际的版面（弹窗里的边距和阅读页不一样，不能自己算）；
  // 否则照 PagedBody 的算法：上下各留出标题 / 页脚的位置，宽屏开双页时一屏两页
  final fallbackCols = prefs.dual && size.width >= 900 ? 2 : 1;
  final (box, cols) = PagedBody.lastLayout ?? (Size(size.width / fallbackCols - prefs.margin * 2, size.height - view.top - view.bottom - 72), fallbackCols);
  final starts = c.text.trim().isEmpty
      ? const <int>[]
      : await _enqueueBookmarkPaginate(
          text: c.text,
          style: style,
          box: box,
          title: title,
          paragraphSpacing: prefs.paragraphSpacing,
        );
  final total = starts.length + c.images.length;
  if (total == 0) return null;
  final page = offset > c.text.length ? math.min(starts.length + offset - c.text.length - 1, total - 1) : (starts.isEmpty ? 0 : pageOfOffset(starts, offset));
  // 双页时卷首多一页封面（和正文一样，取不到封面图就没有这一页）
  final cover = cols == 2 && volumeCoverOf(ref, aid, cid, ref.read(readerNovelProvider(aid)).value?.detail.imgUrl ?? '') != null ? 1 : 0;
  return ((page + cover) ~/ cols + 1, (total + cover + cols - 1) ~/ cols);
}

/// [cid] 是一卷的第一章时那一卷的封面，不是卷首或取不到图时为 null。正文和书签页码都用它，保证封面页算法一致。
String? volumeCoverOf(WidgetRef ref, String aid, String cid, String fallback) {
  final v = Volumes.of(aid).where((v) => v.cids.firstOrNull == cid).firstOrNull;
  if (v == null) return null;
  final url = ref.read(volumeCoverQueueProvider).volCover(aid, v, fallback);
  return url.isEmpty ? null : url;
}

