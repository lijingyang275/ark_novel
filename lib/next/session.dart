import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/constants.dart';
import '../data/wenku8/wenku8_client.dart';
import '../data/wenku8/wenku8_exceptions.dart';
import '../data/wenku8/wenku8_parser.dart';
import '../data/wenku8/wenku8_urls.dart';
import '../models/common/charset_type.dart';
import '../models/common/wenku8_node.dart';
import '../models/custom_exception.dart';
import '../models/user_info.dart';
import 'backup.dart';
import 'cache.dart';
import 'env.dart';
import 'net_stub.dart' if (dart.library.io) 'net_io.dart';
import 'web_fetch.dart';

/// 本地保存的登录信息：cookie、选择的节点、代理、浏览器标识。密码放在系统安全存储里。
class SessionStore {
  SessionStore._(this._box);

  final Box _box;
  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)); // 没开发者签名的 Mac 版用不了新式钥匙串（-34018）

  static Future<SessionStore> open() async {
    if (!kIsWeb && Platform.isWindows) {
      // Windows 默认会放进「文档」文件夹，改放 App 自己的数据目录
      Hive.init((await Directory(p.join((await getApplicationSupportDirectory()).path, 'next')).create(recursive: true)).path);
    } else {
      await Hive.initFlutter('next');
    }
    if (!kIsWeb) await Backup.applyPending();
    return SessionStore._(await Hive.openBox('session'));
  }

  /// 登录 cookie（`jieqiUserInfo=…;jieqiVisitInfo=…`）；网页预览：cookie 保存在转发程序里，这里只存一个标记。
  String? get cookie => _box.get('cookie') as String?;

  Future<void> setCookie(String? value) => value == null ? _box.delete('cookie') : _box.put('cookie', value);

  /// Cloudflare 放行 cookie（`cf_clearance` 等）按站点保存：它只对验证时的那个域名有效。
  String? cfCookie(String host) => _box.get('cf:$host') as String?;

  Future<void> setCfCookie(String host, String? value) => value == null || value.isEmpty ? _box.delete('cf:$host') : _box.put('cf:$host', value);

  /// WebView 的真实浏览器标识。Dio 用同一个，Cloudflare 才认得放行 cookie。
  /// 还没验证过（没有 WebView 的标识）时按本机平台给一个自洽的：手机上自称桌面 Chrome 会被 Cloudflare 当成可疑。
  String get userAgent => (_box.get('ua') as String?) ?? _platformUserAgent();

  static String _platformUserAgent() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36',
    TargetPlatform.iOS => 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
    TargetPlatform.macOS => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    _ => kUserAgent['User-Agent']!,
  };

  /// 用系统网络栈发请求（浏览器级 TLS 指纹）。没填代理时才生效：系统网络栈走不了自定义代理。
  bool get nativeNet => (_box.get('nativeNet') as bool?) ?? true;

  Future<void> setNativeNet(bool value) => _box.put('nativeNet', value);

  HttpClientAdapter adapter() {
    HttpClientAdapter io() => IOHttpClientAdapter(createHttpClient: () => HttpClient()..findProxy = (_) => proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy');
    return nativeNet && proxy.isEmpty ? (nativeAdapter(io) ?? io()) : io();
  }

  Future<void> setUserAgent(String ua) => _box.put('ua', ua);

  Wenku8Node get node {
    final i = _box.get('node') as int?;
    return i != null && i >= 0 && i < Wenku8Node.values.length ? Wenku8Node.values[i] : Wenku8Node.wwwWenku8Cc;
  }

  /// 最近一次成功取到的用户页 HTML，断网时用它显示登录状态。
  String? get userHtml => _box.get('userHtml') as String?;

  Future<void> setUserHtml(String? html) => html == null ? _box.delete('userHtml') : _box.put('userHtml', html);

  Future<void> setNode(Wenku8Node node) => _box.put('node', node.index);

  /// HTTP 代理（`127.0.0.1:7890`）。Dart 不会读系统代理，需要走代理的网络要在这里填。
  String get proxy => (_box.get('proxy') as String?) ?? '';

  Future<void> setProxy(String value) => _box.put('proxy', value.trim());

  /// 登录有效期（秒）。wenku8 不接受"临时登录"。
  int get keepSeconds => (_box.get('keepSeconds') as int?) ?? 315360000;

  Future<void> setKeepSeconds(int value) => _box.put('keepSeconds', value);

  static bool get _useLocalPass => kIsWeb || Platform.isMacOS;

  /// 记住的账号密码，没记住时为 null。用户名在 Hive，密码在安卓/iOS 放 Keystore/钥匙串，Mac 放沙盒本地库（避免无证书签名反复弹钥匙串密码框）。
  Future<(String, String)?> loadLogin() async {
    final user = _box.get('savedUser') as String?;
    if (user == null) return null;
    if (_useLocalPass) {
      var pass = _box.get('savedPass') as String?;
      if (pass == null && _box.get('savedPassMoved') != true) {
        // 旧版存在钥匙串里的搬过来，只试一次，免得反复弹窗
        await _box.put('savedPassMoved', true);
        try {
          pass = await _secure.read(key: 'savedPass');
          if (pass != null) await _box.put('savedPass', pass);
        } catch (_) {}
      }
      return pass == null ? null : (user, pass);
    }
    try {
      final legacy = _box.get('savedPass') as String?;
      if (legacy != null) {
        await _secure.write(key: 'savedPass', value: legacy);
        await _box.delete('savedPass');
      }
      final pass = await _secure.read(key: 'savedPass');
      return pass == null ? null : (user, pass);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLogin(String? user, String? pass) async {
    if (_useLocalPass) {
      if (user == null || pass == null) {
        await _box.delete('savedUser');
        await _box.delete('savedPass');
      } else {
        await _box.put('savedUser', user);
        await _box.put('savedPass', pass);
      }
      return;
    }
    try {
      if (user == null || pass == null) {
        await _box.delete('savedUser');
        await _secure.delete(key: 'savedPass');
      } else {
        await _secure.write(key: 'savedPass', value: pass);
        await _box.put('savedUser', user);
      }
    } catch (_) {}
  }
}

final sessionStoreProvider = Provider<SessionStore>((ref) => throw UnimplementedError('在 main() 里通过 overrides 提供'));

/// 当前线路。切换后所有依赖它的 provider（地址、API、图片请求）都会重建，不用重启。
class NodeController extends Notifier<Wenku8Node> {
  @override
  Wenku8Node build() => ref.read(sessionStoreProvider).node;

  Future<void> set(Wenku8Node node) async {
    await ref.read(sessionStoreProvider).setNode(node);
    state = node;
  }
}

final nodeProvider = NotifierProvider<NodeController, Wenku8Node>(NodeController.new);

/// 当前 HTTP 代理配置控制器。
class HttpProxyController extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return ref.read(sessionStoreProvider).proxy;
  }

  /// 输入框用：停手一会儿才生效，半截地址不当代理用。
  void setLater(String proxy) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => set(proxy));
  }

  Future<void> set(String proxy) async {
    _debounce?.cancel();
    final trimmed = proxy.trim();
    await ref.read(sessionStoreProvider).setProxy(trimmed);
    state = trimmed;
  }
}

