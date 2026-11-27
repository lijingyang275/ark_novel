import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/common/wenku8_node.dart';
import '../models/novel_cover.dart';
import '../data/wenku8/wenku8_exceptions.dart';
import '../data/wenku8/wenku8_parser.dart';
import 'package:flutter/services.dart';

import 'data.dart' show PageResult;
import 'image_cache.dart';
import 'env.dart';
import 'motion.dart';
import 'routes.dart';
import 'session.dart';
import 'theme_doodle.dart';
import 'text.dart';
import 'volume_covers.dart';

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
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 48), padding: const EdgeInsets.symmetric(horizontal: 24)),
              onPressed: () => context.push(Routes.login),
              child: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 错误 / 空状态。出错时给"重试"，没登录时额外给"去登录"。可滚动，保证下拉刷新可用。
class StatePanel extends ConsumerWidget {
  const StatePanel({
    super.key,
    required this.title,
    this.detail,
    this.onRetry,
    this.error,
    this.sourceHtml,
    this.icon,
    this.actions = const [],
    this.showEmptyArt = true,
  });

  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  /// 出错的原始异常：被 Cloudflare 拦住时给"去验证"入口
  final Object? error;

  /// 解析失败的页面源码（搜索用），给"复制页面源码"按钮
  final String? sourceHtml;

  /// 普通配色空状态的可选图标（角色主题优先展示 `art.empty` 插画）
  final IconData? icon;

  /// 底部附加操作按钮（如书架空态的「登录」「去发现页」）
  final List<Widget> actions;

  /// 空状态时是否展示角色主题插画 `art.empty`
  final bool showEmptyArt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (error is Wenku8LoginRequiredException) {
      return LoginPrompt(title: title == '加载失败' ? '此功能需要登录' : title, detail: (error as Wenku8LoginRequiredException).message);
    }
    final theme = Theme.of(context);
    final guest = ref.watch(sessionProvider.select((s) => s is! SessionLoggedIn));
    final art = CharacterArt.of(context);
    final isError = error != null || onRetry != null;
    final shownDetail = error != null ? friendlyError(error!) : detail;
    final canSwitchNode = error != null && !isCloudflare(error!) && !isWebPreview && ref.watch(nodeProvider) == Wenku8Node.wwwWenku8Net;
    final artCacheHeight = (140 * MediaQuery.devicePixelRatioOf(context)).round();
    return Semantics(
      container: true,
      liveRegion: error != null,
      child: ListView(
        padding: const EdgeInsets.all(32),
        children: [
          if (art != null && (isError || showEmptyArt))
            // 角色主题：出错时抱头慌张，没内容时托腮发呆
            Padding(
              padding: const EdgeInsets.only(top: 24, bottom: 12),
              child: Image.asset(isError ? art.error : art.empty, height: 140, cacheWidth: artCacheHeight, cacheHeight: artCacheHeight, excludeFromSemantics: true),
            )
          else if (icon != null) ...[
            const SizedBox(height: 64),
            ExcludeSemantics(child: Icon(icon, size: 48, color: theme.colorScheme.primary.withValues(alpha: 0.75))),
            const SizedBox(height: 16),
          ] else
            const SizedBox(height: 80),
          Semantics(header: true, child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge)),
          if (shownDetail != null && shownDetail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              shownDetail,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 24),
            Center(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(140, 44), padding: const EdgeInsets.symmetric(horizontal: 24)),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ),
          ],
          if (error != null && isCloudflare(error!))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(160, 44), padding: const EdgeInsets.symmetric(horizontal: 24)),
                  onPressed: () async {
                    final ok = await context.push<bool>(Routes.verify);
                    if (ok == true && context.mounted) onRetry?.call();
                  },
                  child: const Text('去验证'),
                ),
              ),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 10, children: actions),
          ],
          if (canSwitchNode)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: TextButton(
                  onPressed: () async {
                    await ref.read(nodeProvider.notifier).set(Wenku8Node.wwwWenku8Cc);
                    onRetry?.call();
                  },
                  child: const Text('连不上？切到备用节点 wenku8.cc'),
                ),
              ),
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
      ),
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

