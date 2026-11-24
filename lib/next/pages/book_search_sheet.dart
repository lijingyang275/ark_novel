import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/cat_volume.dart';
import '../book_search.dart';
import '../cache.dart';
import '../hant.dart';
import '../local_books.dart';
import '../reader/reader_sheets.dart';
import '../settings.dart';
import '../text.dart';

/// 书内全文搜索弹窗，可在阅读器、书籍详情页、人物词典页复用。
Future<void> showBookSearchSheet(
  BuildContext context, {
  required String aid,
  required List<CatVolume> catalogue,
  String? currentCid,
  String? currentChapterText,
  String? initialQuery,
  bool initialRegex = false,
  BookSearchScope? initialScope,
  ReaderPalette? palette,
  Color? accent,
  required void Function(BookSearchHit hit) onSelectHit,
}) {
  final sheetTheme = palette != null ? readerThemeData(Theme.of(context), palette, accent) : null;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette?.bg,
    builder: (_) {
      final sheet = DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.45,
        maxChildSize: 0.94,
        builder: (sheetCtx, scroll) => _BookSearchSheet(
          aid: aid,
          catalogue: catalogue,
          currentCid: currentCid,
          currentChapterText: currentChapterText,
          initialQuery: initialQuery ?? '',
          initialRegex: initialRegex,
          initialScope: initialScope,
          scrollController: scroll,
          onSelectHit: onSelectHit,
        ),
      );
      return sheetTheme == null ? sheet : Theme(data: sheetTheme, child: sheet);
    },
  );
}

sealed class _SearchRow {
  const _SearchRow();
}

class _GroupHeaderRow extends _SearchRow {
  const _GroupHeaderRow({required this.volTitle, required this.chapterTitle, required this.count});

  final String volTitle;
  final String chapterTitle;
  final int count;
}

class _HitRow extends _SearchRow {
  const _HitRow(this.hit);

  final BookSearchHit hit;
}

class _BookSearchSheet extends ConsumerStatefulWidget {
  const _BookSearchSheet({
    required this.aid,
    required this.catalogue,
    required this.currentCid,
    required this.currentChapterText,
    required this.initialQuery,
    required this.initialRegex,
    required this.initialScope,
    required this.scrollController,
    required this.onSelectHit,
  });

  final String aid;
  final List<CatVolume> catalogue;
  final String? currentCid;
  final String? currentChapterText;
  final String initialQuery;
  final bool initialRegex;
  final BookSearchScope? initialScope;
  final ScrollController scrollController;
  final void Function(BookSearchHit hit) onSelectHit;

