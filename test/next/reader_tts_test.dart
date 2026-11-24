import 'dart:ui' show VoidCallback;

import 'package:ark_novel/next/reader/reader_tts.dart';
import 'package:ark_novel/next/settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTtsEngine implements TtsEngine {
  void Function()? _onComplete;
  void Function(dynamic message)? _onError;

  final spoken = <String>[];
  int stopCalls = 0;
  double? rate;
  double? pitch;
  String? language;
  Map<String, String>? voice;
  List<TtsVoice> voices = const [(name: 'zh-female', locale: 'zh-CN')];

  @override
  void setCompletionHandler(void Function() handler) => _onComplete = handler;

  @override
  void setErrorHandler(void Function(dynamic message) handler) => _onError = handler;

  @override
  Future<void> setLanguage(String language) async => this.language = language;

  @override
  Future<void> setSpeechRate(double rate) async => this.rate = rate;

  @override
  Future<void> setPitch(double pitch) async => this.pitch = pitch;

  @override
  Future<void> setVoice(Map<String, String> voice) async => this.voice = voice;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<List<TtsVoice>> zhVoices() async => voices;

  void emitComplete() => _onComplete?.call();

  void emitError(dynamic message) => _onError?.call(message);
}

class _FakeNoticePort implements TtsNoticePort {
  final shows = <({String book, String chapter, String? cover, bool playing})>[];
  int hideCalls = 0;
  int clearCalls = 0;
  VoidCallback? onPlay, onPause, onStop, onNext, onPrev;

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
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onStop = onStop;
    this.onNext = onNext;
    this.onPrev = onPrev;
    shows.add((book: book, chapter: chapter, cover: cover, playing: playing));
  }

  @override
  Future<void> hide() async => hideCalls++;

  @override
  void clearCallbacks() {
    clearCalls++;
    onPlay = onPause = onStop = onNext = onPrev = null;
  }
}

