import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/wenku8/wenku8_client.dart';
import '../../models/common/wenku8_node.dart';
import '../session.dart';
import '../web_fetch.dart';
import '../text.dart';

class WebSessionResult {
  const WebSessionResult(this.cookies, this.userAgent, {this.origin});

  /// 站点的全部 cookie（`a=1;b=2`）
  final String cookies;

  /// WebView 的真实 User-Agent，Dio 要用同一个，Cloudflare 才认放行 cookie
  final String? userAgent;

  /// 实际完成登录/验证时的站点 origin（例如 `https://www.wenku8.cc`）
  final String? origin;
}

enum _GuardState { none, challenge, blocked }

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

/// 是否为轻小说文库主站域名（`wenku8.net` / `wenku8.cc` 及其子域名）。
bool isMainSiteHost(String host) => isSameSite(host, 'wenku8.net') || isSameSite(host, 'wenku8.cc');

/// 自动填表可信域名判定：同一站点及其子域名，或在文库两个官方主站（`wenku8.cc` 301 到 `wenku8.net`）之间跳转；
/// 仿冒域名（如 `evilwenku8.net`）仍严格拒绝。
bool isTrustedLoginHost(String currentHost, String initialHost) {
  final root = _rootDomainOf(initialHost);
  return isSameSite(currentHost, root) || (isMainSiteHost(initialHost) && isMainSiteHost(currentHost));
}

/// 文库站点常把首页或未登录请求 302 到明文 `http://www.wenku8.net/login.php`，
/// Android `network_security_config` 默认禁止主站明文 HTTP，会触发 `ERR_CLEARTEXT_NOT_PERMITTED`；
/// 拦截并升级为 `https://` 可避免白屏报错。
Uri? upgradeMainSiteHttp(Uri uri) => uri.scheme == 'http' && isMainSiteHost(uri.host) ? uri.replace(scheme: 'https') : null;

String _rootDomainOf(String host) => host.split('.').reversed.take(2).toList().reversed.join('.');

/// 验证模式下计算读取与回写 `cf_clearance` 的目标地址：
/// - 若站点在文库主站镜像间跳转（例如 `www.wenku8.cc` 301 到 `www.wenku8.net`），Cloudflare 实际在跳转后的主站域名下签发 `cf_clearance`，应跟随该主站域名；
/// - 若跳到非同站外部域名，则仍锚定最初请求验证的域名（统一 https）。
Uri resolveVerifyTargetUri(Uri initialUri, Uri? currentUri) {
  final root = _rootDomainOf(initialUri.host);
  final bothMainSite = currentUri != null && isMainSiteHost(initialUri.host) && isMainSiteHost(currentUri.host);
  final useInitial = currentUri == null || currentUri.host.isEmpty || (!bothMainSite && root.isNotEmpty && !isSameSite(currentUri.host, root));
  final chosen = useInitial ? initialUri : currentUri;
  return chosen.scheme == 'http' ? chosen.replace(scheme: 'https') : chosen;
}

/// 计算「去验证」页默认打开的目标地址：主站默认打开 `/login.php` 停留在当前线路，避免 `/` 直接踢去 `http://www.wenku8.net/login.php`。
String defaultVerifyUrl({required String? url, required String? host, required Wenku8Node node}) {
  if (url != null && url.isNotEmpty) {
    final parsed = Uri.tryParse(url);
    final upgraded = parsed == null ? null : upgradeMainSiteHttp(parsed);
    return (upgraded ?? parsed)?.toString() ?? url;
  }
  if (host != null && host.isNotEmpty) {
    return isMainSiteHost(host) ? 'https://$host/login.php' : 'https://$host/';
  }
  return '${siteBase(node)}/login.php';
}

class _LoginWebViewPageState extends ConsumerState<LoginWebViewPage> {
  final _cookieManager = CookieManager.instance();
  late final WebUri _initialUri = WebUri(widget.url);
  late final String _host = Uri.parse(widget.url).host;
  // 站点可能在 wenku8.net 和 www.wenku8.net 之间跳转，按主域名判断
  late final String _root = _rootDomainOf(_host);
  String _status = '';
  String _hint = '';
  bool _blocked = false;
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

