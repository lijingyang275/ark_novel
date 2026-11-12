import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/common/wenku8_node.dart';
import '../session.dart';
import '../web_fetch.dart';
import '../text.dart';

class WebSessionResult {
  const WebSessionResult(this.cookies, this.userAgent);

  /// 站点的全部 cookie（`a=1;b=2`）
  final String cookies;

  /// WebView 的真实 User-Agent，Dio 要用同一个，Cloudflare 才认放行 cookie
  final String? userAgent;
}

/// 内嵌浏览器页，两种用法：
/// - 登录（[username] 不为空）：打开登录页，过完 Cloudflare 验证后把用户名、密码、有效期填进表单提交，出现登录 cookie 后返回
/// - 验证（[username] 为空）：只打开站点，让用户通过 Cloudflare 验证（游客、已登录都能用），出现 `cf_clearance` 后返回，也可以点右上角"完成"
///
/// 只在登录页本身的域名上、表单提交到同一域名时才自动填密码。
class LoginWebViewPage extends ConsumerStatefulWidget {
  const LoginWebViewPage({super.key, required this.url, required this.title, this.username, this.password, this.keepSeconds = 0, this.onDone});

  final String url;
  final String title;
  final String? username;
  final String? password;
  final int keepSeconds;

  /// 不为空时用它接收结果（路由页用），否则 pop 返回
  final Future<void> Function(WebSessionResult result)? onDone;

  bool get isLogin => username != null;

  @override
  ConsumerState<LoginWebViewPage> createState() => _LoginWebViewPageState();
}

/// [host] 是不是 [root] 这个站点（或它的子域名）。只比后缀的话 `evilwenku8.net` 也算，会把密码填进仿冒站。
bool isSameSite(String host, String root) => host == root || host.endsWith('.$root');

class _LoginWebViewPageState extends ConsumerState<LoginWebViewPage> {
  final _cookieManager = CookieManager.instance();
  late final String _host = Uri.parse(widget.url).host;
  // 站点可能在 wenku8.net 和 www.wenku8.net 之间跳转，按主域名判断
  late final String _root = _host.split('.').reversed.take(2).toList().reversed.join('.');
  String _status = '';
  bool _ready = false;
  bool _done = false;
  bool _submitted = false;
  int _progress = 0;
  String? _ua;
  final _events = <String>[]; // 最近的页面加载 / 报错记录，复制诊断信息时带上

