import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cat_volume.dart';
import '../cache.dart';
import '../cover_color.dart';
import '../library.dart';
import '../progress.dart';
import '../read_state.dart';
import '../router.dart';
import '../stats.dart';
import '../swipe.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'cover_picker_page.dart';
import 'novel_page.dart';
import '../text.dart';

/// 书架"卷册"模式点进来：一本书的各卷叠在一起，左右滑把某一卷转到最前面；点最前面那卷像翻开书一样开始读，点下面的横条展开详情和目录。
class VolumesPage extends ConsumerStatefulWidget {
  const VolumesPage({super.key, required this.aid});

  final String aid;

  @override
  ConsumerState<VolumesPage> createState() => _VolumesPageState();
}

/// 书架上一叠书露出后面几卷的边：卷数越多露得越多（0~3 条）
int stackEdges(int count) => count <= 1 ? 0 : (count <= 4 ? 1 : (count <= 9 ? 2 : 3));

/// 叠在第一卷后面的第 k 卷（k ≥ 1，0 是第一卷自己）：以封面中心缩小一点、往右错开露出一条边、越往后越暗。
/// 书架上的一叠和轮播打开时往右抽出的起点都用它，飞到位时两边对得上。
({double dx, double scale, double dim}) stackPose(int k, double width) {
  final s = 1 - 0.04 * k;
  return (dx: width * ((1 - s) / 2 + 0.026 * k), scale: s, dim: k <= 1 ? 0.0 : 0.12 * (k - 1));
}

/// 书架卷册模式的一叠书：第一卷的封面压着后面几卷（右边露出一条条真封面的边）。按自己的宽度排，飞的时候整叠一起放大。
class VolumeStack extends StatelessWidget {
  const VolumeStack({super.key, required this.cover, this.behind = const []});

  final String cover;

  /// 后面几卷的封面，近的在前
  final List<String> behind;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      Widget sheet(String url, double dim) => DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.32), blurRadius: 4, offset: const Offset(1.5, 0))]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(fit: StackFit.expand, children: [CoverImage(url), if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim))]),
        ),
      );
      return Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none, // 后面几卷的边在封面右边、自己的范围外面
        children: [
          for (var k = behind.length; k >= 1; k--)
            Builder(
              builder: (context) {
                final p = stackPose(k, c.maxWidth);
                return Transform.translate(offset: Offset(p.dx, 0), child: Transform.scale(scale: p.scale, child: sheet(behind[k - 1], p.dim)));
              },
            ),
          sheet(cover, 0),
        ],
      );
    },
  );
}

/// 书架封面和轮播最前面那卷之间飞的时候：书架那叠垫底（整叠一起放大），轮播那张跟着动画淡入（返回时淡出），
/// 停在的卷不是第一卷时封面在飞行中自然换过去。
Widget volumeHeroShuttle(BuildContext context, Animation<double> animation, HeroFlightDirection direction, BuildContext from, BuildContext to) {
  final (shelf, carousel) = direction == HeroFlightDirection.push ? (from, to) : (to, from);
  // 飞行时在 Overlay 里，没有 Material 的话「在读」标签会带上默认的黄色双下划线
  return Material(
    type: MaterialType.transparency,
    child: Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none, // 书架那叠后面几卷的边在范围外面
      children: [
        (shelf.widget as Hero).child,
        FadeTransition(opacity: animation, child: (carousel.widget as Hero).child),
      ],
    ),
  );
}

/// 打开这一卷从哪章读：进度在这卷就接着读，不然从第一章没读过的正文开始，全读过就从头。
String startCid(String aid, Vol v) {
  final p = ReadingProgress.of(aid);
  if (p != null && v.cids.contains(p.cid)) return p.cid;
  final read = ReadState.read(aid);
  return v.textCids.where((c) => !read.contains(c)).firstOrNull ?? v.cids.first;
}

/// 正在读第几卷：阅读进度所在的那卷；那卷已经读完（比如手动标了读完）就往后找第一卷没读完的。
/// 没读过、或者从那卷往后全读完了为 -1。
int readingVolume(String aid) {
  final p = ReadingProgress.of(aid);
  final i = p == null ? -1 : Volumes.indexOf(aid, p.cid);
  if (i < 0) return -1;
  final vols = Volumes.of(aid);
  final done = Volumes.done(aid);
  for (var j = i; j < vols.length; j++) {
    if (!done.containsKey(vols[j].title)) return j;
  }
  return -1;
}