/// 按图片地址细粒度订阅超分版本号；若测试桩仅实现了旧 `srVersion` 未实现 `srNotifierFor`，自动回退避免破坏旧桩。
final _urlSrVersionProvider = Provider.autoDispose.family<int, String>((ref, url) {
  try {
    return ref.watch(srVersionForProvider(url));
  } on Object {
    return ref.watch(srVersionProvider);
  }
});

bool _shouldWatchSr(String url) => ImageStore.srSupported && (ImageStore.srAutoEnabled || wantsSr(url));

Uint8List? _peekThumbSafe(ImageStore store, String url) {
  try {
    return store.peekThumb(url);
  } on Object {
    return store.peek(url);
  }
}

Future<Uint8List> _loadThumbSafe(ImageStore store, String url, {required bool lowPriority}) {
  try {
    return store.loadThumb(url, lowPriority: lowPriority);
  } on Object {
    return store.load(url);
  }
}

Future<Uint8List> _loadLowSafe(ImageStore store, String url) {
  try {
    return store.loadWithPriority(url, lowPriority: true);
  } on Object {
    return store.load(url);
  }
}

void _cancelThumbSafe(ImageStore store, String url) {
  try {
    store.cancelThumb(url);
  } on Object {
    store.cancel(url);
  }
}

bool _isThumbBakedSafe(ImageStore store, String url) {
  try {
    return store.isThumbBaked(url);
  } on Object {
    return false;
  }
}

bool _wasFromNetworkSafe(ImageStore store, String url) {
  try {
    return store.wasLoadedFromNetwork(url);
  } on Object {
    return false;
  }
}

int _srVersionNow(ImageStore store, String url) {
  if (!_shouldWatchSr(url)) return 0;
  try {
    return store.srNotifierFor(url).value;
  } on Object {
    return store.srVersion.value;
  }
}

/// 保留给已有外部引用方兼容；[NetImage] 自身改为直接走异步 [_Fitted] ImageProvider，不在 Riverpod 中钉死压缩字节。
final imageBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, url) {
  if (_shouldWatchSr(url)) ref.watch(_urlSrVersionProvider(url)); // 仅超分适用图订阅超分版本号，非超分图零额外 Riverpod 订阅
  final store = ref.read(imageStoreProvider);
  ref.onDispose(() => store.cancel(url)); // 没人看了（滑出屏幕），还在排队的就别下了
  return store.load(url);
}, retry: (_, _) => null);

/// 追踪各 `(store, cacheKeyUrl)` 的活跃 [NetImage] 挂载数与在途网络请求，
/// 当最后一个活跃控件在加载完成前卸载时立即取消底层请求并从 [ImageCache] 移除 pending 条目。
class _NetImageTracker {
  static final _activeCount = <(ImageStore, String), int>{};
  static final _pendingCancel = <(ImageStore, String), (Object key, VoidCallback cancel)>{};

  static void mount(ImageStore store, String cacheKeyUrl) {
    final k = (store, cacheKeyUrl);
    _activeCount[k] = (_activeCount[k] ?? 0) + 1;
  }

  static void unmount(ImageStore store, String cacheKeyUrl) {
    final k = (store, cacheKeyUrl);
    final left = (_activeCount[k] ?? 0) - 1;
    if (left > 0) {
      _activeCount[k] = left;
      return;
    }
    _activeCount.remove(k);
    final pending = _pendingCancel.remove(k);
    if (pending != null) {
      pending.$2();
      PaintingBinding.instance.imageCache.evict(pending.$1);
    }
  }

  static void registerPending(ImageStore store, String cacheKeyUrl, Object imageKey, VoidCallback cancel) {
    _pendingCancel[(store, cacheKeyUrl)] = (imageKey, cancel);
  }

  static void finishPending(ImageStore store, String cacheKeyUrl, Object imageKey) {
    final k = (store, cacheKeyUrl);
    if (identical(_pendingCancel[k]?.$1, imageKey)) {
      _pendingCancel.remove(k);
    }
  }
}