  void _log(String line) {
    _events.add('${DateTime.now().toIso8601String().substring(11, 19)} $line');
    if (_events.length > 12) _events.removeAt(0);
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    await applyWebViewProxy(ref.read(sessionStoreProvider).proxy);
    if (widget.isLogin) {
      // 只清掉旧的登录 cookie，保留 Cloudflare 的放行 cookie，免得又要验证一遍
      for (final c in await _cookieManager.getCookies(url: WebUri(widget.url))) {
        if (c.name.startsWith('jieqi')) await _cookieManager.deleteCookie(url: WebUri(widget.url), name: c.name);
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  /// 找到带密码框的表单，确认提交地址和当前页面同域、https，再填值提交。返回 null 表示已提交，否则是没填的原因（例如还在验证页）。
  Future<String?> _fillAndSubmit(InAppWebViewController c) async {
    final js = '''
(() => {
  const pass = document.querySelector('input[name=password]');
  const form = pass && pass.form;
  if (!form) return '页面上没有登录表单';
  const action = new URL(form.getAttribute('action') || location.href, location.href);
  if (action.host !== location.host) return '表单提交到其他域名：' + action.host;
  if (action.protocol !== 'https:') return '表单不是 https 提交';
  form.querySelector('input[name=username]').value = ${_js(widget.username!)};
  pass.value = ${_js(widget.password!)};
  const keep = form.querySelector('[name=usecookie]');
  if (keep) {
    const want = '${widget.keepSeconds}';
    if (keep.tagName === 'SELECT' && ![...keep.options].some(o => o.value === want)) {
      const opts = [...keep.options].map(o => +o.value).filter(v => v > 0).sort((a, b) => a - b);
      keep.value = String([...opts].reverse().find(v => v <= ${widget.keepSeconds}) ?? opts[opts.length - 1]);
    } else {
      keep.value = want;
    }
  }
  form.submit();
  return 'ok';
})()
''';
    final r = await c.evaluateJavascript(source: js);
    return r == 'ok' ? null : '$r';
  }

  static String _js(String s) => jsonEncode(s);

  /// 站点可能跳到 http 页面（例如 http 的 login.php，会被系统拦成报错页），按 http 地址取不到 Secure 的 `cf_clearance`，统一按 https 取
  Future<List<Cookie>> _cookiesOf(WebUri uri) => _cookieManager.getCookies(url: uri.scheme == 'http' ? WebUri.uri(uri.replace(scheme: 'https')) : uri);

  Future<void> _finish(InAppWebViewController c, WebUri uri) async {
    if (_done) return;
    _done = true;
    try {
      final cookies = await _cookiesOf(uri);
      final result = WebSessionResult(cookies.map((e) => '${e.name}=${e.value}').join(';'), _ua);
      if (widget.onDone != null) {
        await widget.onDone!(result);
      } else if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      // 出错了还能再点"完成"重试
      _done = false;
      _log('完成时出错：$e');
      if (mounted) setState(() => _status = '完成时出错：$e');
    }
  }

  Future<void> _check(InAppWebViewController c, WebUri? uri) async {
    if (_done || uri == null) return;
    _log('加载完成 ${uri.host}${uri.path}');
    if (!isSameSite(uri.host, _root)) {
      if (mounted) setState(() => _status = '当前在其他域名 ${uri.host}，不会自动填表（登录页是 $_host）');
      return;
    }
    _ua ??= (await c.evaluateJavascript(source: 'navigator.userAgent')) as String?;
    final names = (await _cookiesOf(uri)).map((e) => e.name).toSet();
    if (mounted) setState(() => _status = '${uri.host}${uri.path}  登录cookie：${names.any((n) => n.startsWith('jieqiUserInfo')) ? '有' : '无'}  已填表：${_submitted ? '是' : '否'}');
    if (widget.isLogin) {
      if (names.any((n) => n.startsWith('jieqiUserInfo'))) return _finish(c, uri);
      String? why;
      if (!_submitted) {
        why = await _fillAndSubmit(c);
        _submitted = why == null;
        if (why != null) _log('没填表：$why');
      }
      if (mounted) setState(() => _status = '${uri.host}${uri.path}  登录cookie：无  已填表：${_submitted ? '是' : '否${why == null ? '' : '（$why）'}'}');
    } else if (names.contains('cf_clearance')) {
      await _finish(c, uri);
    }
  }

  /// 登录出问题时复制：当前地址、cookie 名（不含值）、页面上的表单结构（不含已填的值）。
  Future<void> _copyDiagnostics() async {
    final c = _controller;
    if (c == null) return;
    final url = await c.getUrl();
    final names = url == null ? <String>[] : (await _cookiesOf(url)).map((e) => e.name).toList();
    final forms = await c.evaluateJavascript(source: "JSON.stringify([...document.forms].map(f => ({action: f.getAttribute('action'), fields: [...f.elements].map(e => e.name + ':' + e.type)})))");
    final info = '地址：$url\ncookie 名：${names.join(',')}\nUA：$_ua\n表单：$forms\n状态：$_status\n最近记录：\n${_events.join('\n')}';
    await Clipboard.setData(ClipboardData(text: info));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制诊断信息')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_ready) IconButton(tooltip: hz(context, '复制诊断信息'), icon: const Icon(Icons.bug_report_outlined), onPressed: _copyDiagnostics),
          if (_ready)
            TextButton(
              onPressed: () async {
                final c = _controller;
                if (c != null) await _finish(c, (await c.getUrl()) ?? WebUri(widget.url));
              },
              child: const Text('完成'),
            ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100, minHeight: 2),
              )
            : null,
      ),
      bottomNavigationBar: _status.isEmpty ? null : Padding(padding: const EdgeInsets.all(8), child: Text(_status, style: Theme.of(context).textTheme.bodySmall)),
      body: !_ready
          ? const SizedBox.shrink()
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
              onWebViewCreated: (c) => _controller = c,
              onProgressChanged: (_, p) {
                if (mounted) setState(() => _progress = p);
              },
              onLoadStop: _check,
              onReceivedError: (_, req, err) => _log('出错 ${req.url.host}${req.url.path}：${err.description}'),
              onReceivedHttpError: (_, req, res) => _log('HTTP ${res.statusCode} ${req.url.host}${req.url.path}'),
            ),
    );
  }

  InAppWebViewController? _controller;
}

/// "去验证"路由页：打开当前线路的首页过 Cloudflare 验证，通过后写回 cookie、重新确认登录状态并返回。
class VerifyPage extends ConsumerWidget {
  const VerifyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ref.watch(nodeProvider);
    return LoginWebViewPage(
      url: '${siteBase(node)}/',
      title: '验证（${node.node.replaceFirst('https://www.', '')}）',
      onDone: (r) async {
        await ref.read(sessionProvider.notifier).afterVerify(r.cookies, userAgent: r.userAgent);
        if (context.mounted) context.pop();
      },
    );
  }
}
