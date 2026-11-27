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
import 'meta_cache.dart';
import 'net_stub.dart' if (dart.library.io) 'net_io.dart';
import 'web_fetch.dart';

/// 本地保存的登录信息：cookie、选择的节点、代理、浏览器标识。密码放在系统安全存储里。
class SessionStore {
  SessionStore._(this._box);

  final Box _box;
  static const _secure = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)); // 没开发者签名的 Mac 版用不了新式钥匙串（-34018）

  static Future<SessionStore> open({bool openMetaCache = true}) async {
    if (kIsWeb) {
      await Hive.initFlutter('next');
    } else if (Platform.isWindows) {
      // Windows 默认会放进「文档」文件夹，改放 App 自己的数据目录；复用同一次 supportDir 避免重复平台通道查询
      final supportDir = (await getApplicationSupportDirectory()).path;
      Hive.init((await Directory(p.join(supportDir, 'next')).create(recursive: true)).path);
      await Backup.apply(supportDir);
    } else {
      final results = await Future.wait<Object?>([Hive.initFlutter('next'), getApplicationSupportDirectory()]);
      await Backup.apply((results[1] as Directory).path);
    }
    final sessionBox = await Hive.openBox('session');
    if (openMetaCache) await MetaCache.open();
    return SessionStore._(sessionBox);
  }

  /// 登录 cookie（`jieqiUserInfo=…;jieqiVisitInfo=…`）；网页预览：cookie 保存在转发程序里，这里只存一个标记。
  String? get cookie => _box.get('cookie') as String?;

  Future<void> setCookie(String? value) => value == null ? _box.delete('cookie') : _box.put('cookie', value);

  static const cfClearanceMaxAge = Duration(hours: 24);
  static const _desktopUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0';

  /// Cloudflare 放行 cookie（`cf_clearance` 等）按站点保存：它只对验证时的那个域名有效。
  String? cfCookie(String host) {
    final raw = _box.get('cf:$host');
    if (raw is String) return raw;
    if (raw is Map) return raw['v'] as String?;
    return null;
  }

  /// 站点 Cloudflare cookie 最近一次写入时间（毫秒时间戳），无记录为 null。
  int? cfCookieTimestamp(String host) {
    final ts = _box.get('cf:ts:$host');
    if (ts is int) return ts;
    final raw = _box.get('cf:$host');
    if (raw is Map) return raw['ts'] as int?;
    return null;
  }

  Future<void> setCfCookie(String host, String? value, {int? timestampMs}) async {
    if (value == null || value.isEmpty) {
      await _box.delete('cf:$host');
      await _box.delete('cf:ts:$host');
    } else {
      await _box.put('cf:$host', value);
      await _box.put('cf:ts:$host', timestampMs ?? DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// 启动恢复时清理已过期的 `cf_clearance`（超过 [maxAge] 或旧版本无时间戳记录），避免冷启动反复发送失效放行 cookie。
  Future<int> pruneExpiredCfCookies({Duration maxAge = cfClearanceMaxAge, int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - maxAge.inMilliseconds;
    final expired = <String>[];
    for (final k in _box.keys.whereType<String>()) {
      if (!k.startsWith('cf:') || k.startsWith('cf:ts:')) continue;
      final host = k.substring(3);
      final ts = cfCookieTimestamp(host);
      if (ts != null && ts < cutoff) {
        expired.add(host);
      } else if (ts == null) {
        // 旧版本未记录时间戳的放行 cookie 先补打当前时间戳，避免升级首启就强制重验；若已失效会在实际请求时自然刷新
        await _box.put('cf:ts:$host', now);
      }
    }
    for (final host in expired) {
      await setCfCookie(host, null);
    }
    return expired.length;
  }

  /// WebView 的真实浏览器标识。Dio 用同一个，Cloudflare 才认得放行 cookie。
  /// 还没验证过（没有 WebView 的标识）时按本机平台给一个自洽的：手机上自称桌面 Chrome 会被 Cloudflare 当成可疑。
  String get userAgent => (_box.get('ua') as String?) ?? _platformUserAgent();

  static String _platformUserAgent() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36',
    TargetPlatform.iOS => 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
    TargetPlatform.macOS => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    _ => _desktopUserAgent,
  };

  /// 用系统网络栈发请求（浏览器级 TLS 指纹）。没填代理时才生效：系统网络栈走不了自定义代理。
  bool get nativeNet => (_box.get('nativeNet') as bool?) ?? true;

  Future<void> setNativeNet(bool value) => _box.put('nativeNet', value);

  HttpClientAdapter adapter() {
    HttpClientAdapter io() => IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..idleTimeout = const Duration(seconds: 45)
        ..findProxy = (_) => proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy',
    );
    return nativeNet && proxy.isEmpty ? (nativeAdapter(io) ?? io()) : io();
  }

  Future<void> setUserAgent(String ua) => _box.put('ua', ua);

  Wenku8Node get node {
    final i = _box.get('node') as int?;
    return i != null && i >= 0 && i < Wenku8Node.values.length ? Wenku8Node.values[i] : Wenku8Node.wwwWenku8Cc;
  }

  /// 最近一次成功取到的用户页 HTML（兼容旧版本字符串格式；新版本在同一本地键存轻量结构化 Map）。
  String? get userHtml {
    final raw = _box.get('userHtml');
    return raw is String ? raw : null;
  }

  Future<void> setUserHtml(String? html) => html == null ? _box.delete('userHtml') : _box.put('userHtml', html);

  /// 本地缓存的结构化用户信息：优先从轻量 Map 直接构造（免冷启动 HTML DOM 解析），
  /// 若本地仍是旧版本 HTML 字符串则自动回退解析，保持完全向后兼容且复用已受备份守卫保护的 `userHtml` 本地键。
  UserInfo? get cachedUser {
    final raw = _box.get('userHtml');
    if (raw is Map) return _decodeUser(raw);
    if (raw is String) {
      try {
        return Wenku8Parser.userInfo(raw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> setCachedUser(UserInfo? user) => user == null ? _box.delete('userHtml') : _box.put('userHtml', _encodeUser(user));

  static Map<String, String> _encodeUser(UserInfo u) => {
    'avatar': u.avatar,
    'uid': u.uid,
    'username': u.username,
    'userLevel': u.userLevel,
    'email': u.email,
    'registerDate': u.registerDate,
    'contribution': u.contribution,
    'experience': u.experience,
    'point': u.point,
    'maxBookshelfNum': u.maxBookshelfNum,
    'maxRecommendNum': u.maxRecommendNum,
  };

  static UserInfo? _decodeUser(Map raw) {
    final uid = raw['uid'];
    if (uid is! String || uid.isEmpty) return null;
    String field(String k) => raw[k] is String ? raw[k] as String : '';
    return UserInfo(
      avatar: field('avatar'),
      uid: uid,
      username: field('username'),
      userLevel: field('userLevel'),
      email: field('email'),
      registerDate: field('registerDate'),
      contribution: field('contribution'),
      experience: field('experience'),
      point: field('point'),
      maxBookshelfNum: field('maxBookshelfNum'),
      maxRecommendNum: field('maxRecommendNum'),
    );
  }

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

/// 是否启用系统原生网络栈（安卓 Cronet / 苹果 NSURLSession）。切换后实时热更新各 Dio 适配器，无需重启。
class NativeNetController extends Notifier<bool> {
  @override
  bool build() => ref.read(sessionStoreProvider).nativeNet;

  Future<void> set(bool value) async {
    await ref.read(sessionStoreProvider).setNativeNet(value);
    state = value;
  }
}

final nativeNetProvider = NotifierProvider<NativeNetController, bool>(NativeNetController.new);

/// 包装共享的底层 [HttpClientAdapter]：忽略单个上层 [Dio.close]，由 [sharedHttpAdapterProvider] 统一管理生命周期。
class NonClosingHttpClientAdapter implements HttpClientAdapter {
  NonClosingHttpClientAdapter(this._inner);

  final HttpClientAdapter _inner;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      _inner.fetch(options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) {}
}

/// 全局共享单一底层网络适配器（Cronet / NSURLSession / Dart IO），避免多个 Dio 各自创建独立的原生网络引擎。
final sharedHttpAdapterProvider = Provider<HttpClientAdapter>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  ref.watch(nativeNetProvider);
  final raw = store.adapter();
  ref.onDispose(() {
    try {
      raw.close(force: false);
    } catch (_) {}
  });
  return NonClosingHttpClientAdapter(raw);
});

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
    dio: kIsWeb ? null : (Dio()..httpClientAdapter = ref.read(sharedHttpAdapterProvider)),
    challengeFallback: kIsWeb
        ? null
        : (url, {referer}) => webFetch(
            url,
            referer: referer,
            proxy: ref.read(proxyProvider),
            loginCookies: store.cookie,
            onSession: (cookies, ua, origin) {
              final session = ref.read(sessionProvider.notifier);
              // 退出登录不清 WebView 的 cookie：没登录时只收 Cloudflare 的，不把旧账号存回来
              return session.acceptWebCookies(cookies, userAgent: ua, login: ref.read(sessionProvider) is SessionLoggedIn, origin: origin);
            },
          ),
    shouldRetryAfterFallback: kIsWeb ? null : (html) => store.cookie != null && store.cookie != 'preview' && Wenku8Parser.needsLogin(html),
  );
  // 换代理或切换原生网络栈时热替换共享适配器（旧底层适配器优雅排空在途请求后自动释放）
  if (!kIsWeb) {
    ref.listen<HttpClientAdapter>(sharedHttpAdapterProvider, (_, next) => client.dio.httpClientAdapter = next);
  }
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
    return webFetchImage(
      url,
      referer: '${siteBase(node)}/',
      proxy: ref.read(proxyProvider),
      onSession: (cookies, ua, origin) async {
        await store.setCfCookie(origin, cookies);
        await jar.saveFromResponse(Uri.parse(origin), Wenku8Client.parseCookieString(cookies));
        if (ua != null && ua.isNotEmpty && ua != store.userAgent) {
          await store.setUserAgent(ua);
          ref.read(wenku8ClientProvider).dio.options.headers['User-Agent'] = ua;
          // imageDioProvider 通过拦截器动态读取 store.userAgent，不在此提前初始化它
        }
      },
    );
  };
});

