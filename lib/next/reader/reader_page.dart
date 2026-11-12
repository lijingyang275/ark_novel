import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../app_prefs.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../color_picker.dart';
import '../data.dart';
import '../env.dart';
import '../fonts.dart';
import '../hant.dart';
import '../history.dart';
import '../image_cache.dart' show imageStoreProvider;
import '../incognito.dart';
import '../library.dart' show LibraryStore;
import '../net_state.dart';
import '../pages/novel_page.dart';
import '../pages/rules_page.dart' show showRuleDialog;
import '../progress.dart';
import '../read_state.dart';
import '../router.dart';
import '../rules.dart';
import '../settings.dart';
import '../stats.dart';
import '../sync.dart';
import '../volumes.dart';
import '../theme.dart';
import '../theme_doodle.dart';
import '../theme_squire.dart';
import '../unlock.dart';
import '../widgets.dart';
import '../x_list.dart';
import 'paginator.dart';
import 'reader_body.dart';
import 'tts_notice.dart';
import 'volume_done.dart';
import '../text.dart';

/// 每个非空行当一段：去掉网页里零散的空白，统一首行缩进两个全角空格；全角英文、数字转半角。
String formatChapter(String raw) => halfWidth(raw).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).map((l) => '　　$l').join('\n');

/// 「Ｄｉｖｅ　Ｍａｓｓｉｖｅｌｙ」这种全角英文每个字母占一个汉字宽，排出来字距很怪：字母、数字转半角，
/// 英文之间的全角空格、连字符也换成半角。一个字换一个字，阅读进度、书签的位置不变。
String halfWidth(String s) => s
    .replaceAllMapped(RegExp('[０-９Ａ-Ｚａ-ｚ]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
    .replaceAllMapped(RegExp(r'(?<=[0-9A-Za-z])[　－](?=[0-9A-Za-z])'), (m) => m[0] == '　' ? ' ' : '-');

/// 章节：先查离线缓存，再联网；套用替换规则、统一缩进后算出高亮位置。
/// 读过的章节在内存里留 3 分钟（预加载的下一章、来回翻章都不用重新取），之后释放。
final chapterProvider = FutureProvider.autoDispose.family<Chapter, (String, String)>((ref, key) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 3), link.close);
  ref.onDispose(timer.cancel);
  final hantOn = ref.watch(readerPrefsProvider.select((p) => p.hant));
  var raw = await ChapterCache.get(key.$1, key.$2);
  if (raw != null && isLockedContent(raw) && ref.read(unlockServiceProvider).enabled) raw = null; // 以前存下的「因版权问题…」，重新取
  if (raw == null) {
    final ticket = ChapterCache.ticket(key.$1, key.$2);
    try {
      raw = await ref.read(apiProvider).chapter(key.$1, key.$2);
    } on ChapterLockedException catch (e) {
      // 受限书里取不到的章（多半是插图）：给一句说明照常往后翻；不存缓存，下次还会再试
      final text = formatChapter(e.message);
      return Chapter(text: text, images: const [], marks: ReplaceRules.marks(text, null, key.$1), locked: true);
    }
    // 读过的章节顺手存下来，断网也能再看；写失败不影响阅读。取的这会儿刚好清了缓存、或者开启了无痕阅读时不写回去
    if (!Incognito.on) {
      try {
        await ChapterCache.put(key.$1, key.$2, raw, ticket: ticket);
      } catch (_) {}
    }
  }
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
  if (prefs.mode == 0 || ChapterCache.length(aid, cid) == null) return Future.value();
  final size = MediaQuery.sizeOf(context);
  final view = MediaQuery.viewPaddingOf(context);
  final key = (aid, cid, title, offset, prefs, size, view, PagedBody.lastLayout, ChapterCache.length(aid, cid));
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

class _Palette {
  const _Palette(this.bg, this.fg);

  final Color bg;
  final Color fg;
}

/// 「晴空」背景的章节标题色和装饰小旗色
const _skyAccent = (Color(0xFFA8452F), Color(0xFFD9A03F));

/// 章节标题的颜色和标题下的装饰线：「晴空」背景是三角旗；角色主题是蜡笔线加小图案（发色按正文背景深浅挑）；其余没有
(Color, Widget Function(double))? _headingAccent(BuildContext context, ReaderPrefs prefs, _Palette palette) {
  if (prefs.theme == 5) return (_skyAccent.$1, (w) => PennantRule(line: _skyAccent.$1, flag: _skyAccent.$2, width: w));
  final art = CharacterArt.of(context);
  if (art == null) return null;
  final line = palette.bg.computeLuminance() < 0.25 ? art.accentDark : art.accentLight;
  return (line, (w) => DoodleRule(motif: art.motif, line: line, accent: art.secondary, width: w));
}

_Palette _paletteOf(ReaderPrefs prefs, ColorScheme scheme) => switch (prefs.theme) {
  0 => const _Palette(Color(0xFFF6F1E7), Color(0xFF2B2A27)),
  1 => const _Palette(Color(0xFFCFE6D0), Color(0xFF263A27)),
  2 => const _Palette(Color(0xFF1C1C1A), Color(0xFFBDBBB2)),
  4 => const _Palette(Colors.black, Color(0xFF9E9C94)), // AMOLED 纯黑，字再暗一点免得刺眼
  5 => const _Palette(Color(0xFFF4ECDC), Color(0xFF3B2C20)), // 晴空：云朵的米白底、深褐字，章节标题赭红带旗
  _ => _Palette(scheme.surface, scheme.onSurface),
};

/// 阅读器：这里只管取章节、预加载、进度、书签、朗读和菜单；排版在 paginator.dart，正文显示在 reader_body.dart，仿真翻页在 page_curl.dart。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.aid, required this.cid, this.offset});

  final String aid;
  final String cid;

  /// 从书签进来时的章内位置；不传就用保存的阅读进度
  final int? offset;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> with WidgetsBindingObserver {
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
    if (!_background) {
      _watch.start();
    } else if (!_listening) {
      _flushStats();
      _watch.stop();
    }
  }

  /// 正在听朗读（开着且没暂停）
  bool get _listening => _speaking && !_paused;

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
  double? _slide; // 正在拖底部进度条：拖到的页（滚动模式是百分比）
  bool _scrubbing = false;
  // 返回之前的位置（Kindle 那样）：拖进度条、切章、从目录跳走前记下离开的位置，菜单里出一个「返回」按钮，点了能来回切
  ({String cid, int offset, String title, String label})? _back;
  int _backTurns = 0; // 跳走后又自己翻了几页：翻够 3 页就当已经接着读下去了，不再提示返回
  String? _bookTitle;
  String _chapterTitle = '';

  // ---- 朗读：按句依次朗读，高亮正在读的句子并跟着翻页，读完一章自动读下一章 ----
  final _tts = FlutterTts();
  bool _speaking = false;
  bool _paused = false; // 从通知栏暂停：句子位置留着，继续时从这句重读
  List<(int, int)> _segs = const []; // 每句在章节正文里的 [start, end)
  String _ttsText = '';
  int _si = 0;
  DateTime _jumped = DateTime(0); // 手动跳句的时刻：刚被打断的那句的"读完"回调要忽略
  bool _skipDone = false; // 跳句后还没忽略过被打断那句的"读完"回调（只忽略一次，新的短句很快读完时不会被一起吞掉）
  DateTime _ttsSavedAt = DateTime(0); // 朗读时上次保存进度的时刻
  DateTime _spokeAt = DateTime(0); // 最近一句开始朗读的时刻：这之后马上发生的翻页是跟读造成的，不是用户翻的
  int _lastPageOffset = -1;
  Timer? _turnTimer;
  DateTime? _sleepAt; // 定时关闭
  bool _stopAtChapterEnd = false;
  CatChapter? _nextChapter;
  final _nav = ReaderNav();

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
    want = want && !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !_speaking;
    if (want == _volOn) return;
    _volOn = want;
    _vol.invokeMethod('setEnabled', {'enabled': want}).ignore();
  }

  @override
  void initState() {
    super.initState();
    _vol.setMethodCallHandler((call) async {
      final inv = ref.read(readerPrefsProvider).volumeInvert;
      // 长按：系统连发得很快，隔一段才翻一页，动画才放得完；菜单、弹窗开着时不连翻
      final now = DateTime.now();
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return; // 设置面板、目录这类弹窗开着时不在下面翻页
      if (call.arguments == true && (_bar || now.difference(_volTurn) < const Duration(milliseconds: 300))) return;
      _volTurn = now;
      // 菜单开着时按音量键先只收起菜单，再按才翻页
      if (_bar && (call.method == 'volumeUp' || call.method == 'volumeDown')) return _toggleBar();
      if (call.method == (inv ? 'volumeUp' : 'volumeDown')) _nav.next?.call();
      if (call.method == (inv ? 'volumeDown' : 'volumeUp')) _nav.prev?.call();
    });
    _tick();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      _tick();
      if (!_background || _listening) _flushStats();
      // 暂停时不会走到 _speakNext，定时关闭在这里检查
      if (_speaking && _paused && _sleepAt != null && DateTime.now().isAfter(_sleepAt!)) _stopTts();
    });
    _initial = widget.offset;
    _doneAtOpen = Volumes.done(widget.aid).keys.toSet();
    FontStore.ready.addListener(_onFontReady);
    WidgetsBinding.instance.addObserver(this);
    _applyChrome(ref.read(readerPrefsProvider));
    _tts.setCompletionHandler(() {
      if (!mounted || !_speaking || _paused) return;
      if (_skipDone && DateTime.now().difference(_jumped).inMilliseconds < 400) {
        _skipDone = false;
        return;
      }
      _skipDone = false;
      _si++;
      _speakNext();
    });
    // 引擎出错（没装中文语音、引擎被系统杀掉）时不会有"读完"回调：停下来，不然一直显示在朗读
    _tts.setErrorHandler((message) {
      if (!mounted || !_speaking) return;
      _stopTts();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('朗读出错，已停止：$message')));
    });
  }

  void _onFontReady() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FontStore.ready.removeListener(_onFontReady);
    _screen.invokeMethod('setBrightness', {'value': -1.0}).ignore();
    _syncVolumeKeys(false);
    _vol.setMethodCallHandler(null);
    _clock?.cancel();
    _status.dispose();
    _pos.dispose();
    _nav.page.dispose();
    _turnTimer?.cancel();
    _tts.setCompletionHandler(() {});
    _tts.setErrorHandler((_) {});
    _tts.stop();
    _notice?.clearCallbacks();
    if (_speaking) _notice?.hide();
    WidgetsBinding.instance.removeObserver(this);
    _flushStats();
    Sync.auto();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 从当前阅读位置所在的句子开始读。
  Future<void> _startTts(Chapter c, {bool fromStart = false}) async {
    _ttsText = c.text;
    _segs = splitSentences(c.text);
    if (_segs.isEmpty) {
      // 纯插图章、空章：自动续读时接着读下一章；手动点朗读时说明一下
      if (fromStart && _speaking) {
        _si = 0;
        return _speakNext();
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这一章没有可以朗读的文字')));
      return;
    }
    final at = fromStart ? 0 : _offset;
    _si = _segs.indexWhere((e) => e.$2 > at);
    if (_si < 0) _si = _segs.length - 1;
    setState(() {
      _speaking = true;
      _paused = false;
    });
    _showNotice();
    await _applyTtsPrefs();
    await _speakNext();
  }

  Future<void> _applyTtsPrefs() async {
    final prefs = ref.read(readerPrefsProvider);
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(prefs.ttsRate);
    await _tts.setPitch(prefs.ttsPitch);
    if (prefs.ttsVoice.isNotEmpty) {
      try {
        await _tts.setVoice({'name': prefs.ttsVoice, 'locale': 'zh-CN'});
      } catch (_) {}
    }
  }

  TtsNotice? _notice;

  /// 通知栏卡片：书名、章节名、封面，按钮接到这里的暂停 / 继续 / 跳句 / 停止
  Future<void> _showNotice() async {
    final n = _notice = await TtsNotice.get();
    if (n == null || !_speaking || !mounted) return;
    n
      ..onPlay = _resumeSpeech
      ..onPause = _pauseSpeech
      ..onStop = _stopTts
      ..onNext = (() => _skipSentence(1))
      ..onPrev = (() => _skipSentence(-1));
    final novel = ref.read(novelProvider(widget.aid)).value;
    final chapter = novel?.catalogue.expand((v) => v.chapters).where((c) => c.cid == _cid).firstOrNull?.title ?? _chapterTitle;
    final img = novel?.detail.imgUrl ?? '';
    // 封面用 App 自己缓存的文件：通知自己联网下载过不了网站的验证
    String? cover;
    try {
      if (img.isNotEmpty) cover = await ref.read(imageStoreProvider).path(img);
    } catch (_) {}
    if (!_speaking || !mounted) return;
    n.show(book: LibraryStore.shown(widget.aid, novel?.detail.title ?? ''), chapter: chapter, cover: cover, playing: !_paused);
  }

  void _pauseSpeech() {
    if (!_speaking || _paused) return;
    _paused = true;
    _jumped = DateTime.now(); // 被打断的这句的"读完"回调不算
    _skipDone = true;
    _tts.stop();
    // 暂停不算在读：在后台的话先把时间记上、停表
    if (_background) {
      _flushStats();
      _watch.stop();
    }
    _showNotice();
  }

  void _resumeSpeech() {
    if (!_speaking || !_paused) return;
    _paused = false;
    if (_background) _watch.start();
    _showNotice();
    _speakNext();
  }

  /// 下一章；开了"跳过已读章节"时是后面第一个没读过的（全读过就没有下一章）
  CatChapter? _nextIn(List<CatChapter> chapters, int index, ReaderPrefs prefs) {
    if (index < 0) return null;
    if (!prefs.skipRead) return index < chapters.length - 1 ? chapters[index + 1] : null;
    final readSet = ReadState.read(widget.aid);
    return chapters.skip(index + 1).where((c) => !readSet.contains(c.cid)).firstOrNull;
  }

  Future<void> _speakNext() async {
    if (!mounted || !_speaking || _paused) return;
    if (_sleepAt != null && DateTime.now().isAfter(_sleepAt!)) return _stopTts();
    if (_si < _segs.length) {
      final (s, e) = _segs[_si];
      _spokeAt = DateTime.now();
      setState(() {});
      _saveTtsProgress(s);
      await _tts.speak(_ttsText.substring(s, e).trim());
      return;
    }
    // 下一章当场算：熄屏时界面不重建，build 里的 _nextChapter 可能还停在上一章
    final prefs = ref.read(readerPrefsProvider);
    final chapters = ref.read(novelProvider(widget.aid)).value?.catalogue.expand((v) => v.chapters).toList() ?? const <CatChapter>[];
    final next = _nextIn(chapters, chapters.indexWhere((c) => c.cid == _cid), prefs);
    if (next == null || _stopAtChapterEnd || !prefs.ttsAutoNext) return _stopTts();
    _nextChapter = next;
    _segs = const [];
    _ttsText = '';
    _go(next.cid, keepTts: true);
    _recordChapter(next.cid, next.title); // 熄屏时界面不重建，build 里记不到读过这章
    // 不等界面重建，直接取下一章接着读（熄屏时界面不重建）
    try {
      final c = await ref.read(chapterProvider((widget.aid, next.cid)).future);
      if (mounted && _speaking && _cid == next.cid) await _startTts(c, fromStart: true);
    } catch (_) {
      _stopTts();
    }
  }

  /// 朗读到的位置隔几秒存一次进度：熄屏听书时正文不跟着翻页，进度只能在这里记，不然进程被杀后回到熄屏前的位置。
  void _saveTtsProgress(int offset) {
    final now = DateTime.now();
    if (now.difference(_ttsSavedAt) < const Duration(seconds: 5)) return;
    _ttsSavedAt = now;
    ReadingProgress.save(widget.aid, _cid, offset);
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

  /// 上一句 / 下一句。
  void _skipSentence(int delta) {
    if (!_speaking || _segs.isEmpty) return;
    _si = (_si + delta).clamp(0, _segs.length - 1);
    _jumped = DateTime.now();
    _skipDone = true;
    _speakNext();
  }

  Future<void> _stopTts() async {
    _turnTimer?.cancel();
    if (_background) {
      _flushStats();
      _watch.stop();
    }
    _paused = false;
    _sleepAt = null;
    _stopAtChapterEnd = false;
    await _tts.stop();
    _notice?.clearCallbacks();
    _notice?.hide();
    if (mounted) setState(() => _speaking = false);
  }

  /// 键盘：→ ↓ 空格 PageDown 下一页，← ↑ Shift+空格 PageUp 上一页，] [ 下一章 / 上一章，Esc 呼出 / 收起菜单。
  KeyEventResult _onKey(KeyEvent e, CatChapter? prev, CatChapter? next, int mode) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final scroll = mode == 0;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.pageDown || (key == LogicalKeyboardKey.space && !shift)) {
      _nav.next?.call();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp || (key == LogicalKeyboardKey.space && shift)) {
      _nav.prev?.call();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      scroll ? _nav.scrollBy?.call(80) : _nav.next?.call();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      scroll ? _nav.scrollBy?.call(-80) : _nav.prev?.call();
    } else if (key == LogicalKeyboardKey.bracketRight && next != null) {
      _go(next.cid);
    } else if (key == LogicalKeyboardKey.bracketLeft && prev != null) {
      _go(prev.cid);
    } else if (key == LogicalKeyboardKey.escape) {
      _bar ? _toggleBar() : Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  DateTime _lastWheel = DateTime(0);

  /// 分页模式下滚轮翻页。滚一下会连发好几个事件，隔一小段时间才算下一次。
  void _onWheel(PointerSignalEvent e) {
    if (_bar || e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 250)) return;
    _lastWheel = now;
    e.scrollDelta.dy > 0 ? _nav.next?.call() : _nav.prev?.call();
  }

  void _toggleBar() {
    setState(() => _bar = !_bar);
    _setUi();
  }

  /// 跳到某章的某个位置。[offset] 默认章首；往前翻章时传 [kToEnd]，落在上一章的最后一页。
  /// 手动切章会停掉朗读（[keepTts] 是朗读自己读完一章后的自动续读）；往后翻时把离开的这章标为已读。
  /// [lead] 和 [seamless] 是从正文翻进相邻章节时用的：画面已经翻到位了，不再放换章动画。
  void _go(String cid, {int offset = 0, bool keepTts = false, int lead = 0, bool seamless = false}) {
    if (cid == _cid && offset == _offset) return;
    if (cid != _cid && ref.read(readerPrefsProvider).chapterToast) {
      final t = ref.read(novelProvider(widget.aid)).value?.catalogue.expand((v) => v.chapters).where((c) => c.cid == cid).firstOrNull?.title;
      if (t != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));
    }
    _flushStats(); // 离开这章前把时间记到这章
    if (!keepTts && _speaking) _stopTts();
    final next = _nextChapter;
    final forward = next != null && cid == next.cid;
    // 往后翻出了这一卷、这卷刚好读完：换过去之后弹庆祝卡片
    final finished = forward && Volumes.indexOf(widget.aid, cid) != Volumes.indexOf(widget.aid, _cid) ? _justFinished() : null;
    if (forward) _markRead();
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
    final read = ReadState.read(widget.aid);
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
    if (r == VolumeDoneAction.shelf && mounted) context.go(Routes.bookshelf);
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
    _scrubbing = true; // 重新定位触发的保存进度不收起菜单、不算翻页
    setState(() {
      _initial = b.offset;
      _shown = null;
      _epoch++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrubbing = false);
  }

  void _saveOffset(int offset) {
    if (_back != null && !_scrubbing && offset != _offset && ++_backTurns >= 3) _back = null;
    // 翻了页（点、滑、音量键）就收起菜单；拖底部进度条跳页、朗读跟着翻页时不收
    final following = _speaking && DateTime.now().difference(_spokeAt).inMilliseconds <= 1200;
    if (_bar && !_scrubbing && !following && offset != _offset) {
      setState(() => _bar = false);
      _setUi();
    }
    _offset = offset;
    _pos.value = offset;
    ReadingProgress.save(widget.aid, _cid, offset);
    // 朗读时用户自己翻页 / 滚动（不是跟读造成的）：停稳后从新位置的句子接着读
    final turned = offset != _lastPageOffset;
    _lastPageOffset = offset;
    if (_speaking && turned && DateTime.now().difference(_spokeAt).inMilliseconds > 1200) {
      _turnTimer?.cancel();
      _turnTimer = Timer(const Duration(milliseconds: 600), () => _readFrom(offset));
    }
  }

  void _readFrom(int offset) {
    if (!_speaking || !mounted || ref.read(chapterProvider((widget.aid, _cid))).value?.text != _ttsText) return;
    final i = _segs.indexWhere((e) => e.$2 > offset);
    if (i < 0 || i == _si) return;
    _si = i;
    _jumped = DateTime.now();
    _skipDone = true;
    _speakNext();
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
          state.hideToolbar();
          _addBookmark(selection: text);
        },
      ),
    ],
  );

  Future<void> _replaceFromSelection(SelectableRegionState state) async {
    final text = (_selected ?? '').trim();
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

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(readerPrefsProvider);
    _syncVolumeKeys(prefs.volumeKeys);
    _applyChrome(prefs);
    final palette = _paletteOf(prefs, Theme.of(context).colorScheme);
    // 菜单里的强调色：有章节标题色（晴空、角色主题）就用它，和正文是一套
    final accent = _headingAccent(context, prefs, palette)?.$1 ?? Theme.of(context).colorScheme.primary;
    final novel = ref.watch(novelProvider(widget.aid)).value;
    final chapters = novel?.catalogue.expand((v) => v.chapters).toList() ?? const <CatChapter>[];
    final index = chapters.indexWhere((c) => c.cid == _cid);
    final prev = index > 0 ? chapters[index - 1] : null;
    final next = _nextIn(chapters, index, prefs);
    _nextChapter = next;
    final content = ref.watch(chapterProvider((widget.aid, _cid)));
    // 插图章：一加载好就把整章的图排进下载队列，翻页时不用一张一张现取（网页预览不走图片缓存）
    final images = content.value?.images ?? const <String>[];
    if (images.isNotEmpty && !isWebPreview && _imagesQueued.add(_cid)) {
      Future.microtask(() => ref.read(imageStoreProvider).prefetch(images));
    }
    // 章节一加载好就预加载后面几章（用 read 触发，且每章只触发一次）
    if (index >= 0 && content.hasValue) {
      for (final ahead in chapters.skip(index + 1).take(prefs.prefetch)) {
        if (_preloaded.add(ahead.cid)) {
          Future.microtask(() async {
            // 只在 Wi-Fi 下预加载：现在不是就先不加载，以后再翻到这章时重新判断
            if (prefs.prefetchWifi && !await onWifi()) {
              _preloaded.remove(ahead.cid);
              return;
            }
            if (!mounted) return;
            final loaded = ref.read(chapterProvider((widget.aid, ahead.cid)).future);
            setState(() {}); // 让正文拿到下一章，翻过去时接得上
            try {
              final images = (await loaded).images;
              if (mounted && images.isNotEmpty && !isWebPreview && _imagesQueued.add(ahead.cid)) ref.read(imageStoreProvider).prefetch(images);
            } catch (_) {} // 真翻到这章时会再报错
          });
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

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e, prev, next, prefs.mode),
      child: Listener(onPointerSignal: prefs.mode == 0 ? null : _onWheel, child: Scaffold(
        resizeToAvoidBottomInset: false, // 键盘盖在上面，不把正文压矮（压矮会重新分页、跳页）
      backgroundColor: palette.bg,
      body: _filtered(prefs, Stack(
        children: [
          _chapterSwitch(prefs, KeyedSubtree(key: ValueKey(_cid), child: content.when(
            loading: () => Center(child: CircularProgressIndicator(color: palette.fg)),
            error: (e, _) => StatePanel(title: '章节加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(chapterProvider((widget.aid, _cid)))),
            data: (c) {
              // 自选字体还在后台加载（刚启动就从小组件直接进来时）：等它好了再排版，不然分页按别的字体算
              if (prefs.font == 2 && !FontStore.ready.value) return Center(child: CircularProgressIndicator(color: palette.fg));
              if (_shown != (_cid, _epoch)) {
                // 这一章第一次显示：起点取书签 / 保存的进度，之后 _offset 随翻页更新
                _shown = (_cid, _epoch);
                final saved = ReadingProgress.of(widget.aid);
                _offset = _initial ?? (saved?.cid == _cid ? saved!.offset : _offset);
                _initial = null;
              }
              _recordChapter(_cid, title);
              final reading = _speaking && prefs.ttsHighlight && _si < _segs.length && _ttsText == c.text ? _segs[_si] : null;
              InlineSpan spanOf(int from, int to) => buildSpan(c, from, to, style, noted, reading, Theme.of(context).colorScheme.primary);
              final heading = _headingAccent(context, prefs, palette);
              final key = ValueKey((_cid, _epoch, prefs.mode, prefs.font, prefs.fontSize, prefs.lineHeight, prefs.margin, c.marks.length, c.text.length));
              void onMark(Mark m) => _editNote(m.rule);
              final fallbackCover = novel?.detail.imgUrl ?? '';
              // 相邻章节：有缓存、或者预加载已经取了才接上，不为这个多联网（预加载关了、不在 Wi-Fi 时就还是原来的换章动画）
              ChapterPeek? peek(CatChapter? ch) {
                if (ch == null) return null;
                final p = chapterProvider((widget.aid, ch.cid));
                if (!ChapterCache.has(widget.aid, ch.cid) && !ref.exists(p)) return null;
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
                      follow: reading?.$1,
                      nav: _nav,
                      hasSelection: () => _hasSelection,
                      onPullDown: _addBookmark,
                      marked: () => Bookmarks.has(widget.aid, _cid, _offset),
                    )
                  : PagedBody(
                      key: key,
                      chapter: c,
                      spanOf: spanOf,
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
                      follow: reading?.$1,
                      nav: _nav,
                      hasSelection: () => _hasSelection,
                    );
            },
          ))),
          if (prefs.mode == 0 && prefs.showStatus && content.hasValue)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: ColoredBox(
                  color: palette.bg,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(prefs.margin, 6, prefs.margin, MediaQuery.viewPaddingOf(context).bottom + 8),
                    child: ValueListenableBuilder<int>(
                      valueListenable: _pos,
                      builder: (_, pos, _) {
                        final len = content.value!.text.length;
                        final f = len == 0 ? 0.0 : (pos / len).clamp(0.0, 1.0);
                        return ReaderFooter(status: _status, right: '本章 ${(f * 100).floor()}% · 本卷 ${(_volumeProgress(f) * 100).floor()}%', style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.5)));
                      },
                    ),
                  ),
                ),
              ),
            ),
          // 亮度遮罩：盖住正文和页脚，不盖菜单栏，不挡点击
          if (prefs.dim > 0) Positioned.fill(child: IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: prefs.dim)))),
          if (_bar) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                color: palette.bg,
                shape: Border(bottom: BorderSide(color: palette.fg.withValues(alpha: 0.12))), // 不要阴影：阴影会把正文一行字切成两半
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(icon: Icon(Icons.arrow_back, color: palette.fg), onPressed: () => context.pop()),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: palette.fg)),
                            if (_bookTitle != null) Text(_bookTitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.fg.withValues(alpha: 0.6))),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Material(
                color: palette.bg,
                shape: Border(top: BorderSide(color: palette.fg.withValues(alpha: 0.12))),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 拖的是本章的页（滚动模式是本章的比例），拖的时候上面显示章节名和页码，松手跳过去；跨章用两边的按钮或目录
                      if (content.hasValue)
                        ValueListenableBuilder<(int, int)>(
                          valueListenable: _nav.page,
                          builder: (context, pg, _) {
                            final paged = prefs.mode != 0;
                            final len = content.value!.text.length;
                            final total = paged ? pg.$2 : 100;
                            final cur = paged ? pg.$1 : (len == 0 ? 0 : (_pos.value * 100 ~/ len).clamp(0, 100));
                            final shown = (_slide ?? cur.toDouble()).round();
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
                                          _slide == null ? label : '$title · $label',
                                          textAlign: _back == null || _slide != null ? TextAlign.center : TextAlign.start,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.fg.withValues(alpha: _slide == null ? 0.6 : 1), fontWeight: _slide == null ? null : FontWeight.w600),
                                        ),
                                      ),
                                      if (_back case final b? when _slide == null)
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
                                    IconButton(tooltip: hz(context, '上一章'), color: palette.fg, disabledColor: palette.fg.withValues(alpha: 0.3), icon: const Icon(Icons.skip_previous_rounded), onPressed: prev == null ? null : () {
                                      _markBack();
                                      _go(prev.cid);
                                    }),
                                    Expanded(
                                      child: total > 1
                                          ? SliderTheme(
                                              data: _menuSlider(context, accent, palette),
                                              child: Slider(
                                              min: 0,
                                              max: (total - 1).toDouble(),
                                              divisions: paged ? total - 1 : null,
                                              value: (_slide ?? cur.toDouble()).clamp(0, total - 1).toDouble(),
                                              onChanged: (v) => setState(() => _slide = v),
                                              onChangeEnd: (v) {
                                                setState(() => _slide = null);
                                                _markBack();
                                                _scrubbing = true; // 跳页触发的保存进度不收起菜单
                                                paged ? _nav.toPage?.call(v.round()) : _nav.toFraction?.call(v / 100);
                                                WidgetsBinding.instance.addPostFrameCallback((_) => _scrubbing = false);
                                              },
                                            ),
                                            )
                                          : const SizedBox(height: 48),
                                    ),
                                    IconButton(tooltip: hz(context, '下一章'), color: palette.fg, disabledColor: palette.fg.withValues(alpha: 0.3), icon: const Icon(Icons.skip_next_rounded), onPressed: next == null ? null : () {
                                      _markBack();
                                      _go(next.cid);
                                    }),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      Row(
                        children: [
                          for (final (icon, label, onTap) in <(IconData, String, VoidCallback)>[
                            (Icons.format_list_bulleted_rounded, '目录', () => _showCatalogue(novel?.catalogue ?? const [], _cid)),
                            (Bookmarks.has(widget.aid, _cid, _offset) ? Icons.bookmark : Icons.bookmark_border, '书签', _addBookmark),
                            (_speaking ? Icons.stop_circle_outlined : Icons.record_voice_over_outlined, _speaking ? '停止' : '朗读', () => _speaking ? _stopTts() : content.whenData(_startTts)),
                            (Icons.tune, '朗读设置', _showTtsSettings),
                            (Icons.settings_outlined, '设置', _showSettings),
                          ])
                            Expanded(
                              child: InkWell(
                                onTap: onTap,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 21, weight: 300, color: palette.fg.withValues(alpha: 0.85)), const SizedBox(height: 3), Text(label, style: TextStyle(fontSize: 11, color: palette.fg.withValues(alpha: 0.65)))]),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      )),
      )),
    );
  }

  SliderThemeData _menuSlider(BuildContext context, Color accent, _Palette palette) => SliderTheme.of(context).copyWith(
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

  /// 灰度、反色、暖色滤镜：套在整个阅读界面外面（盖在文字和背景上，不改排版）
  Widget _filtered(ReaderPrefs p, Widget child) {
    var w = child;
    if (p.warm > 0) {
      // 暖色：压低蓝色和一点绿色，像护眼模式
      w = ColorFiltered(colorFilter: ColorFilter.matrix([1, 0, 0, 0, 0, 0, 1 - 0.6 * p.warm, 0, 0, 0, 0, 0, 1 - 1.4 * p.warm, 0, 0, 0, 0, 0, 1, 0]), child: w);
    }
    if (p.grayscale) {
      w = ColorFiltered(colorFilter: const ColorFilter.matrix([0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0, 0, 0, 1, 0]), child: w);
    }
    if (p.invert) {
      w = ColorFiltered(colorFilter: const ColorFilter.matrix([-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]), child: w);
    }
    return w;
  }

  final _preloaded = <String>{};
  final _imagesQueued = <String>{}; // 已经把插图排进下载队列的章节
  bool _bookQueued = false;

  /// 后台把整本的正文存到离线缓存（不含插图），一章一章慢慢取；先往后，再补前面。退出阅读器就停，下次打开接着来。
  /// 每章之前都重新看一遍设置和网络：中途关掉开关、离开 Wi-Fi（开了仅 Wi-Fi 时）就停。
  Future<void> _cacheBook(List<CatChapter> chapters, int index) async {
    final api = ref.read(apiProvider);
    for (final c in [...chapters.skip(index + 1), ...chapters.take(index)]) {
      if (!mounted || Incognito.on) return;
      if (ChapterCache.has(widget.aid, c.cid)) continue;
      final prefs = ref.read(readerPrefsProvider);
      if (prefs.prefetch <= 0 || !prefs.prefetchBook) {
        _bookQueued = false; // 开关关掉了：重新打开时 build 会再排一次（已缓存的章直接跳过）
        return;
      }
      if (prefs.prefetchWifi && !await onWifi()) return; // 不在 Wi-Fi：下次打开阅读器再说
      if (!mounted) return;
      final ticket = ChapterCache.ticket(widget.aid, c.cid);
      try {
        final raw = await api.chapter(widget.aid, c.cid);
        if (!mounted || Incognito.on) return;
        await ChapterCache.put(widget.aid, c.cid, raw, ticket: ticket);
      } on ChapterLockedException {
        continue; // 受限书取不到的章（插图），跳过
      } catch (_) {
        return; // 断网或被限流：不重试，下次打开再说
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// 正文里的章节标题跟阅读设置的「繁体」走（不跟界面繁体）
  String _bodyTitle(String t) => ref.read(readerPrefsProvider).hant ? Hant.loaded?.convert(t) ?? t : t;

  /// 目录（按卷分层，当前章所在的卷默认展开）、本书的书签、人物备注。
  void _showCatalogue(List<CatVolume> volumes, String current) {
    final theme = Theme.of(context);
    final read = ReadState.read(widget.aid);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DefaultTabController(
        length: 3,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          builder: (context, scroll) => Column(
            children: [
              const TabBar(tabs: [Tab(child: Text('目录')), Tab(child: Text('书签')), Tab(child: Text('备注'))]),
              Expanded(
                child: TabBarView(
                  children: [
                    ListView(
                      controller: scroll,
                      children: [
                        for (final v in volumes)
                          ExpansionTile(
                            initiallyExpanded: volumes.length == 1 || v.chapters.any((c) => c.cid == current),
                            title: Text(v.title, style: theme.textTheme.titleSmall),
                            subtitle: Text('${v.chapters.where((c) => read.contains(c.cid)).length}/${v.chapters.length} 章已读', style: theme.textTheme.bodySmall),
                            children: [
                              for (final c in v.chapters)
                                ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.only(left: 32, right: 16),
                                  selected: c.cid == current,
                                  leading: read.contains(c.cid) ? const Icon(Icons.check, size: 16) : null,
                                  title: Text(c.title, style: read.contains(c.cid) && c.cid != current ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null),
                                  trailing: ChapterCache.has(widget.aid, c.cid) ? Icon(Icons.download_for_offline_outlined, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)) : null,
                                  onTap: () {
                                    Navigator.pop(context);
                                    if (c.cid == _cid) return;
                                    _markBack();
                                    _go(c.cid);
                                  },
                                ),
                            ],
                          ),
                      ],
                    ),
                    Builder(
                      builder: (context) {
                        final marks = Bookmarks.all(widget.aid);
                        return marks.isEmpty
                            ? const Center(child: Text('还没有书签'))
                            : ListView(
                                children: [
                                  for (final b in marks)
                                    ListTile(
                                      title: Text(b.excerpt.isEmpty ? b.chapter : b.excerpt, maxLines: 2, overflow: TextOverflow.ellipsis),
                                      subtitle: FutureBuilder(
                                        future: bookmarkPage(ref, context, b.aid, b.cid, b.chapter, b.offset),
                                        builder: (_, snap) => Text([b.chapter, if (snap.data case (final p, final n)) '第 $p / $n 页'].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      ),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _go(b.cid, offset: b.offset);
                                      },
                                    ),
                                ],
                              );
                      },
                    ),
                    Builder(
                      builder: (context) {
                        final notes = RuleNotes.of(widget.aid);
                        final rules = ReplaceRules.all().where((r) => r.kind == RuleKind.highlight && notes.containsKey(r.id) && (r.aid.isEmpty || r.aid == widget.aid)).toList();
                        return rules.isEmpty
                            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('还没有备注。\n选中文字点"高亮"，之后点一下高亮的字就能写备注。', textAlign: TextAlign.center)))
                            : ListView(
                                children: [
                                  for (final r in rules)
                                    ListTile(
                                      leading: CircleAvatar(radius: 8, backgroundColor: Color(r.color)),
                                      title: Text(r.label),
                                      subtitle: Text(notes[r.id]!, maxLines: 3, overflow: TextOverflow.ellipsis),
                                    ),
                                ],
                              );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTtsSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final prefs = ref.watch(readerPrefsProvider);
          void set(ReaderPrefs p) {
            ref.read(readerPrefsProvider.notifier).update(p);
            if (_speaking) _applyTtsPrefs();
          }

          // 定时关闭不在 prefs 里，用一次无变化的更新让这个面板重画
          void sleep(DateTime? at, bool chapterEnd) {
            _sleepAt = at;
            _stopAtChapterEnd = chapterEnd;
            ref.read(readerPrefsProvider.notifier).update(prefs.copyWith());
          }

          final hm = _sleepAt == null ? '' : '${_sleepAt!.hour.toString().padLeft(2, '0')}:${_sleepAt!.minute.toString().padLeft(2, '0')}';
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_speaking)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Row(
                        children: [
                          Expanded(child: OutlinedButton.icon(onPressed: () => _skipSentence(-1), icon: const Icon(Icons.skip_previous), label: const Text('上一句'))),
                          const SizedBox(width: 12),
                          Expanded(child: OutlinedButton.icon(onPressed: () => _skipSentence(1), icon: const Icon(Icons.skip_next), label: const Text('下一句'))),
                        ],
                      ),
                    ),
                  const XGroupTitle('语音'),
                  XSlider(title: '语速', label: prefs.ttsRate.toStringAsFixed(1), slider: Slider(min: 0.1, max: 1.0, divisions: 9, value: prefs.ttsRate, onChanged: (v) => set(prefs.copyWith(ttsRate: v)))),
                  XSlider(title: '音调', label: prefs.ttsPitch.toStringAsFixed(1), slider: Slider(min: 0.5, max: 2.0, divisions: 15, value: prefs.ttsPitch, onChanged: (v) => set(prefs.copyWith(ttsPitch: v)))),
                  FutureBuilder<List<String>>(
                    future: _zhVoices(),
                    builder: (context, snap) => XChips<String>(title: '音色', value: prefs.ttsVoice, options: {'': '系统默认', for (final n in snap.data ?? const <String>[]) n: n}, onChanged: (v) => set(prefs.copyWith(ttsVoice: v))),
                  ),
                  const XDivider(),
                  const XGroupTitle('朗读方式'),
                  XSwitch(title: '跟读高亮', value: prefs.ttsHighlight, onChanged: (v) => set(prefs.copyWith(ttsHighlight: v))),
                  XSwitch(title: '自动朗读下一章', value: prefs.ttsAutoNext, onChanged: (v) => set(prefs.copyWith(ttsAutoNext: v))),
                  const XDivider(),
                  const XGroupTitle('定时停止'),
                  // 分钟数选过就算"定时中"，不再标出选的是哪一档
                  XChips<int>(
                    value: _stopAtChapterEnd ? -1 : (_sleepAt == null ? 0 : null),
                    options: const {0: '关闭', 15: '15 分钟', 30: '30 分钟', 60: '60 分钟', -1: '本章结束'},
                    onChanged: (m) => m == 0 ? sleep(null, false) : (m < 0 ? sleep(null, true) : sleep(DateTime.now().add(Duration(minutes: m)), false)),
                  ),
                  if (_sleepAt != null) XNote('将于 $hm 停止朗读'),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 系统里的中文语音名（引擎不支持列出时返回空）。
  Future<List<String>> _zhVoices() async {
    try {
      final voices = await _tts.getVoices as List?;
      return [
        for (final v in voices ?? const [])
          if (v is Map && '${v['locale']}'.toLowerCase().startsWith('zh')) '${v['name']}',
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 上次停在设置面板的哪一页（显示 / 排版 / 翻页）
  int _settingsTab = 0;

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.transparent, // 不压暗正文：改字号、配色时要看得到效果
      builder: (context) => StatefulBuilder(builder: (context, setSheet) => Consumer(
        builder: (context, ref, _) {
          final prefs = ref.watch(readerPrefsProvider);
          void set(ReaderPrefs p) => ref.read(readerPrefsProvider.notifier).update(p);
          final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
          // 面板跟阅读配色走（纸色底、正文字色），不用应用主题的底色
          final app = Theme.of(context);
          final pal = _paletteOf(prefs, app.colorScheme);
          final scheme = app.colorScheme.copyWith(
            primary: _headingAccent(this.context, prefs, pal)?.$1,
            surface: pal.bg,
            onSurface: pal.fg,
            onSurfaceVariant: pal.fg.withValues(alpha: 0.6),
            outline: pal.fg.withValues(alpha: 0.18),
            outlineVariant: pal.fg.withValues(alpha: 0.18),
          );
          final tab = _settingsTab;
          return Theme(
            data: app.copyWith(colorScheme: scheme, sliderTheme: appSliderTheme(scheme), switchTheme: appSwitchTheme(scheme), dividerTheme: app.dividerTheme.copyWith(color: scheme.outline),
              // 字体标签的底色：主题里的颜色会盖过标签自己的，所以选中、没选中都在这里给
              canvasColor: pal.bg,
              chipTheme: app.chipTheme.copyWith(color: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), pal.bg) : pal.bg)),
            ),
            child: Material(
            color: pal.bg,
            shape: Border(top: BorderSide(color: scheme.outline)),
            child: SafeArea(
            // 略高于半屏：三个分页都不用滑，上面留一些正文
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.56,
              child: Column(
                children: [
                  XSegments<int>(value: tab, options: const {0: '显示', 1: '排版', 2: '翻页'}, onChanged: (v) => setSheet(() => _settingsTab = v)),
                  Expanded(
            child: _ScrollFade(
            child: SingleChildScrollView(
              key: ValueKey(tab), // 换分页时回到顶上
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tab == 0) ...[
                  // 一排背景色样：色块里写个"文"字，选中的外面一圈
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final (i, name) in ['纸张', '护眼', '夜间', '跟随应用', '纯黑', '晴空'].indexed)
                          GestureDetector(
                            onTap: () => set(prefs.copyWith(theme: i)),
                            child: Column(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  padding: const EdgeInsets.all(2.5),
                                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: prefs.theme == i ? scheme.primary : Colors.transparent, width: 2)),
                                  child: Builder(builder: (context) {
                                    final pal = _paletteOf(prefs.copyWith(theme: i), app.colorScheme);
                                    return DecoratedBox(
                                      decoration: BoxDecoration(shape: BoxShape.circle, color: pal.bg, border: Border.all(color: scheme.outline)),
                                      child: Center(child: Text('文', style: TextStyle(fontSize: 14, color: i == 5 ? _skyAccent.$1 : pal.fg))),
                                    );
                                  }),
                                ),
                                const SizedBox(height: 4),
                                Text(name, maxLines: 1, style: TextStyle(fontSize: 12, color: prefs.theme == i ? scheme.primary : scheme.onSurfaceVariant, fontWeight: prefs.theme == i ? FontWeight.w600 : null)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 越往左越暗：滑块值是亮度，存的是遮罩不透明度
                  XSlider(compact: true, title: '页面亮度', label: '${((1 - prefs.dim) * 100).round()}%', slider: Slider(min: 0.3, max: 1.0, divisions: 14, value: (1 - prefs.dim).clamp(0.3, 1.0), onChanged: (v) => set(prefs.copyWith(dim: 1 - v)))),
                  if (android) ...[
                    XSwitch(title: '独立屏幕亮度', help: '不跟随系统亮度，最高能调得比系统更亮；退出阅读后恢复。', value: prefs.customBrightness, onChanged: (v) => set(prefs.copyWith(customBrightness: v))),
                    if (prefs.customBrightness) XSlider(compact: true, title: '屏幕亮度', label: '${(prefs.brightness * 100).round()}%', slider: Slider(min: 0.02, max: 1.0, value: prefs.brightness.clamp(0.02, 1.0), onChanged: (v) => set(prefs.copyWith(brightness: v)))),
                  ],
                  XSlider(compact: true, title: '暖色滤镜', label: prefs.warm == 0 ? '关闭' : '${(prefs.warm * 200).round()}%', slider: Slider(min: 0, max: 0.5, divisions: 10, value: prefs.warm, onChanged: (v) => set(prefs.copyWith(warm: v)))),
                  XTile(
                    title: '色彩',
                    trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
                      _toggleChip(scheme, '灰度', prefs.grayscale, (v) => set(prefs.copyWith(grayscale: v))),
                      _toggleChip(scheme, '反色', prefs.invert, (v) => set(prefs.copyWith(invert: v))),
                    ]),
                  ),
                  ],
                  if (tab == 1) ...[
                  _LayoutSlider(title: '字号', label: (v) => '${v.round()}', min: 14, max: 32, divisions: 18, value: prefs.fontSize, onCommit: (v) => set(prefs.copyWith(fontSize: v))),
                  _LayoutSlider(title: '行距', label: (v) => v.toStringAsFixed(1), min: 1.3, max: 2.4, divisions: 11, value: prefs.lineHeight, onCommit: (v) => set(prefs.copyWith(lineHeight: v))),
                  _LayoutSlider(title: '页边距', label: (v) => '${v.round()}', min: 8, max: 48, divisions: 20, value: prefs.margin, onCommit: (v) => set(prefs.copyWith(margin: v))),
                  XChips<int>(
                    title: '字体',
                    value: prefs.font,
                    options: FontStore.names,
                    onChanged: (k) async {
                      if (k == 2 && FontStore.customFamily == null && !await FontStore.pick()) return;
                      set(prefs.copyWith(font: k));
                    },
                    extra: [
                      if (!isWebPreview)
                        ActionChip(
                          avatar: const Icon(Icons.upload_file_outlined, size: 18),
                          label: const Text('导入字体'),
                          onPressed: () async {
                            if (await FontStore.pick()) set(prefs.copyWith(font: 2));
                          },
                        ),
                    ],
                  ),
                  XSwitch(title: '繁体', value: prefs.hant, onChanged: (v) => set(prefs.copyWith(hant: v))),
                  ],
                  if (tab == 2) ...[
                  XSegments<int>(value: prefs.mode, options: const {0: '滚动', 1: '滑动', 2: '仿真', 3: '覆盖'}, onChanged: (v) => set(prefs.copyWith(mode: v))),
                  // 点击区域、音量键、预加载这些在设置页
                  XTile(
                    title: '更多阅读设置',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      Navigator.pop(context);
                      _flushStats();
                      if (!_speaking) _watch.stop();
                      _syncVolumeKeys(false);
                      await this.context.push(Routes.settingsSection('reading'));
                      if (!mounted) return;
                      if (!_background) _watch.start();
                      _syncVolumeKeys(ref.read(readerPrefsProvider).volumeKeys);
                    },
                  ),
                  ],
                ],
              ),
            ),
            ),
                  ),
                ],
              ),
            ),
            ),
            ),
          );
        },
      )),
    );
  }
}