void main() {
  const sampleText = '第一句用来测试朗读状态机是否正常工作。第二句检查换句高亮与自动续读。第三句验证暂停与继续状态同步！';

  test('开始朗读、逐句续读、高亮与进度节流保存', () async {
    final engine = _FakeTtsEngine();
    final notice = _FakeNoticePort();
    var now = DateTime(2026, 1, 1, 20, 0, 0);
    final savedOffsets = <int>[];
    final highlights = <(int, int)?>[];
    var prefs = const ReaderPrefs(ttsRate: 0.7, ttsPitch: 1.1, ttsVoice: 'zh-female', ttsHighlight: true, ttsAutoNext: false);

    final tts = ReaderTtsController(
      engine: engine,
      notice: notice,
      now: () => now,
      requestNotificationPermission: () {},
      readPrefs: () => prefs,
      resolveNoticeMeta: () async => (book: '测试书', chapter: '第一章', cover: null),
      onSaveProgress: savedOffsets.add,
    );
    addTearDown(tts.dispose);
    tts.highlight.addListener(() => highlights.add(tts.highlight.value));

    final ok = await tts.start(sampleText, fromOffset: 0);
    expect(ok, isTrue);
    expect(tts.isSpeaking, isTrue);
    expect(tts.isPaused, isFalse);
    expect(tts.isListening, isTrue);
    expect(engine.language, 'zh-CN');
    expect(engine.rate, 0.7);
    expect(engine.pitch, 1.1);
    expect(engine.voice, {'name': 'zh-female', 'locale': 'zh-CN'});
    expect(engine.spoken, ['第一句用来测试朗读状态机是否正常工作。']);
    expect(tts.highlight.value, isNotNull);
    expect(savedOffsets, hasLength(1));
    expect(notice.shows.last.playing, isTrue);

    // 2 秒后播完第 1 句：自动读第 2 句，高亮局部变更，但 5 秒内不重复写盘
    now = now.add(const Duration(seconds: 2));
    engine.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(engine.spoken, hasLength(2));
    expect(engine.spoken.last, '第二句检查换句高亮与自动续读。');
    expect(savedOffsets, hasLength(1));
    expect(highlights, hasLength(2));

    // 6 秒后播完第 2 句：超过 5 秒阈值，写入进度
    now = now.add(const Duration(seconds: 6));
    engine.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(engine.spoken.last, '第三句验证暂停与继续状态同步！');
    expect(savedOffsets, hasLength(2));

    // 播完最后一句且关闭自动下一章：自动停止并收起通知
    engine.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(tts.isSpeaking, isFalse);
    expect(tts.highlight.value, isNull);
    expect(notice.hideCalls, 1);
  });

  test('暂停 / 继续同步 ValueNotifier、通知栏播放态与切句', () async {
    final engine = _FakeTtsEngine();
    final notice = _FakeNoticePort();
    var listeningEvents = 0;

    final tts = ReaderTtsController(
      engine: engine,
      notice: notice,
      requestNotificationPermission: () {},
      readPrefs: () => const ReaderPrefs(ttsAutoNext: false),
      resolveNoticeMeta: () async => (book: '测试书', chapter: '第一章', cover: '/tmp/c.jpg'),
      onListeningChanged: () => listeningEvents++,
    );
    addTearDown(tts.dispose);

    await tts.start(sampleText);
    expect(tts.isPaused, isFalse);
    expect(listeningEvents, 1);

    // 暂停：状态立即同步，通知栏切到 playing=false
    tts.pause();
    await Future<void>.delayed(Duration.zero);
    expect(tts.isSpeaking, isTrue);
    expect(tts.isPaused, isTrue);
    expect(tts.isListening, isFalse);
    expect(engine.stopCalls, 1);
    expect(notice.shows.last.playing, isFalse);
    expect(listeningEvents, 2);

    // 暂停期间点下一句：仅移动高亮不发声
    final beforeSkip = tts.highlight.value;
    tts.skip(1);
    expect(tts.sentenceIndex, 1);
    expect(tts.highlight.value, isNot(beforeSkip));
    expect(engine.spoken, hasLength(1));

    // 恢复：从新句子重读，通知栏切回 playing=true
    tts.togglePause();
    await Future<void>.delayed(Duration.zero);
    expect(tts.isPaused, isFalse);
    expect(tts.isListening, isTrue);
    expect(engine.spoken.last, '第二句检查换句高亮与自动续读。');
    expect(notice.shows.last.playing, isTrue);
    expect(listeningEvents, 3);

    // 朗读中点上一句：打断并切回第 0 句
    tts.skip(-1);
    await Future<void>.delayed(Duration.zero);
    expect(tts.sentenceIndex, 0);
    expect(engine.spoken.last, '第一句用来测试朗读状态机是否正常工作。');
  });

  test('读完一章自动续读下一章，遇到空插图章继续跳过', () async {
    final engine = _FakeTtsEngine();
    final notice = _FakeNoticePort();
    final queue = <String>['   \n   ', '下一章的正文第一句继续自动朗读。'];
    var advanced = 0;

    final tts = ReaderTtsController(
      engine: engine,
      notice: notice,
      requestNotificationPermission: () {},
      readPrefs: () => const ReaderPrefs(ttsAutoNext: true),
      onAdvanceChapter: () async {
        advanced++;
        return queue.isEmpty ? null : queue.removeAt(0);
      },
    );
    addTearDown(tts.dispose);

    await tts.start('本章唯一一句结束。');
    expect(engine.spoken, ['本章唯一一句结束。']);

    engine.emitComplete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(advanced, 2);
    expect(tts.isSpeaking, isTrue);
    expect(engine.spoken.last, '下一章的正文第一句继续自动朗读。');
  });

  test('定时停止：支持本章结束与分钟倒计时（含暂停态到点检查）', () async {
    final engine = _FakeTtsEngine();
    final notice = _FakeNoticePort();
    var now = DateTime(2026, 1, 1, 22, 0, 0);
    var advanceCalls = 0;

    final tts = ReaderTtsController(
      engine: engine,
      notice: notice,
      now: () => now,
      requestNotificationPermission: () {},
      readPrefs: () => const ReaderPrefs(ttsAutoNext: true),
      onAdvanceChapter: () async {
        advanceCalls++;
        return '不应该读到的下一章。';
      },
    );
    addTearDown(tts.dispose);

    // 1. 本章结束停止
    await tts.start('本章只有一句。');
    tts.setSleepOption(-1);
    expect(tts.sleepState.value.stopAtChapterEnd, isTrue);
    expect(tts.sleepState.value.shortLabel, '章末');
    engine.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(tts.isSpeaking, isFalse);
    expect(advanceCalls, 0);

    // 2. 15 分钟定时：暂停态下通过 checkSleepTimer 到点自动停止
    await tts.start(sampleText);
    tts.setSleepOption(15);
    expect(tts.sleepState.value.optionValue, 15);
    expect(tts.sleepState.value.shortLabel, '15m');
    expect(tts.sleepState.value.stopTimeText, '22:15');
    tts.pause();

    now = now.add(const Duration(minutes: 10));
    tts.checkSleepTimer();
    expect(tts.isSpeaking, isTrue);

    now = now.add(const Duration(minutes: 6));
    tts.checkSleepTimer();
    await Future<void>.delayed(Duration.zero);
    expect(tts.isSpeaking, isFalse);
    expect(tts.sleepState.value.enabled, isFalse);
  });

  test('引擎报错自动停止、空章提示、跟读高亮开关与 readFrom 同步', () async {
    final engine = _FakeTtsEngine();
    final notice = _FakeNoticePort();
    var prefs = const ReaderPrefs(ttsHighlight: true, ttsAutoNext: false);
    Object? lastError;

    final tts = ReaderTtsController(
      engine: engine,
      notice: notice,
      requestNotificationPermission: () {},
      readPrefs: () => prefs,
      onError: (e) => lastError = e,
    );
    addTearDown(tts.dispose);

    expect(await tts.start('   \n  '), isFalse);

    await tts.start(sampleText);
    expect(tts.highlight.value, isNotNull);

    // 动态关闭跟读高亮
    prefs = prefs.copyWith(ttsHighlight: false);
    tts.syncPrefs();
    expect(tts.highlight.value, isNull);

    // 重新打开跟读高亮并跳到第 3 句
    prefs = prefs.copyWith(ttsHighlight: true);
    tts.syncPrefs();
    final thirdStart = sampleText.indexOf('第三句');
    tts.readFrom(thirdStart, currentText: sampleText);
    await Future<void>.delayed(Duration.zero);
    expect(tts.sentenceIndex, 2);
    expect(tts.highlight.value?.$1, thirdStart);

    // 正文不匹配时忽略 readFrom
    tts.readFrom(0, currentText: '别的章节正文');
    expect(tts.sentenceIndex, 2);

    // 引擎异常自动停止并上报错误
    engine.emitError('engine died');
    await Future<void>.delayed(Duration.zero);
    expect(tts.isSpeaking, isFalse);
    expect(lastError, 'engine died');
  });
}
