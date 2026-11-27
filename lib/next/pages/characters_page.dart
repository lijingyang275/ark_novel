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
import 'package:hive_ce_flutter/hive_flutter.dart';
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
import '../motion.dart';
import '../reader/reader_body.dart' show readableHighlightColor;
import '../reader/reader_sheets.dart';
import '../routes.dart';
import '../rules.dart' show RuleNotes;
import '../stats.dart';
import '../text.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../x_list.dart';
import 'book_search_sheet.dart';
import 'novel_page.dart' show novelProvider;

part 'characters/character_detail_sheets.dart';
part 'characters/character_bgm_import.dart';
part 'characters/character_editor.dart';

/// 人物 / 设定词典页面（路由 `/novel/:aid/characters`）。
class CharactersPage extends ConsumerStatefulWidget {
  const CharactersPage({super.key, required this.aid});

  final String aid;

  @override
  ConsumerState<CharactersPage> createState() => _CharactersPageState();
}

class _CharactersPageState extends ConsumerState<CharactersPage> {
  static final _wsRe = RegExp(r'\s+');

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
      final batchUpdates = <String, String>{};
      await Future.wait(batch.map((c) async {
        if (_cancelBatchCn) return;
        try {
          final intro = await api.fetchIntro(c.name);
          if (intro != null && intro.isNotEmpty) {
            batchUpdates[c.id] = intro;
          }
        } catch (_) {}
        if (mounted) setState(() => _batchCnDone++);
      }));
      if (batchUpdates.isNotEmpty) {
        hits += await BookCharacters.batchUpdateCnSummaries(widget.aid, batchUpdates, onlyIfEmpty: true);
      }
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
          _snack('已切换为仅主角开启正文高亮');
        }
      case 'hl_none':
        await BookCharacters.setHighlightForAll(widget.aid, predicate: (_) => false);
        if (mounted) {
          _snack('已关闭全部正文高亮');
        }
      case 'normalize':
        final n = await BookCharacters.normalizeExisting(widget.aid);
        if (mounted) {
          _snack(n > 0 ? '已整理 $n 位人物的常用称呼与冗余日文别名' : '所有人物的称呼与别名均已规范');
        }
      case 'fetch_cn':
        await _batchFetchCnSummaries();
      case 'clear_support':
        final all = BookCharacters.of(widget.aid);
        final notes = Hive.isBoxOpen('session') ? RuleNotes.of(widget.aid) : const <String, String>{};
        final toDelete = {
          for (final c in all)
            if (c.role != CharacterRole.main && (notes[c.effectiveNoteKey] ?? '').trim().isEmpty) c.id,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allChars = BookCharacters.of(widget.aid);
    final notes = Hive.isBoxOpen('session') ? RuleNotes.of(widget.aid) : const <String, String>{};
    final activeRuleIds = BookCharacters.activeHighlightRuleIds();
    final hlIds = {for (final c in allChars) if (c.ruleId.isNotEmpty && activeRuleIds.contains(c.ruleId)) c.id};
    final q = _search.trim().toLowerCase();
    final chars = allChars.where((c) {
      if (_roleFilter.isNotEmpty && c.role != _roleFilter) return false;
      if (_onlyHighlighted && !hlIds.contains(c.id)) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.originalName.toLowerCase().contains(q) ||
          c.aliases.any((a) => a.toLowerCase().contains(q)) ||
          c.preferredSummary.toLowerCase().contains(q) ||
          (notes[c.effectiveNoteKey] ?? '').toLowerCase().contains(q);
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
      body: AppCrossfade(
        fill: true,
        child: allChars.isEmpty
            ? KeyedSubtree(
                key: const ValueKey('empty'),
                child: contentWidth(
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
                ),
              )
            : KeyedSubtree(
                key: const ValueKey('list'),
                child: contentWidth(
                  Column(
                    children: [
                      AppCollapse(
                        visible: _batchFetchingCn,
                        child: Container(
                          width: double.infinity,
                          color: scheme.surfaceContainerLow,
                          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                          child: Row(
                            children: [
                              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '正在从萌娘百科补全中文简介（$_batchCnDone/$_batchCnTotal）…',
                                  style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                                ),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                onPressed: () => setState(() => _cancelBatchCn = true),
                                child: const Text('停止'),
                              ),
                            ],
                          ),
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
                                  suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                  suffixIcon: AppReveal(
                                    visible: _search.isNotEmpty,
                                    beginScale: 0.82,
                                    child: IconButton(
                                      tooltip: hz(context, '清空'),
                                      icon: const Icon(Icons.close, size: 17),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _search = '');
                                      },
                                    ),
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
                        child: AppCrossfade(
                          fill: true,
                          child: chars.isEmpty
                              ? Center(
                                  key: const ValueKey('no-match'),
                                  child: Text('没有匹配的人物词条', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                                )
                              : ListView.builder(
                                  key: ValueKey('chars-${_roleFilter}_$_onlyHighlighted'),
                                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
                                  itemCount: chars.length,
                                  itemBuilder: (context, i) => _buildCard(chars[i], currentVol, hlIds.contains(chars[i].id), notes[chars[i].effectiveNoteKey] ?? ''),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildCard(BookCharacter c, int currentVol, bool hlOn, String note) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
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
                        summaryText.replaceAll(_wsRe, ' '),
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
                              hideSpoiler ? '个人笔记已折叠（第 ${c.spoilerVol} 卷解锁）' : note.replaceAll(_wsRe, ' '),
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

/// 全屏立绘弹窗过渡：持有并释放 [CurvedAnimation]，避免每次动画帧重复创建泄漏。
class _PortraitDialogTransition extends StatefulWidget {
  const _PortraitDialogTransition({required this.animation, required this.reduce, required this.child});

  final Animation<double> animation;
  final bool reduce;
  final Widget child;

  @override
  State<_PortraitDialogTransition> createState() => _PortraitDialogTransitionState();
}

class _PortraitDialogTransitionState extends State<_PortraitDialogTransition> {
  late CurvedAnimation _fade;
  late CurvedAnimation _scaleCurve;
  late Animation<double> _scale;

  void _bind(Animation<double> animation) {
    _fade = CurvedAnimation(parent: animation, curve: AppMotion.decelerate, reverseCurve: AppMotion.exit);
    _scaleCurve = CurvedAnimation(parent: animation, curve: AppMotion.curve, reverseCurve: AppMotion.exit);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(_scaleCurve);
  }

  @override
  void initState() {
    super.initState();
    _bind(widget.animation);
  }

  @override
  void didUpdateWidget(_PortraitDialogTransition old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      _fade.dispose();
      _scaleCurve.dispose();
      _bind(widget.animation);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _scaleCurve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reduce) return FadeTransition(opacity: _fade, child: widget.child);
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// 人物头像组件：优先展示内存预览/本地裁剪图，其次 Bangumi 上半身特写（顶部对齐露脸），点击可放大查看完整立绘。
class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({required this.char, this.size = 48, this.allowPreview = true, this.previewBytes});

  final BookCharacter char;
  final double size;
  final bool allowPreview;
  final Uint8List? previewBytes;

  void _showFullPortrait(BuildContext context, File? localFile) {
    final reduce = AppMotion.reduce(context);
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final maxPx = math.min(2048, (math.max(screen.width, screen.height) * dpr).ceil().clamp(720, 2048));
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      transitionDuration: reduce ? AppMotion.instant : AppMotion.standard,
      transitionBuilder: (ctx, animation, _, child) => _PortraitDialogTransition(animation: animation, reduce: reduce, child: child),
      pageBuilder: (ctx, _, _) => Material(
        type: MaterialType.transparency,
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
                            ? Image.file(localFile, fit: BoxFit.contain, cacheWidth: maxPx)
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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (size * dpr).ceil().clamp(48, 320);
    final fallbackColor = readableHighlightColor(Color(char.color), darkSurface: dark);
    final initial = char.name.trim().isEmpty ? '?' : String.fromCharCode(char.name.trim().runes.first);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: fallbackColor.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.24)),
      alignment: Alignment.center,
      child: Text(initial, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: fallbackColor)),
    );

    final localFile = previewBytes != null ? null : BookCharacters.localAvatarFileSync(char.localAvatar);
    Widget box;
    if (previewBytes != null && previewBytes!.isNotEmpty) {
      box = ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.memory(previewBytes!, width: size, height: size, fit: BoxFit.cover, cacheWidth: cachePx, cacheHeight: cachePx, errorBuilder: (_, _, _) => placeholder),
      );
    } else if (localFile != null) {
      box = ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.file(localFile, width: size, height: size, fit: BoxFit.cover, cacheWidth: cachePx, cacheHeight: cachePx, errorBuilder: (_, _, _) => placeholder),
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
    return AppPressScale(
      scale: 0.94,
      child: GestureDetector(
        onTap: () => _showFullPortrait(context, localFile),
        child: box,
      ),
    );
  }
}
