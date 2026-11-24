import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerPanZoomUpdateEvent, PointerScrollEvent, PointerScrollInertiaCancelEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/wenku8/wenku8_client.dart' show Wenku8Client, runInBackground;
import '../../data/wenku8/wenku8_parser.dart';
import '../../data/wenku8/wenku8_urls.dart';
import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../../models/content.dart';
import '../app_prefs.dart';
import '../book_search.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../characters.dart';
import '../color_picker.dart';
import '../data.dart';
import '../env.dart';
import '../fonts.dart';
import '../hant.dart';
import '../history.dart';
import '../image_cache.dart' show ImageStore, imageStoreProvider;
import '../incognito.dart';
import '../library.dart' show LibraryStore;
import '../local_books.dart' show LocalBooks, isLocalAid;
import '../net_state.dart';
import '../pages/book_search_sheet.dart';
import '../pages/characters_page.dart';
import '../pages/novel_page.dart';
import '../pages/rules_page.dart' show showRuleDialog;
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../rules.dart';
import '../session.dart' show isCloudflare, sessionProvider, wenku8ClientProvider, wenku8UrlsProvider;
import '../settings.dart';
import '../stats.dart';
import '../sync.dart';
import '../text.dart';
import '../unlock.dart';
import '../volume_covers.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'auto_scroll.dart';
import 'paginator.dart';
import 'reader_bg.dart';
import 'reader_body.dart';
import 'reader_chrome.dart';
import 'reader_sheets.dart';
import 'reader_tts.dart';
import 'volume_done.dart';

/// 每个非空行当一段：去掉网页里零散的空白，统一首行缩进两个全角空格；全角英文、数字转半角。
String formatChapter(String raw) => halfWidth(raw).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).map((l) => '　　$l').join('\n');

/// 「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」这种全角英文每个字母占一个汉字宽，排出来字距很怪：字母、数字转半角，
/// 英文之间的全角空格、连字符也换成半角。一个字换一个字，阅读进度、书签的位置不变。
String halfWidth(String s) => s
    .replaceAllMapped(RegExp('[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
    .replaceAllMapped(RegExp(r'(?<=[0-9A-Za-z])[　－](?=[0-9A-Za-z])'), (m) => m[0] == '　' ? ' ' : '-');

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
  VoidCallback? onCloudflare,
}) async {
  try {
    final html = await client.getPage(urls.chapterContent(aid, cid), charsetParam: false, referer: urls.catalogue(aid), cancelToken: cancelToken);
    final content = Wenku8Parser.chapterContent(html);
    if (!isLockedContent(content) || !unlock.enabled) return content;
    return await unlock.chapter(aid, cid, () => catalogue(cancelToken));
  } catch (e) {
    if (isCloudflare(e)) onCloudflare?.call();
    rethrow;
  }
}

