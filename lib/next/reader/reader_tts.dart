import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, VoidCallback, defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_tts/flutter_tts.dart';

import '../settings.dart';
import 'paginator.dart';
import 'tts_notice.dart';

typedef TtsVoice = ({String name, String locale});

/// 定时停止状态。
class TtsSleepState {
  const TtsSleepState._({this.at, this.minutes, this.stopAtChapterEnd = false});

  const TtsSleepState.off() : this._();
  const TtsSleepState.chapterEnd() : this._(stopAtChapterEnd: true);
  const TtsSleepState.at(DateTime at, int minutes) : this._(at: at, minutes: minutes);

  final DateTime? at;
  final int? minutes;
  final bool stopAtChapterEnd;

  bool get enabled => stopAtChapterEnd || at != null;

  /// 对应定时选项芯片的值：0 关闭，-1 本章结束，>0 分钟数。
  int get optionValue => stopAtChapterEnd ? -1 : (at == null ? 0 : (minutes ?? 0));

  String get shortLabel => stopAtChapterEnd ? '章末' : (minutes == null ? '' : '${minutes}m');

  String get stopTimeText => at == null ? '' : '${at!.hour.toString().padLeft(2, '0')}:${at!.minute.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) => other is TtsSleepState && other.at == at && other.minutes == minutes && other.stopAtChapterEnd == stopAtChapterEnd;

  @override
  int get hashCode => Object.hash(at, minutes, stopAtChapterEnd);
}

/// 底层语音合成引擎抽象（便于单测注入假引擎）。
abstract interface class TtsEngine {
  void setCompletionHandler(void Function() handler);
  void setErrorHandler(void Function(dynamic message) handler);
  Future<void> setLanguage(String language);
  Future<void> setSpeechRate(double rate);
  Future<void> setPitch(double pitch);
  Future<void> setVoice(Map<String, String> voice);
  Future<void> speak(String text);
  Future<void> stop();
  Future<List<TtsVoice>> zhVoices();
}

