import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/novel_cover.dart';
import '../data/wenku8/wenku8_parser.dart';
import 'package:flutter/services.dart';

import 'data.dart' show PageResult;
import 'image_cache.dart';
import 'env.dart';
import 'router.dart';
import 'session.dart';
import 'theme_doodle.dart';
import 'text.dart';

/// 宽屏（平板、电脑）上把内容限制在 760 宽并居中。
Widget contentWidth(Widget child) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: child));

/// 游客看到需要账号的内容时显示的提示，点按钮再去登录。
class LoginPrompt extends StatelessWidget {
  const LoginPrompt({super.key, required this.title, this.detail = '登录轻小说文库账号后即可使用。'});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(detail, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => context.push(Routes.login), child: const Text('去登录')),
          ],
        ),
      ),
    );
  }
}

/// 错误 / 空状态。出错时给"重试"，没登录时额外给"去登录"。可滚动，保证下拉刷新可用。
class StatePanel extends ConsumerWidget {
  const StatePanel({super.key, required this.title, this.detail, this.onRetry, this.error, this.sourceHtml});

  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  /// 出错的原始异常：被 Cloudflare 拦住时给"去验证"入口
  final Object? error;

  /// 解析失败的页面源码（搜索用），给"复制页面源码"按钮
  final String? sourceHtml;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final guest = ref.watch(sessionProvider) is! SessionLoggedIn;
    final art = CharacterArt.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        if (art == null)
          const SizedBox(height: 80)
        else
          // 角色主题：出错时抱头慌张，没内容时托腮发呆
          Padding(padding: const EdgeInsets.only(top: 24, bottom: 12), child: Image.asset(error != null || onRetry != null ? art.error : art.empty, height: 140)),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        if (detail != null) ...[
          const SizedBox(height: 8),
          Text(
            detail!,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (onRetry != null) ...[
          const SizedBox(height: 24),
          Center(child: OutlinedButton(onPressed: onRetry, child: const Text('重试'))),
        ],
        if (error != null && isCloudflare(error!))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Center(child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(160, 44)), onPressed: () => context.push(Routes.verify), child: const Text('去验证'))),
          ),
        if (onRetry != null && sourceHtml != null)
          Center(
            child: TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: sourceHtml!));
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制页面源码，可以粘贴给开发者排查')));
              },
              child: const Text('复制页面源码'),
            ),
          ),
        if (onRetry != null && guest) ...[
          const SizedBox(height: 12),
          Center(
            child: TextButton(onPressed: () => context.push(Routes.login), child: const Text('可能需要登录，去登录')),
          ),
        ],
      ],
    );
  }
}

/// 原生 App 里 Image.network 不走代理，所以用 [ImageStore] 取图（内存 LRU + 磁盘缓存）；网页预览走转发程序，直接用 Image.network。
/// 有图放大好了清晰度、换了模式（见 [ImageStore.srVersion]）
final srVersionProvider = Provider<int>((ref) {
  final n = ref.watch(imageStoreProvider).srVersion;
  void listener() => ref.invalidateSelf();
  n.addListener(listener);
  ref.onDispose(() => n.removeListener(listener));
  return n.value;
});

final imageBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, url) {
  ref.watch(srVersionProvider); // 放大好了重新取
  final store = ref.read(imageStoreProvider);
  ref.onDispose(() => store.cancel(url)); // 没人看了（滑出屏幕），还在排队的就别下了
  return store.load(url);
});

