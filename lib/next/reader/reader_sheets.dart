import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../bookmarks.dart';
import '../cache.dart';
import '../env.dart';
import '../fonts.dart';
import '../highlights.dart';
import '../motion.dart';
import '../read_state.dart';
import '../rules.dart';
import '../settings.dart';
import '../text.dart';
import '../theme.dart';
import '../theme_doodle.dart';
import '../theme_squire.dart';
import '../x_list.dart';
import 'reader_bg.dart';
import 'reader_body.dart';
import 'reader_chrome.dart';
import 'reader_tts.dart';

/// 阅读器底色与前景色。
class ReaderPalette {
  const ReaderPalette(this.bg, this.fg);

  final Color bg;
  final Color fg;
}

/// 「晴空」背景的章节标题色和装饰小旗色。
const readerSkyAccent = (Color(0xFFA8452F), Color(0xFFD9A03F));

/// 根据阅读器背景编号推导底色与正文字色。
ReaderPalette readerPaletteOf(ReaderPrefs prefs, ColorScheme scheme) => switch (prefs.theme) {
  0 => const ReaderPalette(Color(0xFFF6F1E7), Color(0xFF2B2A27)),
  1 => const ReaderPalette(Color(0xFFCFE6D0), Color(0xFF263A27)),
  2 => const ReaderPalette(Color(0xFF1C1C1A), Color(0xFFBDBBB2)),
  4 => const ReaderPalette(Colors.black, Color(0xFF9E9C94)), // AMOLED 纯黑，字再暗一点免得刺眼
  5 => const ReaderPalette(Color(0xFFF4ECDC), Color(0xFF3B2C20)), // 晴空：云朵的米白底、深褐字，章节标题赭红带旗
  _ => ReaderPalette(scheme.surface, scheme.onSurface),
};

/// 章节标题的颜色和标题下的装饰线：「晴空」背景是三角旗；角色主题是蜡笔线加小图案（发色按正文背景深浅挑）；其余没有。
(Color, Widget Function(double))? readerHeadingAccent(BuildContext context, ReaderPrefs prefs, ReaderPalette palette) {
  if (prefs.theme == 5) return (readerSkyAccent.$1, (w) => PennantRule(line: readerSkyAccent.$1, flag: readerSkyAccent.$2, width: w));
  final art = CharacterArt.of(context);
  if (art == null) return null;
  final line = palette.bg.computeLuminance() < 0.25 ? art.accentDark : art.accentLight;
  return (line, (w) => DoodleRule(motif: art.motif, line: line, accent: art.secondary, width: w));
}

/// 从阅读器当前背景推导完整明暗 [ThemeData]，供错误态 `StatePanel`、目录/书签/备注弹窗、朗读面板与设置面板统一使用。
ThemeData readerThemeData(ThemeData app, ReaderPalette palette, Color? accent) {
  final brightness = ThemeData.estimateBrightnessForColor(palette.bg);
  final isDark = brightness == Brightness.dark;
  final primary = accent ?? app.colorScheme.primary;
  final onPrimary = ThemeData.estimateBrightnessForColor(primary) == Brightness.dark ? Colors.white : const Color(0xFF141413);
  final scheme = app.colorScheme.copyWith(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    surface: palette.bg,
    surfaceContainerLowest: palette.bg,
    surfaceContainerLow: Color.alphaBlend(palette.fg.withValues(alpha: 0.04), palette.bg),
    surfaceContainer: Color.alphaBlend(palette.fg.withValues(alpha: 0.06), palette.bg),
    surfaceContainerHigh: Color.alphaBlend(palette.fg.withValues(alpha: 0.09), palette.bg),
    surfaceContainerHighest: Color.alphaBlend(palette.fg.withValues(alpha: 0.12), palette.bg),
    onSurface: palette.fg,
    onSurfaceVariant: palette.fg.withValues(alpha: 0.65),
    outline: palette.fg.withValues(alpha: 0.18),
    outlineVariant: palette.fg.withValues(alpha: 0.14),
    error: isDark ? const Color(0xFFF2B8B5) : const Color(0xFFB3261E),
    onError: isDark ? const Color(0xFF601410) : Colors.white,
  );
  return app.copyWith(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.bg,
    canvasColor: palette.bg,
    sliderTheme: appSliderTheme(scheme),
    switchTheme: appSwitchTheme(scheme),
    dividerTheme: app.dividerTheme.copyWith(color: scheme.outline),
    tabBarTheme: app.tabBarTheme.copyWith(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      dividerColor: scheme.outline,
    ),
    bottomSheetTheme: app.bottomSheetTheme.copyWith(
      backgroundColor: palette.bg,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: palette.fg.withValues(alpha: 0.35),
    ),
    chipTheme: app.chipTheme.copyWith(
      color: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), palette.bg) : palette.bg),
    ),
    textTheme: app.textTheme.apply(bodyColor: palette.fg, displayColor: palette.fg),
    iconTheme: app.iconTheme.copyWith(color: palette.fg),
  );
}