/// 字号、行距、页边距：拖动时只改数字，松手才生效。每改一档都要整章重新排版，拖动中每档都排一次会卡顿。
class _LayoutSlider extends StatefulWidget {
  const _LayoutSlider({required this.title, required this.label, required this.min, required this.max, required this.divisions, required this.value, required this.onCommit});

  final String title;
  final String Function(double value) label;
  final double min;
  final double max;
  final int divisions;
  final double value;
  final ValueChanged<double> onCommit;

  @override
  State<_LayoutSlider> createState() => _LayoutSliderState();
}

class _LayoutSliderState extends State<_LayoutSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = (_dragging ?? widget.value).clamp(widget.min, widget.max);
    return XSlider(
      compact: true,
      title: widget.title,
      label: widget.label(v),
      slider: Slider(
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        value: v,
        onChanged: (x) => setState(() => _dragging = x),
        onChangeEnd: (x) {
          setState(() => _dragging = null);
          if (x != widget.value) widget.onCommit(x);
        },
      ),
    );
  }
}

/// 两个可以同时选中的标签，样子和 XChips 的一样
Widget _toggleChip(ColorScheme scheme, String label, bool on, ValueChanged<bool> onChanged) => ChoiceChip(
  label: Text(label),
  selected: on,
  showCheckmark: false,
  selectedColor: scheme.primary.withValues(alpha: 0.14),
  labelStyle: TextStyle(color: on ? scheme.primary : scheme.onSurface, fontWeight: on ? FontWeight.w600 : null),
  side: BorderSide(color: on ? scheme.primary.withValues(alpha: 0.5) : scheme.outline),
  onSelected: onChanged,
);

/// 下面还有内容没露出来时，底边渐隐，提示可以往下滑
class _ScrollFade extends StatefulWidget {
  const _ScrollFade({required this.child});

  final Widget child;

  @override
  State<_ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<_ScrollFade> {
  var _more = false;

  bool _onMetrics(ScrollMetrics m) {
    final more = m.extentAfter > 1;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (n) => _onMetrics(n.metrics),
    child: NotificationListener<ScrollNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: Scrollbar(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, if (_more) Colors.transparent else Colors.black],
            stops: [0, r.height <= 48 ? 0 : 1 - 48 / r.height, 1],
          ).createShader(r),
          child: widget.child,
        ),
      ),
    ),
  );
}