final proxyProvider = NotifierProvider<HttpProxyController, String>(HttpProxyController.new);

/// 当前用于请求的站点地址：网页预览走转发程序，原生 App 直连所选节点。
String siteBase(Wenku8Node node) => isWebPreview ? previewProxyBase : node.node;

final wenku8ClientProvider = Provider<Wenku8Client>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final client = Wenku8Client(
    // 用 read：客户端自己带着 cookie jar，节点变了只换地址，不能重建
    baseUrl: () => siteBase(ref.read(nodeProvider)),
    charset: () => CharsetType.gbk,
    // 浏览器不允许网页设置 User-Agent，由转发程序代为添加
    headers: kIsWeb ? const {} : {'User-Agent': store.userAgent},
    dio: kIsWeb ? null : (Dio()..httpClientAdapter = store.adapter()),
    challengeFallback: kIsWeb
        ? null
        : (url, {referer}) => webFetch(
            url,
            referer: referer,
            proxy: ref.read(proxyProvider),
            onSession: (cookies, ua) {
              final session = ref.read(sessionProvider.notifier);
              // 退出登录不清 WebView 的 cookie：没登录时只收 Cloudflare 的，不把旧账号存回来
              return session.acceptWebCookies(cookies, userAgent: ua, login: ref.read(sessionProvider) is SessionLoggedIn);
            },
          ),
  );
  // shortcut: 换代理时旧适配器不关（Cronet 有请求在途时关闭可能出错），只有手动改代理才多留一个，真成问题再等请求结束后关
  if (!kIsWeb) ref.listen(proxyProvider, (_, _) => client.dio.httpClientAdapter = store.adapter());
  return client;
});

