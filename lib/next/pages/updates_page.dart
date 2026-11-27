import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library.dart';
import '../motion.dart';
import '../routes.dart';
import '../updates.dart';
import '../volume_covers.dart';
import '../volumes.dart' show volumeChangesProvider;
import '../widgets.dart';
import '../x_list.dart';
import '../text.dart';

String dayLabel(DateTime t) {
  final now = DateTime.now();
  final d = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  return switch (diff) {
    0 => '今天',
    1 => '昨天',
    _ => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}',
  };
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 更新：追踪书架里的书有没有新章节，按日期分组，未读的有标记。
class UpdatesPage extends ConsumerStatefulWidget {
  const UpdatesPage({super.key});

  @override
  ConsumerState<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends ConsumerState<UpdatesPage> {
  int _seen = UpdateStore.lastSeen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ref.watch(updateProvider);
    ref.watch(volumeChangesProvider);
    final covers = ref.read(volumeCoverQueueProvider);
    final feed = UpdateStore.feed();
    final lastCheck = UpdateStore.lastCheck;
    // 主界面用 indexedStack 保活，切走 Tab 不会走 dispose：只要当前处在更新页且有未读项，渲染后立即消掉底栏红点，
    // 同时保留 _seen 让本次页面内刚出的新章节继续带小圆点提示
    final active = TickerMode.valuesOf(context).enabled;
    if (active && UpdateStore.unread() > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        UpdateStore.markSeen();
      });
    } else if (!active) {
      _seen = UpdateStore.lastSeen;
    }

    final rows = <_UpdateRow>[const _UpdateStatusRow()];
    String? day;
    for (final e in feed) {
      final label = dayLabel(e.time);
      if (label != day) {
        day = label;
        rows.add(_UpdateDayRow(label));
      }
      rows.add(_UpdateEntryRow(e));
    }

    final statusText = progress.error ??
        (progress.running
            ? '正在检查 ${progress.done}/${progress.total}'
            : (lastCheck == 0
                ? '还没检查过，下拉或点右上角刷新。第一次只记录现有章节数。'
                : '上次检查：${dayLabel(DateTime.fromMillisecondsSinceEpoch(lastCheck))} ${hhmm(DateTime.fromMillisecondsSinceEpoch(lastCheck))} · 点条目直达最新章，点右侧 ⓘ 看详情'));
    final statusBar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        statusText,
        style: theme.textTheme.bodySmall?.copyWith(color: progress.error != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant),
      ),
    );

    final String bodyKey;
    Widget body;
    if (feed.isEmpty && !progress.running && progress.error != null) {
      bodyKey = 'upd-error';
      body = StatePanel(
        title: '检查更新失败',
        detail: progress.error,
        error: progress.errorObject,
        onRetry: () => ref.read(updateProvider.notifier).refresh(),
      );
    } else if (feed.isEmpty && !progress.running) {
      bodyKey = 'upd-empty';
      body = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (lastCheck != 0) SliverToBoxAdapter(child: statusBar),
          SliverFillRemaining(
            hasScrollBody: false,
            child: XEmpty(
              icon: lastCheck == 0 ? Icons.update_outlined : Icons.check_circle_outline,
              title: lastCheck == 0 ? '还没有检查过更新' : '暂时没有新章节',
              detail: lastCheck == 0 ? '下拉或点右上角刷新开始检查，\n第一次只记录书架中各本书的现有章节数。' : '书架里的书目前都是最新的，下拉可重新检查。',
            ),
          ),
        ],
      );
    } else {
      bodyKey = 'upd-list';
      body = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (context, i) => switch (rows[i]) {
          _UpdateStatusRow() => statusBar,
          _UpdateDayRow(:final label) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary))),
          _UpdateEntryRow(entry: final e) => ListTile(
            leading: SizedBox(width: 40, height: 54, child: CoverImage(covers.bookCover(e.aid, e.img), aid: e.aid, thumbnail: true, decodeSize: const Size(40, 54))),
            title: Text(LibraryStore.shown(e.aid, e.title), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${e.chapter} · ${hhmm(e.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (e.time.millisecondsSinceEpoch > _seen) ...[Icon(Icons.circle, size: 10, color: theme.colorScheme.primary), const SizedBox(width: 4)],
                IconButton(icon: const Icon(Icons.info_outline, size: 20), tooltip: hz(context, '书籍详情'), onPressed: () => context.push(Routes.novel(e.aid))),
              ],
            ),
            onTap: () => context.push(Routes.reader(e.aid, e.cid)),
            onLongPress: () => context.push(Routes.novel(e.aid)),
          ),
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('更新'),
        actions: [
          AppIconSwap(
            child: progress.running
                ? TextButton(key: const ValueKey('cancel'), onPressed: () => ref.read(updateProvider.notifier).cancel(), child: const Text('取消'))
                : IconButton(key: const ValueKey('refresh'), tooltip: hz(context, '检查更新'), icon: const Icon(Icons.refresh), onPressed: () => ref.read(updateProvider.notifier).refresh()),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(progress.running ? 2 : 0),
          child: AppCollapse(
            visible: progress.running,
            duration: AppMotion.fast,
            reverseDuration: AppMotion.fast,
            child: progress.total == 0
                ? const LinearProgressIndicator(minHeight: 2)
                : AppProgressBar(value: progress.done / progress.total, minHeight: 2, borderRadius: 0),
          ),
        ),
      ),
      body: contentWidth(
        RefreshIndicator(
          onRefresh: () => ref.read(updateProvider.notifier).refresh(),
          child: AppCrossfade(fill: true, duration: AppMotion.fast, child: KeyedSubtree(key: ValueKey(bodyKey), child: body)),
        ),
      ),
    );
  }
}

sealed class _UpdateRow {
  const _UpdateRow();
}

final class _UpdateStatusRow extends _UpdateRow {
  const _UpdateStatusRow();
}

final class _UpdateDayRow extends _UpdateRow {
  const _UpdateDayRow(this.label);

  final String label;
}

final class _UpdateEntryRow extends _UpdateRow {
  const _UpdateEntryRow(this.entry);

  final UpdateEntry entry;
}
