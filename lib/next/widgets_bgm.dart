import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bangumi.dart';
import 'text.dart';

/// 书籍详情页的 Bangumi 信息卡：
/// - 有本地缓存直接秒出，未命中或网络出错时静默不占位、不报错；
/// - 展示评分/评价人数/排名、日文原名、热门标签与关联动画/漫画外链。
class BangumiInfoCard extends ConsumerStatefulWidget {
  const BangumiInfoCard({super.key, required this.aid, required this.title});

  final String aid;
  final String title;

  @override
  ConsumerState<BangumiInfoCard> createState() => _BangumiInfoCardState();
}

class _BangumiInfoCardState extends ConsumerState<BangumiInfoCard> {
  BgmSubjectInfo? _info;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  @override
  void didUpdateWidget(BangumiInfoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aid != widget.aid || oldWidget.title != widget.title) {
      _cancel?.cancel();
      _initAndLoad();
    }
  }

  void _initAndLoad() {
    final saved = BangumiCovers.savedInfo(widget.aid);
    _info = saved;
    if (saved != null && !BangumiCovers.isInfoExpired(saved)) return;
    final token = CancelToken();
    _cancel = token;
    _fetch(token);
  }

  Future<void> _fetch(CancelToken token) async {
    try {
      final fresh = await ref.read(bangumiProvider).subjectInfo(widget.aid, fallbackTitle: widget.title, cancelToken: token);
      if (!mounted || token.isCancelled) return;
      if (fresh != null) setState(() => _info = fresh);
    } catch (_) {
      // 未命中或网络不可达时静默不占位不报错
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  void _openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    final scoreParts = <String>[
      if (info.ratingTotal > 0) '${info.ratingTotal} 人评价',
      if (info.rank > 0) '#${info.rank}',
    ];
    final showOriginal = info.name.isNotEmpty && info.name != info.nameCn;
    final metaLine = [if (showOriginal) info.name, if (info.date.isNotEmpty) info.date].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
                  child: Text('Bangumi', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      if (info.score > 0) ...[
                        Icon(Icons.star_rounded, size: 16, color: scheme.primary),
                        const SizedBox(width: 2),
                        Text(info.score.toStringAsFixed(1), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        if (scoreParts.isNotEmpty) const SizedBox(width: 4),
                      ],
                      if (scoreParts.isNotEmpty)
                        Flexible(
                          child: Text(
                            info.score > 0 ? '· ${scoreParts.join(' · ')}' : scoreParts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ),
                    ],
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openUrl(info.url),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('在 Bangumi 查看', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                        const SizedBox(width: 2),
                        Icon(Icons.open_in_new, size: 13, color: scheme.primary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (metaLine.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(metaLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
            ],
            if (info.tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in info.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(8)),
                      child: Text(tag, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ],
            if (info.relations.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in info.relations)
                    Tooltip(
                      message: hz(context, '在 Bangumi 查看：${r.displayName}'),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _openUrl(r.url),
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 260),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(r.type == 2 ? Icons.live_tv_outlined : Icons.auto_stories_outlined, size: 14, color: scheme.primary),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  r.relation.isNotEmpty ? '${r.relation} · ${r.displayName}' : r.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