typedef ImageChallengeFallback = Future<Uint8List?> Function(String url);

/// 图床专用 cookie jar：与主站分开存放，切换账号或清理登录 cookie 时不影响图床已通过验证的 `cf_clearance`。
final imageCookieJarProvider = Provider<CookieJar>((ref) => CookieJar());

/// 图床遇到 Cloudflare 拦截时，用无头网页过一次盾并把图床 cookie / UA 写回给后续并发下载复用。
final imageChallengeProvider = Provider<ImageChallengeFallback?>((ref) {
  if (kIsWeb) return null;
  return (url) {
    final store = ref.read(sessionStoreProvider);
    final node = ref.read(nodeProvider);
    final jar = ref.read(imageCookieJarProvider);
    final origin = 'https://${Uri.parse(url).host}';
    return webFetchImage(
      url,
      referer: '${siteBase(node)}/',
      proxy: ref.read(proxyProvider),
      onSession: (cookies, ua) async {
        await store.setCfCookie(origin, cookies);
        await jar.saveFromResponse(Uri.parse(origin), Wenku8Client.parseCookieString(cookies));
        if (ua != null && ua.isNotEmpty && ua != store.userAgent) {
          await store.setUserAgent(ua);
          ref.read(wenku8ClientProvider).dio.options.headers['User-Agent'] = ua;
          ref.read(imageDioProvider).options.headers['User-Agent'] = ua;
        }
      },
    );
  };
});

/// 图片专用的 Dio：和请求页面一样走所选代理，并带上浏览器 UA、Referer 与各图床保存的 Cloudflare cookie。
final imageDioProvider = Provider<Dio>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final node = ref.watch(nodeProvider);
  ref.watch(proxyProvider);
  final jar = ref.watch(imageCookieJarProvider);
  final dio = Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 25), headers: {'User-Agent': store.userAgent, 'Referer': '${siteBase(node)}/'}))
    ..httpClientAdapter = store.adapter();
  if (!kIsWeb) {
    final restoring = <String, Future<void>>{};
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final host = options.uri.host;
          if (host.isNotEmpty) {
            final origin = 'https://$host';
            await (restoring[origin] ??= () async {
              final saved = store.cfCookie(origin);
              if (saved != null && saved.isNotEmpty) {
                await jar.saveFromResponse(Uri.parse(origin), Wenku8Client.parseCookieString(saved));
              }
            }());
          }
          handler.next(options);
        },
      ),
    );
    dio.interceptors.add(CookieManager(jar));
  }
  ref.onDispose(dio.close);
  return dio;
});

final wenku8UrlsProvider = Provider<Wenku8Urls>((ref) => Wenku8Urls(siteBase(ref.watch(nodeProvider)), CharsetType.gbk));

sealed class SessionState {
  const SessionState();
}

/// 启动时正在检查登录是否有效
class SessionChecking extends SessionState {
  const SessionChecking();
}

class SessionLoggedOut extends SessionState {
  const SessionLoggedOut({this.message, this.needsVerify = false});