class _VolumesPageState extends ConsumerState<VolumesPage> with SingleTickerProviderStateMixin {
  // 先停在第一卷（和书架上那叠对得上），开场动画放完再滑到正在读的那卷
  int _cur = 0;
  final _pc = PageController(viewportFraction: 0.5);
  // 开场：封面飞到位以后，后面几卷从封面后面往右抽出来
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  Animation<double>? _route;
  bool _open = false;
  bool _list = false; // 展开"全部卷"列表（和详情二选一）
  final _coverKey = GlobalKey(); // 最前面那卷的封面，翻开动画从它的位置开始
  OverlayEntry? _opening; // 正在放的翻开动画

  /// 点最前面那卷：封面绕书脊翻开、放大铺满屏幕，进阅读页。动画放在最上层的 Overlay 里，阅读页推上来以后再淡出。
  void _openBook(Vol v, String url) {
    final cid = startCid(widget.aid, v);
    final box = _coverKey.currentContext?.findRenderObject() as RenderBox?;
    if (_opening != null) return;
    if (box == null || !box.hasSize) {
      context.push(Routes.reader(widget.aid, cid)).then((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    _opening = OverlayEntry(
      builder: (_) => _OpeningBook(
        from: box.localToGlobal(Offset.zero) & box.size,
        url: url,
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
  void _startIntro() => _intro.forward().whenComplete(() {
    final target = readingVolume(widget.aid);
    if (!mounted || target <= 0 || !_pc.hasClients) return;
    _pc.animateToPage(target, duration: Duration(milliseconds: math.min(250 + 80 * target, 900)), curve: Curves.easeInOutCubic);
  });

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
      _pc.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    } else {
      _openBook(v, url);
    }
  }

  void _stepVol(int delta, int count) {
    if (!_pc.hasClients || count <= 0) return;
    final target = (_cur + delta).clamp(0, count - 1);
    if (target == _cur) return;
    _pc.animateToPage(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  DateTime _lastWheel = DateTime(0);

  void _onWheel(PointerSignalEvent e, int count) {
    if (e is! PointerScrollEvent) return;
    final delta = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    if (delta.abs() < 4) return;
    final now = DateTime.now();
    if (now.difference(_lastWheel) < const Duration(milliseconds: 220)) return;
    _lastWheel = now;
    _stepVol(delta > 0 ? 1 : -1, count);
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
    ref.watch(volumeChangesProvider);
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
      body = novel == null ? const Center(child: CircularProgressIndicator(color: Colors.white)) : const StatePanel(title: '这本书没有分卷信息');
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
        onPage: (i) => setState(() => _cur = i),
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
      final volList = _VolList(
        aid: aid,
        vols: vols,
        cur: cur,
        wide: wide,
        coverOf: coverOf,
        onClose: () => setState(() => _list = false),
        onPick: (i) {
          setState(() => _list = false);
          _pc.animateToPage(i, duration: Duration(milliseconds: math.min(250 + 40 * (i - cur).abs(), 700)), curve: Curves.easeInOutCubic);
        },
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
      final shown = CurveTween(curve: const Interval(0.5, 1, curve: Curves.easeOut)).animate(ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation);
      final summary = FadeTransition(
        opacity: shown,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(shown),
          child: _Summary(aid: aid, vol: v, index: cur, count: vols.length),
        ),
      );
      final details = _Details(
        key: ValueKey(v.title),
        aid: aid,
        vol: v,
        index: cur,
        wide: wide,
        book: title,
        bg: base,
        onClose: () => setState(() => _open = false),
        onCache: (cid) {
          final chs = [for (final cv in novel?.catalogue ?? const <CatVolume>[]) ...cv.chapters];
          final c = chs.where((c) => c.cid == cid).firstOrNull;
          if (c != null && novel != null) ref.read(downloadProvider.notifier).start(aid, novel.detail.title, [c], total: chs.length, img: novel.detail.imgUrl, firstCid: chs.first.cid);
        },
        chapterTitles: {
          for (final cv in novel?.catalogue ?? const <CatVolume>[])
            for (final c in cv.chapters) c.cid: c.title,
        },
      );
      final Widget? panel = _open ? details : (_list ? volList : null);
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
                  duration: const Duration(milliseconds: 250),
                  child: panel != null ? SizedBox(width: 400, child: panel) : const SizedBox(height: double.infinity),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, c) => Column(
                children: [
                  // 展开后封面缩小、拖动条收起，把地方让给目录
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    height: c.maxHeight * (panel != null ? 0.26 : 0.68),
                    child: swipe(carousel),
                  ),
                  swipe(toggle),
                  if (panel == null) scrubber,
                  Expanded(
                    child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]), child: panel ?? swipe(summary)),
                  ),
                ],
              ),
            );
    }

