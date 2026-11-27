import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/comment_item.dart';
import '../../models/reply_item.dart';
import '../data.dart';
import '../routes.dart';
import '../session.dart';
import '../widgets.dart';
import '../text.dart';

/// 单页书评请求：离页或刷新时自动 cancel 对应 Dio 请求。
final commentsProvider = FutureProvider.autoDispose.family<List<CommentItem>, (String aid, int page)>((ref, arg) {
  final (aid, page) = arg;
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) cancelToken.cancel('disposed');
  });
  return ref.watch(apiProvider).comments(aid, page, cancelToken: cancelToken);
});

/// 单页回复请求：离页或刷新时自动 cancel 对应 Dio 请求。
final repliesProvider = FutureProvider.autoDispose.family<List<ReplyItem>, (String rid, int page)>((ref, arg) {
  final (rid, page) = arg;
  final cancelToken = CancelToken();
  ref.onDispose(() {
    if (!cancelToken.isCancelled) cancelToken.cancel('disposed');
  });
  return ref.watch(apiProvider).replies(rid, page, cancelToken: cancelToken);
});

/// 分页加载书评 / 回复的通用列表，底部输入框发表。
class _ThreadList<T> extends ConsumerStatefulWidget {
  const _ThreadList({super.key, required this.providerFor, required this.itemBuilder, required this.send, required this.hint});

  final FutureProvider<List<T>> Function(int page) providerFor;
  final Widget Function(BuildContext, T) itemBuilder;
  final Future<void> Function(String text) send;
  final String hint;

  @override
  ConsumerState<_ThreadList<T>> createState() => _ThreadListState<T>();
}

class _ThreadListState<T> extends ConsumerState<_ThreadList<T>> {
  final _items = <T>[];
  final _input = TextEditingController();
  ProviderSubscription<Future<List<T>>>? _inflightSub;
  int _loadGen = 0;
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
    _loadGen++;
    _inflightSub?.close();
    _inflightSub = null;
    _input.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if ((_loading && !reset) || (!reset && _end)) return;
    final gen = ++_loadGen;
    _inflightSub?.close();
    _inflightSub = null;
    setState(() {
      _loading = true;
      _error = null;
    });
    final next = reset ? 1 : _page + 1;
    final provider = widget.providerFor(next);
    if (reset) ref.invalidate(provider);
    final sub = ref.listenManual(provider.future, (_, _) {});
    _inflightSub = sub;
    try {
      final list = await sub.read();
      if (!mounted || gen != _loadGen) return;
      setState(() {
        if (reset) {
          _items.clear();
          _end = false;
        }
        _items.addAll(list);
        _page = next;
        if (list.isEmpty) _end = true;
      });
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (mounted && gen == _loadGen) setState(() => _error = e);
    } catch (e) {
      if (mounted && gen == _loadGen) setState(() => _error = e);
    } finally {
      if (identical(_inflightSub, sub)) {
        sub.close();
        _inflightSub = null;
      }
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (ref.read(sessionProvider) is! SessionLoggedIn) {
      await context.push(Routes.login);
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(sessionProvider.select((s) => s is SessionLoggedIn));
    final theme = Theme.of(context);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget footer() {
      if (_error != null) return Center(child: TextButton(onPressed: _load, child: const Text('加载失败，点击重试')));
      if (_loading) return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
      if (_end) return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Center(child: Text('没有更多了', style: hintStyle)));
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        Expanded(
          child: _items.isEmpty
              ? (_loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: () => _load(reset: true),
                        child: StatePanel(title: _error != null ? '加载失败' : '还没有内容', detail: _error?.toString(), error: _error, onRetry: _error != null ? () => _load(reset: true) : null),
                      ))
              : RefreshIndicator(
                  onRefresh: () => _load(reset: true),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (_error == null && !_end && n.metrics.extentAfter < 400) _load();
                      return false;
                    },
                    child: contentWidth(
                      ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _items.length + 1,
                        itemBuilder: (c, i) => i < _items.length ? widget.itemBuilder(c, _items[i]) : footer(),
                      ),
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: contentWidth(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: loggedIn
                  ? Row(
                      children: [
                        Expanded(
                          child: TextField(controller: _input, minLines: 1, maxLines: 4, decoration: InputDecoration(hint: Text(widget.hint, maxLines: 1, overflow: TextOverflow.ellipsis))),
                        ),
                        IconButton(
                          tooltip: hz(context, '发送'),
                          onPressed: _sending ? null : _send,
                          icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_outlined),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: Text('登录后可发表评论与回复', style: hintStyle)),
                        TextButton(onPressed: () => context.push(Routes.login), child: const Text('去登录')),
                      ],
                    ),
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
    return Scaffold(
      appBar: AppBar(title: const Text('书评')),
      body: _ThreadList<CommentItem>(
        key: ValueKey('comments:$aid'),
        providerFor: (page) => commentsProvider((aid, page)),
        hint: '写下你的书评',
        send: (text) => ref.read(apiProvider).sendComment(aid, text.length > 20 ? text.substring(0, 20) : text, text),
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
    return Scaffold(
      appBar: AppBar(title: const Text('回复')),
      body: _ThreadList<ReplyItem>(
        key: ValueKey('replies:$rid'),
        providerFor: (page) => repliesProvider((rid, page)),
        hint: '写下你的回复',
        send: (text) => ref.read(apiProvider).sendReply(aid, rid, text),
        itemBuilder: (context, r) => _card(context, user: r.userName, time: r.time, body: r.content),
      ),
    );
  }
}