  /// 给登录页显示的提示，例如"登录已过期"
  final String? message;

  /// 被 Cloudflare 拦住了，需要先过一次浏览器验证
  final bool needsVerify;
}

class SessionLoggedIn extends SessionState {
  const SessionLoggedIn(this.user, {this.offline = false, this.needsVerify = false});

  final UserInfo user;

  /// 没连上网站，用的是上次保存的账号信息；已缓存的内容仍可阅读
  final bool offline;

  /// 离线的原因是被 Cloudflare 拦住：去验证一下就能恢复，不是真的没网
  final bool needsVerify;
}

bool isCloudflare(Object e) => e is Cloudflare403Exception || e is CloudflareChallengeException;

/// 把各种底层网络 / 解析 / Dart 异常转成适合直接展示给普通用户的中文说明。
String friendlyError(Object e) {
  if (e is Wenku8HttpException) return e.status == 429 ? e.message : '网站返回 HTTP ${e.status}';
  if (e is Wenku8Exception) return e.message;
  if (isCloudflare(e)) return e.toString();
  if (e is TimeoutException) return '连接超时，请检查网络或代理设置';
  if (e is _OddUserPage) return e.toString();
  if (e is FormatException) return e.message;
  if (e is StateError) return e.message;
  if (e is DioException) {
    if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络或切换线路';
    }
    final err = e.error;
    if (err != null && isCloudflare(err)) return err.toString();
    final detail = err?.toString() ?? e.message ?? e.type.name;
    if (detail.contains('127.0.0.1') || detail.contains('Connection refused')) {
      return '连接被拒绝（本地 DNS 可能拦截了域名，建议切到 wenku8.cc 或开启代理）';
    }
    if (err is SocketException) return '网络不可达：${err.osError?.message ?? err.message}';
    if (err is HandshakeException) return '安全连接（TLS）握手失败，可能被网络拦截，建议切换线路或开启系统网络栈';
    return '连接失败：$detail';
  }
  final raw = e.toString();
  if (raw.startsWith('Bad state: ')) return raw.substring(11);
  if (raw.startsWith('FormatException: ')) return raw.substring(17);
  return raw;
}

/// 登录状态。没登录也能进主界面（游客），需要账号的页面再提示登录。
class SessionController extends Notifier<SessionState> {
  int _restoreEpoch = 0;
  int _cookieSwaps = 0;

  static UserInfo? _tryParseUser(String? html) {
    if (html == null) return null;
    try {
      return Wenku8Parser.userInfo(html);
    } catch (_) {
      return null;
    }
  }

  @override
  SessionState build() {
    Future.microtask(restore);
    // 换节点后重新确认：两个站点的验证状态不一样，顶部"被拦住 / 离线"提示要跟着变（静默重连不闪回启动页）
    ref.listen(nodeProvider, (_, _) => restore(silent: true));
    // 本地就能定下来的直接给，第一帧就进主界面，不在启动页停：没登录 → 游客；有上次的账号信息 → 先当已登录，确认在后台做。
    // 只有存了 cookie 却没有账号信息（刚登录完就被杀掉）时才在启动页等确认
    if (_store.cookie == null) return const SessionLoggedOut();
    final cached = _tryParseUser(_store.userHtml);
    return cached != null ? SessionLoggedIn(cached) : const SessionChecking();
  }

  final _cookiesReady = Completer<void>();
  bool _startup = true;

  /// 保存的 cookie 放进请求用的 cookie jar 以后才完成。启动后第一批联网请求（同步书架等）要先等它，否则不带登录状态。
  Future<void> get ready => _cookiesReady.future;

  SessionStore get _store => ref.read(sessionStoreProvider);

  Wenku8Client get _client => ref.read(wenku8ClientProvider);

  Wenku8Urls get _urls => ref.read(wenku8UrlsProvider);

  static const _nodeHosts = [Wenku8Node.wwwWenku8Net, Wenku8Node.wwwWenku8Cc];