class NetImage extends ConsumerStatefulWidget {
  const NetImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.loading,
    this.error,
    this.errorBuilder,
    this.full = false,
    this.maxDecodeWidth,
    this.thumbnail = false,
    this.lowPriority = false,
    this.decodeSize,
  });

  final String url;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Widget? loading;
  final Widget? error;
  final Widget Function(VoidCallback retry)? errorBuilder;

  /// 按高清大图模式解码（能放大看的地方用）；统一走 [_Fitted] 并受 2048/2560 解码宽度上限约束，不再走裸 MemoryImage
  final bool full;

  /// 可选解码宽度上限（物理像素，如卷册后置露出边 120px 降低内存峰值）
  final int? maxDecodeWidth;

  /// 是否使用书架级磁盘缩略图（烘焙裁剪框，避免反复解码原图和二次裁剪）
  final bool thumbnail;

  /// 是否排入低优先级网络队列（如后置露边封面，避免抢占主封面带宽）
  final bool lowPriority;

  /// 已知的逻辑展示尺寸：传入后直接算解码档位，省掉图片内部的 [LayoutBuilder]
  final Size? decodeSize;

  @override
  ConsumerState<NetImage> createState() => _NetImageState();

  /// 提前下载，并按 [size]（逻辑像素，图片要放进的格子）解码进图片缓存：之后同样大小的 NetImage 直接出图。
  /// 翻页时下一页才建出来，大插图解码要一两百毫秒，不提前做就会先空一下。
  /// [decode] 为 false 时只下载（存进本机），不解码。
  static Future<void> precache(
    BuildContext context,
    String url,
    Size size, {
    BoxFit fit = BoxFit.cover,
    bool decode = true,
    bool thumbnail = false,
    bool lowPriority = false,
    int? maxDecodeWidth,
  }) async {
    if (url.isEmpty || isWebPreview) return;
    final store = ProviderScope.containerOf(context, listen: false).read(imageStoreProvider);
    try {
      if (thumbnail) {
        await _loadThumbSafe(store, url, lowPriority: lowPriority);
      } else if (lowPriority) {
        await _loadLowSafe(store, url);
      } else {
        await store.load(url);
      }
    } catch (_) {
      return; // 下不下来就等真正显示时再说
    }
    if (!decode || !context.mounted) return;
    final baked = thumbnail && _isThumbBakedSafe(store, url);
    final crop = baked ? null : splitCrop(url).crop;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final box = Size(_bucket(size.width * dpr / (crop?.width ?? 1)), _bucket(size.height * dpr / (crop?.height ?? 1)));
    final srVer = _srVersionNow(store, url);
    await precacheImage(
      _Fitted(
        store,
        url,
        thumbnail ? '$url#thumb' : url,
        srVer,
        0,
        box,
        fit == BoxFit.cover,
        maxDecodeWidth: maxDecodeWidth,
        thumbnail: thumbnail,
        lowPriority: lowPriority,
      ),
      context,
      onError: (_, _) {},
    );
  }

  /// 往上取到几个固定档位（每档大 25%）：格子大小一直在变时（比如封面飞过去的动画）不用每帧都重新解码
  static double _bucket(double px) =>
      const <double>[128, 160, 200, 256, 320, 400, 512, 640, 800, 1024, 1280, 1600, 2048, 2560, 3200].firstWhere((b) => b >= px, orElse: () => double.infinity);
}

class _NetImageState extends ConsumerState<NetImage> {
  int _attempt = 0;
  bool _fade = false;
  bool _bytesReady = false;
  late bool _baked;
  ImageStore? _trackedStore;
  String? _trackedKey;

  String get _cacheKeyUrl => widget.thumbnail ? '${widget.url}#thumb' : widget.url;

  bool _hasSyncBytes(ImageStore store) {
    if (widget.url.isEmpty) return false;
    final hit = widget.thumbnail ? _peekThumbSafe(store, widget.url) : store.peek(widget.url);
    if (hit != null) return true;
    if (!widget.thumbnail && !widget.lowPriority && ref.exists(imageBytesProvider(widget.url))) {
      return ref.read(imageBytesProvider(widget.url)).hasValue;
    }
    return false;
  }

  void _syncTracking() {
    final nextStore = (widget.url.isEmpty || isWebPreview) ? null : ref.read(imageStoreProvider);
    final nextKey = nextStore == null ? null : _cacheKeyUrl;
    if (identical(_trackedStore, nextStore) && _trackedKey == nextKey) return;
    if (_trackedStore != null && _trackedKey != null) {
      _NetImageTracker.unmount(_trackedStore!, _trackedKey!);
    }
    _trackedStore = nextStore;
    _trackedKey = nextKey;
    if (nextStore != null && nextKey != null) {
      _NetImageTracker.mount(nextStore, nextKey);
    }
  }