/// 图片专用的 Dio：和请求页面一样走所选代理与原生网络栈，通过拦截器动态读取当前节点 Referer、浏览器 UA 与各图床保存的 Cloudflare cookie。
final imageDioProvider = Provider<Dio>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final jar = ref.watch(imageCookieJarProvider);
  final dio = Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 25)))
    ..httpClientAdapter = ref.watch(sharedHttpAdapterProvider);
  if (!kIsWeb) {
    final restoring = <String, Future<void>>{};
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.headers['User-Agent'] = store.userAgent;
          options.headers['Referer'] ??= '${siteBase(ref.read(nodeProvider))}/';
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLoggedIn &&
          other.offline == offline &&
          other.needsVerify == needsVerify &&
          other.user.uid == user.uid &&
          other.user.username == user.username &&
          other.user.avatar == user.avatar &&
          other.user.userLevel == user.userLevel &&
          other.user.email == user.email &&
          other.user.registerDate == user.registerDate &&
          other.user.contribution == user.contribution &&
          other.user.experience == user.experience &&
          other.user.point == user.point &&
          other.user.maxBookshelfNum == user.maxBookshelfNum &&
          other.user.maxRecommendNum == user.maxRecommendNum;

  @override
  int get hashCode => Object.hash(
    offline,
    needsVerify,
    user.uid,
    user.username,
    user.avatar,
    user.userLevel,
    user.email,
    user.registerDate,
    user.contribution,
    user.experience,
    user.point,
    user.maxBookshelfNum,
    user.maxRecommendNum,
  );
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
    if (e.type == DioExceptionType.cancel) return '请求已取消';
    if (e.type == DioExceptionType.badCertificate) return '安全证书校验失败，请检查系统时间或网络环境';
    if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络或切换线路';
    }
    final err = e.error;
    if (err != null && isCloudflare(err)) return err.toString();
    final detail = err?.toString() ?? e.message ?? e.type.name;
    final lower = detail.toLowerCase();
    if (detail.contains('127.0.0.1') || lower.contains('connection refused') || detail.contains('ERR_CONNECTION_REFUSED')) {
      return '连接被拒绝（本地 DNS 可能拦截了域名，建议切到 wenku8.cc 或开启代理）';
    }
    if (detail.contains('ERR_NAME_NOT_RESOLVED') || detail.contains('HOSTNAME_NOT_RESOLVED') || lower.contains('failed host lookup') || detail.contains('NSURLErrorCannotFindHost') || lower.contains('code=-1003') || lower.contains('cannot find host')) {
      return '无法解析域名，请检查网络或切换站点线路';
    }
    if (detail.contains('ERR_CONNECTION_TIMED_OUT') || detail.contains('ERR_TIMED_OUT') || detail.contains('NSURLErrorTimedOut') || lower.contains('code=-1001') || lower.contains('request timed out')) {
      return '连接超时，请检查网络或切换线路';
    }
    if (detail.contains('ERR_INTERNET_DISCONNECTED') || detail.contains('ERR_NETWORK_CHANGED') || detail.contains('NSURLErrorNotConnectedToInternet') || lower.contains('code=-1009') || lower.contains('appears to be offline')) {
      return '网络已断开，请检查网络连接';
    }
    if (detail.contains('ERR_CONNECTION_RESET') || detail.contains('ERR_CONNECTION_CLOSED') || detail.contains('ERR_CONNECTION_ABORTED') || detail.contains('NSURLErrorNetworkConnectionLost') || lower.contains('code=-1005') || lower.contains('connection reset') || lower.contains('connection closed')) {
      return '网络连接被中断，请稍后重试或切换线路';
    }
    if (detail.contains('NSURLErrorBadURL') || (lower.contains('nsurlerrordomain') && (lower.contains('code=-1000') || lower.contains('bad url')))) {
      return '系统网络栈请求异常（NSURLError -1000），如开启了虚拟网卡/代理，可在设置中关闭「系统网络栈」或填写 HTTP 代理';
    }
    if (detail.contains('ERR_PROXY_CONNECTION_FAILED') || detail.contains('ERR_TUNNEL_CONNECTION_FAILED')) {
      return '代理服务器连接失败，请检查代理地址与端口';
    }
    if (err is HandshakeException || detail.contains('ERR_SSL_') || detail.contains('ERR_CERT_') || detail.contains('NSURLErrorSecureConnectionFailed') || detail.contains('NSURLErrorServerCertificate') || lower.contains('code=-1200') || lower.contains('code=-1202')) {
      return '安全连接（TLS）握手失败，可能被网络拦截，建议切换线路或开关系统网络栈';
    }
    if (detail.contains('ERR_ADDRESS_UNREACHABLE') || lower.contains('network is unreachable')) {
      return '网络不可达，请检查网络连接';
    }
    if (err is SocketException) return '网络不可达：${err.osError?.message ?? err.message}';
    return '连接失败：$detail';
  }
  final raw = e.toString();
  if (raw.startsWith('Bad state: ')) return raw.substring(11);
  if (raw.startsWith('FormatException: ')) return raw.substring(17);
  return raw;
}

