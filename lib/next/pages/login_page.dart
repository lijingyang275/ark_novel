import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/common/wenku8_node.dart';
import '../env.dart';
import '../motion.dart';
import '../routes.dart';
import '../session.dart';
import 'login_webview_page.dart';
import '../text.dart';

/// 登录页。游客在需要账号时按需打开，登录成功后自动返回上一页。
///
/// 账号密码表单，可选登录有效期，可记住账号密码。原生 App 额外可选线路和 HTTP 代理；
/// 网页预览由服务器上的转发程序提交。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final _proxy = TextEditingController(text: ref.read(sessionStoreProvider).proxy);
  late int _keepSeconds = ref.read(sessionStoreProvider).keepSeconds;
  bool _remember = false;
  bool _showPassword = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(sessionStoreProvider).loadLogin().then((saved) {
      if (saved == null || !mounted) return;
      setState(() {
        _remember = true;
        _username.text = saved.$1;
        _password.text = saved.$2;
      });
    });
  }

  @override
  void dispose() {
    _proxy.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e is String ? e : friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() => _run(() async {
    final store = ref.read(sessionStoreProvider);
    final username = _username.text.trim();
    if (username.isEmpty || _password.text.isEmpty) throw '请输入用户名和密码';
    final cleanProxy = _proxy.text.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').trim();
    if (cleanProxy != _proxy.text) _proxy.text = cleanProxy;
    await ref.read(proxyProvider.notifier).set(cleanProxy);
    await store.setKeepSeconds(_keepSeconds);
    if (isWebPreview) {
      await ref.read(sessionProvider.notifier).loginWithPassword(username, _password.text, _keepSeconds);
    } else {
      if (!mounted) return;
      final result = await Navigator.of(context).push<WebSessionResult>(
        MaterialPageRoute(
          builder: (_) => LoginWebViewPage(url: '${siteBase(ref.read(nodeProvider))}/login.php', title: '登录轻小说文库', username: username, password: _password.text, keepSeconds: _keepSeconds),
        ),
      );
      if (result == null) return;
      await ref.read(sessionProvider.notifier).loginWithCookie(result.cookies, userAgent: result.userAgent);
    }
    await store.saveLogin(_remember ? username : null, _remember ? _password.text : null);
    // 从详情、搜索等子页面点进来登录时返回原页面；否则回书架
    if (mounted) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.bookshelf);
      }
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final notice = _error ?? (session is SessionLoggedOut ? session.message : null);

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Builder(
                        builder: (context) {
                          final px = (72 * MediaQuery.devicePixelRatioOf(context)).round();
                          return Image.asset('assets/images/logo.png', height: 72, cacheWidth: px, cacheHeight: px);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text('登录', style: theme.textTheme.displaySmall),
                  const SizedBox(height: 10),
                  Text('登录轻小说文库账号后继续阅读。', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 32),
                  ..._form(theme),
                  AppCollapse(
                    visible: notice != null,
                    duration: AppMotion.standard,
                    reverseDuration: AppMotion.fast,
                    child: notice == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 16), child: _Notice(text: notice)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _keepOptions = [(86400, '一天'), (2592000, '一个月'), (315360000, '永久')];

  List<Widget> _form(ThemeData theme) {
    return [
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _username,
              enabled: !_busy,
              decoration: const InputDecoration(label: Text('用户名')),
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                label: const Text('密码'),
                suffixIcon: IconButton(
                  tooltip: hz(context, _showPassword ? '隐藏密码' : '显示密码'),
                  icon: AppIconSwap(child: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, key: ValueKey(_showPassword), size: 20)),
                  onPressed: _busy ? null : () => setState(() => _showPassword = !_showPassword),
                ),
              ),
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Text('保持登录', style: theme.textTheme.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [for (final (seconds, label) in _keepOptions) ButtonSegment(value: seconds, label: Text(label))],
        selected: {_keepSeconds},
        onSelectionChanged: _busy ? null : (s) => setState(() => _keepSeconds = s.first),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('记住用户名和密码'),
        value: _remember,
        onChanged: _busy ? null : (v) => setState(() => _remember = v ?? false),
      ),
      if (!isWebPreview) ...[
        const SizedBox(height: 8),
        Text('线路', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<Wenku8Node>(
          segments: const [
            ButtonSegment(value: Wenku8Node.wwwWenku8Net, label: Text('wenku8.net')),
            ButtonSegment(value: Wenku8Node.wwwWenku8Cc, label: Text('wenku8.cc')),
          ],
          selected: {ref.watch(nodeProvider)},
          onSelectionChanged: _busy
              ? null
              : (s) async {
                  await ref.read(nodeProvider.notifier).set(s.first);
                },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _proxy,
          enabled: !_busy,
          decoration: const InputDecoration(label: Text('HTTP 代理（可选）'), hint: Text('127.0.0.1:7890', maxLines: 1, overflow: TextOverflow.ellipsis)),
        ),
        const SizedBox(height: 4),
        Text('连不上时填写（无需加 http://）。App 不会自动读取系统代理。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('系统网络栈'),
          subtitle: Text('更容易通过 Cloudflare 验证，切换后立即生效（设了代理时不启用）', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          value: ref.watch(nativeNetProvider),
          onChanged: _busy ? null : (v) => ref.read(nativeNetProvider.notifier).set(v),
        ),
      ],
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: AppPressScale(
          scale: 0.975,
          enabled: !_busy,
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: AppCrossfade(
              duration: AppMotion.fast,
              child: _busy ? const _ButtonSpinner(key: ValueKey('spin')) : const Text('登录', key: ValueKey('lbl')),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('${siteBase(ref.read(nodeProvider))}/register.php'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('没有账号？前往轻小说文库注册'),
        ),
      ),
      Text(
        '提示：文库新注册账号通常需等待一段时间后才能使用搜索等功能；不登录也可直接浏览推荐与阅读已缓存章节。',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      if (isWebPreview) ...[
        const SizedBox(height: 8),
        Text('预览版：账号密码由你的服务器转交给轻小说文库，不会经过其他地方。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    ];
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary));
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(color: scheme.primary)),
    );
  }
}
