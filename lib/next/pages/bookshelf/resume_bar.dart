part of '../bookshelf_page.dart';

/// 书架顶上的「继续阅读」：最近读的一本，点了直接进阅读器（返回回到书架）；关掉后，读到别的书时再出现。
/// 像音乐 App 的"正在播放"：底色取封面的色调，封面、书名、读到的章节，右边一个大的继续按钮。
/// 往下滑书架时以纯 GPU 位移与透明度叠加收起（[hidden]），不改下方 TabBarView 高度避免整屏连续 relayout；设置里可以整个关掉。
class _ResumeBar extends ConsumerWidget {
  const _ResumeBar({required this.hidden, required this.onHeight});

  final ValueListenable<bool> hidden;
  final ValueChanged<double> onHeight;

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.month} 月 ${t.day} 日';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder(
    valueListenable: Hive.box('session').listenable(keys: ['history2', 'resumeClosed']),
    builder: (context, box, _) {
      final h = ReadingHistory.latest(limit: 1).firstOrNull;
      if (h == null || box.get('resumeClosed') == h.aid) {
        onHeight(0);
        return const SizedBox.shrink();
      }
      // 用 Consumer 包一层：_bar 里的 ref.watch 要在一次 build 里执行，换了书（封面变了）旧的订阅才会被清掉
      final card = _MeasureHeight(
        onHeight: onHeight,
        child: RepaintBoundary(child: Consumer(builder: (context, ref, _) => _bar(context, ref, box, h))),
      );
      return ValueListenableBuilder<bool>(
        valueListenable: hidden,
        builder: (context, isHidden, _) => TweenAnimationBuilder<double>(
          tween: Tween<double>(end: isHidden ? 0.0 : 1.0),
          duration: AppMotion.dur(context, AppMotion.standard),
          curve: isHidden ? AppMotion.exit : AppMotion.decelerate,
          child: card,
          builder: (context, t, child) => ClipRect(
            child: IgnorePointer(
              ignoring: isHidden || t < 0.05,
              child: FractionalTranslation(
                translation: Offset(0, -(1 - t)),
                child: Opacity(opacity: Curves.easeIn.transform(t), child: child),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _bar(BuildContext context, WidgetRef ref, Box box, HistoryEntry h) {
    ref.watch(volumeChangeForProvider(h.aid)); // 仅订阅当前书的高清封面变化
    final cover = ref.read(volumeCoverQueueProvider).bookCover(h.aid, h.img);
    final tint = ref.watch(coverColorProvider(cover)).value ?? savedCoverColor(cover) ?? kNeutralCoverColor;
    final theme = Theme.of(context);
    final radius = appPalettes[ref.watch(paletteProvider)].scene ? 6.0 : 16.0;
    void open() => context.push(Routes.reader(h.aid, h.cid));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: AppPressScale(
        scale: 0.98,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: tint),
          duration: AppMotion.dur(context, AppMotion.ambient),
          curve: AppMotion.curve,
          builder: (context, color, child) => Material(
            color: color,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        child: InkWell(
          onTap: open,
          onLongPress: () => context.push(Routes.novel(h.aid)),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 42, 14),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 64,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 3))]),
                      clipBehavior: Clip.antiAlias,
                      child: CoverImage(cover, aid: h.aid, thumbnail: true, decodeSize: const Size(46, 64)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('继续阅读 · ${_ago(h.time)}', style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60, letterSpacing: 0.5)),
                          const SizedBox(height: 2),
                          Text(LibraryStore.shown(h.aid, h.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(h.chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filled(
                      tooltip: hz(context, '继续阅读'),
                      style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87, fixedSize: const Size(44, 44)),
                      icon: const Icon(Icons.play_arrow_rounded, size: 26),
                      onPressed: open,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: hz(context, '关闭'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: Colors.white60,
                  icon: const Icon(Icons.close),
                  onPressed: () => box.put('resumeClosed', h.aid),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