  @override
  void initState() {
    super.initState();
    final store = (widget.url.isEmpty || isWebPreview) ? null : ref.read(imageStoreProvider);
    _baked = store != null && widget.thumbnail && _isThumbBakedSafe(store, widget.url);
    _bytesReady = store != null && _hasSyncBytes(store);
    _syncTracking();
  }

  @override
  void didUpdateWidget(NetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.thumbnail != widget.thumbnail) {
      _attempt = 0;
      _fade = false;
      final store = (widget.url.isEmpty || isWebPreview) ? null : ref.read(imageStoreProvider);
      _baked = store != null && widget.thumbnail && _isThumbBakedSafe(store, widget.url);
      _bytesReady = store != null && _hasSyncBytes(store);
      _syncTracking();
    }
  }

  @override
  void dispose() {
    if (_trackedStore != null && _trackedKey != null) {
      _NetImageTracker.unmount(_trackedStore!, _trackedKey!);
      _trackedStore = null;
      _trackedKey = null;
    }
    super.dispose();
  }

  void _retry() {
    if (!mounted) return;
    if (widget.url.isNotEmpty && !widget.thumbnail && !widget.lowPriority && ref.exists(imageBytesProvider(widget.url))) {
      ref.invalidate(imageBytesProvider(widget.url));
    }
    setState(() {
      _fade = false;
      _bytesReady = false;
      _attempt++;
    });
  }

  void _onBytesReady(bool fromNetwork, bool baked) {
    _fade = fromNetwork;
    if (mounted && (!_bytesReady || _baked != baked)) {
      setState(() {
        _bytesReady = true;
        _baked = baked;
      });
    }
  }

  /// 若已有外部调用方（如阅读页插图或仅 override `imageBytesProvider` 的单测）创建了 `imageBytesProvider(url)`，
  /// 直接复用该 Future 而不重复调用 `ImageStore.load`；全 App 其他场景 `ref.exists` 为 false，完全零 Riverpod 字节驻留。
  Future<Uint8List>? _existingProviderFuture() {
    if (widget.thumbnail || widget.lowPriority || !ref.exists(imageBytesProvider(widget.url))) return null;
    try {
      return ref.read(imageBytesProvider(widget.url).future);
    } catch (e, st) {
      return Future<Uint8List>.error(e, st);
    }
  }

  /// 只显示图片里裁剪框那一块，再按 [fit] 填进格子
  Widget _cropped(Widget img, Rect? c) {
    if (c == null) return img;
    double align(double start, double size) => size >= 1 ? 0 : start / (1 - size) * 2 - 1;
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: ClipRect(child: Align(alignment: Alignment(align(c.left, c.width), align(c.top, c.height)), widthFactor: c.width, heightFactor: c.height, child: img)),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => widget.errorBuilder?.call(_retry) ?? widget.error ?? const SizedBox.shrink();
    if (widget.url.isEmpty) return fallback();
    final crop = splitCrop(widget.url).crop;
    if (isWebPreview) {
      return _cropped(
        Image.network(displayImageUrl(splitCrop(widget.url).url), fit: widget.fit, alignment: widget.alignment, errorBuilder: (_, _, _) => fallback()),
        crop,
      );
    }
    final store = ref.read(imageStoreProvider);
    _syncTracking();
    final srVer = _shouldWatchSr(widget.url) ? ref.watch(_urlSrVersionProvider(widget.url)) : 0;
    final effectiveCrop = (widget.thumbnail && _baked) ? null : crop;
    final cacheKeyUrl = _cacheKeyUrl;
    final effectiveMaxDecodeWidth = widget.maxDecodeWidth ?? (widget.full ? (isDesktop ? 2560 : 2048) : null);
    final existingFuture = _existingProviderFuture();

    Widget buildForBox(Size box) {
      final provider = _Fitted(
        store,
        widget.url,
        cacheKeyUrl,
        srVer,
        _attempt,
        box,
        widget.fit == BoxFit.cover,
        maxDecodeWidth: effectiveMaxDecodeWidth,
        thumbnail: widget.thumbnail,
        lowPriority: widget.lowPriority,
        existingFuture: existingFuture,
        onBytesReady: _onBytesReady,
      );
      return _cropped(
        Image(
          // 仅在点击重试（_attempt 变化）时重置 _ImageState 清除旧 _lastException；SR 版本升级保持同 key 实现 gaplessPlayback
          key: ValueKey(_attempt),
          image: provider,
          fit: widget.fit,
          alignment: widget.alignment,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame == null) {
              return _bytesReady ? const SizedBox.shrink() : (widget.loading ?? const SizedBox.shrink());
            }
            if (wasSynchronouslyLoaded || !_fade || AppMotion.reduce(context)) return child;
            return _FadeInMount(key: ValueKey((widget.url, _attempt)), child: child);
          },
          errorBuilder: (_, _, _) => fallback(),
        ),
        effectiveCrop,
      );
    }

    if (widget.full) return buildForBox(Size.infinite);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget fitFor(Size s) {
      // 缩略图已烘焙裁剪框时不再除以 crop.width 放大解码宽度
      final box = Size(
        NetImage._bucket(s.width * dpr / (effectiveCrop?.width ?? 1)),
        NetImage._bucket(s.height * dpr / (effectiveCrop?.height ?? 1)),
      );
      return buildForBox(box);
    }

    if (widget.decodeSize != null) return fitFor(widget.decodeSize!);
    return LayoutBuilder(builder: (context, c) => fitFor(Size(c.maxWidth, c.maxHeight)));
  }
}

