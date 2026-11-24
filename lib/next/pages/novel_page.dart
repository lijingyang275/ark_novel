import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../app_prefs.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../chapter_list.dart';
import '../data.dart';
import '../env.dart';
import '../export_book.dart';
import '../image_cache.dart';
import '../library.dart';
import '../local_books.dart';
import '../stats.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Vol, Volumes, volumeChangeForProvider;
import 'book_search_sheet.dart';
import 'categories_page.dart';
import 'cover_picker_page.dart';
import '../progress.dart';
import '../read_state.dart';
import '../routes.dart';
import '../swipe.dart';
import '../session.dart';
import '../updates.dart';
import '../widgets.dart';
import '../widgets_bgm.dart';
import '../text.dart';

/// 详情与目录本地缓存的短保鲜时间（45s）：刚刷新或书架预取后直接复用，避免短时间内重复拉取 2 次网络请求。
const novelCacheTtl = Duration(seconds: 45);

@visibleForTesting
bool isNovelCacheFresh(String base, String aid, {Duration ttl = novelCacheTtl, DateTime? now}) {
  if (!Hive.isBoxOpen('chapter_index')) return false;
  final box = Hive.box('chapter_index');
  final dTs = (box.get('pt|$base/modules/article/articleinfo.php?id=$aid') as int?) ?? 0;
  final cTs = (box.get('pt|$base/modules/article/reader.php?aid=$aid') as int?) ?? 0;
  if (dTs <= 0 || cTs <= 0) return false;
  final oldest = math.min(dTs, cTs);
  final elapsed = (now ?? DateTime.now()).millisecondsSinceEpoch - oldest;
  return elapsed >= 0 && elapsed < ttl.inMilliseconds;
}

/// 详情 + 目录：存过的先给（不等网络，挂 VPN 时也秒开），缓存过期后再联网取最新的；联网失败而本地有就不报错。
final novelProvider = StreamProvider.autoDispose.family<NovelPage, String>((ref, aid) async* {
  if (isLocalAid(aid)) {
    yield await LocalBooks.loadNovel(aid);
    return;
  }
  final api = ref.watch(apiProvider);
  final base = siteBase(ref.watch(nodeProvider));
  final saved = await api.saved(aid);
  if (saved != null) {
    await Volumes.saveCatalogue(aid, saved.catalogue);
    await UpdateStore.noteKnownCount(aid, saved.catalogue.expand((v) => v.chapters).length);
    yield saved;
    if (isNovelCacheFresh(base, aid)) return;
  }
  try {
    final fresh = await api.novel(aid);
    final d = fresh.detail;
    // 请求期间退出了详情页：这个 provider 已经销毁，不能再用 ref（书架那边的书名、封面等下次再记）
    if (ref.mounted) ref.read(libraryProvider.notifier).noteDetail(aid, title: d.title, img: d.imgUrl, status: d.status);
    await Volumes.saveCatalogue(aid, fresh.catalogue);
    await UpdateStore.noteKnownCount(aid, fresh.catalogue.expand((v) => v.chapters).length);
    // 读过的书补记书名（离线时读的统计里没有书名，会显示成"书号"）
    if (ReadingStats.perBook().containsKey(aid)) await ReadingStats.setMeta(aid, d.title, d.author, d.imgUrl);
    yield fresh;
  } catch (_) {
    if (saved == null) rethrow;
  }
});

class NovelPageView extends ConsumerWidget {
  const NovelPageView({super.key, required this.aid});

