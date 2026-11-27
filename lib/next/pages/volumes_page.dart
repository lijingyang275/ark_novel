import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerScrollInertiaCancelEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../models/cat_volume.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../cover_color.dart';
import '../image_cache.dart';
import '../library.dart';
import '../motion.dart';
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../settings.dart';
import '../shelf_3d.dart' show MaskedRollSwitcher;
import '../stats.dart';
import '../swipe.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Vol, Volumes, volumeChangeForProvider;
import '../widgets.dart';
import 'cover_picker_page.dart';
import 'novel_page.dart';
import '../text.dart';

part 'volumes/volume_stack.dart';
part 'volumes/volume_widgets.dart';

/// 书架"卷册"模式点进来：一本书的各卷叠在一起，左右滑把某一卷转到最前面；点最前面那卷像翻开书一样开始读，点下面的横条展开详情和目录。
class VolumesPage extends ConsumerStatefulWidget {
  const VolumesPage({super.key, required this.aid});

  final String aid;

  @override
  ConsumerState<VolumesPage> createState() => _VolumesPageState();
}


class _VolumesPageState extends ConsumerState<VolumesPage> with SingleTickerProviderStateMixin {
  // 先停在第一卷（和书架上那叠对得上），开场动画放完再滑到正在读的那卷
  int _cur = 0;
  int _dir = 1;
  final _pc = PageController(viewportFraction: 0.5);
  // 开场：封面飞到位以后，后面几卷从封面后面往右抽出来
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  Animation<double>? _route;
  bool _open = false;
  bool _list = false; // 展开"全部卷"列表（和详情二选一）
  final _coverKey = GlobalKey(); // 最前面那卷的封面，翻开动画从它的位置开始
  OverlayEntry? _opening; // 正在放的翻开动画
  Size? _carouselCoverSize;
  final _precachedVols = <String>{};
  int _lastPrecachedCur = -1;
  List<CatVolume>? _cachedCatalogue;
  Map<String, String> _cachedChapterTitles = const {};

  Map<String, String> _chapterTitlesOf(List<CatVolume>? catalogue) {
    if (catalogue == null || catalogue.isEmpty) return const {};
    if (identical(_cachedCatalogue, catalogue)) return _cachedChapterTitles;
    _cachedCatalogue = catalogue;
    return _cachedChapterTitles = {
      for (final cv in catalogue)
        for (final c in cv.chapters) c.cid: c.title,
    };
  }

  void _precacheAround(int center, List<Vol> vols, String Function(Vol) coverOf) {
    final size = _carouselCoverSize;
    if (!mounted || size == null || vols.isEmpty) return;
    _lastPrecachedCur = center;
    for (var d = 1; d <= 2; d++) {
      for (final idx in [center + d, center - d]) {
        if (idx < 0 || idx >= vols.length) continue;
        final url = coverOf(vols[idx]);
        if (url.isEmpty || _precachedVols.contains(url)) continue;
        if (_precachedVols.length >= 128) _precachedVols.remove(_precachedVols.first);
        _precachedVols.add(url);
        NetImage.precache(context, url, size).ignore();
      }
    }
  }

  /// 跟随阅读器背景色，避免夜间 / 纯黑阅读模式下翻书动画出现刺眼白闪。
  Color _readerBg(ReaderPrefs prefs, ColorScheme scheme) => switch (prefs.theme) {
    0 => const Color(0xFFF6F1E7),
    1 => const Color(0xFFCFE6D0),
    2 => const Color(0xFF1C1C1A),
    4 => Colors.black,
    5 => const Color(0xFFF4ECDC),
    _ => scheme.surface,
  };