/// 按格子大小解码。高清封面原图 1440×2048，原样解码一张占 12 MB，Flutter 的图片缓存装不下一屏书架，滑回来又得重新解码。
/// 缓存键仅保留 store 标识、地址、超分版本、重试计数与目标尺寸，绝不持有 [Uint8List] 或 [ImageStore] 引用。
@immutable
class _FittedKey {
  const _FittedKey(this.storeId, this.url, this.srVersion, this.attempt, this.box, this.cover, this.maxDecodeWidth);

  final int storeId;
  final String url;
  final int srVersion;
  final int attempt;
  final Size box;
  final bool cover;
  final int? maxDecodeWidth;

  @override
  bool operator ==(Object other) =>
      other is _FittedKey &&
      other.storeId == storeId &&
      other.url == url &&
      other.srVersion == srVersion &&
      other.attempt == attempt &&
      other.box == box &&
      other.cover == cover &&
      other.maxDecodeWidth == maxDecodeWidth;

  @override
  int get hashCode => Object.hash(storeId, url, srVersion, attempt, box, cover, maxDecodeWidth);
}

@immutable
class _Fitted extends ImageProvider<_FittedKey> {
  const _Fitted(
    this.store,
    this.rawUrl,
    this.cacheKeyUrl,
    this.srVersion,
    this.attempt,
    this.box,
    this.cover, {
    this.maxDecodeWidth,
    this.thumbnail = false,
    this.lowPriority = false,
    this.existingFuture,
    this.onBytesReady,
  });

  final ImageStore store;
  final String rawUrl;
  final String cacheKeyUrl;
  final int srVersion;
  final int attempt;
  final Size box; // 物理像素；无限表示这个方向不限
  final bool cover; // 铺满格子（取两边缩放比里大的那个），否则整张放进格子
  final int? maxDecodeWidth;
  final bool thumbnail;
  final bool lowPriority;
  final Future<Uint8List>? existingFuture;
  final void Function(bool fromNetwork, bool baked)? onBytesReady;

  @override
  Future<_FittedKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(_FittedKey(identityHashCode(store), cacheKeyUrl, srVersion, attempt, box, cover, maxDecodeWidth));

  @override
  ImageStreamCompleter loadImage(_FittedKey key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(key, decode), scale: 1);