    return PopScope(
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
          duration: const Duration(milliseconds: 400),
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
    );
  }
}

/// 叠在一起的卷封面：最前面的最大，越往两边越小、越往后压，越暗。
/// 封面自己画（按离当前页的距离排先后），上面盖一层透明的 PageView 只管滑动和点击。
class _Carousel extends StatelessWidget {
  const _Carousel({
    required this.aid,
    required this.vols,
    required this.controller,
    required this.page,
    required this.cur,
    required this.intro,
    required this.coverOf,
    required this.onPage,
    required this.onTap,
    required this.onLongPress,
    required this.coverKey,
  });

  final String aid;
  final List<Vol> vols;
  final PageController controller;
  final double Function() page;
  final int cur;
  final Animation<double> intro;
  final String Function(Vol) coverOf;
  final ValueChanged<int> onPage;
  final void Function(int, Vol) onTap;
  final ValueChanged<Vol> onLongPress;
  final GlobalKey coverKey;

  @override
  Widget build(BuildContext context) {
    final done = Volumes.done(aid);
    final read = ReadState.read(aid);
    final reading = readingVolume(aid);
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight * 0.92;
        final w = math.min(h * kCoverAspect, c.maxWidth * 0.72);
        final route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
        return Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([controller, route, intro]),
              builder: (context, _) {
                final p = page();
                // 打开：书架那叠飞过来的时候其他卷先不画，飞到位后从书架上露边的位置往右抽出来（[stackPose]）；
                // 返回时原地很快淡出（往中间收会在封面飞走后露出来）
                final closing = route.status == AnimationStatus.reverse;
                final flying = route.status == AnimationStatus.forward;
                final q = closing ? 1.0 : Curves.easeOutCubic.transform(intro.value);
                final fade = closing ? const Interval(0.6, 1).transform(route.value) : 1.0;
                final edges = stackEdges(vols.length);
                final shown = [for (var i = math.max(0, p.floor() - 3); i <= math.min(vols.length - 1, p.ceil() + 3); i++) i]
                  ..sort((a, b) => (b - p).abs().compareTo((a - p).abs())); // 远的先画，近的压在上面
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    for (final i in shown)
                      Builder(
                        builder: (context) {
                          final d = i - p;
                          final a = d.abs();
                          // 第一张错开大半个身位，再往后的只露一条边
                          final dx = d.sign * (w * 0.55 * math.min(a, 1) + w * 0.16 * math.max(a - 1, 0));
                          final v = vols[i];
                          final untouched = !v.cids.any(read.contains);
                          // 最前面那卷是飞过来的封面，不用抽；后面的从露边的位置出发，露不出边的藏在封面后面淡入
                          final k = i - cur;
                          final from = i == cur ? null : stackPose(math.min(math.max(k, 0), edges), w);
                          double lerp(double a, double b) => from == null ? b : a + (b - a) * q;
                          final shade = math.min(a, 1.5) * 0.3;
                          final card = _VolumeCard(
                            url: coverOf(v),
                            width: w,
                            done: done.containsKey(v.title),
                            reading: i == reading,
                            untouched: from == null && untouched,
                            shade: lerp(from?.dim ?? 0, shade + (from != null && untouched ? 0.2 : 0)),
                          );
                          final show = from == null ? 1.0 : (flying ? 0.0 : (k >= 1 && k <= edges ? 1.0 : q));
                          return Opacity(
                            opacity: (3.2 - a).clamp(0.0, 1.0) * show * (i == cur ? 1.0 : fade),
                            child: Transform.translate(
                              offset: Offset(lerp(from?.dx ?? 0, dx), 0),
                              child: Transform.scale(
                                scale: lerp(from?.scale ?? 1, 1 - 0.14 * math.min(a, 2.5)),
                                child: i == cur
                                    // key 包在 Hero 外面：放里面会被飞行动画复制一份，同一个 GlobalKey 出现两次就红屏
                                    ? KeyedSubtree(
                                        key: coverKey,
                                        child: Hero(tag: 'vols:$aid', flightShuttleBuilder: volumeHeroShuttle, child: card),
                                      )
                                    : card,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
            PageView.builder(
              controller: controller,
              itemCount: vols.length,
              onPageChanged: onPage,
              itemBuilder: (context, i) =>
                  GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onTap(i, vols[i]), onLongPress: () => onLongPress(vols[i])),
            ),
          ],
        );
      },
    );
  }
}

/// 一卷的封面，带状态：读完了打勾，正在读的有"在读"标签，一章都没读的暗一点。
class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.url, required this.width, required this.done, required this.reading, required this.untouched, required this.shade});

  final String url;
  final double width;
  final bool done;
  final bool reading;
  final bool untouched;

  /// 离最前面越远越暗（0~1）
  final double shade;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width / kCoverAspect,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24, offset: const Offset(0, 12))],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.white.withValues(alpha: 0.15)),
          NetImage(url, error: const Icon(Icons.menu_book_outlined, color: Colors.white54)),
          ColoredBox(color: Colors.black.withValues(alpha: (shade + (untouched ? 0.2 : 0)).clamp(0, 0.75))),
          if (reading)
            Positioned(
              top: 10,
              left: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
                ),
                child: Text(
                  '在读',
                  style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (done)
            const Positioned(
              right: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Icon(Icons.check_circle, color: Color(0xFF2E9E5B), size: 26),
              ),
            ),
        ],
      ),
    ),
  );
}

