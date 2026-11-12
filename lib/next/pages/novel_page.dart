import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../app_prefs.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../chapter_list.dart';
import '../data.dart';
import '../library.dart';
import '../stats.dart';
import '../volumes.dart';
import 'categories_page.dart';
import 'cover_picker_page.dart';
import '../progress.dart';
import '../read_state.dart';
import '../router.dart';
import '../swipe.dart';
import '../session.dart';
import '../widgets.dart';
import '../text.dart';

/// 详情 + 目录：存过的先给（不等网络，挂 VPN 时也秒开），再联网取最新的；联网失败而本地有就不报错。
final novelProvider = StreamProvider.autoDispose.family<NovelPage, String>((ref, aid) async* {
  final api = ref.watch(apiProvider);
  final saved = await api.saved(aid);
  if (saved != null) {
    await Volumes.saveCatalogue(aid, saved.catalogue);
    yield saved;
  }
  try {
    final fresh = await api.novel(aid);
    final d = fresh.detail;
    // 请求期间退出了详情页：这个 provider 已经销毁，不能再用 ref（书架那边的书名、封面等下次再记）
    if (ref.mounted) ref.read(libraryProvider.notifier).noteDetail(aid, title: d.title, img: d.imgUrl, status: d.status);
    await Volumes.saveCatalogue(aid, fresh.catalogue);
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
    return Scaffold(
      appBar: AppBar(),
      body: novel.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => StatePanel(title: '加载失败', detail: e.toString(), error: e, onRetry: () => ref.invalidate(novelProvider(aid))),
        data: (data) => _Body(aid: aid, data: data),
      ),
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
  final _picked = <String>{}; // 目录里多选的章节
  late ChapterListOptions _chl = ChapterListOptions.of(widget.aid);

  String get aid => widget.aid;
  NovelPage get data => widget.data;
  late final VolumeCoverQueue _covers; // dispose 里不能再用 ref，先取好

  @override
  void initState() {
    super.initState();
    _covers = ref.read(volumeCoverQueueProvider);
  }

  @override
  void dispose() {
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
    if (inLib) return ref.read(libraryProvider.notifier).remove([aid]);
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

  /// 目录筛选后的章节（没筛选就是全部）
  Iterable<CatChapter> _visible(List<CatChapter> chapters) {
    if (!_chl.filtering) return chapters;
    final read = ReadState.read(aid);
    final marked = Bookmarks.all(aid).map((b) => b.cid).toSet();
    return chapters.where((c) => chapterTri(_chl.unread, () => !read.contains(c.cid)) && chapterTri(_chl.bookmarked, () => marked.contains(c.cid)) && chapterTri(_chl.cached, () => ChapterCache.has(aid, c.cid)));
  }

  /// 章节在整本书里按网站顺序数是第几章（从 1 开始），"标题前加序号"用
  late final Map<String, int> _indexOf = {for (final (i, c) in data.catalogue.expand((v) => v.chapters).indexed) c.cid: i + 1};

  String? _firstCid() => data.catalogue.expand((v) => v.chapters).firstOrNull?.cid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = data.detail;
    ref.watch(volumeChangesProvider); // 取到卷封面后换上
    final cover = ref.read(volumeCoverQueueProvider).bookCover(aid, d.imgUrl);
    final inLib = ref.watch(libraryProvider.select((s) => s.books.containsKey(aid)));
    final progress = ReadingProgress.of(aid);
    final all = data.catalogue.expand((v) => v.chapters).toList();
    final read = ReadState.read(aid);
    final unread = all.where((c) => !read.contains(c.cid)).length;
    final latest = all.reversed.take(3).toList();
    final startCid = progress?.cid ?? _firstCid();
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final list = contentWidth(ListView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, _picked.isEmpty ? 32 : 96),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              height: 150,
              child: GestureDetector(
                onTap: () => showDialog(
                  context: context,
                  builder: (context) => GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(context), child: InteractiveViewer(child: NetImage(cover, fit: BoxFit.contain, full: true))),
                ),
                child: CoverImage(cover),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(LibraryStore.shown(aid, d.title), style: theme.textTheme.headlineSmall),
                  // 书架上改过名：原名用小字写在下面
                  if (LibraryStore.shown(aid, d.title) != d.title) Text(d.title, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => context.push(Routes.searchAuthor(d.author)),
                    child: Text(d.author, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.primary)),
                  ),
                  const SizedBox(height: 6),
                  Text([d.status, if (d.isDelisted) '已下架' else '更新于 ${d.lastUpdate}'].join(' · '), style: muted),
                  if (d.heat != null) Text('热度 ${d.heat}　上升 ${d.trending}', style: muted),
                  if (d.isAnimated) Text('已动画化', style: muted),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final t in d.tags.where((e) => e.isNotEmpty)) Chip(label: Text(t))]),
        const SizedBox(height: 16),
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
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: () async {
                  if (ref.read(sessionProvider) is! SessionLoggedIn) {
                    context.push(Routes.login);
                    return;
                  }
                  try {
                    final msg = await ref.read(apiProvider).vote(aid);
                    if (context.mounted) _snack(context, msg.isEmpty ? '已投票' : msg);
                  } catch (e) {
                    if (context.mounted) _snack(context, e.toString());
                  }
                },
                icon: const Icon(Icons.thumb_up_outlined),
                label: const Text('推荐'),
              ),
            ),
            Expanded(
              child: TextButton.icon(onPressed: () => _open(Routes.comments(aid)), icon: const Icon(Icons.forum_outlined), label: const Text('书评')),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('${siteBase(ref.read(nodeProvider))}/book/$aid.htm'), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('网页'),
              ),
            ),
          ],
        ),
        _DownloadRow(aid: aid, title: d.title, data: data),
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
        Text('长按章节可多选：批量标记已读、缓存', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        for (final CatVolume v in _chl.reverse ? data.catalogue.reversed : data.catalogue)
          if (!_chl.filtering || _visible(v.chapters).isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: data.catalogue.length == 1 || v.chapters.any((c) => c.cid == progress?.cid || _picked.contains(c.cid)),
            title: Row(
              children: [
                Expanded(child: Text(v.title)),
                IconButton(
                  tooltip: hz(context, '换这一卷的封面'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.image_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  onPressed: () => pickVolumeCover(context, aid, Vol.from(v)),
                ),
                Builder(
                  builder: (context) {
                    final isDone = Volumes.done(aid).containsKey(v.title);
                    return IconButton(
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
                    );
                  },
                ),
              ],
            ),
            children: [
              for (final c in _chl.reverse ? _visible(v.chapters).toList().reversed : _visible(v.chapters))
                ChapterSwipe(
                  aid: aid,
                  book: data.detail.title,
                  cid: c.cid,
                  title: c.title,
                  enabled: _picked.isEmpty,
                  onChanged: () => setState(() {}),
                  onCache: () => ref.read(downloadProvider.notifier).start(aid, data.detail.title, [c], total: data.catalogue.expand((v) => v.chapters).length, img: data.detail.imgUrl, firstCid: data.catalogue.expand((v) => v.chapters).first.cid),
                  child: ListTile(
                  dense: true,
                  selected: _picked.contains(c.cid),
                  leading: _picked.isNotEmpty
                      ? Icon(_picked.contains(c.cid) ? Icons.check_box : Icons.check_box_outline_blank, size: 20)
                      : (read.contains(c.cid) ? Icon(Icons.check, size: 16, color: theme.colorScheme.onSurfaceVariant) : null),
                  title: Text(
                    _chl.showIndex ? '${_indexOf[c.cid]}. ${c.title}' : c.title,
                    style: c.cid == progress?.cid
                        ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)
                        : (read.contains(c.cid) ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null),
                  ),
                  trailing: c.cid == progress?.cid ? Text('读到这里', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)) : (ChapterCache.has(aid, c.cid) ? Icon(Icons.download_for_offline_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)) : null),
                  onTap: _picked.isNotEmpty ? () => _pick(c.cid) : () => _open(Routes.reader(aid, c.cid)),
                  onLongPress: () => _pick(c.cid),
                )),
            ],
          ),
      ],
    ));
    if (_picked.isEmpty) return list;
    return Stack(
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
                  TextButton(
                    onPressed: () {
                      final chosen = all.where((c) => _picked.contains(c.cid)).toList();
                      ref.read(downloadProvider.notifier).start(aid, data.detail.title, chosen, total: all.length, img: data.detail.imgUrl, firstCid: all.first.cid);
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
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _pick(String cid) => setState(() => _picked.contains(cid) ? _picked.remove(cid) : _picked.add(cid));

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

/// 缓存全本：显示已缓存章数，下载中显示进度并可取消。
class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.aid, required this.title, required this.data});

  final String aid;
  final String title;
  final NovelPage data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = data.catalogue.expand((v) => v.chapters).toList();
    final task = ref.watch(downloadProvider)[aid];
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
          TextButton(onPressed: () => context.push(Routes.cacheBook(aid)), child: const Text('管理')),
        ],
      ],
    );
  }
}