  Future<ui.Codec> _codec(_FittedKey key, ImageDecoderCallback decode) async {
    try {
      Uint8List? bytes = thumbnail ? _peekThumbSafe(store, rawUrl) : store.peek(rawUrl);
      var fromNetwork = false;
      if (bytes == null) {
        final external = existingFuture;
        if (external != null) {
          bytes = await external;
          fromNetwork = _wasFromNetworkSafe(store, rawUrl);
        } else {
          _NetImageTracker.registerPending(
            store,
            cacheKeyUrl,
            key,
            () => thumbnail ? _cancelThumbSafe(store, rawUrl) : store.cancel(rawUrl),
          );
          try {
            bytes = await (thumbnail
                ? _loadThumbSafe(store, rawUrl, lowPriority: lowPriority)
                : (lowPriority ? _loadLowSafe(store, rawUrl) : store.load(rawUrl)));
            fromNetwork = _wasFromNetworkSafe(store, rawUrl);
          } finally {
            _NetImageTracker.finishPending(store, cacheKeyUrl, key);
          }
        }
      }
      onBytesReady?.call(fromNetwork, thumbnail && _isThumbBakedSafe(store, rawUrl));
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      bytes = null; // 提交原生缓冲后立即丢弃局部 Uint8List 引用
      final targetBox = box;
      final isCover = cover;
      final maxW = maxDecodeWidth;
      final codec = await decode(
        buffer,
        getTargetSize: (w, h) {
          final sx = targetBox.width / w, sy = targetBox.height / h;
          var s = sx.isInfinite ? sy : (sy.isInfinite ? sx : (isCover ? math.max(sx, sy) : math.min(sx, sy)));
          if (maxW != null && w > maxW) {
            s = math.min(s, maxW / w);
          }
          return s >= 1 ? const ui.TargetImageSize() : ui.TargetImageSize(width: math.max(1, (w * s).ceil()));
        },
      );
      CoverImage.clearFailed(rawUrl);
      return codec;
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _Fitted &&
      identical(other.store, store) &&
      other.cacheKeyUrl == cacheKeyUrl &&
      other.srVersion == srVersion &&
      other.attempt == attempt &&
      other.box == box &&
      other.cover == cover &&
      other.maxDecodeWidth == maxDecodeWidth &&
      other.thumbnail == thumbnail &&
      other.lowPriority == lowPriority;

  @override
  int get hashCode => Object.hash(identityHashCode(store), cacheKeyUrl, srVersion, attempt, box, cover, maxDecodeWidth, thumbnail, lowPriority);
}

/// 网络刚下载完成的图片首次出帧时做轻量 GPU 透明度淡入（0 → 1），磁盘/内存命中直接跳过。
class _FadeInMount extends StatefulWidget {
  const _FadeInMount({super.key, required this.child});

  final Widget child;

  @override
  State<_FadeInMount> createState() => _FadeInMountState();
}

class _FadeInMountState extends State<_FadeInMount> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.fast);
  late final CurvedAnimation _opacity = CurvedAnimation(parent: _controller, curve: AppMotion.decelerate);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _opacity, child: widget.child);
}

class CoverImage extends ConsumerWidget {
  const CoverImage(
    this.url, {
    super.key,
    this.aid,
    this.volumeTitle,
    this.maxDecodeWidth,
    this.thumbnail = false,
    this.lowPriority = false,
    this.decodeSize,
    this.borderRadius = 10,
    this.backgroundColor,
  });

  final String url;
  final String? aid;
  final String? volumeTitle;
  final int? maxDecodeWidth;
  final bool thumbnail;
  final bool lowPriority;
  final Size? decodeSize;
  final double borderRadius;
  final Color? backgroundColor;

  /// 封面加载失败的短 TTL 记录（30s）：首次偶发失败先轻量重试，避免瞬态抖动直接整轮拉黑。
  static const failedUrlTtl = Duration(seconds: 30);
  static final _failedUrls = <String, DateTime>{};

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static void _pruneFailed(DateTime now) {
    _failedUrls.removeWhere((_, at) => now.difference(at) >= failedUrlTtl);
  }

  /// 手动重试或刷新时清除失败记录（传入 [url] 仅清该图，留空全清）。
  static void clearFailed([String? url]) {
    if (url == null) {
      _failedUrls.clear();
    } else {
      _failedUrls.remove(splitCrop(url).url);
    }
  }

