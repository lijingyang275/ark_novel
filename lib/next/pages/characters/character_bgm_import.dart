part of '../characters_page.dart';

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
                        AppCollapse(
                          visible: (_importing && _importStatus.isNotEmpty) || (_enriching && _enrichTotal > 0),
                          child: _importing && _importStatus.isNotEmpty
                              ? Text(_importStatus, style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary, fontFeatures: const [FontFeature.tabularFigures()]))
                              : Text('正在补全简体中文名与称呼（$_enrichDone/$_enrichTotal）…', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
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
            AppCollapse(visible: _loading || _enriching || _importing, child: const LinearProgressIndicator(minHeight: 2)),
            Expanded(
              child: AppCrossfade(
                fill: true,
                child: _loading
                    ? const Center(key: ValueKey('loading'), child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        key: const ValueKey('error'),
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
                    ? Center(key: const ValueKey('empty'), child: Text('Bangumi 暂未收录本书角色', style: TextStyle(color: scheme.onSurfaceVariant)))
                    : ListView.builder(
                        key: const ValueKey('list'),
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