/// 朗读中的紧凑应用内播放控制条（上一句 / 暂停继续 / 下一句 / 定时 / 设置 / 停止）。
class ReaderTtsBar extends StatelessWidget {
  const ReaderTtsBar({
    super.key,
    required this.tts,
    required this.palette,
    required this.accent,
    required this.onOpenSettings,
    this.embedded = false,
  });

  final ReaderTtsController tts;
  final ReaderPalette palette;
  final Color accent;
  final VoidCallback onOpenSettings;

  /// 为 true 时嵌入底部菜单栏，为 false 时作为悬浮胶囊条显示在正文上方。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final bg = embedded ? Color.alphaBlend(palette.fg.withValues(alpha: 0.05), palette.bg) : Color.alphaBlend(palette.fg.withValues(alpha: 0.09), palette.bg);
    final fg = palette.fg;
    return ValueListenableBuilder<bool>(
      valueListenable: tts.paused,
      builder: (_, paused, _) => ValueListenableBuilder<TtsSleepState>(
        valueListenable: tts.sleepState,
        builder: (context, sleep, _) {
          final content = Row(
            mainAxisSize: embedded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: hz(context, '上一句'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.skip_previous_rounded, size: 22, color: fg),
                onPressed: () => tts.skip(-1),
              ),
              IconButton(
                tooltip: hz(context, paused ? '继续朗读' : '暂停朗读'),
                visualDensity: VisualDensity.compact,
                icon: AppIconSwap(
                  child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, key: ValueKey(paused), size: 24, color: accent),
                ),
                onPressed: tts.togglePause,
              ),
              IconButton(
                tooltip: hz(context, '下一句'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.skip_next_rounded, size: 22, color: fg),
                onPressed: () => tts.skip(1),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: sleep.enabled ? accent : fg.withValues(alpha: 0.8),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(40, 36),
                ),
                onPressed: onOpenSettings,
                icon: Icon(Icons.timer_outlined, size: 18, color: sleep.enabled ? accent : fg.withValues(alpha: 0.8)),
                label: Text(sleep.enabled ? sleep.shortLabel : '定时', style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              IconButton(
                tooltip: hz(context, '朗读设置'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.tune_rounded, size: 20, color: fg.withValues(alpha: 0.85)),
                onPressed: onOpenSettings,
              ),
              IconButton(
                tooltip: hz(context, '停止朗读'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.stop_rounded, size: 22, color: fg.withValues(alpha: 0.85)),
                onPressed: () => tts.stop(),
              ),
            ],
          );
          if (embedded) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: bg,
                border: Border(bottom: BorderSide(color: fg.withValues(alpha: 0.1))),
              ),
              child: content,
            );
          }
          return Material(
            color: bg,
            elevation: 2,
            shadowColor: Colors.black26,
            shape: StadiumBorder(side: BorderSide(color: fg.withValues(alpha: 0.16))),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: content),
          );
        },
      ),
    );
  }
}

/// 打开目录 / 书签 / 摘录 / 备注弹窗（统一套用阅读器当前明暗主题，支持下拉关闭，目录按展开态懒构建）。
Future<void> showReaderCatalogueSheet(
  BuildContext context, {
  required String aid,
  String bookTitle = '',
  required List<CatVolume> volumes,
  required String currentCid,
  required ReaderPalette palette,
  required Color accent,
  required Future<(int, int)?> Function(BuildContext ctx, Bookmark b) resolveBookmarkPage,
  required void Function(String cid) onSelectChapter,
  required void Function(Bookmark b) onSelectBookmark,
  void Function(HighlightEntry h)? onSelectHighlight,
  void Function(HighlightEntry h)? onEditHighlight,
  required void Function(ReplaceRule rule) onEditNote,
  VoidCallback? onOpenCharacters,
  VoidCallback? onBookmarksChanged,
  VoidCallback? onHighlightsChanged,
}) {
  final sheetTheme = readerThemeData(Theme.of(context), palette, accent);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.bg,
    builder: (_) => Theme(
      data: sheetTheme,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (sheetCtx, scroll) => _ReaderCatalogueSheet(
          aid: aid,
          bookTitle: bookTitle,
          volumes: volumes,
          currentCid: currentCid,
          scrollController: scroll,
          resolveBookmarkPage: resolveBookmarkPage,
          onSelectChapter: onSelectChapter,
          onSelectBookmark: onSelectBookmark,
          onSelectHighlight: onSelectHighlight,
          onEditHighlight: onEditHighlight,
          onEditNote: onEditNote,
          onOpenCharacters: onOpenCharacters,
          onBookmarksChanged: onBookmarksChanged,
          onHighlightsChanged: onHighlightsChanged,
        ),
      ),
    ),
  );
}

sealed class _CatRow {
  const _CatRow();
}

class _VolumeHeaderRow extends _CatRow {
  const _VolumeHeaderRow(this.volIndex, this.volume);

  final int volIndex;
  final CatVolume volume;
}

class _ChapterRow extends _CatRow {
  const _ChapterRow(this.chapter);

  final CatChapter chapter;
}