String _progress(String aid, Vol v) {
  final read = ReadState.read(aid);
  final at = Volumes.done(aid)[v.title];
  final d = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  return ['已读 ${v.textCids.where(read.contains).length} / ${v.textCids.length} 章', if (d != null) '${d.year}.${d.month}.${d.day} 读完'].join(' · ');
}

/// 没展开时封面下面的一行：卷名和进度
class _Summary extends StatelessWidget {
  const _Summary({required this.aid, required this.vol, required this.index, required this.count});

  final String aid;
  final Vol vol;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      children: [
        // 固定两行的高度：卷名一行还是两行，下面的字都不动
        SizedBox(
          height: 50,
          child: Center(
            child: Text(
              vol.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, height: 1.25),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '第 ${index + 1} / $count 卷 · ${_progress(aid, vol)}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    ),
  );
}

/// 展开后的这一卷：进度、评分、继续读、换封面、阅读报告，以及这一卷的目录。
class _Details extends StatefulWidget {
  const _Details({
    super.key,
    required this.aid,
    required this.vol,
    required this.index,
    required this.chapterTitles,
    required this.book,
    required this.onCache,
    required this.bg,
    required this.onClose,
    this.wide = false,
  });

  final String aid;
  final Vol vol;
  final int index;
  final Map<String, String> chapterTitles;
  final String book;
  final void Function(String cid) onCache;

  /// 页面最终的底色（封面取色）。不能用 Scaffold 当前的颜色：换卷时它正在渐变，取到的是上一卷的颜色
  final Color bg;

  /// 目录在最顶上还往下拉：收起，回到大封面
  final VoidCallback onClose;
  final bool wide;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  final _picked = <String>{}; // 长按多选的章节

  void _pick(String cid) => setState(() => _picked.contains(cid) ? _picked.remove(cid) : _picked.add(cid));

  /// 只选了一章时：整本书里它前面的章节全标为已读（跨卷）
  Future<void> _markBefore() async {
    final all = [for (final v in Volumes.of(widget.aid)) ...v.cids];
    final i = all.indexWhere(_picked.contains);
    if (i > 0) await ReadState.setRead(widget.aid, all.take(i), true);
    if (mounted) setState(_picked.clear);
  }

  Future<void> _mark(bool read) async {
    await ReadState.setRead(widget.aid, _picked, read); // 这卷读没读完会跟着重新核对
    if (mounted) setState(_picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final aid = widget.aid;
    final v = widget.vol;
    final read = ReadState.read(aid);
    final p = ReadingProgress.of(aid);
    final inVol = p != null && v.cids.contains(p.cid);
    final next = startCid(aid, v);
    final label = inVol ? '继续读' : (v.textCids.every(read.contains) ? '重读这一卷' : '开始读');
    final rating = Volumes.rating(aid, v.title);
    const muted = TextStyle(color: Colors.white60);

    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // 卷名、进度、星级挤在一行，按钮一行，尽量把地方留给目录
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(_progress(aid, v), style: muted.copyWith(fontSize: 12)),
                ],
              ),
            ),
            for (var i = 1; i <= 5; i++)
              GestureDetector(
                onTap: () async {
                  await Volumes.setRating(aid, v.title, rating == i ? 0 : i); // 再点一次当前星数就取消
                  if (mounted) setState(() {});
                },
                child: Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFFFFC53D), size: 22),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40), textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                onPressed: () => context.push(Routes.reader(aid, next)).then((_) {
                  if (mounted) setState(() {});
                }),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(label),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: hz(context, '换封面'),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: () => pickVolumeCover(context, aid, v),
              icon: const Icon(Icons.image_outlined, size: 20),
            ),
            IconButton.outlined(
              tooltip: hz(context, '阅读报告'),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              onPressed: () => context.push(Routes.report(aid, vol: widget.index)),
              icon: const Icon(Icons.insights, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final (i, cid) in v.cids.indexed)
          ChapterSwipe(
            aid: aid,
            book: widget.book,
            cid: cid,
            title: widget.chapterTitles[cid] ?? '第 ${i + 1} 章',
            enabled: _picked.isEmpty,
            backdrop: Color.alphaBlend(Colors.black.withValues(alpha: 0.18), widget.bg),
            onChanged: () => setState(() {}),
            onCache: () => widget.onCache(cid),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              // 默认给前面的图标留 40 宽再空 16，章节名左边空一大块
              minLeadingWidth: 20,
              horizontalTitleGap: 8,
              leading: _picked.isNotEmpty
                  ? Icon(_picked.contains(cid) ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: Colors.white70)
                  : (read.contains(cid) ? const Icon(Icons.check, size: 16, color: Colors.white38) : const SizedBox(width: 16)),
              title: Text(
                widget.chapterTitles[cid] ?? '第 ${i + 1} 章',
                style: TextStyle(
                  color: cid == p?.cid ? Colors.white : (read.contains(cid) ? Colors.white38 : Colors.white70),
                  fontWeight: cid == p?.cid ? FontWeight.w700 : null,
                ),
              ),
              trailing: cid == p?.cid ? const Text('读到这里', style: TextStyle(color: Colors.white, fontSize: 12)) : null,
              onTap: _picked.isNotEmpty
                  ? () => _pick(cid)
                  : () => context.push(Routes.reader(aid, cid)).then((_) {
                      if (mounted) setState(() {});
                    }),
              onLongPress: () => _pick(cid),
            ),
          ),
      ],
    );

    return Padding(
      padding: widget.wide ? const EdgeInsets.fromLTRB(4, 4, 16, 16) : const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: widget.wide ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              // 横屏里详情在右侧并排展示，往下拉目录顶头时不应该把右侧面板关掉
              child: widget.wide ? list : PullToClose(onClose: widget.onClose, child: list),
            ),
            if (_picked.isNotEmpty)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.25),
                child: SafeArea(
                  top: false,
                  child: TextButtonTheme(
                    data: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Colors.white)),
                    child: Row(
                      children: [
                        IconButton(tooltip: hz(context, '取消'), color: Colors.white, icon: const Icon(Icons.close), onPressed: () => setState(_picked.clear)),
                        Expanded(
                          child: Text('已选 ${_picked.length} 章', style: const TextStyle(color: Colors.white)),
                        ),
                        TextButton(onPressed: () => _mark(true), child: const Text('已读')),
                        TextButton(onPressed: () => _mark(false), child: const Text('未读')),
                        // 按钮全摆出来窄屏放不下，不常用的收进"更多"
                        PopupMenuButton<void Function()>(
                          tooltip: hz(context, '更多'),
                          iconColor: Colors.white,
                          onSelected: (f) => f(),
                          itemBuilder: (_) => [
                            // 从这一卷第一章选到已选的最后一章
                            PopupMenuItem(value: () => setState(() => _picked.addAll(v.cids.take(v.cids.lastIndexWhere(_picked.contains) + 1))), child: const Text('选到开头')),
                            if (_picked.length == 1) PopupMenuItem(value: _markBefore, child: const Text('前面的标为已读')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 封面下面的两个横条：展开 / 收起这一卷的详情和目录，或者全部卷的列表
class _DetailsToggle extends StatelessWidget {
  const _DetailsToggle({required this.open, required this.list, required this.onTap, required this.onList, this.wide = false});

  final bool open;
  final bool list;
  final VoidCallback onTap;
  final VoidCallback onList;
  final bool wide;

  Widget _pill(bool expanded, String text, VoidCallback onTap) => Material(
    color: Colors.white.withValues(alpha: 0.12),
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              wide
                  ? (expanded ? Icons.keyboard_arrow_left : Icons.keyboard_arrow_right)
                  : (expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [_pill(open, open ? '收起' : '详情和目录', onTap), _pill(list, list ? '收起' : '全部卷', onList)],
    ),
  );
}

/// 全部卷：三列封面网格（像 Apple Books 的系列页）。读完的打勾，在读的封面底下一条进度，当前这卷描边；点一卷，轮播翻到那一卷。
class _VolList extends StatelessWidget {
  const _VolList({required this.aid, required this.vols, required this.cur, required this.coverOf, required this.onPick, required this.onClose, this.wide = false});

  final String aid;
  final List<Vol> vols;
  final int cur;
  final String Function(Vol) coverOf;
  final ValueChanged<int> onPick;
  final VoidCallback onClose;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final done = Volumes.done(aid);
    final reading = readingVolume(aid);
    final read = ReadState.read(aid);
    return Padding(
      padding: wide ? const EdgeInsets.fromLTRB(4, 4, 16, 16) : const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: wide ? BorderRadius.circular(20) : const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, c) {
            final n = (c.maxWidth / 120).floor().clamp(3, 6);
            final w = (c.maxWidth - 32 - 12 * (n - 1)) / n;
            final grid = GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              // 一格 = 封面 + 两行卷名
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: n, mainAxisSpacing: 14, crossAxisSpacing: 12, childAspectRatio: w / (w / kCoverAspect + 40)),
              itemCount: vols.length,
              itemBuilder: (context, i) {
                final v = vols[i];
                final finished = done.containsKey(v.title);
                final total = v.textCids.length;
                final progress = i == reading && !finished && total > 0 ? v.textCids.where(read.contains).length / total : null;
                return GestureDetector(
                  onTap: () => onPick(i),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: kCoverAspect,
                        child: DecoratedBox(
                          position: DecorationPosition.foreground,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: i == cur ? Border.all(color: Colors.white, width: 2) : null,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: Colors.white10, child: NetImage(coverOf(v))),
                                if (finished)
                                  const Positioned(
                                    top: 5,
                                    right: 5,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                      child: Padding(padding: EdgeInsets.all(2), child: Icon(Icons.check, size: 14, color: Colors.white)),
                                    ),
                                  ),
                                if (progress != null)
                                  Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: progress, minHeight: 4, color: Colors.white, backgroundColor: Colors.black45)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.3, color: i == cur ? Colors.white : Colors.white70, fontWeight: i == cur ? FontWeight.w700 : null),
                      ),
                    ],
                  ),
                );
              },
            );
            return wide ? grid : PullToClose(onClose: onClose, child: grid);
          },
        ),
      ),
    );
  }
}