  final String aid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final novel = ref.watch(novelProvider(aid));
    return novel.when(
      loading: () => Scaffold(appBar: AppBar(), body: const _NovelSkeleton()),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: StatePanel(title: '加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(novelProvider(aid))),
      ),
      data: (data) => _Body(aid: aid, data: data),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.aid, required this.data});

  final String aid;
  final NovelPage data;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _introOpen = false;
  bool _voting = false;
  final _picked = <String>{}; // 目录里多选的章节
  final _expanded = <String>{}; // 展开中的卷标题
  final _scroll = ScrollController();
  final _showTitle = ValueNotifier<bool>(false);
  final _focus = FocusNode(debugLabel: 'novel-catalogue');
  late ChapterListOptions _chl = ChapterListOptions.of(widget.aid);
  Map<String, int> _indexOf = const {};

  String get aid => widget.aid;
  NovelPage get data => widget.data;
  late final VolumeCoverQueue _covers; // dispose 里不能再用 ref，先取好

  void _rebuildIndex() {
    _indexOf = {for (final (i, c) in data.catalogue.expand((v) => v.chapters).indexed) c.cid: i + 1};
  }

  void _initExpanded() {
    if (_expanded.isNotEmpty || data.catalogue.isEmpty) return;
    final progressCid = ReadingProgress.of(aid)?.cid;
    if (data.catalogue.length == 1) {
      _expanded.add(data.catalogue.first.title);
      return;
    }
    for (final v in data.catalogue) {
      if (v.chapters.any((c) => c.cid == progressCid || _picked.contains(c.cid))) {
        _expanded.add(v.title);
      }
    }
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 120;
    if (_showTitle.value != show) _showTitle.value = show;
  }

  @override
  void initState() {
    super.initState();
    _covers = ref.read(volumeCoverQueueProvider);
    _rebuildIndex();
    _initExpanded();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(_Body old) {
    super.didUpdateWidget(old);
    if (old.aid != widget.aid) {
      _chl = ChapterListOptions.of(widget.aid);
      _expanded.clear();
      _picked.clear();
    }
    if (old.data != widget.data || old.aid != widget.aid) {
      _rebuildIndex();
      _initExpanded();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _showTitle.dispose();
    _focus.dispose();
    // 没加入书架的书（从发现页等处点开看看的）：退出时清掉为它挑封面下载的图
    if (!LibraryStore.contains(aid)) _covers.forget(aid);
    super.dispose();
  }

  /// 打开别的页面，回来时刷新（阅读进度、已读状态会变）。
  Future<void> _open(String route, {Object? extra}) async {
    await context.push(route, extra: extra);
    if (mounted) setState(() {});
  }

  void _snack(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 本地书架：先改本地，网站那边由书架同步去推；没登录也能用。有分类时加入后让选分类。
  Future<void> _toggleShelf(bool inLib) async {
    final d = data.detail;
    if (inLib) {
      if (isLocalAid(aid)) {
        final res = await confirmRemoveLocalBooks(context, totalCount: 1, localCount: 1);
        if (!res.confirmed || !mounted) return;
        await ref.read(libraryProvider.notifier).remove([aid]);
        if (res.deleteFiles) {
          await LocalBooks.delete(aid);
          if (mounted) context.pop();
        }
        return;
      }
      return ref.read(libraryProvider.notifier).remove([aid]);
    }
    final cats = ref.read(libraryProvider).cats;
    // 设置里选了"新书默认分类"就直接放进去，不再问
    final def = AppPrefs.read(P.defaultCat, 'ask');
    final List<String>? picked = def == 'ask' || (def.isNotEmpty && !cats.any((c) => c.id == def))
        ? (cats.isEmpty ? const <String>[] : await pickCategories(context, cats, const []))
        : (def.isEmpty ? const <String>[] : [def]);
    // 选分类的时候可能刚同步完、书架 provider 被重建了：要在选完之后再取
    if (picked == null || !mounted) return;
    await ref.read(libraryProvider.notifier).add(aid, d.title, d.imgUrl, cats: picked);
  }

  /// 目录筛选后的章节（没筛选就是全部），复用已读与书签集合避免重复拷贝。
  List<CatChapter> _visible(List<CatChapter> chapters, {required Set<String> read, required Set<String> marked}) {
    if (!_chl.filtering) return chapters;
    return [
      for (final c in chapters)
        if (chapterTri(_chl.unread, () => !read.contains(c.cid)) && chapterTri(_chl.bookmarked, () => marked.contains(c.cid)) && chapterTri(_chl.cached, () => ChapterCache.has(aid, c.cid))) c,
    ];
  }

  String? _firstCid() => data.catalogue.expand((v) => v.chapters).firstOrNull?.cid;

  void _openCoverViewer(BuildContext context, String cover) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _CoverFullscreenDialog(url: cover, ref: ref),
    );
  }

  Future<void> _vote() async {
    if (_voting) return;
    if (ref.read(sessionProvider) is! SessionLoggedIn) {
      context.push(Routes.login);
      return;
    }
    setState(() => _voting = true);
    try {
      final msg = await ref.read(apiProvider).vote(aid);
      if (mounted) _snack(context, msg.isEmpty ? '已投票' : msg);
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = data.detail;
    ref.watch(volumeChangeForProvider(aid)); // 仅订阅本书卷封面/读完状态变化
    final cover = ref.read(volumeCoverQueueProvider).bookCover(aid, d.imgUrl);
    final inLib = ref.watch(libraryProvider.select((s) => s.books.containsKey(aid)));
    final progress = ReadingProgress.of(aid);
    final all = data.catalogue.expand((v) => v.chapters).toList();
    final read = ReadState.readView(aid);
    final markedCids = Bookmarks.bookmarkedCids(aid);
    final doneVols = Volumes.done(aid);
    final skippedIllus = {
      for (final v in Volumes.of(aid))
        if (v.illus != null && v.textCids.isNotEmpty && v.textCids.every(read.contains) && !read.contains(v.illus)) v.illus!,
    };
    final unread = all.where((c) => !read.contains(c.cid) && !skippedIllus.contains(c.cid)).length;
    final latest = all.reversed.take(3).toList();
    final startCid = progress?.cid ?? _firstCid();
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final shownTitle = LibraryStore.shown(aid, d.title);
    final local = isLocalAid(aid);

    // 合并每卷的可见章节计算：单次筛选、按展开态懒构建
    final orderedVols = _chl.reverse ? data.catalogue.reversed : data.catalogue;
    final visibleVols = <(CatVolume, List<CatChapter>)>[];
    for (final v in orderedVols) {
      final vis = _visible(v.chapters, read: read, marked: markedCids);
      if (_chl.filtering && vis.isEmpty) continue;
      visibleVols.add((v, _chl.reverse ? vis.reversed.toList() : vis));
    }

    Widget actionBtn({required VoidCallback? onPressed, required Widget icon, required String label}) => Expanded(
      child: TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8)),
        onPressed: onPressed,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(width: 4), Text(label, maxLines: 1)]),
        ),
      ),
    );

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              height: 150,
              child: Semantics(
                button: true,
                label: hz(context, '查看封面大图'),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openCoverViewer(context, cover),
                    child: CoverImage(cover, aid: aid),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shownTitle, style: theme.textTheme.headlineSmall),
                  // 书架上改过名：原名用小字写在下面
                  if (shownTitle != d.title) Text(d.title, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  if (local)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(d.author, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    )
                  else
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => context.push(Routes.searchAuthor(d.author)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                        child: Text(d.author, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.primary)),
                      ),
                    ),
                  const SizedBox(height: 2),
                  if (local)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                          child: Text(d.status, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
                        ),
                        if (d.lastUpdate != null) Text('导入于 ${d.lastUpdate}', style: muted),
                      ],
                    )
                  else ...[
                    Text([d.status, if (d.isDelisted) '已下架' else '更新于 ${d.lastUpdate}'].join(' · '), style: muted),
                    if (d.heat != null) Text('热度 ${d.heat}　上升 ${d.trending}', style: muted),
                    if (d.isAnimated) Text('已动画化', style: muted),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (!local) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [for (final t in d.tags.where((e) => e.isNotEmpty)) Chip(label: Text(t))]),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), padding: const EdgeInsets.symmetric(horizontal: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: startCid == null ? null : () => _open(Routes.reader(aid, startCid)),
                child: Row(
                  children: [
                    const Icon(Icons.play_arrow_rounded, size: 26),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(progress == null ? '开始阅读' : '继续阅读', style: const TextStyle(fontWeight: FontWeight.w700)),
                          // 读到哪一章写在按钮里，不用点进去才知道
                          if (all.where((c) => c.cid == startCid).firstOrNull?.title case final t?)
                            Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimary.withValues(alpha: 0.8))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: () => _toggleShelf(inLib),
                icon: Icon(inLib ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined, size: 20),
                label: Text(inLib ? '移出书架' : '加入书架'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (local)
          Row(
            children: [
              if (data.catalogue.isNotEmpty)
                actionBtn(onPressed: () => _open(Routes.volumes(aid)), icon: const Icon(Icons.view_carousel_outlined, size: 18), label: '分卷'),
              actionBtn(onPressed: () => _open(Routes.characters(aid)), icon: const Icon(Icons.people_outline, size: 18), label: '人物'),
              actionBtn(
                onPressed: () => showExportBookDialog(context, ref, aid: aid, novel: data),
                icon: const Icon(Icons.ios_share_outlined, size: 18),
                label: '导出',
              ),
            ],
          )
        else
          Row(
            children: [
              actionBtn(
                onPressed: _voting ? null : _vote,
                icon: _voting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.thumb_up_outlined, size: 18),
                label: '推荐',
              ),
              actionBtn(onPressed: () => _open(Routes.comments(aid)), icon: const Icon(Icons.forum_outlined, size: 18), label: '书评'),
              if (data.catalogue.isNotEmpty)
                actionBtn(onPressed: () => _open(Routes.volumes(aid)), icon: const Icon(Icons.view_carousel_outlined, size: 18), label: '分卷'),
              actionBtn(onPressed: () => _open(Routes.characters(aid)), icon: const Icon(Icons.people_outline, size: 18), label: '人物'),
              actionBtn(
                onPressed: () => launchUrl(Uri.parse('${siteBase(ref.read(nodeProvider))}/book/$aid.htm'), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_browser, size: 18),
                label: '网页',
              ),
            ],
          ),
        if (!local && d.isDelisted)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      all.isEmpty ? '本书在网站已下架且无目录，可查看简介与书评。' : '本书在网站已因版权下架；若已缓存可照常阅读，或前往「设置 → 妙妙小工具」了解扩展支持。',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (!local) _DownloadRow(aid: aid, title: d.title, data: data),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('已读 ${all.length - unread} / ${all.length} 章 · 未读 $unread 章', style: theme.textTheme.titleSmall)),
                    TextButton(onPressed: () => _open(Routes.report(aid)), child: const Text('阅读报告')),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: all.isEmpty ? 0 : (all.length - unread) / all.length, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                if (latest.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('最新章节', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  for (final c in latest)
                    InkWell(
                      onTap: () => _open(Routes.reader(aid, c.cid)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(read.contains(c.cid) ? Icons.check_circle_outline : Icons.fiber_manual_record, size: 12, color: read.contains(c.cid) ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: read.contains(c.cid) ? muted : null)),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('简介', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            final intro = d.introduce.trim().isEmpty ? '暂无简介' : d.introduce.trim();
            final style = theme.textTheme.bodyMedium?.copyWith(height: 1.6);
            final tp = TextPainter(text: TextSpan(text: intro, style: style), maxLines: 5, textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout(maxWidth: c.maxWidth);
            final over = tp.didExceedMaxLines;
            tp.dispose();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(intro, maxLines: _introOpen ? null : 5, overflow: _introOpen ? null : TextOverflow.ellipsis, style: style),
                if (over) TextButton(onPressed: () => setState(() => _introOpen = !_introOpen), child: Text(_introOpen ? '收起' : '展开')),
              ],
            );
          },
        ),
        BangumiInfoCard(aid: aid, title: d.title),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Text('目录', style: theme.textTheme.titleMedium)),
            TextButton.icon(
              onPressed: () => showChapterListSheet(context, aid, (o) => setState(() => _chl = o)),
              icon: Icon(Icons.filter_list, size: 18, color: _chl.filtering ? theme.colorScheme.primary : null),
              label: Text('${_chl.filtering ? '已筛选 · ' : ''}${_chl.reverse ? '倒序' : '正序'}'),
            ),
          ],
        ),
        Text(
          local ? '左右滑动章节可标已读或加书签 · 长按或右键章节可多选' : '左右滑动章节可标已读或加书签 · 长按或右键章节可多选缓存',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
      ],
    );

    Widget buildVolumeHeader(CatVolume v, bool expanded) {
      final isDone = doneVols.containsKey(v.title);
      return Column(
        children: [
          InkWell(
            onTap: () => setState(() => expanded ? _expanded.remove(v.title) : _expanded.add(v.title)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text(v.title, style: theme.textTheme.titleSmall)),
                  if (!local)
                    IconButton(
                      tooltip: hz(context, '换这一卷的封面'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.image_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: () => pickVolumeCover(context, aid, Vol.from(v)),
                    ),
                  IconButton(
                    tooltip: hz(context, isDone ? '取消本卷已读' : '标记本卷读完'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(isDone ? Icons.check_circle : Icons.check_circle_outline, size: 18, color: isDone ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(isDone ? '取消「${v.title}」的已读？' : '把「${v.title}」标为已读？'),
                          content: Text(isDone ? '这一卷的章节（含插图）会全部标回未读。' : '这一卷的章节（含插图）会全部标为已读。'),
                          actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定'))],
                        ),
                      );
                      if (ok != true) return;
                      // 插图章不算进"读完"，但手动标记时一起标，否则目录里总剩一章未读
                      await ReadState.setRead(aid, Vol.from(v).cids, !isDone);
                      if (mounted) setState(() {});
                    },
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(Icons.expand_more, size: 20, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
        ],
      );
    }

    Widget buildChapterTile(CatChapter c) {
      final idx = _indexOf[c.cid];
      final titleText = _chl.showIndex && idx != null ? '$idx. ${c.title}' : c.title;
      return ChapterSwipe(
        aid: aid,
        book: data.detail.title,
        cid: c.cid,
        title: c.title,
        enabled: _picked.isEmpty,
        onChanged: () => setState(() {}),
        onCache: local ? null : () => ref.read(downloadProvider.notifier).start(aid, data.detail.title, [c], total: all.length, img: data.detail.imgUrl, firstCid: all.first.cid),
        child: GestureDetector(
          onSecondaryTap: () => _pick(c.cid),
          child: ListTile(
            dense: true,
            selected: _picked.contains(c.cid),
            leading: _picked.isNotEmpty
                ? Icon(_picked.contains(c.cid) ? Icons.check_box : Icons.check_box_outline_blank, size: 20)
                : (read.contains(c.cid) ? Icon(Icons.check, size: 16, color: theme.colorScheme.onSurfaceVariant) : null),
            title: Text(
              titleText,
              style: c.cid == progress?.cid
                  ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)
                  : (read.contains(c.cid) ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (markedCids.contains(c.cid)) ...[
                  Icon(Icons.bookmark_rounded, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                ],
                if (c.cid == progress?.cid)
                  Text('读到这里', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary))
                else if (ChapterCache.has(aid, c.cid))
                  Icon(Icons.download_for_offline_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              ],
            ),
            onTap: _picked.isNotEmpty ? () => _pick(c.cid) : () => _open(Routes.reader(aid, c.cid)),
            onLongPress: () => _pick(c.cid),
          ),
        ),
      );
    }

    final list = contentWidth(
      CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 16), sliver: SliverToBoxAdapter(child: header)),
          for (final (v, chs) in visibleVols) ...[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(child: buildVolumeHeader(v, _expanded.contains(v.title))),
            ),
            if (_expanded.contains(v.title))
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(itemCount: chs.length, itemBuilder: (context, i) => buildChapterTile(chs[i])),
              ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: _picked.isEmpty ? 32 : 96)),
        ],
      ),
    );

    final body = _picked.isEmpty
        ? list
        : Stack(
            children: [
              list,
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Material(
                  elevation: 3,
                  color: theme.colorScheme.surfaceContainer,
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        IconButton(tooltip: hz(context, '取消'), icon: const Icon(Icons.close), onPressed: () => setState(_picked.clear)),
                        Expanded(child: Text('已选 ${_picked.length} 章', maxLines: 1, overflow: TextOverflow.ellipsis)),
                        TextButton(onPressed: () => _markPicked(true), child: const Text('已读')),
                        TextButton(onPressed: () => _markPicked(false), child: const Text('未读')),
                        if (!local)
                          TextButton(
                            onPressed: () {
                              final chosen = all.where((c) => _picked.contains(c.cid)).toList();
                              if (chosen.isNotEmpty) {
                                ref.read(downloadProvider.notifier).start(aid, data.detail.title, chosen, total: all.length, img: data.detail.imgUrl, firstCid: all.first.cid);
                                _snack(context, '已开始缓存 ${chosen.length} 章');
                              }
                              setState(_picked.clear);
                            },
                            child: const Text('缓存'),
                          ),
                        // 按钮全摆出来窄屏放不下，不常用的收进"更多"
                        PopupMenuButton<void Function()>(
                          tooltip: hz(context, '更多'),
                          onSelected: (f) => f(),
                          itemBuilder: (_) => [
                            // 从第一章选到已选的最后一章，方便"之前的全部标为已读"
                            PopupMenuItem(value: () => setState(() => _picked.addAll(all.take(all.lastIndexWhere((c) => _picked.contains(c.cid)) + 1).map((c) => c.cid))), child: const Text('选到开头')),
                            if (_picked.length == 1) PopupMenuItem(value: _markBefore, child: const Text('前面的标为已读')),
                            PopupMenuItem(
                              value: () {
                                final selected = {..._picked};
                                setState(_picked.clear);
                                showExportBookDialog(context, ref, aid: aid, novel: data, selectedCids: selected);
                              },
                              child: const Text('导出选中章节'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );

    return CallbackShortcuts(
      bindings: {
        if (_picked.isNotEmpty) const SingleActivator(LogicalKeyboardKey.escape): () => setState(_picked.clear),
      },
      child: Focus(
        focusNode: _focus,
        child: PopScope(
          canPop: _picked.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _picked.isNotEmpty) setState(_picked.clear);
          },
          child: Scaffold(
            appBar: AppBar(
              title: ValueListenableBuilder<bool>(
                valueListenable: _showTitle,
                builder: (context, show, child) => AnimatedOpacity(opacity: show ? 1 : 0, duration: const Duration(milliseconds: 180), child: child),
                child: Text(shownTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              actions: [
                if (data.catalogue.isNotEmpty)
                  IconButton(
                    tooltip: hz(context, '书内搜索'),
                    icon: const Icon(Icons.search),
                    onPressed: () => showBookSearchSheet(
                      context,
                      aid: aid,
                      catalogue: data.catalogue,
                      onSelectHit: (hit) => _open(Routes.reader(aid, hit.cid, offset: hit.offset)),
                    ),
                  ),
                IconButton(
                  tooltip: hz(context, '人物词典'),
                  icon: const Icon(Icons.people_outline),
                  onPressed: () => _open(Routes.characters(aid)),
                ),
                PopupMenuButton<String>(
                  tooltip: hz(context, '更多'),
                  onSelected: (v) {
                    if (v == 'export') showExportBookDialog(context, ref, aid: aid, novel: data);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'export',
                      child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.ios_share_outlined), title: Text('导出为 EPUB / TXT')),
                    ),
                  ],
                ),
              ],
            ),
            body: body,
          ),
        ),
      ),
    );
  }

  void _pick(String cid) {
    setState(() => _picked.contains(cid) ? _picked.remove(cid) : _picked.add(cid));
    if (_picked.isNotEmpty) _focus.requestFocus();
  }

  /// 只选了一章时：它前面的所有章节标为已读（Mihon 的"标记前面的为已读"）
  Future<void> _markBefore() async {
    final all = data.catalogue.expand((v) => v.chapters).toList();
    final i = all.indexWhere((c) => _picked.contains(c.cid));
    if (i > 0) await ReadState.setRead(aid, all.take(i).map((c) => c.cid), true);
    if (mounted) setState(_picked.clear);
  }

  Future<void> _markPicked(bool read) async {
    await ReadState.setRead(aid, _picked, read);
    if (mounted) setState(_picked.clear);
  }
}

/// 封面全屏查看：黑底、可双指/双击缩放，带分享和关闭按钮。
class _CoverFullscreenDialog extends StatefulWidget {
  const _CoverFullscreenDialog({required this.url, required this.ref});

  final String url;
  final WidgetRef ref;

  @override
  State<_CoverFullscreenDialog> createState() => _CoverFullscreenDialogState();
}

class _CoverFullscreenDialogState extends State<_CoverFullscreenDialog> {
  final _transform = TransformationController();
  bool _controls = true;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.2) {
      _transform.value = Matrix4.identity();
    } else {
      _transform.value = Matrix4.diagonal3Values(2.2, 2.2, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _controls = !_controls),
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 0.8,
            maxScale: 5.0,
            child: Center(child: NetImage(widget.url, fit: BoxFit.contain, full: true)),
          ),
        ),
        if (_controls)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isWebPreview)
                  IconButton.filledTonal(
                    tooltip: hz(context, '保存或分享封面'),
                    style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                    icon: const Icon(Icons.ios_share, size: 20),
                    onPressed: () async {
                      try {
                        final filePath = await widget.ref.read(imageStoreProvider).path(widget.url);
                        await SharePlus.instance.share(ShareParams(files: [XFile(filePath)]));
                      } catch (e) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出图片失败：$e')));
                      }
                    },
                  ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: hz(context, '关闭'),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 详情页首屏加载骨架屏：封面色块 + 书名/作者/状态占位 + 主按钮 + 简介与目录灰条。