class _ReaderCatalogueSheet extends StatefulWidget {
  const _ReaderCatalogueSheet({
    required this.aid,
    required this.bookTitle,
    required this.volumes,
    required this.currentCid,
    required this.scrollController,
    required this.resolveBookmarkPage,
    required this.onSelectChapter,
    required this.onSelectBookmark,
    this.onSelectHighlight,
    this.onEditHighlight,
    required this.onEditNote,
    this.onOpenCharacters,
    this.onBookmarksChanged,
    this.onHighlightsChanged,
  });

  final String aid;
  final String bookTitle;
  final List<CatVolume> volumes;
  final String currentCid;
  final ScrollController scrollController;
  final Future<(int, int)?> Function(BuildContext ctx, Bookmark b) resolveBookmarkPage;
  final void Function(String cid) onSelectChapter;
  final void Function(Bookmark b) onSelectBookmark;
  final void Function(HighlightEntry h)? onSelectHighlight;
  final void Function(HighlightEntry h)? onEditHighlight;
  final void Function(ReplaceRule rule) onEditNote;
  final VoidCallback? onOpenCharacters;
  final VoidCallback? onBookmarksChanged;
  final VoidCallback? onHighlightsChanged;

  @override
  State<_ReaderCatalogueSheet> createState() => _ReaderCatalogueSheetState();
}