  @visibleForTesting
  static bool isMarkedFailed(String url) {
    final now = clock();
    _pruneFailed(now);
    return _failedUrls.containsKey(splitCrop(url).url);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final active = TickerMode.valuesOf(context).enabled;
    final icon = Icon(Icons.menu_book_outlined, color: scheme.onSurfaceVariant);
    final content = DecoratedBox(
      decoration: BoxDecoration(color: backgroundColor ?? scheme.surfaceContainer),
      child: active
          ? SizedBox.expand(
              child: NetImage(
                url,
                maxDecodeWidth: maxDecodeWidth,
                thumbnail: thumbnail,
                lowPriority: lowPriority,
                decodeSize: decodeSize,
                error: icon,
                errorBuilder: (retry) {
                  final clean = splitCrop(url).url;
                  if (clean.isEmpty) return icon;
                  final now = clock();
                  _pruneFailed(now);
                  if (!_failedUrls.containsKey(clean)) {
                    _failedUrls[clean] = now;
                    Future.microtask(() {
                      if (!context.mounted) return;
                      retry();
                    });
                  } else if (aid != null && context.mounted) {
                    final queue = ref.read(volumeCoverQueueProvider);
                    final bookAid = aid!;
                    final bookUrl = url;
                    final bookVol = volumeTitle;
                    Future.microtask(() {
                      if (!context.mounted) return;
                      queue.reportCoverFailed(bookAid, bookUrl, volumeTitle: bookVol);
                    });
                  }
                  return icon;
                },
              ),
            )
          : const SizedBox.expand(),
    );
    if (borderRadius <= 0) return content;
    return ClipRRect(borderRadius: BorderRadius.circular(borderRadius), child: content);
  }
}

/// 封面 + 书名，点击进入详情。
class NovelCard extends StatelessWidget {
  const NovelCard({super.key, required this.title, required this.aid, this.imageUrl, this.onTap, this.badge, this.action, this.thumbnail = true, this.decodeSize, this.cover});

  final String title;
  final String aid;
  final String? imageUrl;
  final VoidCallback? onTap;
  final Widget? badge;

  /// 封面右下角的按钮（书架的"继续阅读"）
  final Widget? action;

  /// 网格小封面默认走磁盘缩略图，避免快滑时解码大图卡顿
  final bool thumbnail;
  final Size? decodeSize;

  /// 可选自定义封面组件（如书架按 aid 细粒度订阅封面变更）
  final Widget? cover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: title,
      button: true,
      child: AppPressScale(
        scale: 0.968,
        hoverScale: isDesktop ? 1.014 : 1.0,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap ?? () => context.push(Routes.novel(aid)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover ?? CoverImage(imageUrl ?? Wenku8Parser.coverUrl(aid), aid: aid, thumbnail: thumbnail, decodeSize: decodeSize),
                    if (badge != null) Positioned(top: 6, right: 6, child: badge!),
                    if (action != null) Positioned(right: 2, bottom: 2, child: action!),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }
}

int gridColumns(double width) => (width / 132).floor().clamp(3, 8);

SliverGridDelegate novelGridDelegate(double width, {int? columns, double textScale = 1.0, double horizontalPadding = 32}) {
  final cols = columns ?? gridColumns(width);
  final scale = textScale.clamp(1.0, 1.6);
  final itemW = math.max(1.0, (width - horizontalPadding - 14 * (cols - 1)) / cols);
  final mainExtent = itemW * 4 / 3 + 8 + 42 * scale;
  return SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 20, crossAxisSpacing: 14, mainAxisExtent: mainExtent);
}

/// 分页的书籍网格：下拉刷新，滑到底自动加载下一页。[fetch] 变化（用 [Key] 区分）时整体重新加载。
class PagedNovelGrid extends ConsumerStatefulWidget {
  const PagedNovelGrid({super.key, this.fetch, this.fetchWithCancel, this.onRefresh, this.sourceHtml, this.hide, this.emptyTitle = '没有内容', this.emptyDetail})
    : assert(fetch != null || fetchWithCancel != null);

  final Future<PageResult> Function(int page)? fetch;

  /// 可选支持取消令牌的分页抓取函数：在下拉刷新或卸载时自动中止在途请求。
  final Future<PageResult> Function(int page, CancelToken cancelToken)? fetchWithCancel;

  /// 下拉刷新或手动重试前触发（例如清掉列表短期内存缓存以强制回源）。
  final VoidCallback? onRefresh;

  /// 不显示的书（比如已在书架上的）
  final bool Function(String aid)? hide;

  /// 出错时取解析失败的页面源码（搜索页用）
  final String? Function()? sourceHtml;

  final String emptyTitle;
  final String? emptyDetail;

  @override
  ConsumerState<PagedNovelGrid> createState() => _PagedNovelGridState();
}