class NetImage extends ConsumerWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.error, this.full = false});

  final String url;
  final BoxFit fit;
  final Widget? error;

  /// 按原图大小解码（能放大看的地方用）；默认按格子大小解码，见 [_Fitted]
  final bool full;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = error ?? const SizedBox.shrink();
    if (url.isEmpty) return fallback;
    final crop = splitCrop(url).crop;
    if (isWebPreview) return _cropped(Image.network(displayImageUrl(splitCrop(url).url), fit: fit, errorBuilder: (_, _, _) => fallback), crop);
    final store = ref.read(imageStoreProvider);
    ref.watch(srVersionProvider);
    Widget image(Uint8List b, {bool fade = false}) {
      Widget build(ImageProvider p) => _cropped(Image(image: p, fit: fit, gaplessPlayback: true, frameBuilder: fade ? _fadeIn : null, errorBuilder: (_, _, _) => fallback), crop);
      if (full) return build(MemoryImage(b));
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return LayoutBuilder(
        builder: (context, c) {
          // 裁剪时整张图比格子大：裁出来的那块才铺满格子
          final box = Size(_bucket(c.maxWidth * dpr / (crop?.width ?? 1)), _bucket(c.maxHeight * dpr / (crop?.height ?? 1)));
          return build(_Fitted(url, b, box, fit == BoxFit.cover));
        },
      );
    }

    // 内存里有就同步直接画，返回页面时不会先空一帧再出来
    final hit = store.peek(url);
    if (hit != null) return image(hit);
    // 不在内存里的（刚下载的、从磁盘读的）都短短淡入一下，比突然蹦出来顺眼；内存里有的上面已经同步画了
    return ref.watch(imageBytesProvider(url)).when(data: (b) => image(b, fade: true), loading: () => const SizedBox.shrink(), error: (_, _) => fallback);
  }

  /// 提前下载，并按 [size]（逻辑像素，图片要放进的格子）解码进图片缓存：之后同样大小的 NetImage 直接出图。
  /// 翻页时下一页才建出来，大插图解码要一两百毫秒，不提前做就会先空一下。
  /// [decode] 为 false 时只下载（存进本机），不解码。
  static Future<void> precache(BuildContext context, String url, Size size, {BoxFit fit = BoxFit.cover, bool decode = true}) async {
    if (url.isEmpty || isWebPreview) return;
    final Uint8List bytes;
    try {
      bytes = await ProviderScope.containerOf(context, listen: false).read(imageStoreProvider).load(url);
    } catch (_) {
      return; // 下不下来就等真正显示时再说
    }
    if (!decode || !context.mounted) return;
    final crop = splitCrop(url).crop;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final box = Size(_bucket(size.width * dpr / (crop?.width ?? 1)), _bucket(size.height * dpr / (crop?.height ?? 1)));
    await precacheImage(_Fitted(url, bytes, box, fit == BoxFit.cover), context, onError: (_, _) {});
  }

  /// 往上取到几个固定档位（每档大 25%）：格子大小一直在变时（比如封面飞过去的动画）不用每帧都重新解码
  static double _bucket(double px) =>
      const <double>[128, 160, 200, 256, 320, 400, 512, 640, 800, 1024, 1280, 1600, 2048, 2560, 3200].firstWhere((b) => b >= px, orElse: () => double.infinity);

  /// 只显示图片里裁剪框那一块，再按 [fit] 填进格子
  Widget _cropped(Widget img, Rect? c) {
    if (c == null) return img;
    double align(double start, double size) => size >= 1 ? 0 : start / (1 - size) * 2 - 1;
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: ClipRect(child: Align(alignment: Alignment(align(c.left, c.width), align(c.top, c.height)), widthFactor: c.width, heightFactor: c.height, child: img)),
    );
  }
}

/// 按格子大小解码。高清封面原图 1440×2048，原样解码一张占 12 MB，Flutter 的图片缓存（100 MB）装不下一屏书架，滑回来又得重新解码。
/// 按地址认图（不按字节对象）：内存里的字节被挤掉、再从磁盘读回来时，Flutter 图片缓存里解码好的那张还能接着用。
class _Fitted extends ImageProvider<_Fitted> {
  const _Fitted(this.url, this.bytes, this.box, this.cover);

  final String url;
  final Uint8List bytes;
  final Size box; // 物理像素；无限表示这个方向不限
  final bool cover; // 铺满格子（取两边缩放比里大的那个），否则整张放进格子

  @override
  Future<_Fitted> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Fitted key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    getTargetSize: (w, h) {
      final sx = box.width / w, sy = box.height / h;
      final s = sx.isInfinite ? sy : (sy.isInfinite ? sx : (cover ? math.max(sx, sy) : math.min(sx, sy)));
      return s >= 1 ? const ui.TargetImageSize() : ui.TargetImageSize(width: (w * s).ceil());
    },
  );

  // 带上字节数：同一个地址换成放大清晰度后的图时不会拿到原图解码好的那张
  @override
  bool operator ==(Object other) => other is _Fitted && other.url == url && other.bytes.length == bytes.length && other.box == box && other.cover == cover;

  @override
  int get hashCode => Object.hash(url, bytes.length, box, cover);
}

Widget _fadeIn(BuildContext context, Widget child, int? frame, bool sync) =>
    sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 150), child: child);