/// 列表滚到最顶上以后继续往下拉超过一段距离：松手前就触发 [onClose]（每次拖动只触发一次）。
class PullToClose extends StatefulWidget {
  const PullToClose({super.key, required this.onClose, required this.child});

  final VoidCallback onClose;
  final Widget child;

  @override
  State<PullToClose> createState() => _PullToCloseState();
}

class _PullToCloseState extends State<PullToClose> {
  double _pull = 0;
  bool _fired = false;

  bool _on(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification) {
      _pull = 0;
      _fired = false;
    } else if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      _pull -= n.overscroll;
    } else if (n is ScrollUpdateNotification && n.dragDetails != null && n.metrics.pixels < 0) {
      _pull = -n.metrics.pixels; // iOS 回弹式滚动
    }
    if (_pull > 70 && !_fired) {
      _fired = true;
      widget.onClose();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(onNotification: _on, child: widget.child);
}

/// 翻开书的动画：封面以左边书脊为轴往外翻开，同时连书页一起放大铺满屏幕；铺满时（[onOpened]）推出阅读页，
/// 再稍等阅读页就位后淡出（[onDone] 里移除自己）。自带计时器，不跟着下面的页面暂停。
class _OpeningBook extends StatefulWidget {
  const _OpeningBook({required this.from, required this.url, required this.onOpened, required this.onDone});

