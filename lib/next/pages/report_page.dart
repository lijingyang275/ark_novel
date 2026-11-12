import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/wenku8/wenku8_parser.dart';
import '../cover_color.dart';
import '../read_state.dart';
import '../stats.dart';
import '../theme.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'cover_picker_page.dart';
import '../text.dart';

String _date(String key) => key.replaceAll('-', '.');

String _dayOf(int ms) => _date(ReadingStats.dayKey(DateTime.fromMillisecondsSinceEpoch(ms)));

const _ratingLabels = ['点星星评分', '不推荐', '一般', '还不错', '值得一读', '神作必读'];
const _gold = Color(0xFFFFC53D);

/// 阅读报告（参考"阅读记录"App 的样式）：背景色从封面取，封面做成实体书的样子。
/// 左右滑封面切换"全书"和每一卷，背景、数据、评分跟着换；可以保存成图片分享。
class ReportPage extends ConsumerStatefulWidget {
  const ReportPage({super.key, required this.aid, this.vol});

  final String aid;

  /// 一打开就显示第几卷（书籍墙点进来时），null 显示全书
  final int? vol;

  @override
  ConsumerState<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends ConsumerState<ReportPage> {
  final _shot = GlobalKey();
  late int _page = (widget.vol ?? -1) + 1; // 0 是全书，i + 1 是第 i 卷
  late final _pager = PageController(initialPage: _page);
  bool _capturing = false; // 截图时不画翻页指示

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _share(String title) async {
    try {
      setState(() => _capturing = true);
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final file = File('${(await getTemporaryDirectory()).path}/report_${widget.aid}_$_page.png');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: '《$title》阅读报告'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享失败：$e')));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(volumeChangesProvider);
    final aid = widget.aid;
    final info = ReadingStats.info(aid);
    final vols = Volumes.of(aid);
    final queue = ref.read(volumeCoverQueueProvider);
    final bookCover = queue.bookCover(aid, info.img.isNotEmpty ? info.img : Wenku8Parser.coverUrl(aid));
    String coverOf(int page) => page == 0 ? bookCover : queue.volCover(aid, vols[page - 1], bookCover);

    final page = _page.clamp(0, vols.length);
    final v = page == 0 ? null : vols[page - 1];
    final cover = coverOf(page);
    // 算过的颜色当场就用（不先闪一下默认色再渐变）；第一次算之前用中性深灰
    final base = ref.watch(coverColorProvider(cover)).value ?? savedCoverColor(cover) ?? kNeutralCoverColor;

    final rating = v == null ? ReadState.rating(aid) : Volumes.rating(aid, v.title);
    final time = v == null ? (seconds: ReadingStats.perBook()[aid] ?? 0, days: ReadingStats.bookDays(aid)) : Volumes.time(aid, v);
    final chars = v == null ? ReadState.readChars(aid) : Volumes.readChars(aid, v);
    final doneAt = v == null ? null : Volumes.done(aid)[v.title];
    final width = MediaQuery.sizeOf(context).width.clamp(0.0, 600.0);
    final bookWidth = width * 0.52;

    void rate(int stars) {
      final next = rating == stars ? 0 : stars; // 再点一次当前星数就取消评分
      v == null ? ReadState.setRating(aid, next) : Volumes.setRating(aid, v.title, next);
      setState(() {});
    }

    const white70 = TextStyle(color: Colors.white70, fontSize: 13);
    Widget header(IconData icon, String label) => Row(children: [Icon(icon, size: 16, color: Colors.white70), const SizedBox(width: 6), Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: white70))]);

    final dates = time.days.isEmpty
        ? (doneAt == null ? '—' : '${_dayOf(doneAt)} 读完')
        : '${_date(time.days.first)} - ${time.days.first.substring(0, 4) == time.days.last.substring(0, 4) ? _date(time.days.last).substring(5) : _date(time.days.last)}';

    final content = Padding(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 64, 20, 28),
      child: Column(
        children: [
          SizedBox(
            height: bookWidth * 4 / 3 + 40,
            child: PageView.builder(
              controller: _pager,
              itemCount: vols.length + 1,
              onPageChanged: (i) => setState(() => _page = i),
              // 长按某一卷的封面换封面
              itemBuilder: (context, i) => Center(child: GestureDetector(onLongPress: i == 0 ? null : () => pickVolumeCover(context, aid, vols[i - 1]), child: _Book(url: coverOf(i), width: bookWidth))),
            ),
          ),
          Visibility(
            visible: !_capturing && vols.isNotEmpty,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _Indicator(count: vols.length + 1, index: page),
          ),
          const SizedBox(height: 16),
          Text(info.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700, fontFamilyFallback: kSerifFallback)),
          const SizedBox(height: 6),
          Text(
            v == null ? [if (info.author.isNotEmpty) info.author, if (vols.isNotEmpty) '全书 · 共 ${vols.length} 卷'].join(' · ') : [v.title, if (doneAt != null) '${_dayOf(doneAt)} 读完'].join(' · '),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15, fontFamilyFallback: kSerifFallback),
          ),
          const SizedBox(height: 26),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Tile(
                    header: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        children: [
                          Transform.flip(flipX: true, child: const Icon(Icons.spa, size: 14, color: _gold)),
                          const SizedBox(width: 3),
                          Text(_ratingLabels[rating], style: const TextStyle(color: _gold, fontSize: 14, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 3),
                          const Icon(Icons.spa, size: 14, color: _gold),
                        ],
                      ),
                    ),
                    value: Row(
                      children: [
                        for (var i = 1; i <= 5; i++)
                          GestureDetector(onTap: () => rate(i), child: Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, color: _gold, size: 22)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _Tile(header: header(Icons.hourglass_bottom, '阅读时间'), value: _amount(_duration(time.seconds)))),
                const SizedBox(width: 10),
                Expanded(child: _Tile(header: header(Icons.text_fields, '已读字数'), value: _amount(chars >= 10000 ? [((chars / 10000).toStringAsFixed(1), '万')] : [('$chars', '字')]))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _Tile(header: header(Icons.calendar_today_outlined, '已读天数'), value: _amount([('${time.days.length}', '天')]))),
                const SizedBox(width: 10),
                Expanded(flex: 3, child: _Tile(header: header(Icons.schedule, '阅读日期（开始 / 结束）'), value: Text(dates, style: _big))),
              ],
            ),
          ),
          if (v != null && time.seconds == 0) ...[
            const SizedBox(height: 10),
            const Text('分卷的阅读时间和日期从这个版本开始记录', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
          const SizedBox(height: 28),
          const Text('该报告由 Ark Novel 统计生成', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: base,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          if (v != null) IconButton(tooltip: hz(context, '换这一卷的封面'), icon: const Icon(Icons.image_outlined), onPressed: () => pickVolumeCover(context, aid, v)),
          IconButton(tooltip: hz(context, '保存为图片并分享'), icon: const Icon(Icons.ios_share), onPressed: () => _share(info.title)),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: RepaintBoundary(
              key: _shot,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: base),
                duration: const Duration(milliseconds: 400),
                builder: (context, color, child) => Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: color!)),
                    // 顶部：放大模糊的封面，往下渐变到背景色
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: bookWidth * 4 / 3 + 260,
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              child: ImageFiltered(
                                key: ValueKey(cover),
                                imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                                child: Opacity(opacity: 0.6, child: NetImage(cover)),
                              ),
                            ),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.6), color]),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    child!,
                  ],
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _big = TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700);