class CoverImage extends StatelessWidget {
  const CoverImage(this.url, {super.key});

  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.surfaceContainer),
        child: SizedBox.expand(
          child: NetImage(url, error: Icon(Icons.menu_book_outlined, color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

/// 封面 + 书名，点击进入详情。
class NovelCard extends StatelessWidget {
  const NovelCard({super.key, required this.title, required this.aid, this.imageUrl, this.onTap, this.badge, this.action});

  final String title;
  final String aid;
  final String? imageUrl;
  final VoidCallback? onTap;
  final Widget? badge;

  /// 封面右下角的按钮（书架的"继续阅读"）
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap ?? () => context.push(Routes.novel(aid)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(fit: StackFit.expand, children: [CoverImage(imageUrl ?? Wenku8Parser.coverUrl(aid)), if (badge != null) Positioned(top: 6, right: 6, child: badge!), if (action != null) Positioned(right: 2, bottom: 2, child: action!)]),
          ),
          const SizedBox(height: 8),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(height: 1.3)),
        ],
      ),
    );
  }
}

int gridColumns(double width) => (width / 132).floor().clamp(3, 8);

SliverGridDelegate novelGridDelegate(double width) =>
    SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: gridColumns(width), mainAxisSpacing: 20, crossAxisSpacing: 14, childAspectRatio: 0.52);

/// 分页的书籍网格：下拉刷新，滑到底自动加载下一页。[fetch] 变化（用 [Key] 区分）时整体重新加载。
class PagedNovelGrid extends ConsumerStatefulWidget {
  const PagedNovelGrid({super.key, required this.fetch, this.sourceHtml, this.hide});

  final Future<PageResult> Function(int page) fetch;

  /// 不显示的书（比如已在书架上的）
  final bool Function(String aid)? hide;

  /// 出错时取解析失败的页面源码（搜索页用）
  final String? Function()? sourceHtml;

  @override
  ConsumerState<PagedNovelGrid> createState() => _PagedNovelGridState();
}

class _PagedNovelGridState extends ConsumerState<PagedNovelGrid> {
  final _items = <NovelCover>[];
  int _page = 0;
  int _maxPage = 1;
  bool _loading = false;
  Object? _error;
  int _autoFill = 0; // 连续自动补页的次数

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!reset && _page >= _maxPage)) return;
    if (reset) _autoFill = 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = reset ? 1 : _page + 1;
      final result = await widget.fetch(next);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(result.items);
        _page = next;
        _maxPage = result.maxPage == 0 ? next : result.maxPage;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      if (_loading) return LayoutBuilder(builder: (context, c) => _GridSkeleton(width: c.maxWidth));
      return RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: _error != null ? StatePanel(title: '加载失败', detail: _error.toString(), error: _error, sourceHtml: widget.sourceHtml?.call(), onRetry: () => _load(reset: true)) : const StatePanel(title: '没有内容'),
      );
    }
    final items = widget.hide == null ? _items : _items.where((e) => !widget.hide!(e.aid)).toList();
    // 滤掉太多、一屏都不满时滑不动，自己接着加载下一页
    // 最多连续补 3 页，再多就等用户滑动或点「加载更多」，避免 429
    if (items.length < 12 && !_loading && _error == null && _page < _maxPage && _autoFill < 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _loading) return;
        _autoFill++;
        _load();
      });
    }
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // 下一页失败后不再自动加载，只能点重试或下拉刷新，避免狂发请求触发 429
    Widget footer() {
      if (_error != null) return TextButton(onPressed: _load, child: const Text('加载失败，点击重试'));
      if (_loading) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      if (_page >= _maxPage) return Center(child: Text('没有更多了', style: hint));
      if (_autoFill >= 3) {
        return TextButton(
          onPressed: () {
            _autoFill = 0;
            _load();
          },
          child: const Text('加载更多'),
        );
      }
      return const SizedBox.shrink();
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_error == null && n.metrics.extentAfter < 600) {
            _autoFill = 0;
            _load();
          }
          return false;
        },
        child: LayoutBuilder(
          builder: (context, c) => CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.8), // 提前排上下面几行的封面
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverGrid.builder(
                  gridDelegate: novelGridDelegate(c.maxWidth),
                  itemCount: items.length,
                  itemBuilder: (context, i) => NovelCard(title: items[i].title, aid: items[i].aid, imageUrl: items[i].imageUrl),
                ),
              ),
              SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: footer())),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首次加载的骨架：12 个封面色块 + 两行灰条。
class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainer;
    Widget bar(double w) => Container(height: 12, width: w, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)));
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: novelGridDelegate(width),
      itemCount: 12,
      itemBuilder: (context, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)), child: const SizedBox.expand())),
          const SizedBox(height: 8),
          bar(double.infinity),
          const SizedBox(height: 6),
          bar(48),
        ],
      ),
    );
  }
}