class _NovelSkeleton extends StatelessWidget {
  const _NovelSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainer;
    Widget bar(double w, {double h = 14, double r = 6}) => Container(width: w, height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(r)));
    return contentWidth(
      ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(110, h: 150, r: 10),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(double.infinity, h: 22),
                    const SizedBox(height: 10),
                    bar(140, h: 16),
                    const SizedBox(height: 12),
                    bar(180),
                    const SizedBox(height: 8),
                    bar(120),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(flex: 3, child: bar(double.infinity, h: 52, r: 16)),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: bar(double.infinity, h: 52, r: 16)),
            ],
          ),
          const SizedBox(height: 20),
          bar(double.infinity, h: 96, r: 14),
          const SizedBox(height: 20),
          bar(64, h: 18),
          const SizedBox(height: 10),
          bar(double.infinity),
          const SizedBox(height: 8),
          bar(double.infinity),
          const SizedBox(height: 8),
          bar(200),
          const SizedBox(height: 24),
          bar(64, h: 18),
          const SizedBox(height: 12),
          for (var i = 0; i < 4; i++) ...[
            bar(double.infinity, h: 36, r: 8),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// 缓存全本：显示已缓存章数，下载中显示进度并可取消。
class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.aid, required this.title, required this.data});

  final String aid;
  final String title;
  final NovelPage data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = data.catalogue.expand((v) => v.chapters).toList();
    final task = ref.watch(downloadProvider.select((m) => m[aid]));
    final cached = task?.done ?? ChapterCache.count(aid);
    final running = task?.running ?? false;
    return Row(
      children: [
        Expanded(
          child: Text(
            running ? '正在缓存 $cached/${chapters.length}' : (task?.error ?? '已缓存 $cached/${chapters.length} 章'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        if (running)
          TextButton(onPressed: () => ref.read(downloadProvider.notifier).cancel(aid), child: const Text('暂停'))
        else ...[
          TextButton(onPressed: cached >= chapters.length ? null : () => ref.read(downloadProvider.notifier).start(aid, title, chapters, img: data.detail.imgUrl), child: const Text('缓存全本')),
          if (cached > 0)
            TextButton(onPressed: () => showExportBookDialog(context, ref, aid: aid, novel: data), child: const Text('导出')),
          TextButton(onPressed: () => context.push(Routes.cacheBook(aid)), child: const Text('管理')),
        ],
      ],
    );
  }
}