/// 章节：先查离线缓存，再联网（支持切章/退出自动取消在途请求）；套用替换规则、统一缩进后算出高亮位置。
/// 读过的章节在内存里留 3 分钟（预加载的下一章、来回翻章都不用重新取），之后释放。
final chapterProvider = FutureProvider.autoDispose.family<Chapter, (String, String)>((ref, key) async {
  final cancel = CancelToken();
  Timer? timer;
  ref.onDispose(() {
    timer?.cancel();
    if (!cancel.isCancelled) cancel.cancel('chapter disposed');
  });
  final hantOn = ref.watch(readerPrefsProvider.select((p) => p.hant));
  Content? raw;
  if (isLocalAid(key.$1)) {
    raw = await LocalBooks.loadChapter(key.$1, key.$2);
  } else {
    raw = await ChapterCache.get(key.$1, key.$2);
    if (raw != null && isLockedContent(raw)) raw = null; // 以前存下的「因版权问题…」，重新取
    if (raw == null) {
      final ticket = ChapterCache.ticket(key.$1, key.$2);
      try {
        raw = await _fetchChapterRaw(
          ref.read(wenku8ClientProvider),
          ref.read(wenku8UrlsProvider),
          ref.read(unlockServiceProvider),
          (c) => ref.read(apiProvider).catalogue(key.$1, cancelToken: c),
          key.$1,
          key.$2,
          cancelToken: cancel,
          onCloudflare: () => ref.read(sessionProvider.notifier).markNeedsVerify(),
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
  }
  // 请求完成后再保活 3 分钟：加载中若用户切章或退出，autoDispose 会立刻触发上面的 CancelToken 取消网络请求
  final link = ref.keepAlive();
  timer = Timer(const Duration(minutes: 3), link.close);
  // 繁体：先转正文，规则也转成繁体再套，简体、繁体下做的替换和高亮都能匹配上
  final hant = hantOn ? await Hant.load() : null;
  final rules = hant == null ? null : [for (final r in ReplaceRules.all()) r.copyWith(pattern: hant.convert(r.pattern), replacement: hant.convert(r.replacement))];
  final text = formatChapter(ReplaceRules.apply(hant?.convert(raw.text) ?? raw.text, rules));
  return Chapter(text: text, images: raw.images, marks: ReplaceRules.marks(text, rules, key.$1));
});

/// 书签在本章第几屏：按现在的阅读设置（字号、行距、边距、字体、双页）重新排版算出来，所以改了设置页码也跟着对。
/// 返回 (第几屏从 1 起, 共几屏)；滚动模式、没缓存过的章节返回 null（不为了算页码去联网）。
///
/// 同样的书签和版面返回同一个 Future：书签列表在可拖动的弹窗里，拖动时每帧都重建，不能每帧都重新整章排版。
Future<(int, int)?> bookmarkPage(WidgetRef ref, BuildContext context, String aid, String cid, String title, int offset) {
  final prefs = ref.read(readerPrefsProvider);
  final local = isLocalAid(aid);
  final len = local ? LocalBooks.chapterLength(aid, cid) : ChapterCache.length(aid, cid);
  if (prefs.mode == 0 || (!local && len == null)) return Future.value();
  final size = MediaQuery.sizeOf(context);
  final view = MediaQuery.viewPaddingOf(context);
  final key = (aid, cid, title, offset, prefs, size, view, PagedBody.lastLayout, len);
  final hit = _bookmarkPages.remove(key);
  final future = hit ?? _bookmarkPage(ref, aid, cid, title, offset, prefs, size, view);
  _bookmarkPages[key] = future;
  if (_bookmarkPages.length > 100) _bookmarkPages.remove(_bookmarkPages.keys.first);
  return future;
}

final _bookmarkPages = <Object, Future<(int, int)?>>{};

/// 同一章、同样版面的分页结果（一章有好几个书签时只排一次版）
final _bookmarkStarts = <Object, List<int>>{};

Future<(int, int)?> _bookmarkPage(WidgetRef ref, String aid, String cid, String title, int offset, ReaderPrefs prefs, Size size, EdgeInsets view) async {
  final c = await ref.read(chapterProvider((aid, cid)).future);
  final f = FontStore.resolve(prefs.font);
  final style = readerStyle(prefs, const Color(0xFF000000), family: f.family, fallback: f.fallback);
  // 这次运行里排过版就直接用正文实际的版面（弹窗里的边距和阅读页不一样，不能自己算）；
  // 否则照 PagedBody 的算法：上下各留出标题 / 页脚的位置，宽屏开双页时一屏两页
  final fallbackCols = prefs.dual && size.width >= 900 ? 2 : 1;
  final (box, cols) = PagedBody.lastLayout ?? (Size(size.width / fallbackCols - prefs.margin * 2, size.height - view.top - view.bottom - 72), fallbackCols);
  final startsKey = (aid, cid, title, c.text.length, c.text.hashCode, style, box);
  final starts = c.text.trim().isEmpty
      ? const <int>[]
      : (_bookmarkStarts[startsKey] ??= paginate(c.text, style, box, strut: readerStrut(style), firstTop: headingHeight(title, style, box.width)));
  if (_bookmarkStarts.length > 8) _bookmarkStarts.remove(_bookmarkStarts.keys.first);
  final total = starts.length + c.images.length;
  if (total == 0) return null;
  final page = offset > c.text.length ? math.min(starts.length + offset - c.text.length - 1, total - 1) : (starts.isEmpty ? 0 : pageOfOffset(starts, offset));
  // 双页时卷首多一页封面（和正文一样，取不到封面图就没有这一页）
  final cover = cols == 2 && volumeCoverOf(ref, aid, cid, ref.read(novelProvider(aid)).value?.detail.imgUrl ?? '') != null ? 1 : 0;
  return ((page + cover) ~/ cols + 1, (total + cover + cols - 1) ~/ cols);
}

/// [cid] 是一卷的第一章时那一卷的封面，不是卷首或取不到图时为 null。正文和书签页码都用它，保证封面页算法一致。
String? volumeCoverOf(WidgetRef ref, String aid, String cid, String fallback) {
  final v = Volumes.of(aid).where((v) => v.cids.firstOrNull == cid).firstOrNull;
  if (v == null) return null;
  final url = ref.read(volumeCoverQueueProvider).volCover(aid, v, fallback);
  return url.isEmpty ? null : url;
}

/// 阅读器：负责章节调度、进度、书签、键鼠与生命周期；
/// 排版在 `paginator.dart`，正文显示在 `reader_body.dart`，仿真翻页在 `page_curl.dart`，
/// 朗读状态机在 `reader_tts.dart`，弹窗与控制条在 `reader_sheets.dart`。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.aid, required this.cid, this.offset});

  final String aid;
  final String cid;

  /// 从书签进来时的章内位置；不传就用保存的阅读进度
  final int? offset;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  // ---- 阅读统计：只在界面可见时计时 ----
  final _watch = Stopwatch()..start();

  void _flushStats() {
    final seconds = _watch.elapsed.inSeconds;
    if (seconds <= 0) return;
    ReadingStats.addSeconds(widget.aid, seconds, cid: _cid);
    final running = _watch.isRunning;
    _watch.reset();
    if (running) _watch.start();
  }

  bool _background = false;

  /// 朗读中退到后台 / 锁屏也算在读，计时不停（暂停了不算）；朗读停下、暂停时若还在后台再停表。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    if (_background) _autoScroll.stop();
    if (!_background) {
      _watch.start();
    } else if (!_tts.isListening) {
      _flushStats();
      _watch.stop();
    }
  }

  // ---- 当前章节与位置 ----
  late String _cid = widget.cid;
  bool _bar = false;
  int _epoch = 0; // 同一章内跳转（书签）时递增，让正文重新定位
  // 打开时已经读完的卷：重读它们不再庆祝。要在 initState 里就记下：懒加载的话，第一次用到时（换卷那一刻）
  // 章末已经把刚读完的这卷记成读完，就被当成以前读过的、不庆祝了
  late final Set<String> _doneAtOpen;
  final _celebrated = <String>{};
  int _dir = 1; // 上次换章的方向：1 往后，-1 往前（换章动画往哪边滑）
  int _lead = 0; // 这章第一屏的左页是不是留给上一章（见 PagedBody.lead）
  bool _seamless = false; // 这次换章是翻页翻过来的，不放换章动画
  int _offset = 0; // 当前读到的字符偏移
  Object? _shown; // 正文第一次显示的标记 (cid, epoch)，用来在那一刻初始化 _offset
  int? _initial; // 从书签进来时的起点，只用一次
  String? _recorded;
  String? _selected;
  final _slide = ValueNotifier<double?>(null); // 正在拖底部进度条：拖到的页（滚动模式是百分比），局部刷新不重建整页
  DateTime _scrubUntil = DateTime(0);
  bool get _scrubbing => DateTime.now().isBefore(_scrubUntil);
  void _beginScrub() => _scrubUntil = DateTime.now().add(const Duration(milliseconds: 650));
  // 返回之前的位置（Kindle 那样）：拖进度条、切章、从目录跳走前记下离开的位置，菜单里出一个「返回」按钮，点了能来回切
  ({String cid, int offset, String title, String label})? _back;
  int _backTurns = 0; // 跳走后又自己翻了几页：翻够 3 页就当已经接着读下去了，不再提示返回
  String? _bookTitle;
  String _chapterTitle = '';
  CatChapter? _nextChapter;
  final _nav = ReaderNav();
  late final ReaderTtsController _tts;
  late final ReaderAutoScrollController _autoScroll;
  ReaderPaceSnapshot _pace = const ReaderPaceSnapshot();
  int _settingsTab = 0;
  ({String cid, int start, int end})? _searchFlash;
  Timer? _searchFlashTimer;

  // ---- 网络预取与取消 ----
  final _preloadCancel = CancelToken();
  final _preloaded = <String>{};
  final _inFlightPrefetch = <String>{};
  final _imagesQueued = <String>{}; // 已经把插图排进下载队列的章节
  final _queuedImageUrls = <String>{}; // 退出阅读器时取消仍未开始的插图预取
  ImageStore? _imageStore;
  bool _bookQueued = false;

  // ---- 页眉页脚的时间、电量：每分钟刷新一次，只重建页脚 ----
  final _status = ValueNotifier<String>('');
  final _pos = ValueNotifier<int>(0); // 滚动模式页脚用的当前字符偏移
  Timer? _clock;

  Future<void> _tick() async {
    final n = DateTime.now();
    var s = '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
    try {
      final level = isWebPreview ? -1 : await Battery().batteryLevel;
      if (level >= 0) s += '  电量 $level%';
    } catch (_) {} // 没有电池的电脑 / 模拟器（返回 -1）/ 取不到就不显示电量
    if (Incognito.on) s += '  无痕';
    if (mounted) _status.value = s;
  }

  // ---- 屏幕常亮、全屏：只在设置变了的时候通知系统 ----
  bool? _keepOn;
  bool? _full;
  double? _bright;
  static const _screen = MethodChannel('ark/screen');

  void _applyChrome(ReaderPrefs p) {
    if (_keepOn != p.keepScreenOn) {
      _keepOn = p.keepScreenOn;
      WakelockPlus.toggle(enable: p.keepScreenOn);
    }
    if (_full != p.fullscreen) {
      _full = p.fullscreen;
      _setUi();
    }
    // 自定义亮度：-1 是交还给系统（原生那边只有安卓实现，别的平台调用失败就算了）
    final want = p.customBrightness ? p.brightness : -1.0;
    if (_bright != want) {
      _bright = want;
      _screen.invokeMethod('setBrightness', {'value': want}).ignore();
    }
  }

  /// 全屏时菜单栏出来才显示状态栏；没开全屏就一直显示
  void _setUi() => SystemChrome.setEnabledSystemUIMode(_full == true && !_bar ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);

  // ---- 音量键翻页：安卓原生那边拦下音量键后通过这个通道回调 ----
  static const _vol = MethodChannel('ark/reader_volume_keys');
  bool _volOn = false;
  DateTime _volTurn = DateTime(0);

  /// 开着、而且不在朗读时才拦音量键（朗读时让它调音量）；只在状态变化时通知原生。
  void _syncVolumeKeys(bool want) {
    want = want && !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !_tts.isSpeaking;
    if (want == _volOn) return;
    _volOn = want;
    _vol.invokeMethod('setEnabled', {'enabled': want}).ignore();
  }

  void _leaveReader() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.bookshelf);
    }
  }

  @override
  void initState() {
    super.initState();
    final initPrefs = ref.read(readerPrefsProvider);
    _pace = ReaderPaceSnapshot.capture();
    _autoScroll = ReaderAutoScrollController(
      createTicker: createTicker,
      initialSpeed: initPrefs.autoScrollSpeed,
      initialTurnSeconds: initPrefs.autoTurnSeconds,
      initialMode: initPrefs.mode,
      onScrollStep: (dx) {
        if (!mounted || !ref.read(chapterProvider((widget.aid, _cid))).hasValue) return AutoScrollStep.unavailable;
        final res = _nav.autoScrollStep?.call(dx);
        return res == null ? AutoScrollStep.unavailable : (res ? AutoScrollStep.scrolled : AutoScrollStep.reachedEnd);
      },
      onNextChapter: () {
        final next = _nextChapter;
        if (!mounted || next == null) return false;
        _go(next.cid, keepAutoScroll: true);
        return true;
      },
      onTurnNext: () {
        if (!mounted || !ref.read(chapterProvider((widget.aid, _cid))).hasValue) return true;
        final (curPage, units) = _nav.page.value;
        if (_nextChapter == null && (units <= 0 || curPage >= units - 1)) return false;
        _nav.next?.call();
        return true;
      },
      onSpeedChanged: (v) => ref.read(readerPrefsProvider.notifier).update(ref.read(readerPrefsProvider).copyWith(autoScrollSpeed: v)),
      onTurnSecondsChanged: (v) => ref.read(readerPrefsProvider.notifier).update(ref.read(readerPrefsProvider).copyWith(autoTurnSeconds: v)),
      onReachedBookEnd: () {
        if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已读到最后，自动阅读已停止'), duration: Duration(seconds: 2)));
      },
    );
    _tts = ReaderTtsController(
      readPrefs: () => ref.read(readerPrefsProvider),
      resolveNoticeMeta: _resolveNoticeMeta,
      onSaveProgress: (offset) => ReadingProgress.save(widget.aid, _cid, offset),
      onAdvanceChapter: _advanceTtsChapter,
      onError: (message) {
        if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('朗读出错，已停止：$message')));
      },
      onListeningChanged: _onTtsListeningChanged,
    );
    _vol.setMethodCallHandler((call) async {
      final inv = ref.read(readerPrefsProvider).volumeInvert;
      // 长按：系统连发得很快，隔一段才翻一页，动画才放得完；菜单、弹窗开着时不连翻
      final now = DateTime.now();
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return; // 设置面板、目录这类弹窗开着时不在下面翻页
      if (call.arguments == true && (_bar || now.difference(_volTurn) < const Duration(milliseconds: 300))) return;
      _volTurn = now;
      // 菜单开着时按音量键先只收起菜单，再按才翻页
      if (_bar && (call.method == 'volumeUp' || call.method == 'volumeDown')) return _toggleBar();
      _autoScroll.pauseByUser();
      if (call.method == (inv ? 'volumeUp' : 'volumeDown')) _nav.next?.call();
      if (call.method == (inv ? 'volumeDown' : 'volumeUp')) _nav.prev?.call();
    });
    _tick();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      _tick();
      if (!_background || _tts.isListening) _flushStats();
      _tts.checkSleepTimer();
    });
    _initial = widget.offset;
    _doneAtOpen = Volumes.done(widget.aid).keys.toSet();
    FontStore.ready.addListener(_onFontReady);
    WidgetsBinding.instance.addObserver(this);
    _applyChrome(ref.read(readerPrefsProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (ref.read(readerPrefsProvider).mode != 0 && !AppPrefs.read('r.tapHintShown', false)) {
          AppPrefs.write('r.tapHintShown', true);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('轻触中央呼出菜单，点两侧翻页，下拉添加书签'), duration: Duration(seconds: 3)),
          );
        }
      } catch (_) {}
    });
  }

  void _onTtsListeningChanged() {
    if (!mounted) return;
    _syncVolumeKeys(ref.read(readerPrefsProvider).volumeKeys);
    if (_background) {
      if (_tts.isListening) {
        _watch.start();
      } else {
        _flushStats();
        _watch.stop();
      }
    }
  }

  Future<({String book, String chapter, String? cover})?> _resolveNoticeMeta() async {
    if (!mounted) return null;
    final novel = ref.read(novelProvider(widget.aid)).value;
    final chapter = novel?.catalogue.expand((v) => v.chapters).where((c) => c.cid == _cid).firstOrNull?.title ?? _chapterTitle;
    final img = novel?.detail.imgUrl ?? '';
    String? cover;
    try {
      if (img.isNotEmpty) cover = await ref.read(imageStoreProvider).path(img);
    } catch (_) {}
    if (!mounted) return null;
    return (book: LibraryStore.shown(widget.aid, novel?.detail.title ?? ''), chapter: chapter, cover: cover);
  }

  Future<String?> _advanceTtsChapter() async {
    if (!mounted) return null;
    final prefs = ref.read(readerPrefsProvider);
    final chapters = ref.read(novelProvider(widget.aid)).value?.catalogue.expand((v) => v.chapters).toList() ?? const <CatChapter>[];
    final next = _nextIn(chapters, chapters.indexWhere((c) => c.cid == _cid), prefs);
    if (next == null) return null;
    _nextChapter = next;
    _go(next.cid, keepTts: true);
    _recordChapter(next.cid, next.title); // 熄屏时界面不重建，build 里记不到读过这章
    final c = await ref.read(chapterProvider((widget.aid, next.cid)).future);
    if (!mounted || _cid != next.cid) return null;
    return c.text;
  }

  Future<void> _startTts(Chapter c) async {
    _autoScroll.stop();
    final started = await _tts.start(c.text, fromOffset: _offset);
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这一章没有可以朗读的文字')));
    }
  }

  void _toggleAutoScroll(ReaderPrefs prefs) {
    if (_autoScroll.isActive) {
      _autoScroll.stop();
      return;
    }
    if (_tts.isSpeaking) _tts.stop();
    _autoScroll.start(mode: prefs.mode);
    if (_bar) {
      setState(() => _bar = false);
      _setUi();
    }
  }

  void _onFontReady() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (!_preloadCancel.isCancelled) _preloadCancel.cancel('reader disposed');
    if (!isWebPreview && _queuedImageUrls.isNotEmpty) {
      _imageStore?.cancelPrefetch(_queuedImageUrls);
    }
    FontStore.ready.removeListener(_onFontReady);
    _screen.invokeMethod('setBrightness', {'value': -1.0}).ignore();
    _syncVolumeKeys(false);
    _vol.setMethodCallHandler(null);
    _clock?.cancel();
    _searchFlashTimer?.cancel();
    _status.dispose();
    _pos.dispose();
    _slide.dispose();
    _nav.page.dispose();
    _autoScroll.dispose();
    _tts.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _flushStats();
    Sync.auto();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 下一章；开了"跳过已读章节"时是后面第一个没读过的（全读过就没有下一章）
  CatChapter? _nextIn(List<CatChapter> chapters, int index, ReaderPrefs prefs) {
    if (index < 0) return null;
    if (!prefs.skipRead) return index < chapters.length - 1 ? chapters[index + 1] : null;
    final readSet = ReadState.readView(widget.aid);
    return chapters.skip(index + 1).where((c) => !readSet.contains(c.cid)).firstOrNull;
  }

  /// 记下读到了这一章：阅读历史、章节统计（每章只记一次，正文显示时也走这里）。
  void _recordChapter(String cid, String title) {
    final novel = ref.read(novelProvider(widget.aid)).value;
    if (_recorded == cid || novel == null) return;
    _recorded = cid;
    scheduleMicrotask(() {
      ReadingHistory.record(widget.aid, novel.detail.title, novel.detail.imgUrl, cid, title);
      ReadingStats.addChapter(widget.aid, cid);
      ReadingStats.setMeta(widget.aid, novel.detail.title, novel.detail.author, novel.detail.imgUrl);
    });
  }

  /// 键盘：→ ↓ 空格 PageDown 下一页，← ↑ Shift+空格 PageUp 上一页，] [ 下一章 / 上一章，Esc 呼出 / 收起菜单。
  KeyEventResult _onKey(KeyEvent e, CatChapter? prev, CatChapter? next, int mode) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final scroll = mode == 0;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.pageDown || (key == LogicalKeyboardKey.space && !shift)) {
      _autoScroll.pauseByUser();
      _nav.next?.call();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp || (key == LogicalKeyboardKey.space && shift)) {
      _autoScroll.pauseByUser();
      _nav.prev?.call();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _autoScroll.pauseByUser();
      scroll ? _nav.scrollBy?.call(80) : _nav.next?.call();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _autoScroll.pauseByUser();
      scroll ? _nav.scrollBy?.call(-80) : _nav.prev?.call();
    } else if (key == LogicalKeyboardKey.bracketRight && next != null) {
      _go(next.cid);
    } else if (key == LogicalKeyboardKey.bracketLeft && prev != null) {
      _go(prev.cid);
    } else if (key == LogicalKeyboardKey.escape) {
      _bar ? _toggleBar() : _leaveReader();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  final _wheelFilter = ScrollWheelTurnFilter();
  Offset _panDelta = Offset.zero;
  bool _panTurned = false;

  /// 分页模式下滚轮 / macOS 触控板双指翻页：经 [ScrollWheelTurnFilter] 去重，单次轻滑最多翻 1 页。
  void _onWheel(PointerSignalEvent e) {
    if (e is PointerScrollInertiaCancelEvent) {
      _wheelFilter.reset();
      return;
    }
    if (_bar || e is! PointerScrollEvent) return;
    final d = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    final turn = _wheelFilter.feed(d, DateTime.now(), kind: e.kind);
    if (turn != 0) _autoScroll.pauseByUser();
    if (turn > 0) _nav.next?.call();
    if (turn < 0) _nav.prev?.call();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (_bar || _panTurned) return;
    _panDelta += e.panDelta;
    if (_panDelta.dx.abs() < 48 && _panDelta.dy.abs() < 56) return;
    _panTurned = true;
    _autoScroll.pauseByUser();
    final forward = _panDelta.dx.abs() >= _panDelta.dy.abs() ? _panDelta.dx < 0 : _panDelta.dy < 0;
    forward ? _nav.next?.call() : _nav.prev?.call();
  }

  void _toggleBar() {
    final nextBar = !_bar;
    if (nextBar) _autoScroll.pauseByUser();
    setState(() => _bar = nextBar);
    _setUi();
  }

  /// 跳到某章的某个位置。[offset] 默认章首；往前翻章时传 [kToEnd]，落在上一章的最后一页。
  /// 手动切章会停掉朗读（[keepTts] 是朗读自己读完一章后的自动续读）；往后翻时把离开的这章标为已读。
  /// [lead] 和 [seamless] 是从正文翻进相邻章节时用的：画面已经翻到位了，不再放换章动画。
  void _go(String cid, {int offset = 0, bool keepTts = false, bool keepAutoScroll = false, int lead = 0, bool seamless = false}) {
    if (cid == _cid && offset == _offset) return;
    if (cid != _cid && ref.read(readerPrefsProvider).chapterToast) {
      final t = ref.read(novelProvider(widget.aid)).value?.catalogue.expand((v) => v.chapters).where((c) => c.cid == cid).firstOrNull?.title;
      if (t != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));
    }
    _flushStats(); // 离开这章前把时间记到这章
    _pace = ReaderPaceSnapshot.capture();
    if (!keepTts && _tts.isSpeaking) _tts.stop();
    if (keepAutoScroll || _autoScroll.isStepping) {
      _autoScroll.notifyChapterSwitched();
    } else {
      _autoScroll.pauseByUser();
    }
    final next = _nextChapter;
    final forward = next != null && cid == next.cid;
    final leavingLocked = ref.read(chapterProvider((widget.aid, _cid))).value?.locked == true;
    // 往后翻出了这一卷、这卷刚好读完：换过去之后弹庆祝卡片
    final finished = forward && !leavingLocked && Volumes.indexOf(widget.aid, cid) != Volumes.indexOf(widget.aid, _cid) ? _justFinished() : null;
    if (forward && !leavingLocked) _markRead();
    ReadingProgress.save(widget.aid, cid, offset == kToEnd ? 0 : offset);
    final order = ref.read(novelProvider(widget.aid)).value?.catalogue.expand((v) => v.chapters).map((c) => c.cid).toList() ?? const <String>[];
    if (finished != null) WidgetsBinding.instance.addPostFrameCallback((_) => _celebrate(finished, hasNext: true));
    setState(() {
      if (cid != _cid) _dir = order.indexOf(cid) >= order.indexOf(_cid) ? 1 : -1;
      _lead = lead;
      _seamless = seamless;
      _offset = offset == kToEnd ? 0 : offset;
      _pos.value = _offset;
      _cid = cid;
      _initial = offset;
      _shown = null;
      _epoch++;
      _bar = false;
    });
  }

  /// 当前这章所在的卷，读完这章就整卷读完了、而且这次还没庆祝过：返回卷序号，否则 null。
  int? _justFinished() {
    if (Incognito.on || !AppPrefs.read(P.volumeDone, true)) return null;
    final i = Volumes.indexOf(widget.aid, _cid);
    if (i < 0) return null;
    final v = Volumes.of(widget.aid)[i];
    if (_doneAtOpen.contains(v.title) || _celebrated.contains(v.title) || v.textCids.isEmpty) return null;
    final read = ReadState.readView(widget.aid);
    return v.textCids.every((c) => c == _cid || read.contains(c)) ? i : null;
  }

  Future<void> _celebrate(int index, {required bool hasNext}) async {
    final v = Volumes.of(widget.aid)[index];
    if (!mounted || !_celebrated.add(v.title)) return;
    if (!hasNext) _markRead(); // 有下一章时 _go 已标过，_cid 也已经换成下一章了
    _flushStats();
    final fallback = ref.read(novelProvider(widget.aid)).value?.detail.imgUrl ?? '';
    final cover = ref.read(volumeCoverQueueProvider).volCover(widget.aid, v, fallback);
    final r = await showVolumeDone(context, aid: widget.aid, vol: v, index: index, cover: cover, hasNext: hasNext);
    if (r == VolumeDoneAction.shelf && mounted) _leaveReader();
  }

  /// 换章时的衔接：翻页模式新的一章像翻过一页那样从翻页方向滑进来、旧的滑出去；滚动模式淡入。关了翻页动画就直接换。
  /// [child] 按章节 id 做 key，所以同一章里改字号、跳书签不会触发。
  Widget _chapterSwitch(ReaderPrefs prefs, Widget child) {
    if (!prefs.pageAnim) return child;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: _seamless ? Duration.zero : Duration(milliseconds: prefs.mode == 0 ? 220 : 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
        transitionBuilder: (c, a) {
          if (prefs.mode == 0) return FadeTransition(opacity: a, child: c);
          final incoming = c.key == ValueKey(_cid);
          // 离开的那章动画从 1 倒着走到 0，所以终点写在 begin 上
          final from = Offset(incoming ? _dir.toDouble() : -_dir.toDouble(), 0);
          // 结构不能随 _seamless 变，不然正文会被重建
          final position = _seamless ? const AlwaysStoppedAnimation(Offset.zero) : Tween(begin: from, end: Offset.zero).animate(a);
          return SlideTransition(position: position, child: IgnorePointer(ignoring: !incoming, child: c));
        },
        child: child,
      ),
    );
  }

  /// 本卷进度：前面的章按读完算，加上这章读到的比例 [f]，每章一样重。找不到所在的卷时就是本章进度。
  double _volumeProgress(double f, [String? cid]) {
    cid ??= _cid;
    final v = Volumes.of(widget.aid).where((v) => v.cids.contains(cid)).firstOrNull;
    if (v == null) return f;
    return (v.cids.indexOf(cid) + f) / v.cids.length;
  }

  /// 这章是一卷的第一章时，那一卷的封面（宽屏双页才用）
  String? _coverOf(String cid, ReaderPrefs prefs, String fallback) {
    if (!prefs.dual || MediaQuery.sizeOf(context).width < 900) return null;
    return volumeCoverOf(ref, widget.aid, cid, fallback);
  }

  /// 正文读到底：受限章节只有一句说明，一打开就“到底”了，不算读过；往后翻过去时 [_go] 照常标记。
  void _onEnd() {
    if (ref.read(chapterProvider((widget.aid, _cid))).value?.locked != true) _markRead();
  }

  void _markRead() {
    final len = ref.read(chapterProvider((widget.aid, _cid))).value?.text.length ?? 0;
    ReadState.mark(widget.aid, _cid, len);
  }

  void _markBack() {
    final len = ref.read(chapterProvider((widget.aid, _cid))).value?.text.length ?? 0;
    final label = ref.read(readerPrefsProvider).mode == 0 ? '${len == 0 ? 0 : (_offset * 100 ~/ len).clamp(0, 100)}%' : '第 ${_nav.page.value.$1 + 1} 页';
    _back = (cid: _cid, offset: _offset, title: _chapterTitle, label: label);
    _backTurns = 0;
  }

  /// 回到记下的位置，同时把现在的位置记成新的「返回」点
  void _returnBack() {
    final b = _back;
    if (b == null) return;
    _markBack();
    if (b.cid != _cid) {
      _go(b.cid, offset: b.offset);
      return;
    }
    ReadingProgress.save(widget.aid, _cid, b.offset);
    _beginScrub(); // 重新定位触发的保存进度不收起菜单、不算翻页
    setState(() {
      _initial = b.offset;
      _shown = null;
      _epoch++;
    });
  }

  void _saveOffset(int offset) {
    if (_back != null && !_scrubbing && offset != _offset && ++_backTurns >= 3) _back = null;
    // 翻了页（点、滑、音量键）就收起菜单；拖底部进度条跳页、朗读/自动阅读跟着翻页时不收
    if (_bar && !_scrubbing && !_tts.isFollowing && !_autoScroll.isStepping && offset != _offset) {
      setState(() => _bar = false);
      _setUi();
    }
    _offset = offset;
    _pos.value = offset;
    ReadingProgress.save(widget.aid, _cid, offset);
    _tts.onUserOffsetChanged(offset, currentText: () => ref.read(chapterProvider((widget.aid, _cid))).value?.text ?? '');
  }

  // ---- 书签 ----
  Future<void> _addBookmark({String? selection}) async {
    final text = ref.read(chapterProvider((widget.aid, _cid))).value?.text ?? '';
    var at = _offset.clamp(0, text.length);
    String excerpt;
    if (selection != null && selection.trim().isNotEmpty) {
      // 选中文字：书签落在选中的那一处（从当前页开头往后找，找不到再退回当前位置）
      final idx = text.indexOf(selection.trim(), (at - 200).clamp(0, text.length));
      if (idx >= 0) at = idx;
      excerpt = selection.trim();
      if (excerpt.length > 40) excerpt = excerpt.substring(0, 40);
    } else {
      excerpt = text.substring(at, (at + 40).clamp(0, text.length)).replaceAll(RegExp(r'[\s　]+'), ' ').trim();
    }
    final added = await Bookmarks.toggle(widget.aid, _bookTitle ?? '', _cid, _chapterTitle, at, excerpt);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added ? '已加书签' : '已取消书签'), duration: const Duration(seconds: 1)));
    }
  }

  // ---- 选字菜单与高亮备注 ----
  bool get _hasSelection => (_selected ?? '').isNotEmpty;

  /// 选中的文字变成正则：空白（含缩进、换行）都换成 `\s*`，这样跨段选中也能匹配原文。
  static String _patternOf(String selected) => selected.split(RegExp(r'[\s　]+')).where((e) => e.isNotEmpty).map(RegExp.escape).join(r'\s*');

  /// 只保留我们需要的几项，不带系统自带的全选、分享、搜索、翻译。
  Widget _selectionMenu(BuildContext context, SelectableRegionState state) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: [
      ContextMenuButtonItem(
        label: hz(context, '复制'),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: _selected ?? ''));
          state.clearSelection();
          state.hideToolbar();
        },
      ),
      ContextMenuButtonItem(label: hz(context, '替换/屏蔽'), onPressed: () => _replaceFromSelection(state)),
      ContextMenuButtonItem(label: hz(context, '高亮'), onPressed: () => _highlightSelection(state)),
      ContextMenuButtonItem(label: hz(context, '变色'), onPressed: () => _colorSelection(state)),
      ContextMenuButtonItem(
        label: hz(context, '加书签'),
        onPressed: () {
          final text = _selected ?? '';
          state.clearSelection();
          state.hideToolbar();
          _addBookmark(selection: text);
        },
      ),
    ],
  );

  Future<void> _replaceFromSelection(SelectableRegionState state) async {
    final text = (_selected ?? '').trim();
    state.clearSelection();
    state.hideToolbar();
    if (text.isEmpty) return;
    final rule = await showRuleDialog(context, initial: ReplaceRule(pattern: _patternOf(text), replacement: '', kind: RuleKind.replace));
    if (rule == null) return;
    await ReplaceRules.save([...ReplaceRules.all(), rule]);
    if (mounted) ref.invalidate(chapterProvider);
  }

  /// 高亮选中的文字：同一本书里相同的文字只有一条高亮规则，所有出现的地方共用一份备注。随后直接打开备注框。
  Future<void> _highlightSelection(SelectableRegionState state) async {
    final text = (_selected ?? '').trim();
    state.clearSelection();
    state.hideToolbar();
    if (text.isEmpty) return;
    final pattern = _patternOf(text);
    final rules = ReplaceRules.all();
    var rule = rules.where((r) => r.kind == RuleKind.highlight && r.pattern == pattern && (r.aid == widget.aid || r.aid.isEmpty)).firstOrNull;
    if (rule == null) {
      rule = ReplaceRule(pattern: pattern, replacement: '', kind: RuleKind.highlight, color: ruleColors[2], name: text.length <= 8 ? text : '', id: 'h${DateTime.now().microsecondsSinceEpoch}', aid: widget.aid);
      await ReplaceRules.save([...rules, rule]);
      if (mounted) ref.invalidate(chapterProvider);
    }
    if (mounted) await _editNote(rule);
  }

  /// 变色选中的文字：只改字的颜色、不带备注（比如给人物名分色）。同一本书里相同的文字共用一条规则，再选一次可以换色、取消。
  Future<void> _colorSelection(SelectableRegionState state) async {
    final text = (_selected ?? '').trim();
    state.clearSelection();
    state.hideToolbar();
    if (text.isEmpty) return;
    final pattern = _patternOf(text);
    final rules = ReplaceRules.all();
    final old = rules.where((r) => r.kind == RuleKind.color && r.pattern == pattern && r.aid == widget.aid).firstOrNull;
    var color = old?.color ?? ruleColors[5];
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('变色：${text.length > 12 ? '${text.substring(0, 12)}…' : text}'),
          content: SingleChildScrollView(child: ColorPickerField(color: color, sample: text.length > 8 ? text.substring(0, 8) : text, onChanged: (c) => setLocal(() => color = c))),
          actions: [
            if (old != null) TextButton(onPressed: () => Navigator.pop(context, -1), child: const Text('取消变色')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, color), child: const Text('确定')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await ReplaceRules.save(
      old == null
          ? [...rules, ReplaceRule(pattern: pattern, replacement: '', kind: RuleKind.color, color: picked, id: 'c${DateTime.now().microsecondsSinceEpoch}', aid: widget.aid)]
          : [for (final r in rules) if (!identical(r, old)) r else if (picked != -1) r.copyWith(color: picked)],
    );
    if (mounted) ref.invalidate(chapterProvider);
  }

  // 正文里鼠标拖动是选字，不滚动不翻页（翻页用滚轮、键盘、点两侧）
  Widget _selectable(Widget child) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(dragDevices: ScrollConfiguration.of(context).dragDevices.difference({PointerDeviceKind.mouse})),
    child: SelectionArea(onSelectionChanged: (c) => _selected = c?.plainText, contextMenuBuilder: _selectionMenu, child: child),
  );

  /// 点高亮文字：显示并修改备注，也可以换颜色、取消高亮。
  Future<void> _editNote(ReplaceRule rule) async {
    final controller = TextEditingController(text: RuleNotes.get(widget.aid, rule.id));
    var color = rule.color;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(rule.label),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: controller, minLines: 3, maxLines: 8, decoration: const InputDecoration(hint: Text('写点备注：身份、关系、伏笔……', maxLines: 1, overflow: TextOverflow.ellipsis))),
                const SizedBox(height: 12),
                ColorPickerField(color: color, highlight: true, sample: rule.label.length > 8 ? rule.label.substring(0, 8) : rule.label, onChanged: (c) => setLocal(() => color = c)),
              ],
            ),
          ),
          actions: [
            if (rule.aid.isNotEmpty) TextButton(onPressed: () => Navigator.pop(context, 'remove'), child: const Text('取消高亮')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('保存')),
          ],
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose()); // 弹窗关掉的这一帧还在用
    if (result == null) return;
    final text = controller.text;
    final rules = ReplaceRules.all();
    if (result == 'remove') {
      await ReplaceRules.save([for (final r in rules) if (r.id != rule.id) r]);
      await RuleNotes.set(widget.aid, rule.id, '');
    } else {
      await RuleNotes.set(widget.aid, rule.id, text);
      if (color != rule.color) await ReplaceRules.save([for (final r in rules) r.id == rule.id ? r.copyWith(color: color) : r]);
    }
    if (mounted) {
      ref.invalidate(chapterProvider);
      setState(() {});
    }
  }

  void _queueImages(String cid, List<String> images) {
    if (images.isEmpty || isWebPreview || !_imagesQueued.add(cid)) return;
    _queuedImageUrls.addAll(images);
    Future.microtask(() {
      if (!mounted) return;
      final ImageStore store = _imageStore ?? ref.read(imageStoreProvider);
      _imageStore = store;
      store.prefetch(images);
    });
  }

  Widget _floatingBackButton(ReaderPalette palette) => Positioned(
    top: 8,
    left: 8,
    child: SafeArea(
      bottom: false,
      child: IconButton(
        tooltip: hz(context, '返回'),
        style: IconButton.styleFrom(backgroundColor: palette.fg.withValues(alpha: 0.08), foregroundColor: palette.fg),
        icon: const Icon(Icons.arrow_back),
        onPressed: _leaveReader,
      ),
    ),
  );

  /// 加载态：允许轻触唤出顶栏，同时左上角常驻半透明返回键 + 中央章节名提示，避免慢网或无侧滑平台被困在转圈屏。
  Widget _loadingState(ReaderPalette palette, String title) => Stack(
    fit: StackFit.expand,
    children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleBar,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: palette.fg),
                if (title.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: palette.fg.withValues(alpha: 0.8))),
                ],
                const SizedBox(height: 6),
                Text('正在加载章节…', style: TextStyle(fontSize: 12.5, color: palette.fg.withValues(alpha: 0.55))),
              ],
            ),
          ),
        ),
      ),
      if (!_bar) _floatingBackButton(palette),
    ],
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(incognitoProvider, (_, _) => _tick());
    final incognito = ref.watch(incognitoProvider);
    final prefs = ref.watch(readerPrefsProvider);
    final bgImagePath = ref.watch(readerBgImageProvider);
    _autoScroll.syncPrefs(mode: prefs.mode, scrollSpeed: prefs.autoScrollSpeed, turnSeconds: prefs.autoTurnSeconds);
    _syncVolumeKeys(prefs.volumeKeys);
    _applyChrome(prefs);
    final appTheme = Theme.of(context);
    final palette = readerPaletteOf(prefs, appTheme.colorScheme);
    final heading = readerHeadingAccent(context, prefs, palette);
    // 菜单里的强调色：有章节标题色（晴空、角色主题）就用它，和正文是一套
    final accent = heading?.$1 ?? appTheme.colorScheme.primary;
    final readerTheme = readerThemeData(appTheme, palette, accent);
    final isDarkBg = ThemeData.estimateBrightnessForColor(palette.bg) == Brightness.dark;
    final overlayStyle = (isDarkBg ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDarkBg ? Brightness.light : Brightness.dark,
    );

    final novel = ref.watch(novelProvider(widget.aid)).value;
    final chapters = novel?.catalogue.expand((v) => v.chapters).toList() ?? const <CatChapter>[];
    final index = chapters.indexWhere((c) => c.cid == _cid);
    final prev = index > 0 ? chapters[index - 1] : null;
    final next = _nextIn(chapters, index, prefs);
    _nextChapter = next;
    final content = ref.watch(chapterProvider((widget.aid, _cid)));
    // 插图章：一加载好就把整章的图排进下载队列，翻页时不用一张一张现取（网页预览不走图片缓存）
    final images = content.value?.images ?? const <String>[];
    if (images.isNotEmpty) _queueImages(_cid, images);

    // 章节一加载好就预加载后面几章（后台低优队列，跳过已在途/已缓存网络拉取）
    if (index >= 0 && content.hasValue) {
      for (final ahead in chapters.skip(index + 1).take(prefs.prefetch)) {
        if (_preloaded.add(ahead.cid)) {
          Future.microtask(() => _prefetchAhead(ahead.cid, prefs.prefetchWifi));
        }
      }
      if (prefs.prefetch > 0 && prefs.prefetchBook && !_bookQueued && !isWebPreview) {
        _bookQueued = true;
        Future.microtask(() => _cacheBook(chapters, index));
      }
    }

    final title = index >= 0 ? chapters[index].title : '';
    _bookTitle = novel == null ? null : LibraryStore.shown(widget.aid, novel.detail.title);
    _chapterTitle = title;
    final f = FontStore.resolve(prefs.font);
    final style = readerStyle(prefs, palette.fg, family: f.family, fallback: f.fallback);
    final noted = RuleNotes.of(widget.aid).keys.toSet();
    final addon = ref.watch(unlockAddonProvider);
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final readerBg = ReaderBackground(
      baseColor: palette.bg,
      fgColor: palette.fg,
      texture: prefs.bgTexture,
      imagePath: bgImagePath,
      imageOpacity: prefs.bgImageOpacity,
    );
    final hasCustomBg = readerBg.hasCustomLayer;
    final bgKey = Object.hash(prefs.bgTexture, bgImagePath, prefs.bgImageOpacity, _searchFlash?.cid, _searchFlash?.start);
    final chromeConfig = ReaderChromeConfig(
      headerLeft: prefs.headerLeft,
      headerRight: prefs.headerRight,
      footerLeft: prefs.footerLeft,
      footerRight: prefs.footerRight,
      bookTitle: _bodyTitle(_bookTitle ?? ''),
      volumeEta: (frac) => resolveVolumeEtaText(
        aid: widget.aid,
        cid: _cid,
        currentChapterChars: content.value?.text.length ?? 0,
        chapterFraction: frac,
        volumeProgress: _volumeProgress(frac),
        pace: _pace,
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: PopScope(
        canPop: !_bar,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _bar) _toggleBar();
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, e) => _onKey(e, prev, next, prefs.mode),
          child: Listener(
            onPointerSignal: prefs.mode == 0 ? null : _onWheel,
            onPointerPanZoomStart: prefs.mode == 0
                ? null
                : (_) {
                    _panDelta = Offset.zero;
                    _panTurned = false;
                  },
            onPointerPanZoomUpdate: prefs.mode == 0 ? null : _onPanZoomUpdate,
            child: Scaffold(
              resizeToAvoidBottomInset: false, // 键盘盖在上面，不把正文压矮（压矮会重新分页、跳页）
              backgroundColor: palette.bg,
              body: _filtered(
                prefs,
                Stack(
                  children: [
                    Positioned.fill(child: readerBg),
                    _chapterSwitch(
                      prefs,
                      KeyedSubtree(
                        key: ValueKey(_cid),
                        child: content.when(
                          loading: () => _loadingState(palette, title),
                          error: (e, _) => Theme(
                            data: readerTheme,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: _toggleBar,
                                  child: StatePanel(title: '章节加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(chapterProvider((widget.aid, _cid)))),
                                ),
                                if (!_bar) _floatingBackButton(palette),
                              ],
                            ),
                          ),
                          data: (c) {
                            // 自选字体还在后台加载（刚启动就从小组件直接进来时）：等它好了再排版，不然分页按别的字体算
                            if (prefs.font == 2 && !FontStore.ready.value) return _loadingState(palette, title);
                            if (_shown != (_cid, _epoch)) {
                              // 这一章第一次显示：起点取书签 / 保存的进度，之后 _offset 随翻页更新
                              _shown = (_cid, _epoch);
                              final saved = ReadingProgress.of(widget.aid);
                              _offset = _initial ?? (saved?.cid == _cid ? saved!.offset : _offset);
                              _initial = null;
                            }
                            _recordChapter(_cid, title);
                            InlineSpan spanOfHighlight(int from, int to, (int, int)? hl) {
                              final activeHl = _tts.text == c.text
                                  ? hl
                                  : (_searchFlash != null && _searchFlash!.cid == _cid ? (_searchFlash!.start, _searchFlash!.end) : null);
                              return buildSpan(c, from, to, style, noted, activeHl, accent);
                            }
                            InlineSpan spanOf(int from, int to) => spanOfHighlight(from, to, _tts.highlight.value);
                            final key = ValueKey((_cid, _epoch, prefs.mode));
                            void onMark(Mark m) => _onMarkTap(m, palette, accent);
                            final fallbackCover = novel?.detail.imgUrl ?? '';
                            // 相邻章节：有缓存、或者预加载已经取了才接上，不为这个多联网（预加载关了、不在 Wi-Fi 时就还是原来的换章动画）
                            ChapterPeek? peek(CatChapter? ch) {
                              if (ch == null) return null;
                              final p = chapterProvider((widget.aid, ch.cid));
                              if (!isLocalAid(widget.aid) && !ChapterCache.has(widget.aid, ch.cid) && !ref.exists(p)) return null;
                              final v = ref.watch(p).value;
                              if (v == null) return null;
                              return ChapterPeek(
                                chapter: v,
                                title: _bodyTitle(ch.title),
                                spanOf: (from, to) => buildSpan(v, from, to, style, noted),
                                cover: _coverOf(ch.cid, prefs, fallbackCover),
                                volumeProgress: (f) => _volumeProgress(f, ch.cid),
                              );
                            }

                            return prefs.mode == 0
                                ? ScrollBody(
                                    key: key,
                                    chapter: c,
                                    spanOf: spanOf,
                                    spanOfHighlight: spanOfHighlight,
                                    highlight: _tts.highlight,
                                    style: style,
                                    margin: prefs.margin,
                                    title: _bodyTitle(title),
                                    headingAccent: heading,
                                    startOffset: _offset,
                                    onOffset: _saveOffset,
                                    onEnd: _onEnd,
                                    // 全书最后一章滑到底再往后：这卷刚读完就庆祝一下
                                    onNext: next == null ? (_justFinished() == null ? null : () => _celebrate(_justFinished()!, hasNext: false)) : () => _go(next.cid),
                                    nextLabel: next == null ? '读完了' : '下一章',
                                    wrap: _selectable,
                                    onTapZone: _toggleBar,
                                    menuOpen: () => _bar,
                                    tapZone: prefs.tapZone,
                                    tapInvert: prefs.tapInvert,
                                    onMark: onMark,
                                    nav: _nav,
                                    hasSelection: () => _hasSelection,
                                    onPullDown: _addBookmark,
                                    marked: () => Bookmarks.has(widget.aid, _cid, _offset),
                                    onUserInteract: _autoScroll.pauseByUser,
                                    showHeader: prefs.showStatus && chromeConfig.hasHeader,
                                  )
                                : PagedBody(
                                    key: key,
                                    chapter: c,
                                    spanOf: spanOf,
                                    spanOfHighlight: spanOfHighlight,
                                    highlight: _tts.highlight,
                                    style: style,
                                    margin: prefs.margin,
                                    title: _bodyTitle(title),
                                    headingAccent: heading,
                                    prevChapter: peek(prev),
                                    nextChapter: peek(next),
                                    volumeCover: _coverOf(_cid, prefs, fallbackCover),
                                    lead: _lead,
                                    arrivedBack: _seamless && _dir < 0,
                                    onTurn: (dir, lead, offset) => _go(dir > 0 ? next!.cid : prev!.cid, offset: offset, lead: lead, seamless: true),
                                    curl: prefs.mode >= 2,
                                    cover: prefs.mode == 3,
                                    dual: prefs.dual,
                                    status: _status,
                                    showFooter: prefs.showStatus,
                                    animate: prefs.pageAnim,
                                    volumeProgress: _volumeProgress,
                                    onPullDown: _addBookmark,
                                    marked: () => Bookmarks.has(widget.aid, _cid, _offset),
                                    background: palette.bg,
                                    pageBackground: hasCustomBg ? readerBg : null,
                                    backgroundKey: bgKey,
                                    chromeConfig: chromeConfig,
                                    onUserInteract: _autoScroll.pauseByUser,
                                    color: palette.fg,
                                    startOffset: _offset,
                                    onOffset: _saveOffset,
                                    onEnd: _onEnd,
                                    onPrev: prev == null ? null : () => _go(prev.cid, offset: kToEnd),
                                    // 全书最后一章再往后翻：这卷刚读完就庆祝一下
                                    onNext: next == null ? (_justFinished() == null ? null : () => _celebrate(_justFinished()!, hasNext: false)) : () => _go(next.cid),
                                    wrap: _selectable,
                                    onTapZone: _toggleBar,
                                    menuOpen: () => _bar,
                                    tapZone: prefs.tapZone,
                                    tapInvert: prefs.tapInvert,
                                    onMark: onMark,
                                    nav: _nav,
                                    hasSelection: () => _hasSelection,
                                  );
                          },
                        ),
                      ),
                    ),
                    if (content.value?.locked == true && !_bar)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: bottomPad + 44,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 460),
                            child: Material(
                              color: Color.alphaBlend(palette.fg.withValues(alpha: 0.08), palette.bg),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(color: palette.fg.withValues(alpha: 0.16)),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                                child: Row(
                                  children: [
                                    Icon(Icons.lock_outline, size: 20, color: palette.fg.withValues(alpha: 0.7)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        addon == null
                                            ? '本章受网站版权限制无法直接读取，可在设置中了解「妙妙小工具」'
                                            : (!AppPrefs.read(P.unlock, true) ? '「妙妙小工具」已关闭，开启后可尝试读取受限章节' : '扩展通道暂未取到本章（可能为纯插图章或接口不可用）'),
                                        style: TextStyle(fontSize: 13, height: 1.4, color: palette.fg.withValues(alpha: 0.85)),
                                      ),
                                    ),
                                    if (addon != null && AppPrefs.read(P.unlock, true))
                                      TextButton(
                                        style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
                                        onPressed: () => ref.invalidate(chapterProvider((widget.aid, _cid))),
                                        child: const Text('重试'),
                                      ),
                                    TextButton(
                                      style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
                                      onPressed: () => context.push(Routes.settingsSection('unlock')).then((_) {
                                        if (mounted) ref.invalidate(chapterProvider((widget.aid, _cid)));
                                      }),
                                      child: Text(addon == null ? '去了解' : '去设置'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (prefs.mode == 0 && prefs.showStatus && chromeConfig.hasHeader && content.hasValue)
                      Positioned(
                        key: const ValueKey('reader_scroll_header'),
                        left: 0,
                        right: 0,
                        top: 0,
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: palette.bg.withValues(alpha: hasCustomBg ? 0.82 : 1.0),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(prefs.margin, topPad + 8, prefs.margin, 6),
                              child: ValueListenableBuilder<int>(
                                valueListenable: _pos,
                                builder: (_, pos, _) {
                                  final c = content.value!;
                                  final len = c.text.length;
                                  final imgs = c.images.length;
                                  final frac = len > 0 ? (pos / len).clamp(0.0, 1.0) : (imgs > 1 && pos > 0 ? ((pos - 1) / (imgs - 1)).clamp(0.0, 1.0) : 0.0);
                                  final volPct = (_volumeProgress(frac) * 100).floor();
                                  final needEta = chromeConfig.headerLeft == ReaderChromeField.volumeEta || chromeConfig.headerRight == ReaderChromeField.volumeEta;
                                  return ReaderChromeRow(
                                    leftField: chromeConfig.headerLeft,
                                    rightField: chromeConfig.headerRight,
                                    style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.5)),
                                    chapterTitle: _bodyTitle(title),
                                    bookTitle: chromeConfig.bookTitle,
                                    status: _status,
                                    pageProgress: '本章 ${(frac * 100).floor()}% · 本卷 $volPct%',
                                    volumeEta: needEta ? (chromeConfig.volumeEta?.call(frac) ?? '本卷 $volPct%') : '',
                                    volumeProgressText: '本卷 $volPct%',
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (prefs.mode == 0 && prefs.showStatus && chromeConfig.hasFooter && content.hasValue)
                      Positioned(
                        key: const ValueKey('reader_scroll_footer'),
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: palette.bg.withValues(alpha: hasCustomBg ? 0.82 : 1.0),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(prefs.margin, 6, prefs.margin, bottomPad + 8),
                              child: ValueListenableBuilder<int>(
                                valueListenable: _pos,
                                builder: (_, pos, _) {
                                  final c = content.value!;
                                  final len = c.text.length;
                                  final imgs = c.images.length;
                                  final frac = len > 0 ? (pos / len).clamp(0.0, 1.0) : (imgs > 1 && pos > 0 ? ((pos - 1) / (imgs - 1)).clamp(0.0, 1.0) : 0.0);
                                  final volPct = (_volumeProgress(frac) * 100).floor();
                                  final needEta = chromeConfig.footerLeft == ReaderChromeField.volumeEta || chromeConfig.footerRight == ReaderChromeField.volumeEta;
                                  return ReaderChromeRow(
                                    leftField: chromeConfig.footerLeft,
                                    rightField: chromeConfig.footerRight,
                                    style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.5)),
                                    chapterTitle: _bodyTitle(title),
                                    bookTitle: chromeConfig.bookTitle,
                                    status: _status,
                                    pageProgress: '本章 ${(frac * 100).floor()}% · 本卷 $volPct%',
                                    volumeEta: needEta ? (chromeConfig.volumeEta?.call(frac) ?? '本卷 $volPct%') : '',
                                    volumeProgressText: '本卷 $volPct%',
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 亮度遮罩：盖住正文和页脚，不盖菜单栏和朗读/自动阅读条，不挡点击
                    if (prefs.dim > 0) Positioned.fill(key: const ValueKey('reader_dim'), child: IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: prefs.dim)))),
                    // 翻页模式自动翻页的极细底部倒计时进度条
                    Positioned(
                      key: const ValueKey('reader_auto_turn_progress'),
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ReaderAutoTurnProgressBar(controller: _autoScroll, palette: palette, accent: accent),
                    ),
                    // 朗读中或自动阅读中且菜单收起时：底部浮现紧凑胶囊控制条
                    if (!_bar)
                      Positioned(
                        key: const ValueKey('reader_float_bar'),
                        left: 16,
                        right: 16,
                        bottom: bottomPad + 36,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _tts.active,
                          builder: (_, speaking, _) {
                            if (speaking) {
                              return Center(
                                child: ReaderTtsBar(
                                  tts: _tts,
                                  palette: palette,
                                  accent: accent,
                                  onOpenSettings: () => _openTtsSheet(palette, accent),
                                ),
                              );
                            }
                            return ListenableBuilder(
                              listenable: _autoScroll,
                              builder: (_, _) {
                                if (!_autoScroll.isActive) return const SizedBox.shrink();
                                return Center(
                                  child: ReaderAutoScrollBar(
                                    controller: _autoScroll,
                                    palette: palette,
                                    accent: accent,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    // 顶部菜单栏：滑动 + 渐隐平滑过渡（固定 Key 防止条件插入的悬浮条导致与底部栏错位复用动画状态）
                    Positioned(
                      key: const ValueKey('reader_top_bar'),
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ExcludeSemantics(
                        excluding: !_bar,
                        child: IgnorePointer(
                          ignoring: !_bar,
                          child: AnimatedSlide(
                            offset: _bar ? Offset.zero : const Offset(0, -1),
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: _bar ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: Material(
                                color: palette.bg,
                                shape: Border(bottom: BorderSide(color: palette.fg.withValues(alpha: 0.12))), // 不要阴影：阴影会把正文一行字切成两半
                                child: SafeArea(
                                  bottom: false,
                                  child: Row(
                                    children: [
                                      IconButton(tooltip: hz(context, '返回'), icon: Icon(Icons.arrow_back, color: palette.fg), onPressed: _leaveReader),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: appTheme.textTheme.titleMedium?.copyWith(color: palette.fg)),
                                            if (_bookTitle != null) Text(_bookTitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: appTheme.textTheme.bodySmall?.copyWith(color: palette.fg.withValues(alpha: 0.6))),
                                          ],
                                        ),
                                      ),
                                      if (incognito)
                                        Padding(
                                          padding: const EdgeInsets.only(right: 4),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(color: palette.fg.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.visibility_off_outlined, size: 13, color: palette.fg.withValues(alpha: 0.75)),
                                                const SizedBox(width: 4),
                                                Text('无痕', style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.75))),
                                              ],
                                            ),
                                          ),
                                        ),
                                      IconButton(
                                        tooltip: hz(context, '书内搜索'),
                                        visualDensity: VisualDensity.compact,
                                        icon: Icon(Icons.search, size: 22, color: palette.fg),
                                        onPressed: () => _openSearchSheet(novel?.catalogue ?? const [], palette, accent),
                                      ),
                                      IconButton(
                                        tooltip: hz(context, '人物词典'),
                                        visualDensity: VisualDensity.compact,
                                        icon: Icon(Icons.people_outline, size: 22, color: palette.fg),
                                        onPressed: _openCharactersPage,
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 底部菜单栏：滑动 + 渐隐平滑过渡
                    Positioned(
                      key: const ValueKey('reader_bottom_bar'),
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: ExcludeSemantics(
                        excluding: !_bar,
                        child: IgnorePointer(
                          ignoring: !_bar,
                          child: AnimatedSlide(
                            offset: _bar ? Offset.zero : const Offset(0, 1),
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: _bar ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: Material(
                                color: palette.bg,
                                shape: Border(top: BorderSide(color: palette.fg.withValues(alpha: 0.12))),
                                child: SafeArea(
                                  top: false,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ValueListenableBuilder<bool>(
                                        valueListenable: _tts.active,
                                        builder: (_, speaking, _) => speaking
                                            ? ReaderTtsBar(
                                                tts: _tts,
                                                palette: palette,
                                                accent: accent,
                                                embedded: true,
                                                onOpenSettings: () => _openTtsSheet(palette, accent),
                                              )
                                            : ListenableBuilder(
                                                listenable: _autoScroll,
                                                builder: (_, _) => _autoScroll.isActive
                                                    ? ReaderAutoScrollBar(
                                                        controller: _autoScroll,
                                                        palette: palette,
                                                        accent: accent,
                                                        embedded: true,
                                                      )
                                                    : const SizedBox.shrink(),
                                              ),
                                      ),
                                      // 拖的是本章的页（滚动模式是本章的比例），拖的时候上面显示章节名和页码，松手跳过去；跨章用两边的按钮或目录
                                      if (content.hasValue)
                                        ValueListenableBuilder<(int, int)>(
                                          valueListenable: _nav.page,
                                          builder: (context, pg, _) => ValueListenableBuilder<double?>(
                                            valueListenable: _slide,
                                            builder: (context, slide, _) {
                                              final paged = prefs.mode != 0;
                                              final c = content.value!;
                                              final len = c.text.length;
                                              final imgs = c.images.length;
                                              final total = paged ? pg.$2 : 100;
                                              final cur = paged
                                                  ? pg.$1
                                                  : (len > 0
                                                        ? (_pos.value * 100 ~/ len).clamp(0, 100)
                                                        : (imgs > 1 && _pos.value > 0 ? ((_pos.value - 1) * 100 ~/ (imgs - 1)).clamp(0, 100) : 0));
                                              final shown = (slide ?? cur.toDouble()).round();
                                              final label = paged ? '${shown + 1} / $total' : '$shown%';
                                              return Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Padding(
                                                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                                                    child: Row(
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            slide == null ? label : '$title · $label',
                                                            textAlign: _back == null || slide != null ? TextAlign.center : TextAlign.start,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: appTheme.textTheme.bodySmall?.copyWith(color: palette.fg.withValues(alpha: slide == null ? 0.6 : 1), fontWeight: slide == null ? null : FontWeight.w600),
                                                          ),
                                                        ),
                                                        if (_back case final b? when slide == null)
                                                          ConstrainedBox(
                                                            constraints: const BoxConstraints(maxWidth: 220),
                                                            child: TextButton.icon(
                                                              style: TextButton.styleFrom(foregroundColor: palette.fg, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10), side: BorderSide(color: palette.fg.withValues(alpha: 0.25))),
                                                              onPressed: _returnBack,
                                                              icon: const Icon(Icons.undo_rounded, size: 16),
                                                              label: Text(b.cid == _cid ? '返回${b.label}' : '返回「${b.title}」', maxLines: 1, overflow: TextOverflow.ellipsis),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  Row(
                                                    children: [
                                                      IconButton(
                                                        tooltip: hz(context, '上一章'),
                                                        color: palette.fg,
                                                        disabledColor: palette.fg.withValues(alpha: 0.3),
                                                        icon: const Icon(Icons.skip_previous_rounded),
                                                        onPressed: prev == null
                                                            ? null
                                                            : () {
                                                                _markBack();
                                                                _go(prev.cid);
                                                              },
                                                      ),
                                                      Expanded(
                                                        child: total > 1
                                                            ? SliderTheme(
                                                                data: _menuSlider(context, accent, palette),
                                                                child: Slider(
                                                                  min: 0,
                                                                  max: (total - 1).toDouble(),
                                                                  divisions: paged ? total - 1 : null,
                                                                  value: (slide ?? cur.toDouble()).clamp(0, total - 1).toDouble(),
                                                                  onChanged: (v) => _slide.value = v,
                                                                  onChangeEnd: (v) {
                                                                    _slide.value = null;
                                                                    _markBack();
                                                                    _beginScrub(); // 跳页（含仿真翻页动画完成时）触发的保存进度不收起菜单
                                                                    paged ? _nav.toPage?.call(v.round()) : _nav.toFraction?.call(v / 100);
                                                                  },
                                                                ),
                                                              )
                                                            : const SizedBox(height: 48),
                                                      ),
                                                      IconButton(
                                                        tooltip: hz(context, '下一章'),
                                                        color: palette.fg,
                                                        disabledColor: palette.fg.withValues(alpha: 0.3),
                                                        icon: const Icon(Icons.skip_next_rounded),
                                                        onPressed: next == null
                                                            ? null
                                                            : () {
                                                                _markBack();
                                                                _go(next.cid);
                                                              },
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: _tts.active,
                                        builder: (_, speaking, _) => ListenableBuilder(
                                          listenable: _autoScroll,
                                          builder: (_, _) {
                                            final autoActive = _autoScroll.isActive;
                                            return Row(
                                              children: [
                                                for (final item in <(IconData, String, VoidCallback, VoidCallback?)>[
                                                  (Icons.format_list_bulleted_rounded, '目录', () => _openCatalogueSheet(novel?.catalogue ?? const [], palette, accent), null),
                                                  (Bookmarks.has(widget.aid, _cid, _offset) ? Icons.bookmark : Icons.bookmark_border, '书签', _addBookmark, null),
                                                  (
                                                    autoActive ? Icons.stop_circle_outlined : Icons.slow_motion_video_rounded,
                                                    autoActive ? '停自动' : '自动阅读',
                                                    () => _toggleAutoScroll(prefs),
                                                    null,
                                                  ),
                                                  (
                                                    speaking ? Icons.stop_circle_outlined : Icons.record_voice_over_outlined,
                                                    speaking ? '停止' : '朗读',
                                                    () => speaking ? _tts.stop() : content.whenData(_startTts),
                                                    () => _openTtsSheet(palette, accent),
                                                  ),
                                                  (Icons.settings_outlined, '设置', () => _openSettingsSheet(palette, accent), null),
                                                ])
                                                  Expanded(
                                                    child: InkWell(
                                                      onTap: item.$3,
                                                      onLongPress: item.$4,
                                                      child: Padding(
                                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            Icon(item.$1, size: 21, weight: 300, color: palette.fg.withValues(alpha: 0.85)),
                                                            const SizedBox(height: 3),
                                                            Text(item.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.65))),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  SliderThemeData _menuSlider(BuildContext context, Color accent, ReaderPalette palette) => SliderTheme.of(context).copyWith(
    activeTrackColor: accent,
    thumbColor: accent,
    overlayColor: accent.withValues(alpha: 0.12),
    inactiveTrackColor: palette.fg.withValues(alpha: 0.15),
    activeTickMarkColor: Colors.transparent,
    inactiveTickMarkColor: Colors.transparent,
    trackHeight: 2,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0, pressedElevation: 0),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
  );

  /// 灰度、反色、暖色滤镜：合成单个 4×5 矩阵，只包一层 `ColorFiltered`。
  Widget _filtered(ReaderPrefs p, Widget child) {
    final matrix = combineReaderColorMatrix(warm: p.warm, grayscale: p.grayscale, invert: p.invert);
    if (matrix == null) return child;
    return ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: child);
  }

  /// 预加载后续单章：走后台低优队列，跳过已在途请求，退出阅读器自动取消。
  Future<void> _prefetchAhead(String cid, bool wifiOnly) async {
    if (!mounted || _preloadCancel.isCancelled) return;
    if (wifiOnly && !await onWifi()) {
      _preloaded.remove(cid);
      return;
    }
    if (!mounted || _preloadCancel.isCancelled) return;
    if (!_inFlightPrefetch.add(cid)) return;
    try {
      if (!isLocalAid(widget.aid) && !ChapterCache.has(widget.aid, cid) && !Incognito.on) {
        final ticket = ChapterCache.ticket(widget.aid, cid);
        final raw = await runInBackground(
          () => _fetchChapterRaw(
            ref.read(wenku8ClientProvider),
            ref.read(wenku8UrlsProvider),
            ref.read(unlockServiceProvider),
            (c) => ref.read(apiProvider).catalogue(widget.aid, cancelToken: c),
            widget.aid,
            cid,
            cancelToken: _preloadCancel,
          ),
        );
        if (!mounted || _preloadCancel.isCancelled || Incognito.on) return;
        if (!Wenku8Parser.isCopyrightLockedText(raw.text) || raw.images.isNotEmpty) {
          try {
            await ChapterCache.put(widget.aid, cid, raw, ticket: ticket);
          } catch (_) {}
        }
      }
      if (!mounted || _preloadCancel.isCancelled) return;
      final chap = await runInBackground(() => ref.read(chapterProvider((widget.aid, cid)).future));
      if (!mounted || _preloadCancel.isCancelled) return;
      setState(() {}); // 让正文拿到下一章，翻过去时接得上
      if (chap.images.isNotEmpty) _queueImages(cid, chap.images);
    } catch (_) {
      // 真翻到这章时会再报错
    } finally {
      _inFlightPrefetch.remove(cid);
    }
  }

  /// 后台把整本的正文存到离线缓存（不含插图），一章一章慢慢取；先往后，再补前面。退出阅读器就停，下次打开接着来。
  /// 每章之前都重新看一遍设置和网络：中途关掉开关、离开 Wi-Fi（开了仅 Wi-Fi 时）就停。
  Future<void> _cacheBook(List<CatChapter> chapters, int index) async {
    if (isLocalAid(widget.aid)) return;
    for (final c in [...chapters.skip(index + 1), ...chapters.take(index)]) {
      if (!mounted || _preloadCancel.isCancelled || Incognito.on) return;
      if (ChapterCache.has(widget.aid, c.cid) || _inFlightPrefetch.contains(c.cid)) continue;
      final prefs = ref.read(readerPrefsProvider);
      if (prefs.prefetch <= 0 || !prefs.prefetchBook) {
        _bookQueued = false; // 开关关掉了：重新打开时 build 会再排一次（已缓存的章直接跳过）
        return;
      }
      if (prefs.prefetchWifi && !await onWifi()) return; // 不在 Wi-Fi：下次打开阅读器再说
      if (!mounted || _preloadCancel.isCancelled) return;
      if (!_inFlightPrefetch.add(c.cid)) continue;
      final ticket = ChapterCache.ticket(widget.aid, c.cid);
      try {
        final raw = await runInBackground(
          () => _fetchChapterRaw(
            ref.read(wenku8ClientProvider),
            ref.read(wenku8UrlsProvider),
            ref.read(unlockServiceProvider),
            (cancel) => ref.read(apiProvider).catalogue(widget.aid, cancelToken: cancel),
            widget.aid,
            c.cid,
            cancelToken: _preloadCancel,
          ),
        );
        if (!mounted || _preloadCancel.isCancelled || Incognito.on) return;
        if (Wenku8Parser.isCopyrightLockedText(raw.text) && raw.images.isEmpty) continue;
        await ChapterCache.put(widget.aid, c.cid, raw, ticket: ticket);
      } on ChapterLockedException {
        continue; // 受限书取不到的章（插图），跳过
      } catch (_) {
        return; // 断网、取消或被限流：不重试，下次打开再说
      } finally {
        _inFlightPrefetch.remove(c.cid);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// 正文里的章节标题跟阅读设置的「繁体」走（不跟界面繁体）
  String _bodyTitle(String t) => ref.read(readerPrefsProvider).hant ? Hant.loaded?.convert(t) ?? t : t;

  void _openCatalogueSheet(List<CatVolume> volumes, ReaderPalette palette, Color accent) {
    showReaderCatalogueSheet(
      context,
      aid: widget.aid,
      volumes: volumes,
      currentCid: _cid,
      palette: palette,
      accent: accent,
      resolveBookmarkPage: (ctx, b) => bookmarkPage(ref, ctx, b.aid, b.cid, b.chapter, b.offset),
      onSelectChapter: (cid) {
        if (cid == _cid) return;
        _markBack();
        _go(cid);
      },
      onSelectBookmark: (b) => _go(b.cid, offset: b.offset),
      onEditNote: _editNote,
      onOpenCharacters: _openCharactersPage,
      onBookmarksChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// 点击正文高亮词：若绑定了人物词典词条优先弹出「角色浮窗底栏」，否则走原备注编辑逻辑。
  void _onMarkTap(Mark m, ReaderPalette palette, Color accent) {
    final char = BookCharacters.byRuleId(widget.aid, m.rule.id);
    if (char == null) {
      _editNote(m.rule);
      return;
    }
    final catalogue = ref.read(novelProvider(widget.aid)).value?.catalogue ?? const <CatVolume>[];
    showCharacterReaderSheet(
      context,
      aid: widget.aid,
      character: char,
      currentCid: _cid,
      palette: palette,
      accent: accent,
      onSearchAppearances: (terms) {
        if (terms.isEmpty) return;
        _openSearchSheet(
          catalogue,
          palette,
          accent,
          initialQuery: terms.length > 1 ? terms.map(RegExp.escape).join('|') : terms.first,
          initialRegex: terms.length > 1,
          initialScope: BookSearchScope.allCached,
        );
      },
      onOpenDictionary: _openCharactersPage,
      onChanged: () {
        if (mounted) {
          ref.invalidate(chapterProvider);
          setState(() {});
        }
      },
    );
  }

  void _openSearchSheet(
    List<CatVolume> catalogue,
    ReaderPalette palette,
    Color accent, {
    String? initialQuery,
    bool initialRegex = false,
    BookSearchScope? initialScope,
  }) {
    final currentText = ref.read(chapterProvider((widget.aid, _cid))).value?.text;
    showBookSearchSheet(
      context,
      aid: widget.aid,
      catalogue: catalogue,
      currentCid: _cid,
      currentChapterText: currentText,
      initialQuery: initialQuery,
      initialRegex: initialRegex,
      initialScope: initialScope,
      palette: palette,
      accent: accent,
      onSelectHit: _jumpToSearchHit,
    );
  }

  void _jumpToSearchHit(BookSearchHit hit) {
    _searchFlashTimer?.cancel();
    _searchFlash = (cid: hit.cid, start: hit.offset, end: hit.offset + hit.matchLength);
    _searchFlashTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _searchFlash = null);
    });
    if (hit.cid == _cid && hit.offset == _offset) {
      setState(() => _bar = false);
      _setUi();
      return;
    }
    _markBack();
    _go(hit.cid, offset: hit.offset);
  }

  Future<void> _openCharactersPage() async {
    _flushStats();
    if (!_tts.isSpeaking) _watch.stop();
    _syncVolumeKeys(false);
    await context.push(Routes.characters(widget.aid));
    if (!mounted) return;
    ref.invalidate(chapterProvider);
    if (!_background) _watch.start();
    _syncVolumeKeys(ref.read(readerPrefsProvider).volumeKeys);
    setState(() {});
  }

  void _openTtsSheet(ReaderPalette palette, Color accent) {
    showReaderTtsSheet(context, tts: _tts, palette: palette, accent: accent);
  }

  void _openSettingsSheet(ReaderPalette palette, Color accent) {
    showReaderSettingsSheet(
      context,
      initialTab: _settingsTab,
      onTabChanged: (tab) => _settingsTab = tab,
      onOpenTtsSettings: () {
        final prefs = ref.read(readerPrefsProvider);
        final app = Theme.of(context);
        final pal = readerPaletteOf(prefs, app.colorScheme);
        final acc = readerHeadingAccent(context, prefs, pal)?.$1 ?? app.colorScheme.primary;
        _openTtsSheet(pal, acc);
      },
      onOpenMoreSettings: () async {
        _flushStats();
        if (!_tts.isSpeaking) _watch.stop();
        _syncVolumeKeys(false);
        await context.push(Routes.settingsSection('reading'));
        if (!mounted) return;
        if (!_background) _watch.start();
        _syncVolumeKeys(ref.read(readerPrefsProvider).volumeKeys);
      },
    );
  }
}