List<(String, String)> _duration(int s) => s == 0
    ? [('—', '')]
    : s >= 3600
    ? [('${s ~/ 3600}', '时'), (' ${(s % 3600) ~/ 60}', '分')]
    : [('${(s / 60).ceil()}', '分')];

/// 大数字 + 小单位，如"1时 53分"
Widget _amount(List<(String, String)> parts) => Text.rich(
  TextSpan(children: [for (final (n, u) in parts) ...[TextSpan(text: n, style: _big), TextSpan(text: u, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))]]),
);

/// 半透明磨砂卡片，带一点立体感
class _Tile extends StatelessWidget {
  const _Tile({required this.header, required this.value});

  final Widget header;
  final Widget value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 12, offset: const Offset(0, 4))],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, const SizedBox(height: 10), FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: value)],
    ),
  );
}

/// 实体书样式的封面：左边书脊高光、表面光泽、底下深一点的投影。
class _Book extends StatelessWidget {
  const _Book({required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 4 / 3,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 30, offset: const Offset(0, 16))],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.white.withValues(alpha: 0.15)),
          NetImage(url, error: const Icon(Icons.menu_book_outlined, color: Colors.white54)),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: width * 0.07,
            child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0)]))),
          ),
          Positioned(left: width * 0.04, top: 0, bottom: 0, width: 1.2, child: ColoredBox(color: Colors.black.withValues(alpha: 0.18))),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white.withValues(alpha: 0.14), Colors.transparent, Colors.black.withValues(alpha: 0.10)]),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 第几页：页数少时用小圆点，多了用"3 / 15"
class _Indicator extends StatelessWidget {
  const _Indicator({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 16,
    child: count > 12
        ? Text(index == 0 ? '全书 · 左右滑看每一卷' : '第 $index / ${count - 1} 卷', style: const TextStyle(color: Colors.white60, fontSize: 12))
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == index ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: i == index ? 0.9 : 0.4), borderRadius: BorderRadius.circular(3)),
                ),
            ],
          ),
  );
}