  /// 点最前面那卷：封面绕书脊翻开、放大铺满屏幕，进阅读页。动画放在最上层的 Overlay 里，阅读页推上来以后再淡出。
  void _openBook(Vol v, String url) {
    final cid = startCid(widget.aid, v);
    final box = _coverKey.currentContext?.findRenderObject() as RenderBox?;
    if (_opening != null) return;
    if (MediaQuery.disableAnimationsOf(context) || box == null || !box.hasSize) {
      context.push(Routes.reader(widget.aid, cid)).then((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    final pageColor = _readerBg(ref.read(readerPrefsProvider), Theme.of(context).colorScheme);
    _opening = OverlayEntry(
      builder: (_) => _OpeningBook(
        from: box.localToGlobal(Offset.zero) & box.size,
        url: url,
        pageColor: pageColor,
        onOpened: () {
          if (mounted) {
            context.push(Routes.reader(widget.aid, cid)).then((_) {
              if (mounted) setState(() {});
            });
          }
        },
        onDone: _closeBook,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_opening!);
  }

  /// 收掉翻开动画。动画中途返回时也走这里：动画跟着停，不会再推阅读页。
  void _closeBook() {
    _opening?.remove();
    _opening = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    _route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    // 第一次 build 时路由动画还没开始（状态是"完成"），等第一帧画完再看是不是正在推进来
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_route!.isCompleted) {
        _startIntro();
      } else {
        _route!.addStatusListener(_onRoute);
      }
    });
  }

  void _onRoute(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _route!.removeStatusListener(_onRoute);
    _startIntro();
  }

  /// 抽出来以后快速滑到正在读的那卷：卷数差得多也在 0.9 秒内滑到
  void _startIntro() {
    if (AppMotion.reduce(context)) {
      _intro.value = 1.0;
      final target = readingVolume(widget.aid);
      if (mounted && target > 0 && _pc.hasClients) _pc.jumpToPage(target);
      return;
    }
    _intro.forward().whenComplete(() {
      final target = readingVolume(widget.aid);
      if (!mounted || target <= 0 || !_pc.hasClients) return;
      _pc.animateToPage(target, duration: Duration(milliseconds: math.min(250 + 80 * target, 900)), curve: AppMotion.curve);
    });
  }

  @override
  void dispose() {
    _closeBook();
    _route?.removeStatusListener(_onRoute);
    _intro.dispose();
    _pc.dispose();
    super.dispose();
  }

  double get _page => _pc.hasClients && _pc.position.haveDimensions ? _pc.page ?? _cur.toDouble() : _cur.toDouble();

  void _tap(int i, Vol v, String url) {
    if (i != _cur) {
      if (AppMotion.reduce(context)) {
        _pc.jumpToPage(i);
      } else {
        _pc.animateToPage(i, duration: AppMotion.standard, curve: AppMotion.curve);
      }
    } else {
      _openBook(v, url);
    }
  }

  void _stepVol(int delta, int count) {
    if (!_pc.hasClients || count <= 0) return;
    final target = (_cur + delta).clamp(0, count - 1);
    if (target == _cur) return;
    if (AppMotion.reduce(context)) {
      _pc.jumpToPage(target);
    } else {
      _pc.animateToPage(target, duration: AppMotion.standard, curve: AppMotion.curve);
    }
  }

  DateTime _lastScrollEvent = DateTime(0);
  DateTime _lastWheelStep = DateTime(0);
  double _wheelAccum = 0;
  double _lastAbsDelta = 0;
  bool _wheelLocked = false;

  void _onWheel(PointerSignalEvent e, int count) {
    if (e is PointerScrollInertiaCancelEvent) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
      return;
    }
    if (e is! PointerScrollEvent) return;
    final delta = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    if (delta == 0) return;
    final now = DateTime.now();
    // 超过 140ms 无连续滚轮事件，视为新一次手势，解除 macOS 触控板惯性锁
    if (now.difference(_lastScrollEvent) > const Duration(milliseconds: 140)) {
      _wheelAccum = 0;
      _wheelLocked = false;
      _lastAbsDelta = 0;
    }
    _lastScrollEvent = now;
    if (_wheelAccum != 0 && delta.sign != _wheelAccum.sign) {
      _wheelAccum = 0;
      _wheelLocked = false;
    }
    final absDelta = delta.abs();
    if (_wheelLocked) {
      final reaccelerated = absDelta > _lastAbsDelta * 1.8 && absDelta >= 12;
      _lastAbsDelta = absDelta;
      if (!reaccelerated || now.difference(_lastWheelStep) < const Duration(milliseconds: 240)) return;
      _wheelLocked = false;
      _wheelAccum = 0;
    }
    _lastAbsDelta = absDelta;
    _wheelAccum += delta;
    if (_wheelAccum.abs() < 18) return;
    if (now.difference(_lastWheelStep) < const Duration(milliseconds: 220)) return;
    _lastWheelStep = now;
    _wheelLocked = true;
    final step = _wheelAccum > 0 ? 1 : -1;
    _wheelAccum = 0;
    _stepVol(step, count);
  }