  final Rect from;
  final String url;
  final VoidCallback onOpened;
  final VoidCallback onDone;

  @override
  State<_OpeningBook> createState() => _OpeningBookState();
}

class _OpeningBookState extends State<_OpeningBook> with SingleTickerProviderStateMixin {
  // 0 ~ 0.5 翻开、放大；0.5 推出阅读页；0.78 ~ 1 淡出
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _pushed = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (!_pushed && _c.value >= 0.5) {
        _pushed = true;
        widget.onOpened();
      }
    });
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final wide = screen.width > screen.height;
    final aspect = widget.from.height > 0 ? widget.from.width / widget.from.height : kCoverAspect;
    // 宽屏下封面保持自身竖版比例，避免被拉伸到宽窗口而把上下截断；高度留一点余量防止 3D 旋转透视边越出窗口
    final coverTarget = wide
        ? Rect.fromCenter(
            center: screen.center,
            width: screen.height * 0.84 * aspect,
            height: screen.height * 0.84,
          )
        : screen;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final grow = Curves.easeInOutCubic.transform((_c.value / 0.5).clamp(0.0, 1.0));
          final spread = Curves.easeInCubic.transform((_c.value / 0.5).clamp(0.0, 1.0));
          final turn = Curves.easeInCubic.transform((_c.value / 0.46).clamp(0.0, 1.0)); // 0 合着 → 1 翻到垂直看不见
          final fade = 1 - Curves.easeOut.transform(((_c.value - 0.78) / 0.22).clamp(0.0, 1.0));
          final coverRect = Rect.lerp(widget.from, coverTarget, grow)!;
          final pageRect = wide ? Rect.lerp(coverRect, screen, spread)! : coverRect;
          final radius = BorderRadius.circular(8 * (1 - grow));
          final persp = (0.25 / math.max(coverRect.width, 1.0)).clamp(0.0002, 0.0009);
          return Opacity(
            opacity: fade,
            child: Stack(
              children: [
                // 书页：纸色，书脊那边有一点阴影
                Positioned.fromRect(
                  rect: pageRect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: wide
                          ? const LinearGradient(
                              colors: [Color(0xFFF5EEE1), Color(0xFFE5DCCB), Color(0xFFDAD0BE), Color(0xFFF5EEE1), Color(0xFFF5EEE1)],
                              stops: [0.0, 0.48, 0.5, 0.53, 1.0],
                            )
                          : const LinearGradient(colors: [Color(0xFFE2D8C6), Color(0xFFF5EEE1), Color(0xFFF5EEE1)], stops: [0, 0.08, 1]),
                    ),
                  ),
                ),
                if (turn < 1)
                  Positioned.fromRect(
                    rect: coverRect,
                    child: Transform(
                      alignment: Alignment.centerLeft,
                      // 右边朝人抬起来往左翻（真书翻开封面的方向）；透视随封面宽度自适应，避免宽屏下右边转近时放大溢出屏幕上下边界
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, persp)
                        ..rotateY(turn * math.pi / 2),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FittedBox(
                              fit: BoxFit.fill,
                              child: SizedBox.fromSize(
                                size: widget.from.size,
                                child: NetImage(widget.url),
                              ),
                            ),
                            // 翻得越开越暗，像封面背光
                            ColoredBox(color: Colors.black.withValues(alpha: 0.45 * turn)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