  String _appleProxyNote() {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return '';
    final proxy = ref.read(sessionStoreProvider).proxy;
    return proxy.isEmpty ? '' : '（提示：当前平台验证页走系统网络，请确保系统代理出口与 App 内代理一致）';
  }

  @override
  void initState() {
    super.initState();
    final note = _appleProxyNote();
    _hint = (widget.isLogin ? '正在打开登录页，如遇人机验证请点击通过…' : '请在页面中完成人机验证，通过后将自动返回…') + note;
    _prepare();
  }

  Future<void> _prepare() async {
    await applyWebViewProxy(ref.read(sessionStoreProvider).proxy);
    final webUri = WebUri(widget.url);
    if (widget.isLogin) {
      // 只清掉旧的登录 cookie，保留 Cloudflare 的放行 cookie，免得又要验证一遍
      for (final c in await _cookieManager.getCookies(url: webUri)) {
        if (c.name.startsWith('jieqi')) await _cookieManager.deleteCookie(url: webUri, name: c.name);
      }
    } else {
      // 验证模式：清掉已失效的旧 cf_clearance，避免刚打开就误判已经通过验证；同时同步本地登录 cookie，避免主站把验证页踢去登录页
      for (final u in [webUri, WebUri('https://$_root/')]) {
        try {
          await _cookieManager.deleteCookie(url: u, name: 'cf_clearance');
          await _cookieManager.deleteCookie(url: u, name: 'cf_clearance', domain: '.$_root');
        } catch (_) {}
      }
      if (isMainSiteHost(_host)) {
        await syncWebViewLoginCookies(ref.read(sessionStoreProvider).cookie, ['https://$_host', 'https://www.wenku8.net', 'https://www.wenku8.cc']);
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
      final effective = widget.isLogin ? uri : WebUri.uri(resolveVerifyTargetUri(_initialUri, uri));
      _ua ??= await _readUserAgent(c);
      final cookies = await _cookiesOf(effective);
      final origin = effective.host.isEmpty ? null : 'https://${effective.host}';
      final result = WebSessionResult(cookies.map((e) => '${e.name}=${e.value}').join(';'), _ua, origin: origin);
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

  Future<String?> _readUserAgent(InAppWebViewController c) async {
    try {
      final raw = await c.evaluateJavascript(source: 'navigator.userAgent');
      return raw is String && raw.isNotEmpty ? raw : null;
    } catch (_) {
      return null;
    }
  }

  /// 验证模式下检查原始目标域名是否已拿到 `cf_clearance`（例如 `wenku8.cc` 过完 CF 后立即跳转到 `wenku8.net` 时）。
  Future<bool> _finishIfVerifyCleared(InAppWebViewController c, WebUri? currentUri) async {
    if (widget.isLogin || _done) return false;
    final target = WebUri.uri(resolveVerifyTargetUri(_initialUri, currentUri));
    final names = (await _cookiesOf(target)).map((e) => e.name).toSet();
    if (!names.contains('cf_clearance')) return false;
    await _finish(c, target);
    return true;
  }

  Future<_GuardState> _guardState(InAppWebViewController c) async {
    try {
      final title = await c.getTitle() ?? '';
      final lowerTitle = title.toLowerCase();
      if (lowerTitle.startsWith('access denied') ||
          title.contains('Attention Required') ||
          title.contains('已被封锁') ||
          lowerTitle.contains('have been blocked') ||
          lowerTitle.contains('error 1015') ||
          lowerTitle.contains('error 1020')) {
        return _GuardState.blocked;
      }
      if (title.contains('Just a moment') || title.contains('请稍候') || title.contains('Checking your browser')) {
        return _GuardState.challenge;
      }
      final dom = await c.evaluateJavascript(
        source: "!!document.querySelector('#challenge-form, #challenge-running, .cf-turnstile, #cf-challenge-running, iframe[src*=\"challenges.cloudflare.com\"]')",
      );
      if (dom == true) return _GuardState.challenge;
      final blockedBody = await c.evaluateJavascript(
        source: "(() => { const t = (document.body?.innerText || '').slice(0, 600).toLowerCase(); return t.includes('sorry, you have been blocked') || t.includes('you have been blocked') || t.includes('error 1015') || t.includes('error 1020'); })()",
      );
      if (blockedBody == true) return _GuardState.blocked;
      return _GuardState.none;
    } catch (_) {
      return _GuardState.none;
    }
  }

  Future<void> _check(InAppWebViewController c, WebUri? uri) async {
    if (_done || uri == null) return;
    _log('加载完成 ${uri.host}${uri.path}');
    _ua ??= await _readUserAgent(c);
    if (!widget.isLogin && await _finishIfVerifyCleared(c, uri)) return;
    if (!isTrustedLoginHost(uri.host, _host)) {
      if (mounted) {
        setState(() {
          _blocked = false;
          _status = widget.isLogin ? '当前在其他域名 ${uri.host}，不会自动填表（登录页是 $_host）' : '站点已跳转到 ${uri.host}（原验证域名 $_host）';
          _hint = widget.isLogin ? '当前跳转到 ${uri.host}，为保护账号安全未自动填写密码' : '站点已跳转到 ${uri.host}，若验证已完成可点右上角「完成」返回';
        });
      }
      return;
    }
    final guard = await _guardState(c);
    final names = (await _cookiesOf(uri)).map((e) => e.name).toSet();
    _status = '${uri.host}${uri.path}  登录cookie：${names.any((n) => n.startsWith('jieqiUserInfo')) ? '有' : '无'}  已填表：${_submitted ? '是' : '否'}';
    if (guard == _GuardState.blocked) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _hint = '当前网络/IP 已被 Cloudflare 拒绝访问（403 封锁页），无法通过点击验证解除，请尝试切换网络、更换代理节点或切换站点线路';
        });
      }
      return;
    }
    if (guard == _GuardState.challenge) {
      if (mounted) {
        setState(() {
          _blocked = false;
          _hint = '请点击完成页面中的 Cloudflare 人机验证，通过后将自动继续…${_appleProxyNote()}';
        });
      }
      return;
    }
    if (_blocked && mounted) setState(() => _blocked = false);
    if (widget.isLogin) {
      if (names.any((n) => n.startsWith('jieqiUserInfo'))) return _finish(c, uri);
      String? why;
      if (!_submitted) {
        why = await _fillAndSubmit(c);
        _submitted = why == null;
        if (why != null) _log('没填表：$why');
        if (mounted) setState(() => _hint = _submitted ? '已自动提交登录信息，正在等待站点响应…' : '请在页面中完成验证或直接手动登录');
      } else {
        // 已自动提交过一次但未拿到登录 cookie：读取网页上的错误提示（密码错误、验证码等），允许用户在网页内直接重填
        String? pageErr;
        try {
          final raw = await c.evaluateJavascript(source: "(document.querySelector('.blockcontent')?.innerText || '').trim()");
          if (raw is String && raw.isNotEmpty) {
            pageErr = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('您可以') && !l.contains('返回上一页')).firstOrNull;
          }
        } catch (_) {}
        if (mounted) {
          setState(() => _hint = pageErr != null ? '登录未通过：$pageErr（可直接在下方页面重试，成功后自动返回）' : '未检测到登录状态，可直接在下方页面手动登录后点右上角「完成」');
        }
      }
      _status = '${uri.host}${uri.path}  登录cookie：无  已填表：${_submitted ? '是' : '否${why == null ? '' : '（$why）'}'}';
    } else if (names.contains('cf_clearance')) {
      await _finish(c, uri);
    } else if (mounted) {
      setState(() => _hint = '页面已加载，若已正常显示网站内容可点右上角「完成」返回');
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
      bottomNavigationBar: _hint.isEmpty
          ? null
          : Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        _blocked ? Icons.block_outlined : Icons.info_outline,
                        size: 16,
                        color: _blocked ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _hint,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: _blocked ? Theme.of(context).colorScheme.error : null),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      body: !_ready
          ? const SizedBox.shrink()
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              // Android 15/16 + Impeller 下 Hybrid Composition 容易导致 WebView 网页输入框无法唤起软键盘，使用 TLHC（useHybridComposition: false）修复输入焦点
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                useHybridComposition: false,
                needInitialFocus: true,
              ),
              onWebViewCreated: (c) => _controller = c,
              onProgressChanged: (_, p) {
                if (mounted) setState(() => _progress = p);
              },
              shouldOverrideUrlLoading: (c, action) async {
                final target = action.request.url;
                if (target == null || action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
                if (!widget.isLogin && !isSameSite(target.host, _root)) {
                  if (await _finishIfVerifyCleared(c, _initialUri)) return NavigationActionPolicy.CANCEL;
                }
                final upgraded = upgradeMainSiteHttp(target);
                if (upgraded != null) {
                  _log('升级 HTTPS ${upgraded.host}${upgraded.path}');
                  await c.loadUrl(urlRequest: URLRequest(url: WebUri.uri(upgraded)));
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStop: _check,
              onReceivedError: (c, req, err) {
                _log('出错 ${req.url.host}${req.url.path}：${err.description}');
                if (!widget.isLogin && !_done && req.isForMainFrame != false) {
                  _finishIfVerifyCleared(c, _initialUri);
                }
              },
              onReceivedHttpError: (_, req, res) => _log('HTTP ${res.statusCode} ${req.url.host}${req.url.path}'),
            ),
    );
  }

  InAppWebViewController? _controller;
}