  KeyEventResult _onKey(FocusNode node, List<Vol> vols, int cur, String cover, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    // 焦点在里面的按钮、列表上时，回车、空格、方向键归它们自己
    if (!node.hasPrimaryFocus && key != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.arrowDown) {
      _stepVol(1, vols.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.arrowUp) {
      _stepVol(-1, vols.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space && shift) {
      _stepVol(-1, vols.length);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) && vols.isNotEmpty) {
      _openBook(vols[cur], cover);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_open || _list) {
        setState(() => _open = _list = false);
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final aid = widget.aid;
    ref.watch(volumeChangeForProvider(aid));
    final novel = ref.watch(novelProvider(aid)).value; // 顺带把目录存下来，也用来显示章节名
    final vols = Volumes.of(aid);
    final title = LibraryStore.shown(aid, novel?.detail.title ?? (LibraryStore.get(aid)?['title'] as String?) ?? ReadingStats.info(aid).title);
    final fallback = novel?.detail.imgUrl ?? (LibraryStore.get(aid)?['img'] as String?) ?? '';
    final queue = ref.read(volumeCoverQueueProvider);
    String coverOf(Vol v) => queue.volCover(aid, v, fallback);

    final cur = math.min(_cur, math.max(vols.length - 1, 0));
    final cover = vols.isEmpty ? fallback : coverOf(vols[cur]);
    final base = ref.watch(coverColorProvider(cover)).value ?? savedCoverColor(cover) ?? kNeutralCoverColor;
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final Widget body;
    if (vols.isEmpty) {
      final baseTheme = Theme.of(context);
      body = novel == null
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Theme(
              data: baseTheme.copyWith(
                colorScheme: ColorScheme.dark(
                  primary: Colors.white,
                  onPrimary: Colors.black,
                  surface: base,
                  onSurface: Colors.white,
                  onSurfaceVariant: Colors.white70,
                  outline: Colors.white38,
                ),
                textTheme: baseTheme.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
              ),
              child: const StatePanel(title: '这本书没有分卷信息'),
            );
    } else {
      final v = vols[cur];
      final carousel = _Carousel(
        aid: aid,
        vols: vols,
        controller: _pc,
        page: () => _page,
        cur: cur,
        intro: _intro,
        coverOf: coverOf,
        onPage: (i) {
          setState(() {
            if (i != _cur) _dir = i > _cur ? 1 : -1;
            _cur = i;
          });
          _precacheAround(i, vols, coverOf);
        },
        onCoverSize: (s) {
          final changed = _carouselCoverSize == null || (_carouselCoverSize!.width - s.width).abs() > 8;
          if (changed) {
            _carouselCoverSize = s;
            _precachedVols.clear();
          }
          if (changed || _lastPrecachedCur != cur) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _precacheAround(cur, vols, coverOf);
            });
          }
        },
        coverKey: _coverKey,
        onTap: (i, v) => _tap(i, v, coverOf(v)),
        onLongPress: (v) => pickVolumeCover(context, aid, v),
      );
      final toggle = _DetailsToggle(
        open: _open,
        list: _list,
        wide: wide,
        onTap: () => setState(() {
          _open = !_open;
          _list = false;
        }),
        onList: () => setState(() {
          _list = !_list;
          _open = false;
        }),
      );
      final scrubber = vols.length > 6
          ? ExcludeFocus(
              child: SliderTheme(
                data: SliderTheme.of(
                  context,
                ).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  valueIndicatorColor: Colors.black87,
                  // 细轨道、小圆点：默认的大圆点压过封面
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0, pressedElevation: 0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                ),
                child: Slider(
                  value: cur.toDouble(),
                  max: vols.length - 1.0,
                  divisions: vols.length - 1,
                  label: '第 ${cur + 1} 卷',
                  onChanged: (x) => _pc.jumpToPage(x.round()),
                ),
              ),
            )
          : const SizedBox(height: 16);
      // 卷名和进度在打开动画的后半段浮上来
      final shown = AppMotion.reduce(context)
          ? kAlwaysCompleteAnimation
          : CurveTween(curve: const Interval(0.5, 1, curve: AppMotion.decelerate)).animate(ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation);
      final summary = FadeTransition(
        opacity: shown,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(shown),
          child: _Summary(aid: aid, vol: v, index: cur, count: vols.length, direction: _dir),
        ),
      );
      // 收起态不再提前构建隐藏的 _Details 和 _VolList，仅在真正展开对应面板时按需构建
      final Widget? panel = _open
          ? _Details(
              key: ValueKey(v.title),
              aid: aid,
              vol: v,
              index: cur,
              wide: wide,
              book: title,
              bg: base,
              onClose: () => setState(() => _open = false),
              onCache: (cids) {
                final chs = [for (final cv in novel?.catalogue ?? const <CatVolume>[]) ...cv.chapters];
                final picked = [for (final c in chs) if (cids.contains(c.cid)) c];
                if (picked.isEmpty || novel == null) return;
                ref.read(downloadProvider.notifier).start(aid, novel.detail.title, picked, total: chs.length, img: novel.detail.imgUrl, firstCid: chs.first.cid);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(picked.length == 1 ? '已开始缓存《${picked.first.title}》' : '已开始缓存 ${picked.length} 章')));
              },
              chapterTitles: _chapterTitlesOf(novel?.catalogue),
            )
          : (_list
                ? _VolList(
                    aid: aid,
                    vols: vols,
                    cur: cur,
                    wide: wide,
                    coverOf: coverOf,
                    onClose: () => setState(() => _list = false),
                    onPick: (i) {
                      setState(() => _list = false);
                      if (AppMotion.reduce(context)) {
                        _pc.jumpToPage(i);
                      } else {
                        _pc.animateToPage(i, duration: Duration(milliseconds: math.min(250 + 40 * (i - cur).abs(), 700)), curve: AppMotion.curve);
                      }
                    },
                  )
                : null);
      // 竖屏：封面区上滑展开底部详情和目录，下滑收起；
      // 横屏（宽屏）：详情在右侧并排，封面区上下滑 / 滚轮直接切换上一卷、下一卷
      Widget swipe(Widget child) => Listener(
        onPointerSignal: (e) => _onWheel(e, vols.length),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragEnd: (d) {
            final vy = d.primaryVelocity ?? 0;
            if (wide) {
              if (vy < -200) _stepVol(1, vols.length);
              if (vy > 200) _stepVol(-1, vols.length);
            } else {
              if (vy < -250 && panel == null) setState(() => _open = true);
              if (vy > 250 && panel != null) setState(() => _open = _list = false);
            }
          },
          child: child,
        ),
      );
      body = wide
          ? Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: swipe(carousel)),
                      toggle,
                      scrubber,
                      swipe(summary),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
                AnimatedSize(
                  duration: AppMotion.dur(context, AppMotion.standard),
                  curve: AppMotion.curve,
                  child: panel != null ? SizedBox(width: 400, child: panel) : const SizedBox(height: double.infinity),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, c) => Column(
                children: [
                  // 展开后封面缩小、拖动条收起，把地方让给目录
                  AnimatedContainer(
                    duration: AppMotion.dur(context, AppMotion.standard),
                    curve: AppMotion.curve,
                    height: c.maxHeight * (panel != null ? 0.26 : 0.68),
                    child: swipe(carousel),
                  ),
                  swipe(toggle),
                  AppCollapse(visible: panel == null, duration: AppMotion.standard, reverseDuration: AppMotion.fast, child: scrubber),
                  Expanded(
                    child: AppCrossfade(
                      fill: true,
                      alignment: Alignment.topCenter,
                      duration: AppMotion.fast,
                      child: panel ?? KeyedSubtree(key: const ValueKey('vol-summary'), child: swipe(summary)),
                    ),
                  ),
                ],
              ),
            );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: !_open && !_list,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _closeBook();
          } else {
            setState(() => _open = _list = false); // 返回键先收起详情
          }
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, e) => _onKey(node, vols, cur, cover, e),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: base),
            duration: AppMotion.dur(context, AppMotion.ambient),
            curve: AppMotion.curve,
            builder: (context, color, child) => Scaffold(backgroundColor: color, body: child),
            child: SafeArea(
              child: Column(
                children: [
                  AppBar(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    actions: [
                      IconButton(
                        tooltip: hz(context, '书籍详情'),
                        icon: const Icon(Icons.info_outline),
                        onPressed: () => context.push(Routes.novel(aid)).then((_) {
                          if (mounted) setState(() {});
                        }),
                      ),
                    ],
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

