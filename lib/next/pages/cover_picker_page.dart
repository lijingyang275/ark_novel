import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_prefs.dart';
import '../bangumi.dart';
import '../cache.dart';
import '../cover_trim.dart';
import '../data.dart';
import '../image_cache.dart';
import '../unlock.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../text.dart';

/// 封面框的宽高比（文库的封面大多是这个比例）
const kCoverAspect = 0.7;

/// 自选卷封面：列出这卷插图章节里的图，选一张后框出封面那一块（横版展开图只框右边的封面）。
Future<void> pickVolumeCover(BuildContext context, String aid, Vol v) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _PickerPage(aid: aid, vol: v),
  ),
);

class _PickerPage extends ConsumerStatefulWidget {
  const _PickerPage({required this.aid, required this.vol});

  final String aid;
  final Vol vol;

  @override
  ConsumerState<_PickerPage> createState() => _PickerPageState();
}

class _PickerPageState extends ConsumerState<_PickerPage> {
  late Future<List<String>> _images = _load();
  late Future<BgmSeries?> _bgm = ref.read(bangumiProvider).series(widget.aid);

  /// 插图章节缓存过就直接用（若缓存里没有图则重新联网取），没缓存就联网取一次并存下；受限书取不到插图，只能从 Bangumi 挑
  Future<List<String>> _load() async {
    final cid = widget.vol.illus;
    if (cid == null) return const [];
    var content = await ChapterCache.get(widget.aid, cid);
    if (content != null && content.images.isEmpty) content = null;
    if (content == null) {
      try {
        content = await ref.read(apiProvider).chapter(widget.aid, cid);
      } on ChapterLockedException {
        return const [];
      }
      if (content.images.isNotEmpty) await ChapterCache.put(widget.aid, cid, content);
    }
    return content.images;
  }

  Future<void> _pick(String url) async {
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => _CropPage(url: url)));
    if (picked == null) return;
    await Volumes.setCover(widget.aid, widget.vol.title, picked, picked: true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = splitCrop(Volumes.cover(widget.aid, widget.vol.title) ?? '').url;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget head(String text) => SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      sliver: SliverToBoxAdapter(child: Text(text, style: theme.textTheme.titleSmall)),
    );
    Widget note(String text, {VoidCallback? retry}) => SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(child: Text(text, style: muted)),
            if (retry != null) TextButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      ),
    );
    // [labels] 是图上角标（Bangumi 的卷号），[mark] 是按卷号对上这一卷的那张
    Widget grid(List<String> urls, {List<String>? labels, String? mark}) => SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      sliver: SliverLayoutBuilder(
        builder: (context, c) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: (c.crossAxisExtent / 130).floor().clamp(3, 6),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: kCoverAspect,
          ),
          itemCount: urls.length,
          itemBuilder: (context, i) => InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pick(urls[i]),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                border: urls[i] == current
                    ? Border.all(color: theme.colorScheme.primary, width: 3)
                    : (urls[i] == mark ? Border.all(color: theme.colorScheme.outline, width: 2) : null),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(urls[i], fit: BoxFit.contain),
                  if (labels != null && labels[i].isNotEmpty)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), child: Text(labels[i], style: const TextStyle(color: Colors.white, fontSize: 11))),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('选封面 · ${widget.vol.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () async {
              await Volumes.resetCover(widget.aid, widget.vol.title);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('恢复自动'),
          ),
        ],
      ),
      body: contentWidth(
        CustomScrollView(
          slivers: [
            // 插图：选一张再框出封面那一块
            FutureBuilder<List<String>>(
              future: _images,
              builder: (context, snap) {
                if (snap.hasError) return note('插图加载失败：${snap.error}', retry: () => setState(() => _images = _load()));
                if (!snap.hasData) return const SliverToBoxAdapter(child: LinearProgressIndicator());
                if (snap.data!.isEmpty) return const SliverToBoxAdapter();
                return SliverMainAxisGroup(slivers: [head('插图'), grid(snap.data!)]);
              },
            ),
            // Bangumi：日文原版封面，按卷号对上这一卷的那张加了框
            FutureBuilder<BgmSeries?>(
              future: _bgm,
              builder: (context, snap) {
                if (snap.hasError) return SliverMainAxisGroup(slivers: [head('Bangumi'), note('连不上 Bangumi', retry: () => setState(() => _bgm = ref.read(bangumiProvider).series(widget.aid)))]);
                if (snap.connectionState != ConnectionState.done) return SliverMainAxisGroup(slivers: [head('Bangumi'), const SliverToBoxAdapter(child: LinearProgressIndicator())]);
                final s = snap.data;
                if (s == null || s.vols.isEmpty) return SliverMainAxisGroup(slivers: [head('Bangumi'), note('没找到这本书')]);
                final t = widget.vol.title;
                final mark = matchVolumeCovers([t], s.vols)[t] ?? matchExtraCovers([t], s)[t];
                final singles = s.extras.where((x) => x.vols.isEmpty).toList();
                // 主系列、各个外传系列分开列，外传单本放在一起
                return SliverMainAxisGroup(
                  slivers: [
                    head('Bangumi · ${s.name}'),
                    grid([for (final v in s.vols) v.img], labels: [for (final (i, v) in s.vols.indexed) '${bgmVolumeNumber(v.name, i) ?? ''}'], mark: mark),
                    for (final x in s.extras.where((x) => x.vols.isNotEmpty)) ...[
                      head('Bangumi · ${x.cn.isNotEmpty ? x.cn : x.name}'),
                      grid([for (final v in x.vols) v.img], labels: [for (var i = 1; i <= x.vols.length; i++) '$i'], mark: mark),
                    ],
                    if (singles.isNotEmpty) ...[head('Bangumi · 外传单本'), grid([for (final x in singles) x.img], mark: mark)],
                  ],
                );
              },
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        ),
      ),
    );
  }
}