/// "去验证"路由页：打开目标地址/域名（主站默认当前线路登录页，避免 `/` 重定向到另一域名的明文 HTTP）过 Cloudflare 验证，通过后写回 cookie 并返回 `true` 供原页面自动重试。
class VerifyPage extends ConsumerWidget {
  const VerifyPage({super.key, this.url, this.host});

  /// 可选目标验证地址（例如特定被拦页面或图床 URL）
  final String? url;

  /// 可选目标验证域名（例如 `www.wenku8.cc` 或 `pic.wenku8.com`）
  final String? host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ref.watch(nodeProvider);
    final targetUrl = defaultVerifyUrl(url: url, host: host, node: node);
    final targetHost = Uri.tryParse(targetUrl)?.host ?? '';
    final label = targetHost.isEmpty ? node.node.replaceFirst('https://www.', '') : targetHost.replaceFirst('www.', '');
    return LoginWebViewPage(
      url: targetUrl,
      title: '验证（$label）',
      onDone: (r) async {
        final origin = r.origin ?? (targetHost.isEmpty ? null : 'https://$targetHost');
        final originHost = origin == null ? targetHost : (Uri.tryParse(origin)?.host ?? targetHost);
        if (originHost.isEmpty || isMainSiteHost(originHost)) {
          await ref.read(sessionProvider.notifier).afterVerify(r.cookies, userAgent: r.userAgent, origin: origin);
        } else if (origin != null) {
          final store = ref.read(sessionStoreProvider);
          final jar = ref.read(imageCookieJarProvider);
          if (r.cookies.isNotEmpty) {
            await store.setCfCookie(origin, r.cookies);
            await jar.saveFromResponse(Uri.parse(origin), Wenku8Client.parseCookieString(r.cookies));
          }
          final ua = r.userAgent;
          if (ua != null && ua.isNotEmpty && ua != store.userAgent) {
            await store.setUserAgent(ua);
            ref.read(wenku8ClientProvider).dio.options.headers['User-Agent'] = ua;
          }
        }
        if (context.mounted) context.pop(true);
      },
    );
  }
}