const _restoreTimeoutReason = 'restore_timeout';

/// 登录状态。没登录也能进主界面（游客），需要账号的页面再提示登录。
class SessionController extends Notifier<SessionState> {
  int _restoreEpoch = 0;
  int _cookieSwaps = 0;
  CancelToken? _restoreCancel;
  Future<void> _cookieOp = Future<void>.value();
  bool _prunedCf = false;

  static final _titleRe = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);
  static final _wsRe = RegExp(r'\s+');

  @override
  SessionState build() {
    ref.onDispose(() => _restoreCancel?.cancel('disposed'));
    Future.microtask(restore);
    // 换节点后重新确认：两个站点的验证状态不一样，顶部"被拦住 / 离线"提示要跟着变（静默重连不闪回启动页）
    ref.listen(nodeProvider, (_, _) => restore(silent: true));
    // 本地就能定下来的直接给，第一帧就进主界面，不在启动页停：没登录 → 游客；有上次的账号信息 → 先当已登录，确认在后台做。
    // 只有存了 cookie 却没有账号信息（刚登录完就被杀掉）时才在启动页等确认
    if (_store.cookie == null) return const SessionLoggedOut();
    final cached = _store.cachedUser;
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

  /// 对所有写入/清理 cookie jar 的操作互斥串行，防止并发覆盖或空窗。
  Future<T> _serializeCookies<T>(Future<T> Function() fn) {
    final prev = _cookieOp;
    final next = prev.then((_) => fn());
    _cookieOp = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// 业务请求遇到 Cloudflare 拦截时同步点亮顶部验证提示（即便页面回落到了旧缓存）。
  void markNeedsVerify() {
    final s = state;
    if (s is SessionLoggedIn) {
      if (!s.needsVerify) state = SessionLoggedIn(s.user, offline: s.offline, needsVerify: true);
    } else if (s is SessionLoggedOut) {
      if (!s.needsVerify) state = SessionLoggedOut(message: s.message, needsVerify: true);
    }
  }

  /// 把保存的登录 cookie 和各站点的 Cloudflare cookie 放进请求用的 cookie jar。
  Future<void> _restoreCookies() => _serializeCookies(() async {
    if (isWebPreview) return;
    if (!_prunedCf) {
      _prunedCf = true;
      await _store.pruneExpiredCfCookies();
    }
    final login = _store.cookie;
    for (final n in _nodeHosts) {
      final parts = [?login, ?_store.cfCookie(n.node)];
      if (parts.isNotEmpty) await _client.restoreCookie(parts.join(';'), [n.node]);
    }
  });

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

  /// 启动时：有保存的登录信息就向网站确认一次（最多等 [timeout]，用 CancelToken 真正中断在途请求）。
  /// 失效则清除；网络出错、超时、被拦截都按"离线"处理，保留 cookie。
  /// 有上次保存的账号信息就先当已登录，直接进主界面，确认在后台做，不在启动页干等。
  Future<String?> restore({bool silent = false, Duration timeout = const Duration(seconds: 15)}) async {
    final epoch = ++_restoreEpoch;
    _restoreCancel?.cancel('superseded');
    try {
      await _restoreCookies();
    } finally {
      // 出错也要放行：等着它的书架同步、小组件跳转不能一直卡住
      if (!_cookiesReady.isCompleted) _cookiesReady.complete();
    }
    if (!ref.mounted || epoch != _restoreEpoch) return null;
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
    final cancel = _restoreCancel = CancelToken();
    final timer = Timer(timeout, () {
      if (!cancel.isCancelled) cancel.cancel(_restoreTimeoutReason);
    });
    try {
      final user = await _fetchUser(cancelToken: cancel);
      if (!ref.mounted || epoch != _restoreEpoch) return null;
      state = SessionLoggedIn(user);
      return null;
    } catch (e) {
      if (!ref.mounted || epoch != _restoreEpoch) return null;
      // 只有确认是要求登录的页面才清登录（见 [_fetchUser]）；途中换过 cookie 时请求可能没带登录 cookie，这个结论不可信
      if (e is Wenku8UnexpectedPageException && swaps == _cookieSwaps) {
        await _clear();
        if (!ref.mounted || epoch != _restoreEpoch) return null;
        state = const SessionLoggedOut(message: '登录已过期，请重新登录');
        return null;
      }
      // 联网失败不等于没登录：有 cookie 和上次保存的账号信息就按离线登录处理
      final cached = _store.cachedUser;
      final verify = isCloudflare(e);
      state = cached == null ? SessionLoggedOut(needsVerify: verify) : SessionLoggedIn(cached, offline: true, needsVerify: verify);
      return _describeError(e);
    } finally {
      timer.cancel();
      if (identical(_restoreCancel, cancel)) _restoreCancel = null;
    }
  }

  static String _describeError(Object e) {
    if (e is TimeoutException) return '连接超时（15 秒）';
    if (e is DioException && e.type == DioExceptionType.cancel && e.error == _restoreTimeoutReason) return '连接超时（15 秒）';
    return friendlyError(e);
  }

  String _normalizeOrigin(String? origin) {
    if (origin != null && origin.isNotEmpty) {
      final uri = Uri.tryParse(origin);
      if (uri != null && uri.host.isNotEmpty) return 'https://${uri.host}';
    }
    return _store.node.node;
  }

  /// 过完 Cloudflare 验证（或登录）后，WebView 里的 cookie 分流：登录 cookie 全站点通用，其余按实际请求 [origin] 原位覆盖写入。
  /// 不再调用 `clearCookie()`，消除并发请求出现无 cookie 空窗的问题；全部 cookie 变更经互斥串行执行。
  Future<void> acceptWebCookies(String cookies, {String? userAgent, bool login = true, String? origin}) => _serializeCookies(() async {
    ++_cookieSwaps;
    final pairs = cookies.split(';').map((e) => e.trim()).where((e) => e.contains('='));
    final jieqi = pairs.where((e) => e.startsWith('jieqi')).join(';');
    final cf = pairs.where((e) => !e.startsWith('jieqi')).join(';');
    final host = _normalizeOrigin(origin);
    if (cf.isNotEmpty) {
      await _store.setCfCookie(host, cf);
      if (!isWebPreview) await _client.restoreCookie(cf, [host]);
      _client.clearChallengeCooldown(Uri.parse(host).host);
    }
    if (login && jieqi.contains('jieqiUserInfo')) {
      await _store.setCookie(jieqi);
      if (!isWebPreview) await _client.restoreCookie(jieqi, [for (final n in _nodeHosts) n.node]);
    }
    if (userAgent != null && userAgent.isNotEmpty && userAgent != _store.userAgent) {
      await _store.setUserAgent(userAgent);
      _client.dio.options.headers['User-Agent'] = userAgent;
      // imageDioProvider 通过拦截器动态读取 store.userAgent，不在此提前初始化它
    }
    ++_cookieSwaps;
  });

  /// 原生 App：在内嵌网页里登录后拿到的 cookie。
  Future<void> loginWithCookie(String cookies, {String? userAgent, String? origin}) async {
    await acceptWebCookies(cookies, userAgent: userAgent, origin: origin);
    await _confirm(_store.cookie ?? cookies);
    await persistCookies();
  }

  /// 验证完成后静默确认一次登录状态（不切到 SessionChecking，保留二级页面的导航栈）。
  Future<void> afterVerify(String cookies, {String? userAgent, String? origin}) async {
    await acceptWebCookies(cookies, userAgent: userAgent, origin: origin);
    await restore(silent: true);
    await persistCookies();
  }

  /// 网页预览：账号密码登录，由转发程序提交并保存 cookie。
  Future<void> loginWithPassword(String username, String password, int keepSeconds) async {
    await _client.clearCookie();
    await _client.postForm(_urls.loginSubmit(), _urls.loginForm(username, password, keepSeconds: keepSeconds));
    await _confirm('preview');
  }

  Future<void> _confirm(String cookie) async {
    ++_restoreEpoch;
    _restoreCancel?.cancel('confirm');
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
  Future<UserInfo> _fetchUser({CancelToken? cancelToken}) async {
    final html = await _client.getPage(_urls.userInfo(), charsetParam: false, cancelToken: cancelToken);
    final UserInfo user;
    try {
      user = Wenku8Parser.userInfo(html);
    } on Wenku8LoginRequiredException {
      // Wenku8Parser.userInfo 已经解析过一次 DOM 并判定 needsLoginDoc(doc)，直接透传避免重复 parse(html)
      rethrow;
    } on Wenku8UnexpectedPageException {
      final m = _titleRe.firstMatch(html);
      final title = m?.group(1)?.replaceAll(_wsRe, ' ').trim() ?? '';
      throw _OddUserPage(title);
    }
    await _store.setCachedUser(user);
    return user;
  }

  Future<void> logout() async {
    ++_restoreEpoch;
    _restoreCancel?.cancel('logout');
    final s = state;
    if (isWebPreview) {
      try {
        await _client.dio.post('$previewProxyBase/__session/logout');
      } catch (_) {}
    }
    // 书架这类账号私有的离线备份一并清掉，换账号不会看到上一个人的内容（还在确认登录时按上次保存的账号）
    final uid = s is SessionLoggedIn ? s.user.uid : _store.cachedUser?.uid;
    if (uid != null && uid.isNotEmpty) await PageStore.removeScope(uid);
    await _clear();
    state = const SessionLoggedOut();
  }

  /// 注销或登录失效时清理 `jieqi*` 登录 cookie，保留有效 Cloudflare cookie。
  Future<void> _clear() => _serializeCookies(() async {
    await _store.setCookie(null);
    await _store.setCachedUser(null);
    await _client.clearCookie();
    if (!isWebPreview) {
      for (final n in _nodeHosts) {
        final cf = _store.cfCookie(n.node);
        if (cf != null && cf.isNotEmpty) await _client.restoreCookie(cf, [n.node]);
      }
    }
  });
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// 用户页的位置拿到的既不是用户页、也不是登录页（维护页、403 页、没认出来的验证页）：登录状态未知。
class _OddUserPage implements Exception {
  const _OddUserPage([this.title = '']);

  final String title;

  @override
  String toString() => title.isEmpty ? '网站返回了意外页面，暂时确认不了登录状态' : '网站返回异常页面（$title）';
}