class _ReaderCatalogueSheetState extends State<_ReaderCatalogueSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this)..addListener(_onTabChanged);
  final _currentKey = GlobalKey();
  late final Set<int> _expanded;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _expanded = <int>{};
    if (widget.volumes.length == 1) {
      _expanded.add(0);
    } else {
      for (var i = 0; i < widget.volumes.length; i++) {
        if (widget.volumes[i].chapters.any((c) => c.cid == widget.currentCid)) _expanded.add(i);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.index != _tab) setState(() => _tab = _tabs.index);
  }

  List<_CatRow> _visibleRows() {
    final rows = <_CatRow>[];
    for (var i = 0; i < widget.volumes.length; i++) {
      final v = widget.volumes[i];
      rows.add(_VolumeHeaderRow(i, v));
      if (_expanded.contains(i)) {
        for (final c in v.chapters) {
          rows.add(_ChapterRow(c));
        }
      }
    }
    return rows;
  }

  void _scrollToCurrent() {
    if (!mounted || _tab != 0) return;
    if (_currentKey.currentContext case final ctx?) {
      Scrollable.ensureVisible(ctx, alignment: 0.35);
      return;
    }
    final rows = _visibleRows();
    final idx = rows.indexWhere((r) => r is _ChapterRow && r.chapter.cid == widget.currentCid);
    if (idx < 0 || !widget.scrollController.hasClients) return;
    final pos = widget.scrollController.position;
    final target = (idx * 48.0 - 160.0).clamp(0.0, pos.maxScrollExtent);
    widget.scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_currentKey.currentContext case final ctx?) {
        Scrollable.ensureVisible(ctx, alignment: 0.35);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final read = ReadState.readView(widget.aid);
    final marked = Bookmarks.bookmarkedCids(widget.aid);

    Widget body;
    switch (_tab) {
      case 0:
        final rows = _visibleRows();
        body = ListView.builder(
          key: const ValueKey('catalogue'),
          controller: widget.scrollController,
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            if (row is _VolumeHeaderRow) {
              final v = row.volume;
              final open = _expanded.contains(row.volIndex);
              final readCount = v.chapters.where((c) => read.contains(c.cid)).length;
              return ListTile(
                title: Text(v.title, style: theme.textTheme.titleSmall),
                subtitle: Text('$readCount/${v.chapters.length} 章已读', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                trailing: AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: AppMotion.dur(context, AppMotion.fast),
                  curve: AppMotion.snappy,
                  child: Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                ),
                onTap: () => setState(() {
                  if (!open) {
                    _expanded.add(row.volIndex);
                  } else {
                    _expanded.remove(row.volIndex);
                  }
                }),
              );
            }
            final c = (row as _ChapterRow).chapter;
            final isCurrent = c.cid == widget.currentCid;
            final isRead = read.contains(c.cid);
            return ListTile(
              key: isCurrent ? _currentKey : null,
              dense: true,
              contentPadding: const EdgeInsets.only(left: 32, right: 16),
              selected: isCurrent,
              selectedColor: scheme.primary,
              leading: isRead ? Icon(Icons.check, size: 16, color: isCurrent ? scheme.primary : scheme.onSurfaceVariant) : null,
              title: Text(c.title, style: isRead && !isCurrent ? TextStyle(color: scheme.onSurfaceVariant) : null),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (marked.contains(c.cid)) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.bookmark, size: 15, color: scheme.primary)),
                  if (ChapterCache.has(widget.aid, c.cid)) Icon(Icons.download_for_offline_outlined, size: 16, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                ],
              ),
              onTap: () {
                Navigator.pop(context);
                widget.onSelectChapter(c.cid);
              },
            );
          },
        );
      case 1:
        final marks = Bookmarks.all(widget.aid);
        body = marks.isEmpty
            ? ListView(
                key: const ValueKey('bookmarks-empty'),
                controller: widget.scrollController,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 120),
                    child: Center(child: Text('还没有书签', style: TextStyle(color: scheme.onSurfaceVariant))),
                  ),
                ],
              )
            : ListView.builder(
                key: const ValueKey('bookmarks'),
                controller: widget.scrollController,
                itemCount: marks.length,
                itemBuilder: (context, i) {
                  final b = marks[i];
                  return ListTile(
                    title: Text(b.excerpt.isEmpty ? b.chapter : b.excerpt, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: FutureBuilder(
                      future: widget.resolveBookmarkPage(context, b),
                      builder: (_, snap) => Text(
                        [b.chapter, if (snap.data case (final p, final n)) '第 $p / $n 页'].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: hz(context, '删除书签'),
                      icon: Icon(Icons.delete_outline, size: 20, color: scheme.onSurfaceVariant),
                      onPressed: () async {
                        await Bookmarks.remove(b);
                        if (mounted) setState(() {});
                        widget.onBookmarksChanged?.call();
                      },
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onSelectBookmark(b);
                    },
                  );
                },
              );
      case 2:
        final excerpts = HighlightStore.all(widget.aid);
        body = excerpts.isEmpty
            ? ListView(
                key: const ValueKey('highlights-empty'),
                controller: widget.scrollController,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 100, 24, 24),
                    child: Text('还没有摘录。\n选中正文点击「划线摘录」即可收藏句子并写下想法，支持导出 Markdown。', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ],
              )
            : ListView.builder(
                key: const ValueKey('highlights'),
                controller: widget.scrollController,
                itemCount: excerpts.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Row(
                        children: [
                          Text('共 ${excerpts.length} 条摘录', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          const Spacer(),
                          TextButton.icon(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            label: const Text('复制 Markdown'),
                            onPressed: () async {
                              final md = HighlightStore.exportMarkdown(widget.aid, widget.bookTitle);
                              await Clipboard.setData(ClipboardData(text: md));
                              if (context.mounted) {
                                ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已复制 Markdown 摘录'), duration: Duration(seconds: 1)));
                              }
                            },
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            icon: const Icon(Icons.ios_share_outlined, size: 16),
                            label: const Text('分享'),
                            onPressed: () {
                              final md = HighlightStore.exportMarkdown(widget.aid, widget.bookTitle);
                              SharePlus.instance.share(ShareParams(text: md)).ignore();
                            },
                          ),
                        ],
                      ),
                    );
                  }
                  final h = excerpts[i - 1];
                  final barColor = Color(h.colorValue);
                  return ListTile(
                    leading: Container(
                      width: 4,
                      height: 36,
                      decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(2)),
                    ),
                    title: Text(h.quote, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (h.note.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(h.note.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.85))),
                          ),
                        Text(h.chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onEditHighlight != null)
                          IconButton(
                            tooltip: hz(context, '编辑摘录'),
                            icon: Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onEditHighlight!(h);
                            },
                          ),
                        IconButton(
                          tooltip: hz(context, '删除摘录'),
                          icon: Icon(Icons.delete_outline, size: 18, color: scheme.onSurfaceVariant),
                          onPressed: () async {
                            await HighlightStore.remove(h.id);
                            if (mounted) setState(() {});
                            widget.onHighlightsChanged?.call();
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onSelectHighlight?.call(h);
                    },
                  );
                },
              );
      default:
        final notes = RuleNotes.of(widget.aid);
        final rules = ReplaceRules.all().where((r) => r.kind == RuleKind.highlight && notes.containsKey(r.id) && (r.aid.isEmpty || r.aid == widget.aid)).toList();
        final openChars = widget.onOpenCharacters;
        body = rules.isEmpty
            ? ListView(
                key: const ValueKey('notes-empty'),
                controller: widget.scrollController,
                children: [
                  if (openChars != null)
                    ListTile(
                      leading: Icon(Icons.people_outline, color: scheme.primary),
                      title: const Text('人物 / 设定词典'),
                      subtitle: Text('管理本书人物档案、自动高亮与防剧透笔记', style: TextStyle(color: scheme.onSurfaceVariant)),
                      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                      onTap: () {
                        Navigator.pop(context);
                        openChars();
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
                    child: Text('还没有备注。\n选中文字点"高亮"，之后点一下高亮的字就能写备注。', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ],
              )
            : ListView.builder(
                key: const ValueKey('notes'),
                controller: widget.scrollController,
                itemCount: rules.length + (openChars != null ? 1 : 0),
                itemBuilder: (context, i) {
                  if (openChars != null && i == 0) {
                    return ListTile(
                      leading: Icon(Icons.people_outline, color: scheme.primary),
                      title: const Text('人物 / 设定词典'),
                      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                      onTap: () {
                        Navigator.pop(context);
                        openChars();
                      },
                    );
                  }
                  final r = rules[openChars != null ? i - 1 : i];
                  return ListTile(
                    leading: CircleAvatar(radius: 8, backgroundColor: Color(r.color)),
                    title: Text(r.label),
                    subtitle: Text(notes[r.id]!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                    trailing: Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onEditNote(r);
                    },
                  );
                },
              );
    }

    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [Tab(child: Text('目录')), Tab(child: Text('书签')), Tab(child: Text('摘录')), Tab(child: Text('备注'))],
        ),
        Expanded(child: AppCrossfade(fill: true, duration: AppMotion.fast, child: body)),
      ],
    );
  }
}