  /// 把保存的登录 cookie 和各站点的 Cloudflare cookie 放进请求用的 cookie jar。
  Future<void> _restoreCookies() async {
    if (isWebPreview) return;
    final login = _store.cookie;
    for (final n in _nodeHosts) {
      final parts = [?login, ?_store.cfCookie(n.node)];
      if (parts.isNotEmpty) await _client.restoreCookie(parts.join(';'), [n.node]);
    }
  }

  /// 把 cookie jar 里的最新 cookie 写回本地：服务端续期过的 cookie 重启后才不会丢。
  Future<void> persistCookies() async {
    if (isWebPreview) return;
    for (final n in _nodeHosts) {
      final all = await _client.exportCookies(n.node);
      final cf = all.entries.where((e) => !e.key.startsWith('jieqi')).map((e) => '${e.key}=${e.value}').join(';');
      if (cf.isNotEmpty) await _store.setCfCookie(n.node, cf);
    }
    if (_store.cookie != null && _store.cookie != 'preview') {
      final all = await _client.exportCookies(_store.node.node);
      final login = all.entries.where((e) => e.key.startsWith('jieqi')).map((e) => '${e.key}=${e.value}').join(';');
      if (login.contains('jieqiUserInfo')) await _store.setCookie(login);
    }
  }

  /// 启动时：有保存的登录信息就向网站确认一次（最多等 15 秒）。失效则清除；网络出错、超时、被拦截都按"离线"处理，保留 cookie。
  /// 有上次保存的账号信息就先当已登录，直接进主界面，确认在后台做，不在启动页干等。
  Future<String?> restore({bool silent = false}) async {
    final epoch = ++_restoreEpoch;
    try {
      await _restoreCookies();
    } finally {
      // 出错也要放行：等着它的书架同步、小组件跳转不能一直卡住
      if (!_cookiesReady.isCompleted) _cookiesReady.complete();
    }
    if (epoch != _restoreEpoch) return null;
    final startup = _startup;
    _startup = false;
    final cookie = _store.cookie;
    if (cookie == null) {
      state = const SessionLoggedOut();
      return null;
    }
    // 刚启动时 build 已经按上次的账号信息进了主界面，别再切回"检查中"；
    // 静默重连时也保持在主界面，避免 GoRouter 重定向闪回启动页。
    if (!silent && !(startup && state is SessionLoggedIn)) state = const SessionChecking();
    final swaps = _cookieSwaps;
    try {
      final user = await _fetchUser().timeout(const Duration(seconds: 15));
      if (epoch != _restoreEpoch) return null;
      state = SessionLoggedIn(user);
      return null;
    } catch (e) {
      if (epoch != _restoreEpoch) return null;
      // 只有确认是要求登录的页面才清登录（见 [_fetchUser]）；途中换过 cookie 时请求可能没带登录 cookie，这个结论不可信
      if (e is Wenku8UnexpectedPageException && swaps == _cookieSwaps) {
        await _clear();
        state = const SessionLoggedOut(message: '登录已过期，请重新登录');
        return null;
      }
      // 联网失败不等于没登录：有 cookie 和上次保存的账号信息就按离线登录处理
      final cached = _tryParseUser(_store.userHtml);
      final verify = isCloudflare(e);
      state = cached == null ? SessionLoggedOut(needsVerify: verify) : SessionLoggedIn(cached, offline: true, needsVerify: verify);
      return _describeError(e);
    }
  }

  static String _describeError(Object e) {
    if (e is TimeoutException) return '连接超时（15 秒）';
    return friendlyError(e);
  }

