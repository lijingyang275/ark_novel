import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/cat_volume.dart';
import '../../models/content.dart';
import '../bangumi.dart';
import '../book_search.dart';
import '../cache.dart';
import '../characters.dart';
import '../color_picker.dart';
import '../image_cache.dart';
import '../library.dart' show LibraryStore;
import '../local_books.dart';
import '../reader/reader_body.dart' show readableHighlightColor;
import '../reader/reader_page.dart' show chapterProvider;
import '../reader/reader_sheets.dart';
import '../routes.dart';
import '../stats.dart';
import '../text.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../x_list.dart';
import 'book_search_sheet.dart';
import 'novel_page.dart' show novelProvider;

/// 人物 / 设定词典页面（路由 `/novel/:aid/characters`）。
class CharactersPage extends ConsumerStatefulWidget {
  const CharactersPage({super.key, required this.aid});

  final String aid;

  @override
  ConsumerState<CharactersPage> createState() => _CharactersPageState();
}

class _CharactersPageState extends ConsumerState<CharactersPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  String _roleFilter = '';
  bool _onlyHighlighted = false;
  final _revealed = <String>{}; // 当前会话中已点击展开防剧透笔记的角色 id
  bool _batchFetchingCn = false;
  int _batchCnDone = 0;
  int _batchCnTotal = 0;
  bool _cancelBatchCn = false;

  @override
  void initState() {
    super.initState();
    BookCharacters.ensureAvatarDirLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _cancelBatchCn = true;
    _searchCtrl.dispose();
    super.dispose();
  }

  String _bookTitle() {
    final novel = ref.read(novelProvider(widget.aid)).value;
    if (novel != null && novel.detail.title.isNotEmpty) return novel.detail.title;
    return BangumiCovers.bookTitle(widget.aid) ?? LibraryStore.shown(widget.aid, ReadingStats.info(widget.aid).title);
  }

  List<CatVolume> _catalogue() => ref.read(novelProvider(widget.aid)).value?.catalogue ?? const [];

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openBgmImport() async {
    final imported = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BgmImportSheet(aid: widget.aid, bookTitle: _bookTitle()),
    );
    if (imported != null && imported > 0 && mounted) {
      ref.invalidate(chapterProvider);
      _snack('已导入 $imported 个角色');
    }
  }

  Future<void> _openEditor(BookCharacter? initial) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CharacterEditorSheet(aid: widget.aid, initial: initial, catalogue: _catalogue()),
    );
    if (saved == true && mounted) {
      ref.invalidate(chapterProvider);
      setState(() {});
    }
  }

  Future<void> _openDetail(BookCharacter c) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CharacterDetailSheet(
        aid: widget.aid,
        initial: c,
        onEdit: () async {
          Navigator.pop(context);
          await _openEditor(BookCharacters.byId(widget.aid, c.id) ?? c);
        },
        onSearchAppearances: () {
          Navigator.pop(context);
          _searchAppearances(BookCharacters.byId(widget.aid, c.id) ?? c);
        },
      ),
    );
  }

  Future<void> _batchFetchCnSummaries() async {
    if (_batchFetchingCn) return;
    final all = BookCharacters.of(widget.aid);
    // 优先给主角补全，再按顺序补其余角色
    final targets = [
      ...all.where((c) => c.role == CharacterRole.main && MoegirlApi.needsCnSummary(c.summary, c.cnSummary)),
      ...all.where((c) => c.role != CharacterRole.main && MoegirlApi.needsCnSummary(c.summary, c.cnSummary)),
    ];
    if (targets.isEmpty) {
      _snack('当前人物都已有中文简介');
      return;
    }
    setState(() {
      _batchFetchingCn = true;
      _batchCnDone = 0;
      _batchCnTotal = targets.length;
      _cancelBatchCn = false;
    });
    final api = ref.read(moegirlApiProvider);
    var hits = 0;
    for (var i = 0; i < targets.length; i += 3) {
      if (_cancelBatchCn || !mounted) break;
      final batch = targets.sublist(i, math.min(i + 3, targets.length));
      await Future.wait(batch.map((c) async {
        if (_cancelBatchCn) return;
        try {
          final intro = await api.fetchIntro(c.name);
          if (intro != null && intro.isNotEmpty) {
            final latest = BookCharacters.byId(widget.aid, c.id) ?? c;
            await BookCharacters.upsert(latest.copyWith(cnSummary: intro), enableHighlight: latest.ruleId.isNotEmpty);
            hits++;
          }
        } catch (_) {}
        if (mounted) setState(() => _batchCnDone++);
      }));
    }
    if (mounted) {
      setState(() => _batchFetchingCn = false);
      _snack(hits > 0 ? '已为 $hits 位人物补全萌娘百科中文简介' : '萌娘百科未匹配到更多中文简介');
    }
  }

  Future<void> _handleBatchAction(String action) async {
    switch (action) {
      case 'hl_main_only':
        await BookCharacters.setHighlightForAll(widget.aid, predicate: (c) => c.role == CharacterRole.main);
        if (mounted) {
          ref.invalidate(chapterProvider);
          _snack('已切换为仅主角开启正文高亮');
        }
      case 'hl_none':
        await BookCharacters.setHighlightForAll(widget.aid, predicate: (_) => false);
        if (mounted) {
          ref.invalidate(chapterProvider);
          _snack('已关闭全部正文高亮');
        }
      case 'normalize':
        final n = await BookCharacters.normalizeExisting(widget.aid);
        if (mounted) {
          ref.invalidate(chapterProvider);
          _snack(n > 0 ? '已整理 $n 位人物的常用称呼与冗余日文别名' : '所有人物的称呼与别名均已规范');
        }
      case 'fetch_cn':
        await _batchFetchCnSummaries();
      case 'clear_support':
        final all = BookCharacters.of(widget.aid);
        final toDelete = {
          for (final c in all)
            if (c.role != CharacterRole.main && BookCharacters.noteOf(c).trim().isEmpty) c.id,
        };
        if (toDelete.isEmpty) {
          _snack('没有可清理的无笔记配角/设定');
          return;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('清理 ${toDelete.length} 条配角/设定？'),
            content: const Text('将保留全部主角以及你写过个人笔记的词条，其余配角/设定及其高亮规则将被移除。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理')),
            ],
          ),
        );
        if (ok != true) return;
        final n = await BookCharacters.deleteMany(widget.aid, toDelete);
        if (mounted) {
          ref.invalidate(chapterProvider);
          _snack('已清理 $n 条配角/设定');
        }
      case 'clear_all':
        final all = BookCharacters.of(widget.aid);
        if (all.isEmpty) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('清空全部 ${all.length} 条人物词条？'),
            content: const Text('将同时移除这些词条绑定的正文高亮与个人笔记，此操作不可撤销。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('全部清空'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await BookCharacters.deleteMany(widget.aid, {for (final c in all) c.id});
        if (mounted) {
          ref.invalidate(chapterProvider);
          _snack('已清空本书人物词典');
        }
    }
  }

  void _searchAppearances(BookCharacter c) {
    final terms = c.searchTerms;
    if (terms.isEmpty) return;
    showBookSearchSheet(
      context,
      aid: widget.aid,
      catalogue: _catalogue(),
      initialQuery: terms.length > 1 ? terms.map(RegExp.escape).join('|') : terms.first,
      initialRegex: terms.length > 1,
      initialScope: BookSearchScope.allCached,
      onSelectHit: (hit) => context.push(Routes.reader(widget.aid, hit.cid, offset: hit.offset)),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(bookCharactersChangesProvider);
    ref.watch(novelProvider(widget.aid));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allChars = BookCharacters.of(widget.aid);
    final hlIds = {for (final c in allChars) if (BookCharacters.isHighlightActive(c)) c.id};
    final q = _search.trim().toLowerCase();
    final chars = allChars.where((c) {
      if (_roleFilter.isNotEmpty && c.role != _roleFilter) return false;
      if (_onlyHighlighted && !hlIds.contains(c.id)) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.originalName.toLowerCase().contains(q) ||
          c.aliases.any((a) => a.toLowerCase().contains(q)) ||
          c.preferredSummary.toLowerCase().contains(q) ||
          BookCharacters.noteOf(c).toLowerCase().contains(q);
    }).toList();
    final currentVol = BookCharacters.currentReadingVolume(widget.aid);
    final rolesPresent = {for (final c in allChars) c.role};

    return Scaffold(
      appBar: AppBar(
        title: const Text('人物词典'),
        actions: [
          IconButton(
            tooltip: hz(context, '从 Bangumi 导入'),
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: _openBgmImport,
          ),
          IconButton(
            tooltip: hz(context, '手动添加人物或设定'),
            icon: const Icon(Icons.person_add_outlined),
            onPressed: () => _openEditor(null),
          ),
          if (allChars.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: hz(context, '批量管理'),
              onSelected: _handleBatchAction,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'hl_main_only', child: Text('仅主角开启正文高亮')),
                PopupMenuItem(value: 'hl_none', child: Text('关闭全部正文高亮')),
                PopupMenuItem(value: 'normalize', child: Text('一键整理称呼与别名')),
                PopupMenuItem(value: 'fetch_cn', child: Text('一键补全中文简介')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'clear_support', child: Text('清理无笔记配角')),
                PopupMenuItem(value: 'clear_all', child: Text('清空全部人物')),
              ],
            ),
        ],
      ),
      body: allChars.isEmpty
          ? contentWidth(
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
                        child: Icon(Icons.people_outline, size: 34, color: scheme.primary),
                      ),
                      const SizedBox(height: 16),
                      Text('还没有人物或设定词条', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        '可从 Bangumi 一键导入本作角色（自动匹配中文名、常用称呼与头像），或手动添加人物与世界观设定；开启高亮后在阅读器内点按人名即可查看档案与防剧透笔记。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.6),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                            onPressed: _openBgmImport,
                            icon: const Icon(Icons.cloud_download_outlined, size: 18),
                            label: const Text('从 Bangumi 导入'),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                            onPressed: () => _openEditor(null),
                            icon: const Icon(Icons.person_add_outlined, size: 18),
                            label: const Text('手动添加人物/设定'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
          : contentWidth(
              Column(
                children: [
                  if (_batchFetchingCn)
                    Container(
                      width: double.infinity,
                      color: scheme.surfaceContainerLow,
                      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                      child: Row(
                        children: [
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Expanded(child: Text('正在从萌娘百科补全中文简介（$_batchCnDone/$_batchCnTotal）…', style: theme.textTheme.bodySmall)),
                          TextButton(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: () => setState(() => _cancelBatchCn = true),
                            child: const Text('停止'),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (allChars.length >= 6 || _search.isNotEmpty) ...[
                          TextField(
                            controller: _searchCtrl,
                            onChanged: (v) => setState(() => _search = v),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              prefixIcon: const Icon(Icons.search, size: 18),
                              hint: const Text('搜索人物名、称呼或简介', maxLines: 1, overflow: TextOverflow.ellipsis),
                              suffixIcon: _search.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: hz(context, '清空'),
                                      icon: const Icon(Icons.close, size: 17),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _search = '');
                                      },
                                    ),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (rolesPresent.length > 1) ...[
                                ChoiceChip(
                                  label: Text('全部 (${allChars.length})'),
                                  selected: _roleFilter.isEmpty,
                                  showCheckmark: false,
                                  onSelected: (_) => setState(() => _roleFilter = ''),
                                ),
                                for (final r in CharacterRole.all)
                                  if (rolesPresent.contains(r)) ...[
                                    const SizedBox(width: 6),
                                    ChoiceChip(
                                      label: Text('$r (${allChars.where((c) => c.role == r).length})'),
                                      selected: _roleFilter == r,
                                      showCheckmark: false,
                                      onSelected: (_) => setState(() => _roleFilter = r),
                                    ),
                                  ],
                              ] else
                                Text('共 ${allChars.length} 条记录', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                              if (hlIds.isNotEmpty && hlIds.length < allChars.length) ...[
                                const SizedBox(width: 8),
                                FilterChip(
                                  label: Text('已高亮 (${hlIds.length})'),
                                  selected: _onlyHighlighted,
                                  showCheckmark: false,
                                  onSelected: (v) => setState(() => _onlyHighlighted = v),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: chars.isEmpty
                        ? Center(
                            child: Text('没有匹配的人物词条', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
                            itemCount: chars.length,
                            itemBuilder: (context, i) => _buildCard(chars[i], currentVol, hlIds.contains(chars[i].id)),
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildCard(BookCharacter c, int currentVol, bool hlOn) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final note = BookCharacters.noteOf(c);
    final hideSpoiler = note.isNotEmpty && c.shouldHideSpoiler(currentVol) && !_revealed.contains(c.id);
    final displayAliases = BookCharacter.cleanAliases(c.aliases, name: c.name, originalName: c.originalName);
    final summaryText = c.preferredSummary;
    final summaryIsJpOnly = c.cnSummary.trim().isEmpty && MoegirlApi.isMostlyJapanese(c.summary);
    final nameColor = hlOn ? readableHighlightColor(Color(c.color), darkSurface: dark) : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CharacterAvatar(char: c, size: 50),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 15, color: nameColor),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.role == CharacterRole.main ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            c.role,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10.5,
                              color: c.role == CharacterRole.main ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (displayAliases.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('称呼：${displayAliases.join(' / ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                    ] else if (c.originalName.isNotEmpty && c.originalName != c.name) ...[
                      const SizedBox(height: 2),
                      Text(c.originalName, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                    ],
                    if (summaryText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        summaryText.replaceAll(RegExp(r'\s+'), ' '),
                        maxLines: summaryIsJpOnly ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.45,
                          color: summaryIsJpOnly ? scheme.onSurfaceVariant.withValues(alpha: 0.72) : scheme.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(hideSpoiler ? Icons.visibility_off_outlined : Icons.sticky_note_2_outlined, size: 13, color: scheme.primary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              hideSpoiler ? '个人笔记已折叠（第 ${c.spoilerVol} 卷解锁）' : note.replaceAll(RegExp(r'\s+'), ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: hz(context, hlOn ? '关闭正文高亮' : '开启正文高亮'),
                    child: SizedBox(
                      height: 30,
                      child: Transform.scale(
                        scale: 0.76,
                        child: Switch(
                          value: hlOn,
                          onChanged: (v) async {
                            await BookCharacters.upsert(c, enableHighlight: v);
                            if (mounted) ref.invalidate(chapterProvider);
                          },
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: hz(context, '编辑'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                    icon: Icon(Icons.edit_outlined, size: 17, color: scheme.onSurfaceVariant),
                    onPressed: () => _openEditor(c),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 词典页点选人物卡片后弹出的完整档案底栏（含高清头像点击看原图、萌娘百科中文简介、全书出场、笔记与编辑）。
class _CharacterDetailSheet extends ConsumerStatefulWidget {
  const _CharacterDetailSheet({
    required this.aid,
    required this.initial,
    required this.onEdit,
    required this.onSearchAppearances,
  });

  final String aid;
  final BookCharacter initial;
  final Future<void> Function() onEdit;
  final VoidCallback onSearchAppearances;

  @override
  ConsumerState<_CharacterDetailSheet> createState() => _CharacterDetailSheetState();
}

class _CharacterDetailSheetState extends ConsumerState<_CharacterDetailSheet> {
  late BookCharacter _char = widget.initial;
  bool _revealed = false;
  bool _loadingMoegirl = false;
  String? _tip;

  Future<void> _fetchMoegirl() async {
    if (_loadingMoegirl) return;
    setState(() {
      _loadingMoegirl = true;
      _tip = null;
    });
    try {
      final intro = await ref.read(moegirlApiProvider).fetchIntro(_char.name);
      if (!mounted) return;
      if (intro == null || intro.isEmpty) {
        setState(() => _tip = '萌娘百科未找到「${_char.name}」的中文简介');
      } else {
        final next = await BookCharacters.upsert(_char.copyWith(cnSummary: intro), enableHighlight: _char.ruleId.isNotEmpty);
        if (mounted) setState(() => _char = next);
      }
    } catch (_) {
      if (mounted) setState(() => _tip = '获取萌娘百科简介失败');
    } finally {
      if (mounted) setState(() => _loadingMoegirl = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final hlOn = BookCharacters.isHighlightActive(_char);
    final note = BookCharacters.noteOf(_char);
    final currentVol = BookCharacters.currentReadingVolume(widget.aid);
    final hideSpoiler = note.isNotEmpty && _char.shouldHideSpoiler(currentVol) && !_revealed;
    final displayAliases = BookCharacter.cleanAliases(_char.aliases, name: _char.name, originalName: _char.originalName);
    final showMoegirlBtn = MoegirlApi.needsCnSummary(_char.summary, _char.cnSummary);
    final summaryText = _char.preferredSummary;
    final nameColor = hlOn ? readableHighlightColor(Color(_char.color), darkSurface: dark) : null;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CharacterAvatar(char: _char, size: 64),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _char.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: nameColor),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                            child: Text(_char.role, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer)),
                          ),
                        ],
                      ),
                      if (_char.originalName.isNotEmpty && _char.originalName != _char.name) ...[
                        const SizedBox(height: 2),
                        Text(_char.originalName, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                      if (displayAliases.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text('称呼：${displayAliases.join(' / ')}', maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                      if (_char.avatarUrl.isNotEmpty || _char.localAvatar.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text('轻点头像可查看完整立绘', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (summaryText.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(summaryText, style: theme.textTheme.bodyMedium?.copyWith(height: 1.6, fontSize: 13.5)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (showMoegirlBtn)
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                    onPressed: _loadingMoegirl ? null : _fetchMoegirl,
                    icon: _loadingMoegirl
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.translate, size: 15),
                    label: const Text('获取萌娘百科中文简介', style: TextStyle(fontSize: 12.5)),
                  ),
                if (_char.name.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                    onPressed: () => launchUrl(MoegirlApi.pageUrl(_char.name), mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('在萌娘百科查看', style: TextStyle(fontSize: 12.5)),
                  ),
                if (_tip != null) Text(_tip!, style: muted),
              ],
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 10),
              if (hideSpoiler)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _revealed = true),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.visibility_off_outlined, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(child: Text('防剧透已折叠（第 ${_char.spoilerVol} 卷解锁 · 点击展开笔记）', style: muted)),
                      ],
                    ),
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(10)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('个人笔记', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(note, style: theme.textTheme.bodySmall?.copyWith(height: 1.55)),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: widget.onSearchAppearances,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('搜索全书出场'),
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () async {
                    final next = await BookCharacters.upsert(_char, enableHighlight: !hlOn);
                    ref.invalidate(chapterProvider);
                    if (mounted) setState(() => _char = next);
                  },
                  child: Text(hlOn ? '关闭高亮' : '开启高亮'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: widget.onEdit,
                  child: const Text('编辑'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读器中点击绑定了人物词条的高亮词时弹出的「角色浮窗底栏」。
Future<void> showCharacterReaderSheet(
  BuildContext context, {
  required String aid,
  required BookCharacter character,
  required String currentCid,
  required ReaderPalette palette,
  required Color accent,
  required void Function(List<String> searchTerms) onSearchAppearances,
  required VoidCallback onOpenDictionary,
  required VoidCallback onChanged,
}) {
  final sheetTheme = readerThemeData(Theme.of(context), palette, accent);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.bg,
    builder: (_) => Theme(
      data: sheetTheme,
      child: _ReaderCharacterSheet(
        aid: aid,
        initial: character,
        currentCid: currentCid,
        onSearchAppearances: onSearchAppearances,
        onOpenDictionary: onOpenDictionary,
        onChanged: onChanged,
      ),
    ),
  );
}

class _ReaderCharacterSheet extends ConsumerStatefulWidget {
  const _ReaderCharacterSheet({
    required this.aid,
    required this.initial,
    required this.currentCid,
    required this.onSearchAppearances,
    required this.onOpenDictionary,
    required this.onChanged,
  });

  final String aid;
  final BookCharacter initial;
  final String currentCid;
  final void Function(List<String> searchTerms) onSearchAppearances;
  final VoidCallback onOpenDictionary;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ReaderCharacterSheet> createState() => _ReaderCharacterSheetState();
}

class _ReaderCharacterSheetState extends ConsumerState<_ReaderCharacterSheet> {
  late BookCharacter _char = widget.initial;
  late final TextEditingController _note = TextEditingController(text: BookCharacters.noteOf(widget.initial));
  bool _revealed = false;
  bool _loadingMoegirl = false;
  String? _moegirlTip;

  @override
  void initState() {
    super.initState();
    BookCharacters.ensureAvatarDirLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _fetchMoegirl() async {
    if (_loadingMoegirl) return;
    setState(() {
      _loadingMoegirl = true;
      _moegirlTip = null;
    });
    try {
      final intro = await ref.read(moegirlApiProvider).fetchIntro(_char.name);
      if (!mounted) return;
      if (intro == null || intro.isEmpty) {
        setState(() => _moegirlTip = '萌娘百科未找到对应中文简介');
      } else {
        final next = await BookCharacters.upsert(_char.copyWith(cnSummary: intro), enableHighlight: _char.ruleId.isNotEmpty);
        if (mounted) setState(() => _char = next);
      }
    } catch (_) {
      if (mounted) setState(() => _moegirlTip = '获取萌娘百科简介失败');
    } finally {
      if (mounted) setState(() => _loadingMoegirl = false);
    }
  }

  Future<void> _saveNote() async {
    await BookCharacters.setNote(_char, _note.text);
    widget.onChanged();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final currentVol = BookCharacters.currentReadingVolume(widget.aid, currentCid: widget.currentCid);
    final hideSpoiler = _char.shouldHideSpoiler(currentVol) && !_revealed;
    final summaryText = _char.preferredSummary;
    final showMoegirlBtn = MoegirlApi.needsCnSummary(_char.summary, _char.cnSummary);
    final displayAliases = BookCharacter.cleanAliases(_char.aliases, name: _char.name, originalName: _char.originalName);
    final nameColor = readableHighlightColor(Color(_char.color), darkSurface: dark);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CharacterAvatar(char: _char, size: 54),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                _char.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: nameColor),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
                              child: Text(_char.role, style: theme.textTheme.labelSmall),
                            ),
                          ],
                        ),
                        if (_char.originalName.isNotEmpty && _char.originalName != _char.name) ...[
                          const SizedBox(height: 2),
                          Text(_char.originalName, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                        ],
                        if (displayAliases.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text('别名：${displayAliases.join(' / ')}', maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (summaryText.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(summaryText, maxLines: 6, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(height: 1.55)),
              ],
              if (showMoegirlBtn || _moegirlTip != null || _char.name.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (showMoegirlBtn)
                      TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                        onPressed: _loadingMoegirl ? null : _fetchMoegirl,
                        icon: _loadingMoegirl
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.translate, size: 15),
                        label: const Text('获取萌娘百科中文简介', style: TextStyle(fontSize: 12)),
                      ),
                    if (_char.name.isNotEmpty)
                      TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                        onPressed: () => launchUrl(MoegirlApi.pageUrl(_char.name), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('萌娘百科', style: TextStyle(fontSize: 12)),
                      ),
                    if (_moegirlTip != null) Text(_moegirlTip!, style: muted),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (hideSpoiler)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _revealed = true),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: scheme.outline),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.visibility_off_outlined, size: 18, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(child: Text('防剧透保护（第 ${_char.spoilerVol} 卷解锁）：点击展开查看或编辑笔记', style: muted)),
                      ],
                    ),
                  ),
                )
              else
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    label: const Text('个人笔记'),
                    hint: const Text('记录人物身份、关系、伏笔…', maxLines: 1, overflow: TextOverflow.ellipsis),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onSearchAppearances(_char.searchTerms);
                    },
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text('搜索全书出场'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onOpenDictionary();
                    },
                    child: const Text('人物词典'),
                  ),
                  const Spacer(),
                  if (!hideSpoiler)
                    FilledButton(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: _saveNote,
                      child: const Text('保存笔记'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 人物头像组件：优先展示本地裁剪图，其次 Bangumi 上半身特写（顶部对齐露脸），点击可放大查看完整立绘。
class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({required this.char, this.size = 48, this.allowPreview = true});

  final BookCharacter char;
  final double size;
  final bool allowPreview;

  void _showFullPortrait(BuildContext context, File? localFile) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: ColoredBox(
                  color: Colors.transparent,
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: localFile != null
                            ? Image.file(localFile, fit: BoxFit.contain)
                            : NetImage(
                                bgmCharacterFullUrl(char.avatarUrl),
                                fit: BoxFit.contain,
                                full: true,
                                loading: const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: Colors.white70)),
                                error: const Icon(Icons.broken_image_outlined, size: 48, color: Colors.white54),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: hz(ctx, '关闭'),
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
            if (char.name.isNotEmpty)
              Positioned(
                left: 24,
                right: 24,
                bottom: 24,
                child: SafeArea(
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                        child: Text(char.name, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fallbackColor = readableHighlightColor(Color(char.color), darkSurface: dark);
    final initial = char.name.trim().isEmpty ? '?' : String.fromCharCode(char.name.trim().runes.first);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: fallbackColor.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.24)),
      alignment: Alignment.center,
      child: Text(initial, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: fallbackColor)),
    );

    final localFile = BookCharacters.localAvatarFileSync(char.localAvatar);
    Widget box;
    if (localFile != null) {
      box = ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.file(localFile, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
      );
    } else if (char.avatarUrl.isNotEmpty) {
      final avatarUrl = bgmCharacterAvatarUrl(char.avatarUrl);
      final rawFallback = avatarUrl != char.avatarUrl
          ? NetImage(
              char.avatarUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              decodeSize: Size(size, size),
              loading: placeholder,
              error: placeholder,
            )
          : placeholder;
      box = ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: SizedBox(
          width: size,
          height: size,
          child: NetImage(
            avatarUrl,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            decodeSize: Size(size, size),
            loading: placeholder,
            error: rawFallback,
          ),
        ),
      );
    } else {
      return placeholder;
    }

    if (!allowPreview) return box;
    return GestureDetector(
      onTap: () => _showFullPortrait(context, localFile),
      child: box,
    );
  }
}

enum _ImportHighlightMode { mainOnly, allSelected, none }

/// 从 Bangumi 批量导入角色弹窗：拉取角色列表并按需补全中文名与常用称呼，支持分层高亮策略与自动分配高对比度色板。
class _BgmImportSheet extends ConsumerStatefulWidget {
  const _BgmImportSheet({required this.aid, required this.bookTitle});

  final String aid;
  final String bookTitle;

  @override
  ConsumerState<_BgmImportSheet> createState() => _BgmImportSheetState();
}

class _BgmImportSheetState extends ConsumerState<_BgmImportSheet> {
  final _cancel = CancelToken();
  bool _loading = true;
  bool _enriching = false;
  bool _importing = false;
  String _importStatus = '';
  int _enrichDone = 0;
  int _enrichTotal = 0;
  String? _error;
  List<BgmCharacter> _chars = const [];
  final _selected = <int>{};
  late final Set<int> _existingBgmIds;
  late final Set<String> _existingNames;
  _ImportHighlightMode _highlightMode = _ImportHighlightMode.mainOnly;

  @override
  void initState() {
    super.initState();
    final existing = BookCharacters.of(widget.aid);
    _existingBgmIds = {for (final c in existing) if (c.bgmId != null) c.bgmId!};
    _existingNames = {for (final c in existing) c.name.trim()};
    _load();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  bool _alreadyImported(BgmCharacter c) => _existingBgmIds.contains(c.id) || _existingNames.contains(c.displayName.trim());

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(bangumiProvider).characters(widget.aid, fallbackTitle: widget.bookTitle, forceRefresh: forceRefresh, cancelToken: _cancel);
      if (!mounted || _cancel.isCancelled) return;
      final mainSelectable = list.where((c) => !_alreadyImported(c) && c.relation.contains('主角')).map((c) => c.id).toList();
      _selected
        ..clear()
        ..addAll(mainSelectable.isNotEmpty ? mainSelectable : list.where((c) => !_alreadyImported(c)).take(6).map((c) => c.id));
      setState(() {
        _chars = list;
        _loading = false;
      });
      if (list.any((c) => !c.enriched)) {
        setState(() => _enriching = true);
        final enriched = await ref.read(bangumiProvider).enrichCharacters(
          widget.aid,
          list,
          maxFetch: 20,
          cancelToken: _cancel,
          onProgress: (done, total, cur) {
            if (!mounted || _cancel.isCancelled) return;
            setState(() {
              _enrichDone = done;
              _enrichTotal = total;
              _chars = cur;
            });
          },
        );
        if (mounted && !_cancel.isCancelled) {
          setState(() {
            _chars = enriched;
            _selected.removeWhere((id) => enriched.any((c) => c.id == id && _alreadyImported(c)));
            _enriching = false;
          });
        }
      }
    } catch (e) {
      if (mounted && !_cancel.isCancelled) {
        setState(() {
          _loading = false;
          _enriching = false;
          _error = '拉取 Bangumi 角色失败：$e';
        });
      }
    }
  }

  Future<void> _importSelected() async {
    if (_importing) return;
    final selectedIds = Set<int>.of(_selected);
    if (selectedIds.isEmpty) return;

    setState(() {
      _importing = true;
      _importStatus = '正在准备导入…';
    });

    try {
      var list = _chars;
      // 若用户勾选了超过前 20 名尚未补全详情的角色，先全部补全中文名与带空格原名
      final needEnrich = {for (final c in list) if (selectedIds.contains(c.id) && !c.enriched) c.id};
      if (needEnrich.isNotEmpty) {
        list = await ref.read(bangumiProvider).enrichCharacters(
          widget.aid,
          list,
          targetIds: needEnrich,
          cancelToken: _cancel,
          onProgress: (done, total, cur) {
            if (!mounted || _cancel.isCancelled) return;
            setState(() {
              _chars = cur;
              _importStatus = '正在补全所选角色中文名（$done/$total）…';
            });
          },
        );
        if (!mounted || _cancel.isCancelled) return;
      }

      final chosen = list.where((c) => selectedIds.contains(c.id)).toList();
      if (chosen.isEmpty) return;

      // 结合本书已有角色统一推导常用中文姓/名称呼，自动避开同姓冲突并清除冗余日文带空格别名
      final existing = BookCharacters.of(widget.aid);
      final combinedBatch = [
        for (final e in existing)
          (name: e.name, originalName: e.originalName, spacedName: '', role: e.role, aliases: e.aliases),
        for (final c in chosen)
          (
            name: c.displayName,
            originalName: c.name,
            spacedName: c.spacedName,
            role: CharacterRole.fromBgmRelation(c.relation),
            aliases: c.aliases,
          ),
      ];
      final derivedAll = BookCharacter.deriveCallNamesForBatch(combinedBatch);
      final derivedForChosen = derivedAll.sublist(existing.length);

      // 为选中的主角静默尝试拉取萌娘百科中文简介（最多 6 位，失败不阻塞导入）
      final cnIntroById = <int, String>{};
      final mainNeedCn = chosen.where((c) => CharacterRole.fromBgmRelation(c.relation) == CharacterRole.main && MoegirlApi.needsCnSummary(c.summary, '')).take(6).toList();
      if (mainNeedCn.isNotEmpty) {
        if (mounted) setState(() => _importStatus = '正在为主角获取中文简介…');
        final api = ref.read(moegirlApiProvider);
        await Future.wait(mainNeedCn.map((c) async {
          try {
            final intro = await api.fetchIntro(c.displayName).timeout(const Duration(seconds: 5));
            if (intro != null && intro.isNotEmpty) cnIntroById[c.id] = intro;
          } catch (_) {}
        }));
      }
      if (!mounted || _cancel.isCancelled) return;

      final usedColors = {for (final c in existing) c.color};
      final palette = [
        ...characterHighlightColors.where((c) => !usedColors.contains(c)),
        ...characterHighlightColors.where(usedColors.contains),
      ];
      final toAdd = <BookCharacter>[];
      for (var i = 0; i < chosen.length; i++) {
        final c = chosen[i];
        toAdd.add(
          BookCharacter(
            id: '',
            aid: widget.aid,
            name: c.displayName,
            originalName: c.name,
            aliases: derivedForChosen[i],
            role: CharacterRole.fromBgmRelation(c.relation),
            bgmId: c.id,
            avatarUrl: c.img,
            summary: c.summary,
            cnSummary: cnIntroById[c.id] ?? '',
            color: palette[i % palette.length],
          ),
        );
      }

      await BookCharacters.importMany(
        widget.aid,
        toAdd,
        shouldHighlight: (c) => switch (_highlightMode) {
          _ImportHighlightMode.mainOnly => c.role == CharacterRole.main,
          _ImportHighlightMode.allSelected => true,
          _ImportHighlightMode.none => false,
        },
      );
      if (mounted) Navigator.pop(context, toAdd.length);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allSelectable = [for (final c in _chars) if (!_alreadyImported(c)) c.id];
    final mainSelectable = [for (final c in _chars) if (!_alreadyImported(c) && c.relation.contains('主角')) c.id];
    final allPicked = allSelectable.isNotEmpty && allSelectable.every(_selected.contains);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scroll) => SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('从 Bangumi 导入角色', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (_importing && _importStatus.isNotEmpty)
                          Text(_importStatus, style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary))
                        else if (_enriching && _enrichTotal > 0)
                          Text('正在补全简体中文名与称呼（$_enrichDone/$_enrichTotal）…', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: hz(context, '重新拉取'),
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: (_loading || _importing) ? null : () => _load(forceRefresh: true),
                  ),
                ],
              ),
            ),
            if (_loading || _enriching || _importing) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                            const SizedBox(height: 12),
                            OutlinedButton(onPressed: () => _load(forceRefresh: true), child: const Text('重试')),
                          ],
                        ),
                      ),
                    )
                  : _chars.isEmpty
                  ? Center(child: Text('Bangumi 暂未收录本书角色', style: TextStyle(color: scheme.onSurfaceVariant)))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: _chars.length,
                      itemBuilder: (context, i) {
                        final c = _chars[i];
                        final imported = _alreadyImported(c);
                        final checked = _selected.contains(c.id);
                        final cleanAl = BookCharacter.cleanAliases(c.aliases, name: c.displayName, originalName: c.name);
                        final avatarUrl = bgmCharacterAvatarUrl(c.img);
                        final subParts = [
                          if (c.nameCn.isNotEmpty && c.name != c.nameCn) c.name,
                          if (cleanAl.isNotEmpty) '别名：${cleanAl.take(3).join(' / ')}',
                        ];
                        return CheckboxListTile(
                          value: checked,
                          onChanged: _importing ? null : (v) => setState(() => v == true ? _selected.add(c.id) : _selected.remove(c.id)),
                          secondary: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: avatarUrl.isNotEmpty
                                  ? NetImage(
                                      avatarUrl,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.topCenter,
                                      decodeSize: const Size(44, 44),
                                      error: Container(color: scheme.surfaceContainerHigh, child: const Icon(Icons.person_outline, size: 22)),
                                    )
                                  : Container(color: scheme.surfaceContainerHigh, child: const Icon(Icons.person_outline, size: 22)),
                            ),
                          ),
                          title: Row(
                            children: [
                              Flexible(child: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              if (c.relation.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: c.relation.contains('主角') ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    c.relation,
                                    style: theme.textTheme.labelSmall?.copyWith(color: c.relation.contains('主角') ? scheme.onPrimaryContainer : null),
                                  ),
                                ),
                              ],
                              if (imported) ...[
                                const SizedBox(width: 6),
                                Text('已导入', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                              ],
                            ],
                          ),
                          subtitle: subParts.isEmpty ? null : Text(subParts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Text('正文高亮：', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        const SizedBox(width: 4),
                        ChoiceChip(
                          label: const Text('仅主角'),
                          selected: _highlightMode == _ImportHighlightMode.mainOnly,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: _importing ? null : (_) => setState(() => _highlightMode = _ImportHighlightMode.mainOnly),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('全部所选'),
                          selected: _highlightMode == _ImportHighlightMode.allSelected,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: _importing ? null : (_) => setState(() => _highlightMode = _ImportHighlightMode.allSelected),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('暂不开'),
                          selected: _highlightMode == _ImportHighlightMode.none,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: _importing ? null : (_) => setState(() => _highlightMode = _ImportHighlightMode.none),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (mainSelectable.isNotEmpty)
                        TextButton(
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: _importing
                              ? null
                              : () => setState(() {
                                    _selected
                                      ..clear()
                                      ..addAll(mainSelectable);
                                  }),
                          child: Text('只选主角 (${mainSelectable.length})'),
                        ),
                      TextButton(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: (_importing || allSelectable.isEmpty)
                            ? null
                            : () => setState(() => allPicked ? _selected.clear() : _selected.addAll(allSelectable)),
                        child: Text(allPicked ? '取消全选' : '全选 (${allSelectable.length})'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: (_importing || _selected.isEmpty) ? null : _importSelected,
                        child: Text(_importing ? '导入中…' : '导入所选 (${_selected.length})'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 添加 / 编辑人物与设定词条弹窗。
class _CharacterEditorSheet extends ConsumerStatefulWidget {
  const _CharacterEditorSheet({required this.aid, this.initial, required this.catalogue});

  final String aid;
  final BookCharacter? initial;
  final List<CatVolume> catalogue;

  @override
  ConsumerState<_CharacterEditorSheet> createState() => _CharacterEditorSheetState();
}

class _CharacterEditorSheetState extends ConsumerState<_CharacterEditorSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _orig = TextEditingController(text: widget.initial?.originalName ?? '');
  late final TextEditingController _aliasInput = TextEditingController();
  late final TextEditingController _summary = TextEditingController(text: widget.initial?.summary ?? '');
  late final TextEditingController _cnSummary = TextEditingController(text: widget.initial?.cnSummary ?? '');
  late final TextEditingController _note = TextEditingController(text: widget.initial == null ? '' : BookCharacters.noteOf(widget.initial!));
  late final List<String> _aliases = List<String>.of(widget.initial?.aliases ?? const []);
  late String _role = widget.initial?.role ?? CharacterRole.support;
  late int _color = widget.initial?.color ?? _pickNextColor();
  late bool _highlight = widget.initial == null ? true : BookCharacters.isHighlightActive(widget.initial!);
  late int _spoilerVol = widget.initial?.spoilerVol ?? 0;
  late final String _avatarUrl = widget.initial?.avatarUrl ?? '';
  late String _localAvatar = widget.initial?.localAvatar ?? '';
  String? _nameError;

  int _pickNextColor() {
    final used = {for (final c in BookCharacters.of(widget.aid)) c.color};
    return characterHighlightColors.firstWhere((c) => !used.contains(c), orElse: () => characterHighlightColors.first);
  }

  @override
  void dispose() {
    _name.dispose();
    _orig.dispose();
    _aliasInput.dispose();
    _summary.dispose();
    _cnSummary.dispose();
    _note.dispose();
    super.dispose();
  }

  void _addAlias() {
    final raw = _aliasInput.text.trim();
    if (raw.isEmpty) return;
    for (final part in raw.split(RegExp(r'[,，/、]'))) {
      final t = part.trim();
      if (t.isNotEmpty && t != _name.text.trim() && !_aliases.contains(t)) {
        _aliases.add(t);
      }
    }
    _aliasInput.clear();
    setState(() {});
  }

  Future<void> _pickLocalAvatar() async {
    if (kIsWeb) return;
    final picked = await FilePicker.pickFile(type: FileType.image);
    final path = picked?.path;
    if (path == null || !mounted) return;
    final bytes = await File(path).readAsBytes();
    if (!mounted) return;
    await _cropAndSaveAvatar(bytes);
  }

  Future<void> _pickBookIllustrationAvatar() async {
    if (kIsWeb) return;
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _BookIllustrationPickerPage(aid: widget.aid, catalogue: widget.catalogue)),
    );
    if (url == null || !mounted) return;
    try {
      final bytes = await ref.read(imageStoreProvider).load(url);
      if (!mounted) return;
      await _cropAndSaveAvatar(bytes);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载图片失败：$e')));
    }
  }

  Future<void> _cropAndSaveAvatar(Uint8List rawBytes) async {
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => _AvatarCropPage(bytes: rawBytes)),
    );
    if (cropped == null || !mounted) return;
    final key = widget.initial?.id.isNotEmpty == true ? widget.initial!.id : 'new';
    final fileName = await BookCharacters.saveLocalAvatar(key, cropped);
    if (_localAvatar.isNotEmpty && _localAvatar != widget.initial?.localAvatar) {
      await BookCharacters.deleteLocalAvatar(_localAvatar);
    }
    if (mounted) setState(() => _localAvatar = fileName);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请输入名称');
      return;
    }
    if (_aliasInput.text.trim().isNotEmpty) _addAlias();
    final oldLocal = widget.initial?.localAvatar ?? '';
    final base = widget.initial ?? BookCharacter(id: '', aid: widget.aid, name: name);
    await BookCharacters.upsert(
      base.copyWith(
        name: name,
        originalName: _orig.text.trim(),
        aliases: _aliases,
        role: _role,
        avatarUrl: _avatarUrl,
        localAvatar: _localAvatar,
        summary: _summary.text.trim(),
        cnSummary: _cnSummary.text.trim(),
        spoilerVol: _spoilerVol,
        color: _color,
      ),
      enableHighlight: _highlight,
      note: _note.text,
    );
    if (oldLocal.isNotEmpty && oldLocal != _localAvatar) {
      await BookCharacters.deleteLocalAvatar(oldLocal);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final init = widget.initial;
    if (init == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${init.name}」？'),
        content: const Text('将同时移除该人物绑定的正文高亮与笔记。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await BookCharacters.delete(widget.aid, init.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewChar = BookCharacter(
      id: widget.initial?.id ?? '',
      aid: widget.aid,
      name: _name.text.trim().isEmpty ? '人物' : _name.text.trim(),
      avatarUrl: _avatarUrl,
      localAvatar: _localAvatar,
      color: _color,
    );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.initial == null ? '添加人物 / 设定' : '编辑人物 / 设定', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (widget.initial != null)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: _delete,
                      child: const Text('删除'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _CharacterAvatar(char: previewChar, size: 60, allowPreview: false),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (!kIsWeb) ...[
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: _pickBookIllustrationAvatar,
                            icon: const Icon(Icons.photo_library_outlined, size: 16),
                            label: const Text('书内插图裁剪'),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: _pickLocalAvatar,
                            icon: const Icon(Icons.upload_outlined, size: 16),
                            label: const Text('本地选图裁剪'),
                          ),
                        ],
                        if (_localAvatar.isNotEmpty)
                          TextButton(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: () => setState(() => _localAvatar = ''),
                            child: const Text('清除自定头像'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                onChanged: (_) => setState(() => _nameError = null),
                decoration: InputDecoration(label: const Text('显示名称（中文名）'), errorText: _nameError),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _orig,
                decoration: const InputDecoration(label: Text('原名（可选，如日文名）')),
              ),
              const SizedBox(height: 12),
              XSegments<String>(
                title: '定位',
                value: _role,
                options: const {CharacterRole.main: '主角', CharacterRole.support: '配角', CharacterRole.setting: '设定'},
                onChanged: (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _aliasInput,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addAlias(),
                      decoration: const InputDecoration(label: Text('添加别名 / 昵称'), hint: Text('支持用逗号分隔多个', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _addAlias, child: const Text('添加')),
                ],
              ),
              if (_aliases.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in _aliases)
                      InputChip(
                        label: Text(a),
                        onDeleted: () => setState(() => _aliases.remove(a)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开启正文高亮'),
                subtitle: const Text('在阅读器中自动高亮名称与所有别名，点按弹出人物卡'),
                value: _highlight,
                onChanged: (v) => setState(() => _highlight = v),
              ),
              if (_highlight) ...[
                const SizedBox(height: 6),
                ColorPickerField(
                  color: _color,
                  highlight: true,
                  sample: _name.text.trim().isEmpty ? '人物名' : _name.text.trim(),
                  onChanged: (c) => setState(() => _color = c),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('防剧透卷号'),
                        Text(
                          _spoilerVol == 0 ? '不折叠个人笔记' : '读到第 $_spoilerVol 卷前折叠个人笔记',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: hz(context, '减少卷号'),
                    onPressed: _spoilerVol <= 0 ? null : () => setState(() => _spoilerVol--),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(_spoilerVol == 0 ? '关' : '第$_spoilerVol卷', textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    tooltip: hz(context, '增加卷号'),
                    onPressed: () => setState(() => _spoilerVol++),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cnSummary,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(label: Text('中文简介（萌娘百科/自填，可选）')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _summary,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(label: Text('原简介（Bangumi，可选）')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(label: Text('个人笔记（与高亮备注互通）')),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _save,
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 从本书已缓存插图和卷封面中挑选一张图片用于裁剪人物头像。
class _BookIllustrationPickerPage extends ConsumerStatefulWidget {
  const _BookIllustrationPickerPage({required this.aid, required this.catalogue});

  final String aid;
  final List<CatVolume> catalogue;

  @override
  ConsumerState<_BookIllustrationPickerPage> createState() => _BookIllustrationPickerPageState();
}

class _BookIllustrationPickerPageState extends ConsumerState<_BookIllustrationPickerPage> {
  late final Future<List<String>> _images = _collectCachedImages();

  Future<List<String>> _collectCachedImages() async {
    final urls = <String>{};
    final local = isLocalAid(widget.aid);
    for (final v in widget.catalogue) {
      for (final c in v.chapters) {
        Content? content;
        if (local) {
          try {
            content = await LocalBooks.loadChapter(widget.aid, c.cid);
          } catch (_) {}
        } else {
          if (!ChapterCache.has(widget.aid, c.cid)) continue;
          content = await ChapterCache.get(widget.aid, c.cid);
        }
        if (content != null) {
          for (final u in content.images) {
            if (u.isNotEmpty) urls.add(u);
          }
        }
      }
    }
    for (final u in Volumes.covers(widget.aid).values) {
      final clean = splitCrop(u).url;
      if (clean.isNotEmpty) urls.add(clean);
    }
    return urls.toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('从本书插图选择')),
      body: FutureBuilder<List<String>>(
        future: _images,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final urls = snap.data!;
          if (urls.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('暂无已缓存的本书插图。\n阅读过插图章节或缓存本书后即可在此选择。', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.78),
            itemCount: urls.length,
            itemBuilder: (context, i) => InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.pop(context, urls[i]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: scheme.surfaceContainer,
                  child: NetImage(urls[i], fit: BoxFit.cover),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 1:1 方形头像裁剪页：拖动、双指缩放框选头像，导出 256×256 PNG 字节。
class _AvatarCropPage extends StatefulWidget {
  const _AvatarCropPage({required this.bytes});

  final Uint8List bytes;

  @override
  State<_AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<_AvatarCropPage> {
  final _tc = TransformationController();
  late final Future<ui.Image> _decoded = _decode(widget.bytes);
  Size? _laidOut;
  bool _saving = false;

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  static Size _fill(double w, double h, double box) {
    final s = math.max(box / w, box / h);
    return Size(w * s, h * s);
  }

  Future<void> _confirm(ui.Image img, double box) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final child = _fill(img.width.toDouble(), img.height.toDouble(), box);
      final scale = _tc.value.getMaxScaleOnAxis();
      final t = _tc.value.getTranslation();
      final left = (-t.x / scale / child.width).clamp(0.0, 1.0);
      final top = (-t.y / scale / child.height).clamp(0.0, 1.0);
      final width = (box / scale / child.width).clamp(0.01, 1.0 - left);
      final height = (box / scale / child.height).clamp(0.01, 1.0 - top);

      final src = Rect.fromLTWH(left * img.width, top * img.height, width * img.width, height * img.height);
      const outSize = 256;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(img, src, const Rect.fromLTWH(0, 0, 256, 256), Paint()..filterQuality = FilterQuality.high);
      final outImg = await recorder.endRecording().toImage(outSize, outSize);
      final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
      outImg.dispose();
      if (mounted && data != null) {
        Navigator.pop(context, data.buffer.asUint8List());
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('裁剪头像', style: TextStyle(color: Colors.white)),
    ),
    body: FutureBuilder<ui.Image>(
      future: _decoded,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final img = snap.data!;
        return LayoutBuilder(
          builder: (context, c) {
            final box = math.min(c.maxWidth - 48, c.maxHeight - 120).clamp(160.0, 320.0);
            final frame = Size(box, box);
            final child = _fill(img.width.toDouble(), img.height.toDouble(), box);
            if (_laidOut != frame) {
              _laidOut = frame;
              _tc.value = Matrix4.translationValues((box - child.width) / 2, (box - child.height) / 2, 0);
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
                            child: SizedBox.fromSize(size: child, child: Image.memory(widget.bytes, fit: BoxFit.fill)),
                          ),
                          IgnorePointer(child: CustomPaint(size: frame, painter: _SquareFramePainter())),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Row(
                    children: [
                      const Expanded(child: Text('拖动、双指缩放框选头像区域', style: TextStyle(color: Colors.white70, fontSize: 13))),
                      FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                        onPressed: _saving ? null : () => _confirm(img, box),
                        child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('完成'),
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

class _SquareFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final frame = Offset.zero & size;
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(frame.inflate(4000))
        ..addRRect(RRect.fromRectAndRadius(frame, Radius.circular(size.width * 0.24))),
      Paint()..color = Colors.black.withValues(alpha: 0.65),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, Radius.circular(size.width * 0.24)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
