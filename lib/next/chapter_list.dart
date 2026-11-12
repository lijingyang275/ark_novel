import 'package:flutter/material.dart' hide Text;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'text.dart';

/// 详情页目录的筛选、排序、显示方式（Mihon 的"章节设置"）。每本书一份，可以存成默认、也可以重置回默认。
/// 筛选是三态：0 不限 1 必须满足 2 必须不满足。
class ChapterListOptions {
  const ChapterListOptions({this.unread = 0, this.bookmarked = 0, this.cached = 0, this.reverse = false, this.showIndex = false});

  final int unread;
  final int bookmarked;
  final int cached;
  final bool reverse;

  /// 章节标题前面加上序号（第几章，按网站顺序数）
  final bool showIndex;

  bool get filtering => unread + bookmarked + cached > 0;

  ChapterListOptions copyWith({int? unread, int? bookmarked, int? cached, bool? reverse, bool? showIndex}) => ChapterListOptions(
    unread: unread ?? this.unread,
    bookmarked: bookmarked ?? this.bookmarked,
    cached: cached ?? this.cached,
    reverse: reverse ?? this.reverse,
    showIndex: showIndex ?? this.showIndex,
  );

  Map<String, Object> toMap() => {'unread': unread, 'bookmarked': bookmarked, 'cached': cached, 'reverse': reverse, 'showIndex': showIndex};

  static ChapterListOptions fromMap(Map m) => ChapterListOptions(
    unread: (m['unread'] as int?) ?? 0,
    bookmarked: (m['bookmarked'] as int?) ?? 0,
    cached: (m['cached'] as int?) ?? 0,
    reverse: (m['reverse'] as bool?) ?? false,
    showIndex: (m['showIndex'] as bool?) ?? false,
  );

  static Box get _box => Hive.box('session');

  /// 默认设置；老版本只存了"倒序"，从那里接过来
  static ChapterListOptions get defaults {
    final m = _box.get('chl:default');
    return m is Map ? fromMap(m) : ChapterListOptions(reverse: (_box.get('catReverse') as bool?) ?? false);
  }

  static ChapterListOptions of(String aid) {
    final m = _box.get('chl:$aid');
    return m is Map ? fromMap(m) : defaults;
  }

  static Future<void> save(String aid, ChapterListOptions o) => _box.put('chl:$aid', o.toMap());

  static Future<void> saveDefault(ChapterListOptions o) => _box.put('chl:default', o.toMap());

  static Future<void> reset(String aid) => _box.delete('chl:$aid');
}

/// 三态筛选：0 不限，1 必须满足，2 必须不满足
bool chapterTri(int state, bool Function() test) => state == 0 || test() == (state == 1);

/// 弹出目录设置：筛选、排序、显示；[onChanged] 在每次改动后调用（外面据此刷新并拿新的设置）。
Future<void> showChapterListSheet(BuildContext context, String aid, ValueChanged<ChapterListOptions> onChanged) {
  var o = ChapterListOptions.of(aid);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void set(ChapterListOptions v) {
          setState(() => o = v);
          ChapterListOptions.save(aid, v);
          onChanged(v);
        }

        final theme = Theme.of(context);
        Widget title(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 8), child: Text(t, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)));
        Widget tri(String label, int v, ChapterListOptions Function(int) apply) => FilterChip(
          avatar: v == 0 ? null : Icon(v == 1 ? Icons.check : Icons.block, size: 16),
          label: Text(label, style: v == 2 ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
          selected: v != 0,
          showCheckmark: false,
          onSelected: (_) => set(apply((v + 1) % 3)),
        );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title('筛选'),
                Wrap(
                  spacing: 8,
                  children: [
                    tri('未读', o.unread, (v) => o.copyWith(unread: v)),
                    tri('有书签', o.bookmarked, (v) => o.copyWith(bookmarked: v)),
                    tri('已缓存', o.cached, (v) => o.copyWith(cached: v)),
                  ],
                ),
                title('排序'),
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: false, label: Text('正序')), ButtonSegment(value: true, label: Text('倒序'))],
                  selected: {o.reverse},
                  onSelectionChanged: (v) => set(o.copyWith(reverse: v.first)),
                ),
                title('显示'),
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: false, label: Text('只显示标题')), ButtonSegment(value: true, label: Text('标题前加序号'))],
                  selected: {o.showIndex},
                  onSelectionChanged: (v) => set(o.copyWith(showIndex: v.first)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        await ChapterListOptions.saveDefault(o);
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已存为所有书的默认')));
                      },
                      child: const Text('存为默认'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await ChapterListOptions.reset(aid);
                        set(ChapterListOptions.defaults);
                        await ChapterListOptions.reset(aid); // set 会把默认值存成这本书自己的，再清掉，让它继续跟着默认走
                      },
                      child: const Text('重置为默认'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