  /// 过完 Cloudflare 验证（或登录）后，WebView 里的 cookie 分流：登录 cookie 全站点通用，其余只属于验证过的站点。
  Future<void> acceptWebCookies(String cookies, {String? userAgent, bool login = true}) async {
    // 下面要先清空 cookie 再放回去，这段时间里的确认请求可能不带登录 cookie。不能作废确认：这里可能正由确认请求的网页兜底调用
    ++_cookieSwaps;
    final pairs = cookies.split(';').map((e) => e.trim()).where((e) => e.contains('='));
    final jieqi = pairs.where((e) => e.startsWith('jieqi')).join(';');
    final cf = pairs.where((e) => !e.startsWith('jieqi')).join(';');
    final host = _store.node.node;
    if (cf.isNotEmpty) await _store.setCfCookie(host, cf);
    if (login && jieqi.contains('jieqiUserInfo')) await _store.setCookie(jieqi);
    if (userAgent != null && userAgent.isNotEmpty && userAgent != _store.userAgent) {
      await _store.setUserAgent(userAgent);
      _client.dio.options.headers['User-Agent'] = userAgent;
      ref.read(imageDioProvider).options.headers['User-Agent'] = userAgent;
    }
    await _client.clearCookie();
    await _restoreCookies();
    ++_cookieSwaps;
  }

  /// 原生 App：在内嵌网页里登录后拿到的 cookie。
  Future<void> loginWithCookie(String cookies, {String? userAgent}) async {
    await acceptWebCookies(cookies, userAgent: userAgent);
    await _confirm(_store.cookie ?? cookies);
  }

  /// 验证完成后静默确认一次登录状态（不切到 SessionChecking，保留二级页面的导航栈）。
  Future<void> afterVerify(String cookies, {String? userAgent}) async {
    await acceptWebCookies(cookies, userAgent: userAgent);
    await restore(silent: true);
  }

  /// 网页预览：账号密码登录，由转发程序提交并保存 cookie。
  Future<void> loginWithPassword(String username, String password, int keepSeconds) async {
    await _client.clearCookie();
    await _client.postForm(_urls.loginSubmit(), _urls.loginForm(username, password, keepSeconds: keepSeconds));
    await _confirm('preview');
  }

  Future<void> _confirm(String cookie) async {
    ++_restoreEpoch;
    try {
      final user = await _fetchUser();
      await _store.setCookie(cookie);
      state = SessionLoggedIn(user);
    } on Wenku8UnexpectedPageException {
      await _clear();
      throw const Wenku8UnexpectedPageException('登录失败：用户名或密码不正确，或页面验证未通过');
    }
  }

  /// 取用户页。不是用户页时：确认是要求登录的页面才抛 [Wenku8UnexpectedPageException]（调用方据此清掉登录），
  /// 其他意外页面（维护页、没认出来的验证页）抛 [_OddUserPage]，按网络问题处理、保留登录。
  Future<UserInfo> _fetchUser() async {
    final html = await _client.getPage(_urls.userInfo(), charsetParam: false);
    final UserInfo user;
    try {
      user = Wenku8Parser.userInfo(html);
    } on Wenku8UnexpectedPageException {
      if (Wenku8Parser.needsLogin(html)) rethrow;
      final m = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
      final title = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      throw _OddUserPage(title);
    }
    await _store.setUserHtml(html);
    return user;
  }

  Future<void> logout() async {
    ++_restoreEpoch;
    final s = state;
    if (isWebPreview) {
      try {
        await _client.dio.post('$previewProxyBase/__session/logout');
      } catch (_) {}
    }
    // 书架这类账号私有的离线备份一并清掉，换账号不会看到上一个人的内容（还在确认登录时按上次保存的账号）
    final uid = s is SessionLoggedIn ? s.user.uid : _tryParseUser(_store.userHtml)?.uid;
    if (uid != null && uid.isNotEmpty) await PageStore.removeScope(uid);
    await _clear();
    state = const SessionLoggedOut();
  }

  Future<void> _clear() async {
    await _store.setCookie(null);
    await _store.setUserHtml(null);
    await _client.clearCookie();
    await _restoreCookies();
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// 用户页的位置拿到的既不是用户页、也不是登录页（维护页、403 页、没认出来的验证页）：登录状态未知。
class _OddUserPage implements Exception {
  const _OddUserPage([this.title = '']);

  final String title;

  @override
  String toString() => title.isEmpty ? '网站返回了意外页面，暂时确认不了登录状态' : '网站返回异常页面（$title）';
}
