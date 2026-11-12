import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library.dart';
import '../router.dart';
import '../updates.dart';
import '../widgets.dart';
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
  late final int _seen = UpdateStore.lastSeen;

  @override
  void dispose() {
    UpdateStore.markSeen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ref.watch(updateProvider);
    final feed = UpdateStore.feed();
    final lastCheck = UpdateStore.lastCheck;

    final rows = <Widget>[];
    String? day;
    for (final e in feed) {
      final label = dayLabel(e.time);
      if (label != day) {
        day = label;
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary))));
      }
      rows.add(
        ListTile(
          leading: SizedBox(width: 40, height: 54, child: CoverImage(e.img)),
          title: Text(LibraryStore.shown(e.aid, e.title), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${e.chapter} · ${hhmm(e.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: e.time.millisecondsSinceEpoch > _seen ? Icon(Icons.circle, size: 10, color: theme.colorScheme.primary) : null,
          onTap: () => context.push(Routes.reader(e.aid, e.cid)),
          onLongPress: () => context.push(Routes.novel(e.aid)),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('更新'),
        actions: [IconButton(tooltip: hz(context, '检查更新'), icon: const Icon(Icons.refresh), onPressed: progress.running ? null : () => ref.read(updateProvider.notifier).refresh())],
        bottom: progress.running ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: progress.total == 0 ? null : progress.done / progress.total, minHeight: 2)) : null,
      ),
      body: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    progress.error ?? (progress.running ? '正在检查 ${progress.done}/${progress.total}' : (lastCheck == 0 ? '还没检查过，点右上角刷新。第一次只记录现有章节数。' : '上次检查：${dayLabel(DateTime.fromMillisecondsSinceEpoch(lastCheck))} ${hhmm(DateTime.fromMillisecondsSinceEpoch(lastCheck))}')),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (feed.isEmpty && lastCheck != 0 && !progress.running) const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('书架里的书暂时没有新章节'))),
                ...rows,
              ],
            ),
    );
  }
}