/// 框出封面：框固定不动，拖动、双指缩放图片，把封面放进框里。返回带裁剪框的地址（见 [withCrop]）。
class _CropPage extends ConsumerStatefulWidget {
  const _CropPage({required this.url});

  final String url;

  @override
  ConsumerState<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends ConsumerState<_CropPage> {
  final _tc = TransformationController();
  late final Future<(Uint8List, ui.Size, CoverPixels)> _image = () async {
    final bytes = await ref.read(imageStoreProvider).load(widget.url);
    return (bytes, await imageSize(bytes), await CoverPixels.decode(bytes));
  }();
  Size? _laidOut; // 按哪个框的大小摆过初始位置
  bool _trimOn = AppPrefs.read(P.coverTrim, false);
  bool _srOn = false; // 提升清晰度（Real-ESRGAN 放大），选了的封面地址带 #sr
  Rect? _inner; // 去掉白边后留下的那块（框里的坐标），没有白边或正在拖时为 null
  (CoverPixels, ui.Size, Size)? _geom; // 现在的图和框
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    // 停下来一会儿（松手后的惯性也滑完了）再找白边
    _tc.addListener(() {
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 180), () {
        if (_geom case (final px, final img, final frame)) _retrim(px, img, frame);
      });
    });
  }

  /// 框里的这块要收掉白边的话，收完是图片的哪一块（0~1 比例）
  Rect _kept(CoverPixels px, ui.Size img, Size frame) {
    final v = _visible(img, frame);
    return _trimOn ? px.trim(v) : v;
  }

  /// 拖完、缩放完重新找一次白边，在框里标出来
  void _retrim(CoverPixels px, ui.Size img, Size frame) {
    if (!mounted) return;
    final v = _visible(img, frame);
    final k = _kept(px, img, frame);
    setState(
      () => _inner = k == v
          ? null
          : Rect.fromLTRB(
              (k.left - v.left) / v.width * frame.width,
              (k.top - v.top) / v.height * frame.height,
              (k.right - v.left) / v.width * frame.width,
              (k.bottom - v.top) / v.height * frame.height,
            ),
    );
  }

  @override
  void dispose() {
    _settle?.cancel();
    _tc.dispose();
    super.dispose();
  }

  /// 图片在框里铺满（像 BoxFit.cover）时的大小
  static Size _fill(ui.Size img, Size frame) {
    final s = math.max(frame.width / img.width, frame.height / img.height);
    return Size(img.width * s, img.height * s);
  }

  /// 框里现在露出的是图片的哪一块（0~1 比例）
  Rect _visible(ui.Size img, Size frame) {
    final child = _fill(img, frame);
    final scale = _tc.value.getMaxScaleOnAxis();
    final t = _tc.value.getTranslation();
    final r = Rect.fromLTWH(-t.x / scale / child.width, -t.y / scale / child.height, frame.width / scale / child.width, frame.height / scale / child.height);
    return Rect.fromLTRB(r.left.clamp(0, 1), r.top.clamp(0, 1), r.right.clamp(0, 1), r.bottom.clamp(0, 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('框出封面', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            // 整张也去掉四周的白边（开着自动去白边时）
            onPressed: () async {
              const full = Rect.fromLTWH(0, 0, 1, 1);
              final px = _trimOn ? (await _image).$3 : null;
              final r = px?.trim(full) ?? full;
              if (context.mounted) Navigator.pop(context, withSr(r == full ? widget.url : withCrop(widget.url, r), _srOn));
            },
            child: const Text('用整张'),
          ),
        ],
      ),
      body: FutureBuilder<(Uint8List, ui.Size, CoverPixels)>(
        future: _image,
        builder: (context, snap) {
          if (snap.hasError) return const StatePanel(title: '图片加载失败', detail: '检查网络后再试一次。');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (bytes, img, px) = snap.data!;
          return LayoutBuilder(
            builder: (context, c) {
              final w = math.min(c.maxWidth - 48, (c.maxHeight - (ImageStore.srSupported ? 244 : 196)) * kCoverAspect); // 下面留出开关和按钮几行
              final frame = Size(w, w / kCoverAspect);
              final child = _fill(img, frame);
              _geom = (px, img, frame);
              if (_laidOut != frame) {
                _laidOut = frame;
                // 横版展开图（封底 + 书脊 + 封面）的封面在右边，一开始就对准右边；竖图居中
                final dx = img.width > img.height ? frame.width - child.width : (frame.width - child.width) / 2;
                _tc.value = Matrix4.translationValues(dx, (frame.height - child.height) / 2, 0);
              }
              return Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SizedBox.fromSize(
                        size: frame,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            InteractiveViewer(
                              transformationController: _tc,
                              constrained: false,
                              minScale: 1,
                              maxScale: 6,
                              clipBehavior: Clip.none,
                              onInteractionStart: (_) => setState(() => _inner = null),
                              child: SizedBox.fromSize(
                                size: child,
                                child: Image.memory(bytes, fit: BoxFit.fill),
                              ),
                            ),
                            // 框外压暗，框线
                            IgnorePointer(
                              child: CustomPaint(size: frame, painter: _FramePainter(_inner)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 自动去白边：框里比封面宽、框得不准时带上的白底，完成时收掉；收掉的那圈在框里压暗标出来
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 24, 4),
                    child: Row(
                      children: [
                        Switch(
                          value: _trimOn,
                          onChanged: (v) {
                            AppPrefs.write(P.coverTrim, v);
                            _trimOn = v;
                            _retrim(px, img, frame);
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            !_trimOn ? '自动去白边：关' : (_inner == null ? '自动去白边：没找到白边' : '自动去白边：压暗的那圈会去掉'),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ImageStore.srSupported)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 24, 4),
                      child: Row(
                        children: [
                          Switch(value: _srOn, onChanged: (v) => setState(() => _srOn = v)),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('提升清晰度', style: TextStyle(color: Colors.white70))),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('拖动、双指缩放，把封面放进框里', style: TextStyle(color: Colors.white70)),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)), // 主题默认按钮占满整行，这里要和文字并排
                          onPressed: () {
                            final r = _kept(px, img, frame);
                            Navigator.pop(context, withSr(r.width > 0.995 && r.height > 0.995 ? widget.url : withCrop(widget.url, r), _srOn));
                          },
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.inner);

  /// 去掉白边后留下的那块，外面一圈再压暗一点
  final Rect? inner;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Offset.zero & size;
    if (inner case final r?) {
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(frame)
          ..addRect(r),
        Paint()..color = Colors.black.withValues(alpha: 0.5),
      );
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white70,
      );
    }
    // 画一圈很大的暗色，中间挖掉框
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(frame.inflate(4000))
        ..addRect(frame),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.inner != inner;
}
