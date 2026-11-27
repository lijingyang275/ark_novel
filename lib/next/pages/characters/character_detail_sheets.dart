part of '../characters_page.dart';

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
        await BookCharacters.batchUpdateCnSummaries(widget.aid, {_char.id: intro});
        final next = BookCharacters.byId(widget.aid, _char.id) ?? _char.copyWith(cnSummary: intro);
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
            AppCollapse(
              visible: summaryText.isNotEmpty,
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: AppCrossfade(
                  alignment: Alignment.topLeft,
                  child: Text(summaryText, key: ValueKey(summaryText), style: theme.textTheme.bodyMedium?.copyWith(height: 1.6, fontSize: 13.5)),
                ),
              ),
            ),
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
              AnimatedSize(
                duration: AppMotion.dur(context, AppMotion.fast),
                curve: AppMotion.curve,
                alignment: Alignment.topCenter,
                child: AppCrossfade(
                  alignment: Alignment.topCenter,
                  child: hideSpoiler
                      ? InkWell(
                          key: const ValueKey('spoiler-hidden'),
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
                      : Container(
                          key: const ValueKey('spoiler-shown'),
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
        await BookCharacters.batchUpdateCnSummaries(widget.aid, {_char.id: intro});
        final next = BookCharacters.byId(widget.aid, _char.id) ?? _char.copyWith(cnSummary: intro);
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
              AppCollapse(
                visible: summaryText.isNotEmpty,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppCrossfade(
                    alignment: Alignment.topLeft,
                    child: Text(summaryText, key: ValueKey(summaryText), maxLines: 6, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(height: 1.55)),
                  ),
                ),
              ),
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
              AnimatedSize(
                duration: AppMotion.dur(context, AppMotion.fast),
                curve: AppMotion.curve,
                alignment: Alignment.topCenter,
                child: AppCrossfade(
                  alignment: Alignment.topCenter,
                  child: hideSpoiler
                      ? InkWell(
                          key: const ValueKey('reader-spoiler-hidden'),
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
                      : TextField(
                          key: const ValueKey('reader-spoiler-shown'),
                          controller: _note,
                          minLines: 2,
                          maxLines: 6,
                          decoration: InputDecoration(
                            label: const Text('个人笔记'),
                            hint: const Text('记录人物身份、关系、伏笔…', maxLines: 1, overflow: TextOverflow.ellipsis),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
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
                  AppReveal(
                    visible: !hideSpoiler,
                    beginScale: 0.92,
                    child: FilledButton(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: _saveNote,
                      child: const Text('保存笔记'),
                    ),
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