class _PagedNovelGridState extends ConsumerState<PagedNovelGrid> {
  final _items = <NovelCover>[];
  List<NovelCover> _visibleItems = const [];
  int _page = 0;
  int _maxPage = 1;
  bool _loading = false;
  Object? _error;
  int _autoFill = 0; // 连续自动补页的次数
  int _loadSeq = 0;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(PagedNovelGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hide != oldWidget.hide) {
      _rebuildVisible();
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('disposed');
    _cancelToken = null;
    super.dispose();
  }

  void _rebuildVisible() {
    final hide = widget.hide;
    _visibleItems = hide == null ? _items : _items.where((e) => !hide(e.aid)).toList(growable: false);
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || _page >= _maxPage)) return;
    final seq = ++_loadSeq;
    _cancelToken?.cancel('superseded');
    final token = _cancelToken = CancelToken();
    if (reset) _autoFill = 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = reset ? 1 : _page + 1;
      final result = await (widget.fetchWithCancel != null ? widget.fetchWithCancel!(next, token) : widget.fetch!(next));
      if (!mounted || seq != _loadSeq || token.isCancelled) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(result.items);
        _rebuildVisible();
        _page = next;
        _maxPage = result.maxPage == 0 ? next : result.maxPage;
        _error = null;
      });
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      if (mounted && seq == _loadSeq && !token.isCancelled) setState(() => _error = e);
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() {
    widget.onRefresh?.call();
    return _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (_items.isEmpty) {
      if (_loading) {
        content = LayoutBuilder(key: const ValueKey('grid-loading'), builder: (context, c) => _GridSkeleton(width: c.maxWidth));
      } else {
        content = RefreshIndicator(
          key: ValueKey(_error != null ? 'grid-error' : 'grid-empty'),
          onRefresh: _refresh,
          child: _error != null
              ? StatePanel(title: '加载失败', detail: _error.toString(), error: _error, sourceHtml: widget.sourceHtml?.call(), onRetry: _refresh)
              : StatePanel(title: widget.emptyTitle, detail: widget.emptyDetail),
        );
      }
      return AppCrossfade(fill: true, duration: AppMotion.fast, child: content);
    }
    final items = _visibleItems;
    // 滤掉太多、一屏都不满时滑不动，自己接着加载下一页
    // 最多连续补 3 页，再多就等用户滑动或点「加载更多」，避免 429
    if (items.length < 12 && !_loading && _error == null && _page < _maxPage && _autoFill < 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _loading) return;
        _autoFill++;
        _load();
      });
    }
    if (items.isEmpty && !_loading && _error == null && _page >= _maxPage) {
      return AppCrossfade(
        fill: true,
        duration: AppMotion.fast,
        child: RefreshIndicator(
          key: const ValueKey('grid-all-hidden'),
          onRefresh: _refresh,
          child: const StatePanel(title: '结果都在书架里了', detail: '可点右上角筛选按钮取消「隐藏书架里的书」。'),
        ),
      );
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

    content = RefreshIndicator(
      key: const ValueKey('grid-data'),
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_error == null && n.metrics.extentAfter < 600) {
            _autoFill = 0;
            _load();
          }
          return false;
        },
        child: LayoutBuilder(
          builder: (context, c) {
            final cols = gridColumns(c.maxWidth);
            final itemW = math.max(1.0, (c.maxWidth - 32 - 14 * (cols - 1)) / cols);
            final coverSize = Size(itemW, itemW * 4 / 3);
            return CustomScrollView(
              key: widget.key != null ? PageStorageKey<Key>(widget.key!) : null,
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.4), // 适量提前准备上下邻近封面，控制活跃解码纹理数
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverGrid.builder(
                    gridDelegate: novelGridDelegate(c.maxWidth, columns: cols, textScale: MediaQuery.textScalerOf(context).scale(1)),
                    itemCount: items.length,
                    itemBuilder: (context, i) => NovelCard(title: items[i].title, aid: items[i].aid, imageUrl: items[i].imageUrl, decodeSize: coverSize),
                  ),
                ),
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: footer())),
              ],
            );
          },
        ),
      ),
    );
    return AppCrossfade(fill: true, duration: AppMotion.fast, child: content);
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
    return AppSkeletonPulse(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: novelGridDelegate(width, textScale: MediaQuery.textScalerOf(context).scale(1)),
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
      ),
    );
  }
}