/// 默认实现：封装 [FlutterTts]。
class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  void setCompletionHandler(void Function() handler) => _tts.setCompletionHandler(handler);

  @override
  void setErrorHandler(void Function(dynamic message) handler) => _tts.setErrorHandler(handler);

  @override
  Future<void> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<void> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<void> setVoice(Map<String, String> voice) => _tts.setVoice(voice);

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<List<TtsVoice>> zhVoices() async {
    try {
      final voices = await _tts.getVoices as List?;
      return [
        for (final v in voices ?? const [])
          if (v is Map && '${v['locale']}'.toLowerCase().startsWith('zh')) (name: '${v['name']}', locale: '${v['locale']}'),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// 通知栏 / 锁屏媒体控制抽象（便于单测注入）。
abstract interface class TtsNoticePort {
  Future<void> show({
    required String book,
    required String chapter,
    String? cover,
    required bool playing,
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onStop,
    required VoidCallback onNext,
    required VoidCallback onPrev,
  });

  Future<void> hide();
  void clearCallbacks();
}

/// 默认实现：对接 [TtsNotice]。
class SystemTtsNoticePort implements TtsNoticePort {
  TtsNotice? _notice;

  @override
  Future<void> show({
    required String book,
    required String chapter,
    String? cover,
    required bool playing,
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onStop,
    required VoidCallback onNext,
    required VoidCallback onPrev,
  }) async {
    final n = _notice = await TtsNotice.get();
    if (n == null) return;
    n
      ..onPlay = onPlay
      ..onPause = onPause
      ..onStop = onStop
      ..onNext = onNext
      ..onPrev = onPrev;
    n.show(book: book, chapter: chapter, cover: cover, playing: playing);
  }

  @override
  Future<void> hide() async {
    await _notice?.hide();
  }

  @override
  void clearCallbacks() => _notice?.clearCallbacks();
}

/// 阅读器朗读状态机：管理按句切分与续读、暂停/继续状态同步、通知栏控制、定时停止、
/// 以及细粒度 [highlight] 通知（换句只局部刷新正文高亮，避免触发整页 `setState`）。
class ReaderTtsController {
  ReaderTtsController({
    TtsEngine? engine,
    TtsEngine Function()? engineFactory,
    TtsNoticePort? notice,
    DateTime Function()? now,
    VoidCallback? requestNotificationPermission,
    this.readPrefs,
    this.resolveNoticeMeta,
    this.onSaveProgress,
    this.onAdvanceChapter,
    this.onError,
    this.onListeningChanged,
  }) : _engine = engine,
       _engineFactory = engineFactory ?? FlutterTtsEngine.new,
       _notice = notice ?? SystemTtsNoticePort(),
       _now = now ?? DateTime.now,
       _requestNotificationPermission = requestNotificationPermission ?? _defaultRequestPermission {
    if (engine != null) _bindEngine(engine);
  }

  static const _ttsChannel = MethodChannel('ark/tts');

  static void _defaultRequestPermission() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _ttsChannel.invokeMethod('requestNotificationPermission').ignore();
    }
  }

  TtsEngine? _engine;
  final TtsEngine Function() _engineFactory;
  final TtsNoticePort _notice;
  final DateTime Function() _now;
  final VoidCallback _requestNotificationPermission;

  /// 底层语音引擎是否已初始化（默认仅在首次开始朗读或查询音色时按需拉起系统 TTS 服务）。
  @visibleForTesting
  bool get isEngineInitialized => _engine != null;

  TtsEngine _ensureEngine() {
    var eng = _engine;
    if (eng == null) {
      eng = _engineFactory();
      _engine = eng;
      _bindEngine(eng);
    }
    return eng;
  }

  void _bindEngine(TtsEngine eng) {
    eng.setCompletionHandler(_onEngineCompleted);
    eng.setErrorHandler(_onEngineError);
  }

  final ReaderPrefs Function()? readPrefs;
  final Future<({String book, String chapter, String? cover})?> Function()? resolveNoticeMeta;
  final void Function(int offset)? onSaveProgress;

  /// 本章读完需要续读下一章时回调：负责切章、记历史并拉取下一章正文；无下一章或失败返回 null。
  final Future<String?> Function()? onAdvanceChapter;
  final void Function(Object? message)? onError;
  final VoidCallback? onListeningChanged;

  /// 是否处于朗读会话中（含暂停态）。
  final active = ValueNotifier<bool>(false);

  /// 是否已暂停。
  final paused = ValueNotifier<bool>(false);

  /// 当前正在朗读的句子字符区间 `[start, end)`（关闭跟读高亮或未朗读时为 null）。
  final highlight = ValueNotifier<(int, int)?>(null);

  /// 定时停止配置。
  final sleepState = ValueNotifier<TtsSleepState>(const TtsSleepState.off());

  List<(int, int)> _segs = const [];
  String _ttsText = '';
  int _si = 0;
  int _speakGen = 0; // 每次换句 / 暂停 / 停止递增，丢弃过期异步任务和被打断那句的回调
  bool _startingSpeech = false;
  DateTime _ttsSavedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _spokeAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastPageOffset = -1;
  Timer? _turnTimer;
  bool _disposed = false;

  bool get isSpeaking => active.value;
  bool get isPaused => paused.value;

  /// 正在发声听书（开启且未暂停）。
  bool get isListening => active.value && !paused.value;

  /// 刚刚切换句子后的一小段时间内的翻页属于跟读自动翻页，不算用户手动翻页。
  bool get isFollowing => isSpeaking && _now().difference(_spokeAt).inMilliseconds <= 1200;

  int get sentenceIndex => _si;
  int get sentenceCount => _segs.length;
  String get text => _ttsText;

  ReaderPrefs get _prefs => readPrefs?.call() ?? const ReaderPrefs();

  void _onEngineCompleted() {
    if (_disposed || !isSpeaking || isPaused || _startingSpeech) return;
    _si++;
    _speakNext();
  }

  void _onEngineError(dynamic message) {
    if (_disposed || !isSpeaking) return;
    stop();
    onError?.call(message);
  }

  void _updateHighlight() {
    if (_disposed) return;
    highlight.value = (isSpeaking && _prefs.ttsHighlight && _si >= 0 && _si < _segs.length) ? _segs[_si] : null;
  }

  /// 朗读偏好变化时同步高亮开关与语音参数。
  void syncPrefs() {
    if (_disposed) return;
    _updateHighlight();
    if (isSpeaking) applyPrefs();
  }

  /// 从 [fromOffset] 所在句子开始朗读（[fromStart] 为 true 时从章首开始）；无可读文字时返回 false。
  Future<bool> start(String text, {int fromOffset = 0, bool fromStart = false}) async {
    if (_disposed) return false;
    _ttsText = text;
    _segs = splitSentences(text);
    if (_segs.isEmpty) {
      highlight.value = null;
      if (fromStart && isSpeaking) {
        _si = 0;
        await _speakNext();
        return true;
      }
      return false;
    }
    _requestNotificationPermission();
    final at = fromStart ? 0 : fromOffset;
    _si = _segs.indexWhere((e) => e.$2 > at);
    if (_si < 0) _si = _segs.length - 1;
    final gen = ++_speakGen;
    final wasListening = isListening;
    active.value = true;
    paused.value = false;
    if (!wasListening) onListeningChanged?.call();
    unawaited(refreshNotice());
    await applyPrefs();
    if (gen != _speakGen || _disposed || !isSpeaking || isPaused) return true;
    await _speakNext();
    return true;
  }

  Future<void> applyPrefs() async {
    if (_disposed) return;
    final eng = _ensureEngine();
    final prefs = _prefs;
    await eng.setLanguage('zh-CN');
    await eng.setSpeechRate(prefs.ttsRate);
    await eng.setPitch(prefs.ttsPitch);
    if (prefs.ttsVoice.isNotEmpty) {
      try {
        final voices = await eng.zhVoices();
        final locale = voices.where((v) => v.name == prefs.ttsVoice).firstOrNull?.locale ?? 'zh-CN';
        await eng.setVoice({'name': prefs.ttsVoice, 'locale': locale});
      } catch (_) {}
    }
  }

  Future<void> refreshNotice() async {
    if (_disposed || !isSpeaking) return;
    final meta = await resolveNoticeMeta?.call();
    if (_disposed || !isSpeaking || meta == null) return;
    await _notice.show(
      book: meta.book,
      chapter: meta.chapter,
      cover: meta.cover,
      playing: !isPaused,
      onPlay: resume,
      onPause: pause,
      onStop: () => stop(),
      onNext: () => skip(1),
      onPrev: () => skip(-1),
    );
  }

  void pause() {
    if (_disposed || !isSpeaking || isPaused) return;
    paused.value = true;
    _speakGen++;
    _startingSpeech = false;
    _engine?.stop();
    onListeningChanged?.call();
    refreshNotice();
  }

  void resume() {
    if (_disposed || !isSpeaking || !isPaused) return;
    paused.value = false;
    onListeningChanged?.call();
    refreshNotice();
    _speakNext();
  }

  void togglePause() => isPaused ? resume() : pause();

  /// 上一句 / 下一句。暂停中切句会同步移动高亮位置，恢复时从新句子开始读。
  void skip(int delta) {
    if (_disposed || !isSpeaking || _segs.isEmpty) return;
    _si = (_si + delta).clamp(0, _segs.length - 1);
    if (isPaused) {
      _updateHighlight();
      _saveProgress(_segs[_si].$1, force: true);
      return;
    }
    _speakNext(interrupt: true);
  }

  /// 跳到 [offset] 所在的句子继续朗读（仅当 [currentText] 与当前朗读正文一致时生效）。
  void readFrom(int offset, {required String currentText}) {
    if (_disposed || !isSpeaking || currentText != _ttsText || _segs.isEmpty) return;
    final i = _segs.indexWhere((e) => e.$2 > offset);
    if (i < 0 || i == _si) return;
    _si = i;
    if (isPaused) {
      _updateHighlight();
      return;
    }
    _speakNext(interrupt: true);
  }

  /// 读者翻页/滚动时调用：若非跟读自动翻页造成，停稳 600ms 后自动切到新位置续读。
  void onUserOffsetChanged(int offset, {required String Function() currentText}) {
    final turned = offset != _lastPageOffset;
    _lastPageOffset = offset;
    if (!isSpeaking || !turned || isFollowing) return;
    _turnTimer?.cancel();
    _turnTimer = Timer(const Duration(milliseconds: 600), () => readFrom(offset, currentText: currentText()));
  }

  /// 设置定时停止：0 关闭，-1 本章结束，>0 分钟数。
  void setSleepOption(int option) {
    if (_disposed) return;
    if (option == 0) {
      sleepState.value = const TtsSleepState.off();
    } else if (option < 0) {
      sleepState.value = const TtsSleepState.chapterEnd();
    } else {
      sleepState.value = TtsSleepState.at(_now().add(Duration(minutes: option)), option);
    }
  }

  /// 由分钟定时器调用：暂停态下不会走到 [_speakNext]，需要在这里检查是否到点停止。
  void checkSleepTimer() {
    if (_disposed || !isSpeaking) return;
    final at = sleepState.value.at;
    if (at != null && _now().isAfter(at)) stop();
  }

  Future<void> _speakNext({bool interrupt = false}) async {
    if (_disposed || !isSpeaking || isPaused) return;
    final at = sleepState.value.at;
    if (at != null && _now().isAfter(at)) return stop();
    final gen = ++_speakGen;
    if (_si < _segs.length) {
      final (s, e) = _segs[_si];
      _spokeAt = _now();
      _updateHighlight();
      _saveProgress(s);
      _startingSpeech = true;
      try {
        final eng = _ensureEngine();
        if (interrupt) await eng.stop();
        if (gen != _speakGen || _disposed || !isSpeaking || isPaused) return;
        await eng.speak(_ttsText.substring(s, e).trim());
      } finally {
        if (gen == _speakGen) _startingSpeech = false;
      }
      return;
    }
    if (sleepState.value.stopAtChapterEnd || !_prefs.ttsAutoNext) return stop();
    _segs = const [];
    _ttsText = '';
    highlight.value = null;
    try {
      final nextText = await onAdvanceChapter?.call();
      if (nextText == null) {
        if (gen == _speakGen && !_disposed && isSpeaking) await stop();
        return;
      }
      if (gen == _speakGen && !_disposed && isSpeaking && !isPaused) {
        await start(nextText, fromStart: true);
      }
    } catch (_) {
      if (gen == _speakGen && !_disposed && isSpeaking) await stop();
    }
  }

  void _saveProgress(int offset, {bool force = false}) {
    final now = _now();
    if (!force && now.difference(_ttsSavedAt) < const Duration(seconds: 5)) return;
    _ttsSavedAt = now;
    onSaveProgress?.call(offset);
  }

  Future<void> stop() async {
    if (_disposed) return;
    final wasActive = isSpeaking;
    final wasListening = isListening;
    _speakGen++;
    _startingSpeech = false;
    _turnTimer?.cancel();
    paused.value = false;
    sleepState.value = const TtsSleepState.off();
    highlight.value = null;
    active.value = false;
    if (wasListening || wasActive) onListeningChanged?.call();
    final eng = _engine;
    if (eng != null) await eng.stop();
    _notice.clearCallbacks();
    if (wasActive) await _notice.hide();
  }

  Future<List<TtsVoice>> zhVoices() => _ensureEngine().zhVoices();

  void dispose() {
    if (_disposed) return;
    final wasActive = isSpeaking;
    _disposed = true;
    _speakGen++;
    _turnTimer?.cancel();
    final eng = _engine;
    if (eng != null) {
      eng.setCompletionHandler(() {});
      eng.setErrorHandler((_) {});
      eng.stop();
    }
    _notice.clearCallbacks();
    if (wasActive) _notice.hide();
    active.dispose();
    paused.dispose();
    highlight.dispose();
    sleepState.dispose();
  }
}