  @override
  ConsumerState<_BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends ConsumerState<_BookSearchSheet> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialQuery);
  late BookSearchScope _scope;
  late bool _isRegex = widget.initialRegex;
  Timer? _debounce;
  BookSearchCancelToken? _cancel;
  bool _searching = false;
  int _scanned = 0;
  int _total = 0;
  int _totalHits = 0;
  String? _error;
  List<BookSearchHit> _hits = const [];
  List<_SearchRow> _rows = const [];

  bool get _hasCurrent => widget.currentCid != null && widget.currentCid!.isNotEmpty;
  bool get _isLocal => isLocalAid(widget.aid);

  @override
  void initState() {
    super.initState();
    final totalCat = widget.catalogue.fold<int>(0, (a, v) => a + v.chapters.length);
    final available = _isLocal ? totalCat : ChapterCache.count(widget.aid);
    _scope = _hasCurrent
        ? (widget.initialScope ?? (available > 1 ? BookSearchScope.allCached : BookSearchScope.currentChapter))
        : BookSearchScope.allCached;
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), () {
      if (mounted) _runSearch();
    });
  }

  List<_SearchRow> _buildRows(List<BookSearchHit> hits) {
    final rows = <_SearchRow>[];
    var i = 0;
    while (i < hits.length) {
      final first = hits[i];
      var j = i + 1;
      while (j < hits.length && hits[j].cid == first.cid) {
        j++;
      }
      rows.add(_GroupHeaderRow(volTitle: first.volTitle, chapterTitle: first.chapterTitle, count: j - i));
      for (var k = i; k < j; k++) {
        rows.add(_HitRow(hits[k]));
      }
      i = j;
    }
    return rows;
  }

  Future<void> _runSearch() async {
    _debounce?.cancel();
    _cancel?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty) {
      setState(() {
        _searching = false;
        _scanned = 0;
        _total = 0;
        _totalHits = 0;
        _error = null;
        _hits = const [];
        _rows = const [];
      });
      return;
    }

    final token = BookSearchCancelToken();
    _cancel = token;
    setState(() {
      _searching = true;
      _error = null;
      _scanned = 0;
      _total = 0;
      _totalHits = 0;
      _hits = const [];
      _rows = const [];
    });

    Hant? hant;
    if (ref.read(readerPrefsProvider).hant) {
      try {
        hant = Hant.loaded ?? await Hant.load();
      } catch (_) {}
    }
    if (!mounted || token.isCancelled) return;

    final result = await BookSearchEngine.search(
      aid: widget.aid,
      catalogue: widget.catalogue,
      query: q,
      scope: _scope,
      currentCid: widget.currentCid,
      currentChapterText: widget.currentChapterText,
      isRegex: _isRegex,
      hant: hant,
      cancelToken: token,
      onProgress: (p) {
        if (!mounted || token.isCancelled) return;
        setState(() {
          _scanned = p.scannedChapters;
          _total = p.totalChapters;
          _totalHits = p.totalHits;
          _hits = p.hits;
          _rows = _buildRows(p.hits);
        });
      },
    );

    if (!mounted || token.isCancelled) return;
    setState(() {
      _searching = false;
      _scanned = result.scannedChapters;
      _total = result.totalChapters;
      _totalHits = result.totalHits;
      _error = result.error;
      _hits = result.hits;
      _rows = _buildRows(result.hits);
    });
  }

  Widget _snippetText(BookSearchHit hit, ThemeData theme) {
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium?.copyWith(height: 1.5);
    final s = hit.snippet;
    final a = hit.highlightStart.clamp(0, s.length);
    final b = hit.highlightEnd.clamp(a, s.length);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          if (a > 0) TextSpan(text: s.substring(0, a)),
          if (b > a)
            TextSpan(
              text: s.substring(a, b),
              style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, backgroundColor: scheme.primary.withValues(alpha: 0.16)),
            ),
          if (b < s.length) TextSpan(text: s.substring(b)),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalCat = widget.catalogue.fold<int>(0, (a, v) => a + v.chapters.length);
    final cachedCount = _isLocal ? totalCat : ChapterCache.count(widget.aid);
    final q = _controller.text.trim();

    String statusText;
    if (_searching) {
      statusText = _scope == BookSearchScope.currentChapter
          ? '正在搜索当前章，已找到 $_totalHits 处…'
          : (_isLocal ? '正在搜索 $_scanned/$_total 章，已找到 $_totalHits 处…' : '正在搜索 $_scanned/$_total 章已缓存章节，已找到 $_totalHits 处…');
    } else if (_error != null) {
      statusText = _error!;
    } else if (q.isEmpty) {
      statusText = _scope == BookSearchScope.currentChapter
          ? '输入关键词搜索当前章节'
          : (_isLocal ? '全书共 $totalCat 章，输入关键词检索正文' : '全书已缓存 $cachedCount/$totalCat 章，输入关键词检索正文');
    } else if (_scope == BookSearchScope.currentChapter) {
      statusText = '当前章共找到 $_totalHits 处';
    } else {
      final capHint = _hits.length < _totalHits ? '（显示前 ${_hits.length} 处）' : '';
      statusText = _isLocal ? '已搜索 $_scanned/$_total 章，共找到 $_totalHits 处$capHint' : '已搜索 $_scanned/$_total 章已缓存章节，共找到 $_totalHits 处$capHint';
    }

    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: widget.initialQuery.trim().isEmpty,
              textInputAction: TextInputAction.search,
              onChanged: (_) {
                setState(() {});
                _scheduleSearch();
              },
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hint: Text(_isRegex ? '输入正则表达式（如 角色A|别名B）' : '搜索书内正文关键词', maxLines: 1, overflow: TextOverflow.ellipsis),
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: hz(context, '清空'),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _controller.clear();
                          _runSearch();
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                if (_hasCurrent) ...[
                  ChoiceChip(
                    label: const Text('当前章'),
                    selected: _scope == BookSearchScope.currentChapter,
                    showCheckmark: false,
                    onSelected: (_) {
                      if (_scope == BookSearchScope.currentChapter) return;
                      setState(() => _scope = BookSearchScope.currentChapter);
                      _runSearch();
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(_isLocal ? '全书' : '全书已缓存'),
                    selected: _scope == BookSearchScope.allCached,
                    showCheckmark: false,
                    onSelected: (_) {
                      if (_scope == BookSearchScope.allCached) return;
                      setState(() => _scope = BookSearchScope.allCached);
                      _runSearch();
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                FilterChip(
                  label: const Text('正则'),
                  selected: _isRegex,
                  showCheckmark: false,
                  onSelected: (v) {
                    setState(() => _isRegex = v);
                    _runSearch();
                  },
                ),
                const Spacer(),
                if (_searching)
                  TextButton(
                    onPressed: () {
                      _cancel?.cancel();
                      setState(() => _searching = false);
                    },
                    child: const Text('停止'),
                  ),
              ],
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(color: _error != null ? scheme.error : scheme.onSurfaceVariant),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _rows.isEmpty
                ? ListView(
                    controller: widget.scrollController,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
                        child: Text(
                          q.isEmpty
                              ? (_scope == BookSearchScope.allCached && cachedCount == 0
                                    ? '还没有已缓存的章节。\n可先在书籍详情页缓存章节或阅读后再搜全书。'
                                    : '支持关键词检索与正则多词检索（例如：角色名|别名）。')
                              : (_searching
                                    ? '正在检索中…'
                                    : (_error != null
                                          ? '请检查正则表达式语法。'
                                          : (_scope == BookSearchScope.allCached && cachedCount == 0
                                                ? '未找到结果（当前暂无已缓存章节）。'
                                                : '未找到匹配内容。'))),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.6),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _rows.length,
                    itemBuilder: (context, i) {
                      final row = _rows[i];
                      if (row is _GroupHeaderRow) {
                        final heading = row.volTitle.isNotEmpty && row.chapterTitle.isNotEmpty
                            ? '${row.volTitle} · ${row.chapterTitle}'
                            : (row.chapterTitle.isNotEmpty ? row.chapterTitle : row.volTitle);
                        return Container(
                          color: scheme.surfaceContainerLow,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                              ),
                              const SizedBox(width: 8),
                              Text('${row.count} 处', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                            ],
                          ),
                        );
                      }
                      final hit = (row as _HitRow).hit;
                      return InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          widget.onSelectHit(hit);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: _snippetText(hit, theme),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