/// 打开朗读设置面板（套用阅读器当前明暗主题）。
Future<void> showReaderTtsSheet(
  BuildContext context, {
  required ReaderTtsController tts,
  required ReaderPalette palette,
  required Color accent,
}) {
  const systemIntents = MethodChannel('ark/system_intents');
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final sheetTheme = readerThemeData(Theme.of(context), palette, accent);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.bg,
    builder: (context) => Theme(
      data: sheetTheme,
      child: Consumer(
        builder: (context, ref, _) {
          final prefs = ref.watch(readerPrefsProvider);
          void set(ReaderPrefs p) {
            ref.read(readerPrefsProvider.notifier).update(p);
            tts.syncPrefs();
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: tts.active,
                    builder: (_, active, _) {
                      if (!active) return const SizedBox.shrink();
                      return ValueListenableBuilder<bool>(
                        valueListenable: tts.paused,
                        builder: (_, paused, _) => Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Row(
                            children: [
                              Expanded(child: OutlinedButton.icon(onPressed: () => tts.skip(-1), icon: const Icon(Icons.skip_previous, size: 18), label: const Text('上一句'))),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: tts.togglePause,
                                  icon: AppIconSwap(child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, key: ValueKey(paused), size: 18)),
                                  label: AppCrossfade(child: Text(paused ? '继续' : '暂停', key: ValueKey(paused))),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: OutlinedButton.icon(onPressed: () => tts.skip(1), icon: const Icon(Icons.skip_next, size: 18), label: const Text('下一句'))),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const XGroupTitle('语音'),
                  _LayoutSlider(title: '语速', label: (v) => v.toStringAsFixed(1), min: 0.1, max: 1.5, divisions: 14, value: prefs.ttsRate, onCommit: (v) => set(prefs.copyWith(ttsRate: v))),
                  _LayoutSlider(title: '音调', label: (v) => v.toStringAsFixed(1), min: 0.5, max: 2.0, divisions: 15, value: prefs.ttsPitch, onCommit: (v) => set(prefs.copyWith(ttsPitch: v))),
                  FutureBuilder<List<TtsVoice>>(
                    future: tts.zhVoices(),
                    builder: (context, snap) => XChips<String>(
                      title: '音色',
                      value: prefs.ttsVoice,
                      options: {'': '系统默认', for (final v in snap.data ?? const <TtsVoice>[]) v.name: v.name},
                      onChanged: (v) => set(prefs.copyWith(ttsVoice: v)),
                    ),
                  ),
                  if (android)
                    XTile(
                      title: '系统语音引擎设置',
                      subtitle: '切换 TTS 引擎、下载离线中文语音包',
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => systemIntents.invokeMethod('openTtsSettings').ignore(),
                    ),
                  const XDivider(),
                  const XGroupTitle('朗读方式'),
                  XSwitch(title: '跟读高亮', value: prefs.ttsHighlight, onChanged: (v) => set(prefs.copyWith(ttsHighlight: v))),
                  XSwitch(title: '自动朗读下一章', value: prefs.ttsAutoNext, onChanged: (v) => set(prefs.copyWith(ttsAutoNext: v))),
                  const XDivider(),
                  const XGroupTitle('定时停止'),
                  ValueListenableBuilder<TtsSleepState>(
                    valueListenable: tts.sleepState,
                    builder: (_, sleep, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        XChips<int>(
                          value: sleep.optionValue,
                          options: const {0: '关闭', 15: '15 分钟', 30: '30 分钟', 60: '60 分钟', -1: '本章结束'},
                          onChanged: tts.setSleepOption,
                        ),
                        AppCollapse(
                          visible: sleep.at != null,
                          duration: AppMotion.fast,
                          child: sleep.at == null ? const SizedBox.shrink() : XNote('将于 ${sleep.stopTimeText} 停止朗读'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// 打开阅读器外观 / 排版 / 翻页设置面板。
Future<void> showReaderSettingsSheet(
  BuildContext hostContext, {
  required int initialTab,
  required ValueChanged<int> onTabChanged,
  required VoidCallback onOpenTtsSettings,
  required Future<void> Function() onOpenMoreSettings,
}) {
  var currentTab = initialTab;
  ProviderContainer? hostContainer;
  try {
    hostContainer = ProviderScope.containerOf(hostContext, listen: false);
  } catch (_) {}
  return showModalBottomSheet<void>(
    context: hostContext,
    isScrollControlled: true,
    barrierColor: Colors.transparent, // 不压暗正文：改字号、配色时要看得到效果
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => Consumer(
        builder: (context, ref, _) {
          final prefs = ref.watch(readerPrefsProvider);
          void set(ReaderPrefs p) => ref.read(readerPrefsProvider.notifier).update(p);
          void preview(ReaderPrefs p) => ref.read(readerPrefsProvider.notifier).preview(p);
          final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
          final app = Theme.of(context);
          final pal = readerPaletteOf(prefs, app.colorScheme);
          final accent = readerHeadingAccent(hostContext, prefs, pal)?.$1;
          final themed = readerThemeData(app, pal, accent);
          final scheme = themed.colorScheme;
          return Theme(
            data: themed,
            child: AnimatedContainer(
              duration: AppMotion.dur(context, AppMotion.standard),
              curve: AppMotion.curve,
              decoration: BoxDecoration(
                color: pal.bg,
                border: Border(top: BorderSide(color: scheme.outline)),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  // 略高于半屏：三个分页都不用滑，上面留一些正文
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.56,
                    child: Column(
                      children: [
                        XSegments<int>(
                          value: currentTab,
                          options: const {0: '显示', 1: '排版', 2: '翻页'},
                          onChanged: (v) {
                            setSheet(() => currentTab = v);
                            onTabChanged(v);
                          },
                        ),
                        Expanded(
                          child: _ScrollFade(
                            color: pal.bg,
                            child: AppCrossfade(
                              fill: true,
                              duration: AppMotion.fast,
                              child: SingleChildScrollView(
                                key: ValueKey(currentTab), // 换分页时回到顶上
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (currentTab == 0) ...[
                                      // 一排背景色样：色块里写个"文"字，选中的外面一圈
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            for (final (i, name) in ['纸张', '护眼', '夜间', '跟随应用', '纯黑', '晴空'].indexed)
                                              GestureDetector(
                                                onTap: () {
                                                  HapticFeedback.selectionClick();
                                                  set(prefs.copyWith(theme: i));
                                                },
                                                child: Column(
                                                  children: [
                                                    AnimatedScale(
                                                      scale: prefs.theme == i ? 1.08 : 1.0,
                                                      duration: AppMotion.dur(context, AppMotion.fast),
                                                      curve: AppMotion.snappy,
                                                      child: AnimatedContainer(
                                                        duration: AppMotion.dur(context, AppMotion.fast),
                                                        curve: AppMotion.curve,
                                                        width: 42,
                                                        height: 42,
                                                        padding: const EdgeInsets.all(2.5),
                                                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: prefs.theme == i ? scheme.primary : Colors.transparent, width: 2)),
                                                        child: Builder(
                                                          builder: (_) {
                                                            final p = readerPaletteOf(prefs.copyWith(theme: i), app.colorScheme);
                                                            return DecoratedBox(
                                                              decoration: BoxDecoration(shape: BoxShape.circle, color: p.bg, border: Border.all(color: scheme.outline)),
                                                              child: Center(child: Text('文', style: TextStyle(fontSize: 14, color: i == 5 ? readerSkyAccent.$1 : p.fg))),
                                                            );
                                                          },
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    AnimatedDefaultTextStyle(
                                                      duration: AppMotion.dur(context, AppMotion.fast),
                                                      curve: AppMotion.curve,
                                                      style: TextStyle(fontSize: 12, color: prefs.theme == i ? scheme.primary : scheme.onSurfaceVariant, fontWeight: prefs.theme == i ? FontWeight.w600 : FontWeight.w400),
                                                      child: Text(name, maxLines: 1),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      // 越往左越暗：滑块值是亮度，存的是遮罩不透明度
                                      XSlider(compact: true, title: '页面亮度', label: '${((1 - prefs.dim) * 100).round()}%', slider: Slider(min: 0.3, max: 1.0, divisions: 14, value: (1 - prefs.dim).clamp(0.3, 1.0), onChanged: (v) => preview(prefs.copyWith(dim: 1 - v)), onChangeEnd: (v) => set(prefs.copyWith(dim: 1 - v)))),
                                      if (android) ...[
                                        XSwitch(title: '独立屏幕亮度', help: '不跟随系统亮度，最高能调得比系统更亮；退出阅读后恢复。', value: prefs.customBrightness, onChanged: (v) => set(prefs.copyWith(customBrightness: v))),
                                        AppCollapse(
                                          visible: prefs.customBrightness,
                                          child: XSlider(compact: true, title: '屏幕亮度', label: '${(prefs.brightness * 100).round()}%', slider: Slider(min: 0.02, max: 1.0, value: prefs.brightness.clamp(0.02, 1.0), onChanged: (v) => preview(prefs.copyWith(brightness: v)), onChangeEnd: (v) => set(prefs.copyWith(brightness: v)))),
                                        ),
                                      ],
                                      XSlider(compact: true, title: '暖色滤镜', label: prefs.warm == 0 ? '关闭' : '${(prefs.warm * 200).round()}%', slider: Slider(min: 0, max: 0.5, divisions: 10, value: prefs.warm, onChanged: (v) => preview(prefs.copyWith(warm: v)), onChangeEnd: (v) => set(prefs.copyWith(warm: v)))),
                                      XTile(
                                        title: '色彩',
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          spacing: 8,
                                          children: [
                                            _toggleChip(scheme, '灰度', prefs.grayscale, (v) => set(prefs.copyWith(grayscale: v))),
                                            _toggleChip(scheme, '反色', prefs.invert, (v) => set(prefs.copyWith(invert: v))),
                                          ],
                                        ),
                                      ),
                                      XChips<int>(
                                        title: '纸张纹理',
                                        value: prefs.bgTexture,
                                        options: kReaderBgTextures,
                                        onChanged: (v) => set(prefs.copyWith(bgTexture: v)),
                                      ),
                                      if (!isWebPreview)
                                        () {
                                          final bgImg = ref.watch(readerBgImageProvider);
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              XTile(
                                                title: '自定义背景图',
                                                subtitle: bgImg != null ? '已应用本地背景图片' : '叠加本地图片并保留护眼遮罩',
                                                trailing: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  spacing: 6,
                                                  children: [
                                                    OutlinedButton(
                                                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 12)),
                                                      onPressed: () => ref.read(readerBgImageProvider.notifier).pick(),
                                                      child: Text(bgImg == null ? '选图' : '更换'),
                                                    ),
                                                    AppCollapse(
                                                      visible: bgImg != null,
                                                      axis: Axis.horizontal,
                                                      duration: AppMotion.fast,
                                                      child: TextButton(
                                                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                                        onPressed: () => ref.read(readerBgImageProvider.notifier).clear(),
                                                        child: const Text('清除'),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              AppCollapse(
                                                visible: bgImg != null,
                                                child: XSlider(
                                                  compact: true,
                                                  title: '背景浓度',
                                                  label: '${(prefs.bgImageOpacity * 100).round()}%',
                                                  slider: Slider(
                                                    min: 0.05,
                                                    max: 0.85,
                                                    divisions: 16,
                                                    value: prefs.bgImageOpacity.clamp(0.05, 0.85),
                                                    onChanged: (v) => preview(prefs.copyWith(bgImageOpacity: v)),
                                                    onChangeEnd: (v) => set(prefs.copyWith(bgImageOpacity: v)),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );
                                        }(),
                                    ],
                                    if (currentTab == 1) ...[
                                      _LayoutSlider(title: '字号', label: (v) => '${v.round()}', min: 14, max: 32, divisions: 18, value: prefs.fontSize, onCommit: (v) => set(prefs.copyWith(fontSize: v))),
                                      _LayoutSlider(title: '行距', label: (v) => v.toStringAsFixed(1), min: 1.3, max: 2.4, divisions: 11, value: prefs.lineHeight, onCommit: (v) => set(prefs.copyWith(lineHeight: v))),
                                      _LayoutSlider(title: '字间距', label: (v) => v == 0 ? '默认' : v.toStringAsFixed(1), min: -0.5, max: 4.0, divisions: 18, value: prefs.letterSpacing, onCommit: (v) => set(prefs.copyWith(letterSpacing: v))),
                                      _LayoutSlider(title: '段间距', label: (v) => v <= 0 ? '紧排' : '${v.round()}', min: 0, max: 24, divisions: 12, value: prefs.paragraphSpacing, onCommit: (v) => set(prefs.copyWith(paragraphSpacing: v))),
                                      _LayoutSlider(title: '页边距', label: (v) => '${v.round()}', min: 8, max: 48, divisions: 20, value: prefs.margin, onCommit: (v) => set(prefs.copyWith(margin: v))),
                                      XChips<int>(
                                        title: '字体',
                                        value: prefs.font,
                                        options: FontStore.names,
                                        onChanged: (k) async {
                                          if (k == 2) {
                                            if (FontStore.customFamily == null && !await FontStore.pick()) return;
                                            FontStore.ensureLoaded().ignore();
                                          }
                                          set(prefs.copyWith(font: k));
                                        },
                                        extra: [
                                          if (!isWebPreview)
                                            ActionChip(
                                              avatar: const Icon(Icons.upload_file_outlined, size: 18),
                                              label: const Text('导入字体'),
                                              onPressed: () async {
                                                if (await FontStore.pick()) set(prefs.copyWith(font: 2));
                                              },
                                            ),
                                        ],
                                      ),
                                      XSwitch(title: '繁体', value: prefs.hant, onChanged: (v) => set(prefs.copyWith(hant: v))),
                                    ],
                                    if (currentTab == 2) ...[
                                      XSegments<int>(value: prefs.mode, options: const {0: '滚动', 1: '滑动', 2: '仿真', 3: '覆盖'}, onChanged: (v) => set(prefs.copyWith(mode: v))),
                                      AppCollapse(
                                        visible: prefs.mode != 0,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            XChips<int>(
                                              title: '点击区域',
                                              value: prefs.tapZone,
                                              options: const {0: '默认', 1: 'L 形', 2: 'Kindle 式', 3: '边缘式', 4: '仅菜单'},
                                              onChanged: (v) => set(prefs.copyWith(tapZone: v)),
                                            ),
                                            TapZoneDiagram(zone: prefs.tapZone, invert: prefs.tapInvert),
                                            XSwitch(title: '宽屏双页', value: prefs.dual, onChanged: (v) => set(prefs.copyWith(dual: v))),
                                          ],
                                        ),
                                      ),
                                      XSwitch(title: '沉浸式阅读', value: prefs.fullscreen, onChanged: (v) => set(prefs.copyWith(fullscreen: v))),
                                      XSwitch(title: '页脚信息', value: prefs.showStatus, onChanged: (v) => set(prefs.copyWith(showStatus: v))),
                                      XTile(
                                        title: '页眉与页脚字段',
                                        subtitle: '${ReaderChromeField.labels[prefs.headerLeft] ?? '留空'} · ${ReaderChromeField.labels[prefs.footerRight] ?? '留空'}',
                                        trailing: const Icon(Icons.chevron_right),
                                        onTap: () => _showChromeFieldsSheet(context, themed),
                                      ),
                                      XTile(
                                        title: '朗读设置',
                                        trailing: const Icon(Icons.chevron_right),
                                        onTap: () {
                                          Navigator.pop(context);
                                          onOpenTtsSettings();
                                        },
                                      ),
                                      XTile(
                                        title: '更多阅读设置',
                                        trailing: const Icon(Icons.chevron_right),
                                        onTap: () async {
                                          Navigator.pop(context);
                                          await onOpenMoreSettings();
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  ).whenComplete(() {
    try {
      hostContainer?.read(readerPrefsProvider.notifier).flush();
    } catch (_) {}
  });
}

/// 页眉 / 页脚字段配置弹窗（沿用当前阅读器主题，一键挑选各位置显示项）。
Future<void> _showChromeFieldsSheet(BuildContext context, ThemeData sheetTheme) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: sheetTheme.scaffoldBackgroundColor,
  builder: (_) => Theme(
    data: sheetTheme,
    child: Consumer(
      builder: (context, ref, _) {
        final prefs = ref.watch(readerPrefsProvider);
        void set(ReaderPrefs p) => ref.read(readerPrefsProvider.notifier).update(p);
        final isDefault = prefs.headerLeft == ReaderChromeField.chapterTitle &&
            prefs.headerRight == ReaderChromeField.empty &&
            prefs.footerLeft == ReaderChromeField.timeAndBattery &&
            prefs.footerRight == ReaderChromeField.pageOrProgress;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('页眉与页脚字段', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                      AppCollapse(
                        visible: !isDefault,
                        axis: Axis.horizontal,
                        duration: AppMotion.fast,
                        child: TextButton(
                          onPressed: () => set(
                            prefs.copyWith(
                              headerLeft: ReaderChromeField.chapterTitle,
                              headerRight: ReaderChromeField.empty,
                              footerLeft: ReaderChromeField.timeAndBattery,
                              footerRight: ReaderChromeField.pageOrProgress,
                            ),
                          ),
                          child: const Text('恢复默认'),
                        ),
                      ),
                    ],
                  ),
                ),
                XChips<int>(title: '页眉左侧', value: prefs.headerLeft, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(headerLeft: v))),
                XChips<int>(title: '页眉右侧', value: prefs.headerRight, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(headerRight: v))),
                const XDivider(),
                XChips<int>(title: '页脚左侧', value: prefs.footerLeft, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(footerLeft: v))),
                XChips<int>(title: '页脚右侧', value: prefs.footerRight, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(footerRight: v))),
              ],
            ),
          ),
        );
      },
    ),
  ),
);

/// 字号、行距、页边距：拖动时只改数字，松手才生效。每改一档都要整章重新排版，拖动中每档都排一次会卡顿。
class _LayoutSlider extends StatefulWidget {
  const _LayoutSlider({required this.title, required this.label, required this.min, required this.max, required this.divisions, required this.value, required this.onCommit});

  final String title;
  final String Function(double value) label;
  final double min;
  final double max;
  final int divisions;
  final double value;
  final ValueChanged<double> onCommit;

  @override
  State<_LayoutSlider> createState() => _LayoutSliderState();
}

class _LayoutSliderState extends State<_LayoutSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = (_dragging ?? widget.value).clamp(widget.min, widget.max);
    return XSlider(
      compact: true,
      title: widget.title,
      label: widget.label(v),
      slider: Slider(
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        value: v,
        onChanged: (x) => setState(() => _dragging = x),
        onChangeEnd: (x) {
          setState(() => _dragging = null);
          if (x != widget.value) widget.onCommit(x);
        },
      ),
    );
  }
}

/// 两个可以同时选中的标签，样子和 XChips 的一样
Widget _toggleChip(ColorScheme scheme, String label, bool on, ValueChanged<bool> onChanged) => ChoiceChip(
  label: Text(label),
  selected: on,
  showCheckmark: false,
  selectedColor: scheme.primary.withValues(alpha: 0.14),
  labelStyle: TextStyle(color: on ? scheme.primary : scheme.onSurface, fontWeight: on ? FontWeight.w600 : null),
  side: BorderSide(color: on ? scheme.primary.withValues(alpha: 0.5) : scheme.outline),
  onSelected: onChanged,
);

/// 下面还有内容没露出来时，底边用轻量线性渐变遮罩提示可往下滑（仅在 `_more` 时叠放，消除常驻 `ShaderMask` `saveLayer`）。
class _ScrollFade extends StatefulWidget {
  const _ScrollFade({required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  State<_ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<_ScrollFade> {
  var _more = false;

  bool _onMetrics(ScrollMetrics m) {
    final more = m.extentAfter > 1;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.color ?? Theme.of(context).scaffoldBackgroundColor;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Scrollbar(child: widget.child),
            if (_more)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 44,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [bg.withValues(alpha: 0), bg],
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
}
