import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/comment_item.dart';
import '../../models/reply_item.dart';
import '../data.dart';
import '../router.dart';
import '../session.dart';
import '../widgets.dart';
import '../text.dart';

/// 分页加载书评 / 回复的通用列表，底部输入框发表。
class _ThreadList<T> extends ConsumerStatefulWidget {
  const _ThreadList({super.key, required this.fetch, required this.itemBuilder, required this.send, required this.hint});

  final Future<List<T>> Function(int page) fetch;
  final Widget Function(BuildContext, T) itemBuilder;
  final Future<void> Function(String text) send;
  final String hint;

  @override
  ConsumerState<_ThreadList<T>> createState() => _ThreadListState<T>();
}

class _ThreadListState<T> extends ConsumerState<_ThreadList<T>> {
  final _items = <T>[];
  final _input = TextEditingController();
  int _page = 0;
  bool _loading = false, _end = false, _sending = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!reset && _end)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = reset ? 1 : _page + 1;
      final list = await widget.fetch(next);
      if (!mounted) return;
      setState(() {
        if (reset) {
          _items.clear();
          _end = false;
        }
        _items.addAll(list);
        _page = next;
        if (list.isEmpty) _end = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (ref.read(sessionProvider) is! SessionLoggedIn) {
      context.push(Routes.login);
      return;
    }
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.send(text);
      _input.clear(); // 发送成功才清空，失败时保留输入
      await _load(reset: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _items.isEmpty
              ? (_loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: () => _load(reset: true), child: StatePanel(title: _error != null ? '加载失败' : '还没有内容', detail: _error?.toString(), error: _error, onRetry: _error != null ? () => _load(reset: true) : null)))
              : RefreshIndicator(
                  onRefresh: () => _load(reset: true),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 400) _load();
                      return false;
                    },
                    child: ListView.builder(padding: const EdgeInsets.all(16), itemCount: _items.length, itemBuilder: (c, i) => widget.itemBuilder(c, _items[i])),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(controller: _input, minLines: 1, maxLines: 4, decoration: InputDecoration(hint: Text(widget.hint, maxLines: 1, overflow: TextOverflow.ellipsis))),
                ),
                IconButton(onPressed: _sending ? null : _send, icon: const Icon(Icons.send_outlined)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

Widget _card(BuildContext context, {required String user, required String time, required String body, String? footer, VoidCallback? onTap}) {
  final theme = Theme.of(context);
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
            const SizedBox(height: 8),
            Text([time, ?footer].join('　'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    ),
  );
}

class CommentsPage extends ConsumerWidget {
  const CommentsPage({super.key, required this.aid});

  final String aid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('书评')),
      body: _ThreadList<CommentItem>(
        fetch: (page) => api.comments(aid, page),
        hint: '写下你的书评',
        send: (text) => api.sendComment(aid, text.length > 20 ? text.substring(0, 20) : text, text),
        itemBuilder: (context, c) => _card(context, user: c.userName, time: c.time, body: c.content, footer: '回复 ${c.replyCount}　查看 ${c.viewCount}', onTap: () => context.push(Routes.replies(aid, c.rid))),
      ),
    );
  }
}

class RepliesPage extends ConsumerWidget {
  const RepliesPage({super.key, required this.aid, required this.rid});

  final String aid;
  final String rid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('回复')),
      body: _ThreadList<ReplyItem>(
        fetch: (page) => api.replies(rid, page),
        hint: '写下你的回复',
        send: (text) => api.sendReply(aid, rid, text),
        itemBuilder: (context, r) => _card(context, user: r.userName, time: r.time, body: r.content),
      ),
    );
  }
}
