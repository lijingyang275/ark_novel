import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../models/common/wenku8_node.dart';
import '../app_prefs.dart';
import '../cache.dart';
import '../env.dart';
import '../history.dart';
import '../image_cache.dart';
import '../incognito.dart';
import '../library.dart';
import '../main.dart' show evictInactiveImageCache;
import '../meta_cache.dart';
import '../motion.dart';
import '../reading_widget.dart';
import '../routes.dart';
import '../session.dart';
import '../settings.dart';
import '../shelf_tabs.dart' show shelfSearching, shelfSelecting;
import '../sync.dart';
import '../theme.dart';
import '../theme_art.dart';
import '../updates.dart';
import '../volume_covers.dart';
import '../volumes.dart' show Volumes, volumeChangeForProvider;
import '../widgets.dart' show CoverImage;
import '../text.dart';
import 'bookmarks_page.dart' show BookmarksPage;
import 'library_pages.dart' show CachePage, HistoryPage;
import 'profile_page.dart' show AccountAvatar, avatarMenu, confirmLogout;
import 'stats_page.dart' show StatsPage;
import 'wall_page.dart' show WallPage;

/// 宽侧栏里打开的「资料库」页面（路由地址）：在主界面右侧打开，侧栏留着；null 时右侧显示当前标签页。
final shellLibraryPage = ValueNotifier<String?>(null);
bool _libraryInShell = false;

/// 打开资料库页面：宽侧栏在时留在主界面右侧打开（保留侧栏），否则照常整页推入。
void openLibraryPage(BuildContext context, String route) {
  if (_libraryInShell) {
    shellLibraryPage.value = route;
  } else {
    context.push(route);
  }
}

/// 主界面框架：窄屏底部导航，宽屏（平板、电脑、网页）左侧导航。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _syncAutoTimer;
  DateTime _lastBack = DateTime(0);
  bool _reconnecting = false;

  // 桌面小组件：阅读历史、更新变了过一会儿写一次；冷启动时的点击只处理一次（换账号重建主界面时别再跳）
  Timer? _widgetTimer;
  ValueListenable<Box>? _widgetWatch;
  ValueListenable<Box>? _unreadWatch;
  StreamSubscription<Uri>? _widgetClicks;
  static bool _widgetLaunchHandled = false;

  StatefulNavigationShell get shell => widget.shell;

  void _onShellLibraryChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => evictInactiveImageCache());
  }

  void _onSyncChanged() {
    if (!mounted) return;
    ref.read(syncProvider.notifier).refreshProviders();
  }

  /// 同步把本机删除之后还读过的书移出了书架：提示一下，可以一键加回。提示过就清掉，不点也不再提。
  void _onRemovedElsewhere() {
    final books = LibraryStore.removedElsewhere.value;
    if (!mounted || books.isEmpty) return;
    LibraryStore.removedElsewhere.value = const [];
    final first = '《${books.first.shown}》';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(books.length == 1 ? '$first已在其他设备或网站上移出书架' : '$first等 ${books.length} 本已在其他设备或网站上移出书架'),
        duration: const Duration(seconds: 8),
        persist: false, // 带按钮的提示默认不会自己消失
        action: SnackBarAction(
          label: hz(context, books.length == 1 ? '加回书架' : '全部加回'),
          // 点的时候再取：同步完会重建书架的 provider，提前拿的那个已经作废了
          onPressed: () {
            if (mounted) ref.read(libraryProvider.notifier).restore(books);
          },
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // 打开时强制检查一次更新，之后应用在前台时每小时一次（进了后台 Dart 定时器基本不会触发）
    WidgetsBinding.instance.addObserver(this);
    Sync.changes.addListener(_onSyncChanged);
    LibraryStore.removedElsewhere.addListener(_onRemovedElsewhere);
    shellLibraryPage.addListener(_onShellLibraryChanged);
    if (Hive.isBoxOpen('session')) {
      _unreadWatch = Hive.box('session').listenable(keys: ['updates', 'updates:seen']);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRemovedElsewhere()); // 主界面重建前就记下的
    Future.microtask(_syncAndCheck);
    // 延后 2 秒触发 WebDAV 自动同步，避免与首屏封面解码和登录恢复竞争主线程与网络（退后台时已有兜底）
    _syncAutoTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) Sync.auto(adapter: ref.read(sharedHttpAdapterProvider));
    });
    // 空闲时提前加载 imgsr 目录索引，避免首次加载超分封面在热路径扫盘
    if (!isWebPreview && ImageStore.srSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(imageStoreProvider).warmSrIndex().ignore();
      });
    }
    // 清缓存、压图这些不急的活等主界面稳定了再做，不和第一屏抢 CPU 和磁盘
    _maintenance = Timer(const Duration(seconds: 6), _tidy);
    _timer = Timer.periodic(const Duration(hours: 1), (_) {
      _checkUpdates();
      Sync.auto(adapter: ref.read(sharedHttpAdapterProvider));
    });
    if (ReadingWidget.supported) {
      _widgetWatch = Hive.box('session').listenable(keys: ['history2', 'updates', 'updates:seen'])..addListener(_scheduleWidget);
      Volumes.changes.addListener(_scheduleWidget); // 封面取到了、换了
      _scheduleWidget();
      if (!_widgetLaunchHandled) {
        ReadingWidget.initialUri().then((uri) {
          // 主界面可能刚建好又被换掉（登录状态变化），等真正处理了才记下
          if (!mounted || _widgetLaunchHandled) return;
          _widgetLaunchHandled = true;
          _openFromWidget(uri);
        }, onError: (_) {});
      }
      _widgetClicks = ReadingWidget.clicked.listen(_openFromWidget, onError: (_) {});
    }
  }

  Timer? _maintenance;

  void _tidy() {
    if (!mounted) return;
    // 先清再压，省得压了又删
    final cleared = AppPrefs.read(P.autoClear, false) ? ChapterCache.clearAuto() : Future.value(0);
    if (isWebPreview) return cleared.ignore();
    final store = ref.read(imageStoreProvider);
    final covers = ref.read(volumeCoverQueueProvider);
    final aids = ref.read(libraryProvider).books.keys.toList();
    // 先删挑封面剩下的图，再压剩下的，省得压了又删
    store.dropLowQualityOnce().then((_) => store.trim()).then((_) => covers.dropSkippedOnce(aids)).then((_) => store.shrinkOld()).ignore();
    cleared.then((_) => ChapterCache.compressOld()).ignore();
    MetaCache.pruneStale(keepAids: aids.toSet()).ignore();
  }

  void _scheduleWidget() {
    _widgetTimer?.cancel();
    _widgetTimer = Timer(const Duration(seconds: 2), _pushWidget);
  }

  void _pushWidget() {
    _widgetTimer?.cancel();
    ReadingWidget.push(ref.read(volumeCoverQueueProvider), ref.read(imageStoreProvider), appPalettes[ref.read(paletteProvider)], ref.read(themeModeProvider));
  }

  Future<void> _openFromWidget(Uri? uri) async {
    final r = ReadingWidget.route(uri);
    if (r == null) return;
    await ref.read(sessionProvider.notifier).ready; // 冷启动时 cookie 可能还没放好
    if (!mounted) return;
    if (r == Routes.bookshelf) return _go(0);
    if (r == Routes.updates) return _go(2);
    unawaited(context.push(r));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Sync.changes.removeListener(_onSyncChanged);
    LibraryStore.removedElsewhere.removeListener(_onRemovedElsewhere);
    shellLibraryPage.removeListener(_onShellLibraryChanged);
    _libraryInShell = false;
    _timer?.cancel();
    _syncAutoTimer?.cancel();
    _maintenance?.cancel();
    _widgetTimer?.cancel();
    _widgetWatch?.removeListener(_scheduleWidget);
    Volumes.changes.removeListener(_scheduleWidget);
    _widgetClicks?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进后台或桌面端切走窗口时把 cookie jar 里服务端续期过的 cookie 写回本地并触发同步；手机上 inactive 只是下拉通知栏之类，不算
    final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
    if (state == AppLifecycleState.paused || (state == AppLifecycleState.inactive && !mobile)) {
      ref.read(sessionProvider.notifier).persistCookies();
      Sync.auto(adapter: ref.read(sharedHttpAdapterProvider));
      if (ReadingWidget.supported) _pushWidget();
    } else if (state == AppLifecycleState.resumed) {
      Sync.auto(adapter: ref.read(sharedHttpAdapterProvider));
      final s = ref.read(sessionProvider);
      if (s is SessionLoggedIn && s.offline && !s.needsVerify) {
        unawaited(ref.read(sessionProvider.notifier).restore(silent: true));
      } else {
        ref.read(libraryProvider.notifier).sync(); // 距上次不到 30 分钟会跳过
      }
    }
  }

  /// 本地书架里有书、而且不是离线状态才检查（游客也能用本地书架追更新）。
  Future<void> _checkUpdates() async {
    final s = ref.read(sessionProvider);
    final online = s is SessionLoggedOut || (s is SessionLoggedIn && !s.offline);
    if (online && ref.read(libraryProvider).books.isNotEmpty) await ref.read(updateProvider.notifier).refresh(force: false); // 按设置里的间隔和网络限制
  }

  /// 按顺序来：书架 → 目录（检查更新）→ 卷封面 → 详情。第一次打开要取的东西很多，看得见的先取，详情最后。
  Future<void>? _syncRun;
  bool _syncAgain = false;

  /// 启动时和登录状态变成在线时都会调：正在跑就等这次跑完再来一遍，不同时跑两份。
  Future<void> _syncAndCheck() {
    if (_syncRun != null) {
      _syncAgain = true;
      return _syncRun!;
    }
    return _syncRun = () async {
      do {
        _syncAgain = false;
        await _syncOnce();
      } while (_syncAgain && mounted);
    }().whenComplete(() => _syncRun = null);
  }

  Future<void> _syncOnce() async {
    await ref.read(sessionProvider.notifier).ready; // 启动时第一帧就进了主界面，cookie 可能还没放好
    if (!mounted) return;
    final library = ref.read(libraryProvider.notifier);
    await library.sync(details: false);
    await _checkUpdates();
    if (!mounted) return;
    if (!isWebPreview) await ref.read(volumeCoverQueueProvider).prefetchAll(ref.read(libraryProvider).books.keys);
    if (mounted) await library.prefetchDetails();
  }

  // 最后一项是主题导航图标的序号（图标按含义编号：0 发现 1 书架 2 更新 3 我的）
  static const _items = [(Icons.auto_stories_outlined, Icons.auto_stories, '书架', 1), (Icons.explore_outlined, Icons.explore, '发现', 0), (Icons.update_outlined, Icons.update, '更新', 2), (Icons.person_outline, Icons.person, '我的', 3)];

  /// 宽侧栏「资料库」一组：原来要先进「我的」才点得到的常用页面
  static const _library = [
    (Icons.insights_outlined, '阅读统计', Routes.stats),
    (Icons.collections_bookmark_outlined, '书籍墙', Routes.wall),
    (Icons.history, '阅读历史', Routes.history),
    (Icons.bookmark_border, '书签', Routes.bookmarks),
    (Icons.download_outlined, '离线缓存', Routes.cache),
  ];

  static Widget? _libraryWidget(String? route) => switch (route) {
    Routes.stats => const StatsPage(),
    Routes.wall => const WallPage(),
    Routes.history => const HistoryPage(),
    Routes.bookmarks => const BookmarksPage(),
    Routes.cache => const CachePage(),
    _ => null,
  };
  int _lastMainTab = 0;

  void _go(int index) {
    final changed = shellLibraryPage.value != null || index != shell.currentIndex;
    shellLibraryPage.value = null;
    if (index < _items.length) _lastMainTab = index;
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => evictInactiveImageCache());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ReadingWidget.supported) {
      // 换了配色、深浅色，小组件跟着换
      ref.listen(paletteProvider, (_, _) => _scheduleWidget());
      ref.listen(themeModeProvider, (_, _) => _scheduleWidget());
    }
    ref.listen(sessionProvider, (prev, next) {
      final wasOffline = prev is! SessionLoggedIn || prev.offline;
      if (wasOffline && next is SessionLoggedIn && !next.offline) _syncAndCheck();
    });
    final (:offline, :needsVerify) = ref.watch(
      sessionProvider.select((session) {
        final needsVerify = (session is SessionLoggedIn && session.needsVerify) || (session is SessionLoggedOut && session.needsVerify);
        final offline = (session is SessionLoggedIn && session.offline) || needsVerify;
        return (offline: offline, needsVerify: needsVerify);
      }),
    );
    final palette = appPalettes[ref.watch(paletteProvider)];
    final incognito = ref.watch(incognitoProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final libRoute = shellLibraryPage.value;
    final libPage = _libraryWidget(libRoute);
    Widget rawIcon(int i, bool selected) {
      final (outlined, filled, _, artIndex) = _items[i];
      final art = ThemeArt.navIcon(palette, artIndex, selected: selected);
      if (art != null) return art;
      return AnimatedScale(
        scale: selected ? 1.06 : 1.0,
        duration: AppMotion.dur(context, AppMotion.fast),
        curve: AppMotion.snappy,
        child: AppIconSwap(
          duration: AppMotion.fast,
          child: Icon(selected ? filled : outlined, key: ValueKey(selected)),
        ),
      );
    }

    Widget icon(int i, bool selected) {
      final art = rawIcon(i, selected);
      if (_items[i].$3 != '更新' || _unreadWatch == null) return art;
      return ValueListenableBuilder<Box>(
        valueListenable: _unreadWatch!,
        child: art,
        builder: (_, _, child) {
          final unread = UpdateStore.unread();
          return unread > 0 ? Badge(label: Text('$unread'), child: child) : child!;
        },
      );
    }

    final body = Column(
      children: [
        AppCollapse(
          visible: offline,
          child: Material(
            color: scheme.surfaceContainer,
            child: InkWell(
              onTap: needsVerify
                  ? () async {
                      final ok = await context.push<bool>(Routes.verify);
                      if (ok == true && mounted) {
                        await _syncAndCheck();
                        if (!mounted) return;
                        final after = ref.read(sessionProvider);
                        final stillBlocked = (after is SessionLoggedIn && after.needsVerify) || (after is SessionLoggedOut && after.needsVerify);
                        if (stillBlocked) {
                          final onNet = ref.read(nodeProvider) == Wenku8Node.wwwWenku8Net;
                          final messenger = ScaffoldMessenger.of(this.context)..hideCurrentSnackBar();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                onNet
                                    ? '网页未触发人机验证，但当前线路仍被拦截，可切到 wenku8.cc 或检查代理出口'
                                    : '网页未触发人机验证，但接口仍被拦截，请检查系统代理与 App 代理出口是否一致',
                              ),
                              action: onNet
                                  ? SnackBarAction(label: '切到 wenku8.cc', onPressed: () => ref.read(nodeProvider.notifier).set(Wenku8Node.wwwWenku8Cc))
                                  : SnackBarAction(label: '网络设置', onPressed: () => this.context.push(Routes.settingsSection('network'))),
                            ),
                          );
                        }
                      }
                    }
                  : (_reconnecting
                        ? null
                        : () async {
                            setState(() => _reconnecting = true);
                            try {
                              final reason = await ref.read(sessionProvider.notifier).restore(silent: true);
                              if (!mounted || reason == null) return;
                              final onNet = ref.read(nodeProvider) == Wenku8Node.wwwWenku8Net;
                              final messenger = ScaffoldMessenger.of(this.context)..hideCurrentSnackBar();
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(onNet ? '$reason（wenku8.net 可能被本地 DNS 拦截，可切到 wenku8.cc）' : reason),
                                  action: onNet
                                      ? SnackBarAction(label: '切到 wenku8.cc', onPressed: () => ref.read(nodeProvider.notifier).set(Wenku8Node.wwwWenku8Cc))
                                      : null,
                                ),
                              );
                            } finally {
                              if (mounted) setState(() => _reconnecting = false);
                            }
                          }),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      AppIconSwap(
                        child: (_reconnecting && !needsVerify)
                            ? const SizedBox(key: ValueKey('spin'), width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.cloud_off_outlined, key: ValueKey('off'), size: 16),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppCrossfade(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            needsVerify
                                ? '被网站的验证拦住了，点这里去验证'
                                : (_reconnecting ? '正在重新连接…' : '离线模式，显示的是已保存的内容，点这里重新连接'),
                            key: ValueKey((needsVerify, _reconnecting)),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        AppCollapse(
          visible: incognito,
          child: Material(
            color: scheme.tertiaryContainer,
            child: InkWell(
              onTap: () => ref.read(incognitoProvider.notifier).set(false),
              child: SafeArea(
                bottom: false,
                top: !offline,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.visibility_off_outlined, size: 16, color: scheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '无痕模式：不记录阅读进度和历史，点这里关闭',
                          style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 提示条已经让开了状态栏，下面的页面就别再留一次。用 Builder 取这里的 MediaQuery：
        // Mac 宽屏右侧已经去掉了给红绿灯留的顶部空白，直接用外层 context 会把空白又加回来
        Expanded(
          child: Builder(
            builder: (context) => MediaQuery.removePadding(
              context: context,
              removeTop: offline || incognito,
              // 资料库页面盖在标签页上面，标签页留在原地不重建（书架滚动位置、发现页内容都还在）
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(offstage: libPage != null, child: TickerMode(enabled: libPage == null, child: shell)),
                  IgnorePointer(
                    ignoring: libPage == null,
                    child: AppCrossfade(
                      fill: true,
                      duration: AppMotion.fast,
                      child: libPage != null
                          ? KeyedSubtree(key: ValueKey(libRoute), child: libPage)
                          : const SizedBox.shrink(key: ValueKey('__lib_none__')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    // 不在书架页时按返回先回书架；安卓在书架页 2 秒内连按两次才退出
    Widget back(Widget child) => CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.digit1, meta: mac, control: !mac): () => _go(0),
        SingleActivator(LogicalKeyboardKey.digit2, meta: mac, control: !mac): () => _go(1),
        SingleActivator(LogicalKeyboardKey.digit3, meta: mac, control: !mac): () => _go(2),
        SingleActivator(LogicalKeyboardKey.digit4, meta: mac, control: !mac): () => _go(3),
        SingleActivator(LogicalKeyboardKey.keyF, meta: mac, control: !mac): () => context.push(Routes.search),
        SingleActivator(LogicalKeyboardKey.comma, meta: mac, control: !mac): () => _go(4),
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (shellLibraryPage.value != null) {
            shellLibraryPage.value = null;
            return;
          }
          if (shell.currentIndex == 4) return _go(_lastMainTab);
          if (shell.currentIndex != 0) return _go(0);
          if (shelfSelecting.value || shelfSearching.value) return; // 书架自己先退出多选 / 搜索
          if (defaultTargetPlatform != TargetPlatform.android) return;
          final now = DateTime.now();
          if (now.difference(_lastBack) < const Duration(seconds: 2)) {
            SystemNavigator.pop();
            return;
          }
          _lastBack = now;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('再按一次退出'), duration: Duration(seconds: 2)));
        },
        child: child,
      ),
    );
    if (wide) {
      if (shell.currentIndex < _items.length) _lastMainTab = shell.currentIndex;
      final dark = theme.brightness == Brightness.dark;
      final size = MediaQuery.sizeOf(context);
      // 窗口够宽时用 Finder 那样带文字的源列表，窄了退回只有图标的窄栏
      final roomy = size.width >= 960;
      _libraryInShell = roomy;
      final railBg = roomy
          ? (dark ? Color.lerp(scheme.surface, Colors.black, 0.18)! : Color.lerp(scheme.surface, scheme.onSurface, 0.035)!)
          : Color.alphaBlend(scheme.onSurface.withValues(alpha: dark ? 0.03 : 0.022), scheme.surface);
      // Mac：红绿灯在侧栏里，右侧不用让出整条标题栏，只留一点顶部空白（由顶栏自己的底色铺满），不顶到窗口边
      final rightPane = mac
          ? MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: MediaQuery.paddingOf(context).copyWith(top: 12),
                viewPadding: MediaQuery.viewPaddingOf(context).copyWith(top: 12),
              ),
              child: body,
            )
          : body;
      final cur = libRoute == null ? shell.currentIndex : -1; // 打开资料库页面时主导航不选中
      final sourceList = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: mac ? 40 : 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Text(
              'Ark Novel',
              maxLines: 1,
              style: TextStyle(
                fontFamily: palette.scene ? 'LXGWWenKai' : kSerifFallback.first,
                fontFamilyFallback: kSerifFallback,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: scheme.onSurface,
              ),
            ),
          ),
          // 「我的」的内容在宽侧栏里拆开了：资料库一组 + 底部账号行，这里不再单列
          for (final (i, item) in _items.indexed)
            if (item.$3 != '我的')
            _SourceItem(
              label: item.$3,
              selected: cur == i,
              icon: rawIcon(i, cur == i),
              badge: item.$3 == '更新' && _unreadWatch != null ? _SourceUnreadBadge(_unreadWatch!) : null,
              onTap: () => _go(i),
            ),
          const _SourceSection('资料库'),
          for (final (ic, label, route) in _library) _SourceItem(label: label, selected: libRoute == route, icon: Icon(ic), onTap: () => shellLibraryPage.value = route),
          const Spacer(),
          if (size.height >= 680) const _SidebarResume(),
          _SidebarAccount(settingsSelected: cur == 4, onSettings: () => _go(4)),
          const SizedBox(height: 10),
        ],
      );
      return back(Scaffold(
        body: Row(
          children: [
            AnimatedContainer(
              key: const ValueKey('desktop-sidebar'),
              duration: AppMotion.dur(context, AppMotion.standard),
              curve: AppMotion.curve,
              width: roomy ? 200 : 78,
              decoration: BoxDecoration(
                color: railBg,
                border: Border(right: BorderSide(color: scheme.outline.withValues(alpha: dark ? 0.5 : 0.42))),
              ),
              child: ClipRect(
                child: SafeArea(
                  top: !mac,
                  right: false,
                  child: AppCrossfade(
                    fill: true,
                    duration: AppMotion.fast,
                    child: roomy
                        ? OverflowBox(
                            key: const ValueKey('sidebar-roomy'),
                            minWidth: 200,
                            maxWidth: 200,
                            alignment: AlignmentDirectional.topStart,
                            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: sourceList),
                          )
                        : OverflowBox(
                            key: const ValueKey('sidebar-compact'),
                            minWidth: 78,
                            maxWidth: 78,
                            alignment: AlignmentDirectional.topStart,
                            child: Column(
                              children: [
                                SizedBox(height: mac ? 46 : 16),
                                for (final (i, item) in _items.indexed) ...[
                                  if (i > 0) const SizedBox(height: 6),
                                  _SidebarTile(
                                    label: item.$3,
                                    selected: cur == i,
                                    icon: icon(i, cur == i),
                                    onTap: () => _go(i),
                                  ),
                                ],
                                const Spacer(),
                                _SidebarTile(
                                  key: const ValueKey('sidebar-settings'),
                                  label: '设置',
                                  selected: cur == 4,
                                  icon: Icon(cur == 4 ? Icons.settings : Icons.settings_outlined, size: 22),
                                  onTap: () => _go(4),
                                ),
                                const SizedBox(height: 14),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
            Expanded(child: rightPane),
          ],
        ),
      ));
    }
    if (shell.currentIndex < _items.length) _lastMainTab = shell.currentIndex;
    _libraryInShell = false;
    return back(Scaffold(
      body: body,
      // 书架多选或窄屏进入设置时收起底部导航
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: shelfSelecting,
        builder: (context, selecting, _) {
          final showNav = !((selecting && shell.currentIndex == 0) || shell.currentIndex >= _items.length);
          return AppCollapse(
            visible: showNav,
            axisAlignment: 1.0,
            duration: AppMotion.standard,
            reverseDuration: AppMotion.fast,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(),
                NavigationBar(
                  selectedIndex: shell.currentIndex.clamp(0, _items.length - 1),
                  onDestinationSelected: _go,
                  destinations: [for (final (i, item) in _items.indexed) NavigationDestination(icon: icon(i, false), selectedIcon: icon(i, true), label: hz(context, item.$3))],
                ),
              ],
            ),
          );
        },
      ),
    ));
  }
}

/// 宽屏极简侧栏条目：完整包裹图标与文字的柔和圆角底块，避免角色头像被细胶囊裁切，并保持桌面端舒适触感。
class _SidebarTile extends StatefulWidget {
  const _SidebarTile({super.key, required this.label, required this.selected, required this.icon, required this.onTap});

  final String label;
  final bool selected;
  final Widget icon;
  final VoidCallback onTap;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bg = widget.selected
        ? scheme.primary.withValues(alpha: dark ? 0.18 : 0.10)
        : (_hovered ? scheme.onSurface.withValues(alpha: dark ? 0.06 : 0.04) : Colors.transparent);
    final fg = widget.selected ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: _hovered ? 0.95 : 0.78);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: hz(context, widget.label),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AppPressScale(
            scale: 0.96,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: AppMotion.dur(context, AppMotion.fast),
                curve: AppMotion.curve,
                width: 60,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconTheme(
                      data: IconThemeData(color: fg, size: 22),
                      child: SizedBox(height: 32, child: Center(child: widget.icon)),
                    ),
                    const SizedBox(height: 3),
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.dur(context, AppMotion.fast),
                      curve: AppMotion.curve,
                      style: TextStyle(fontSize: 11.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500, color: fg),
                      child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽侧栏的分组名：灰色小字
class _SourceSection extends StatelessWidget {
  const _SourceSection(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
    child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.72))),
  );
}

/// 宽侧栏的一行：图标 + 文字横排，选中是淡强调色的圆角底块，悬停有浅灰底；[badge] 是右侧的数字胶囊。
class _SourceItem extends StatefulWidget {
  const _SourceItem({required this.label, required this.selected, required this.icon, required this.onTap, this.badge});

  final String label;
  final bool selected;
  final Widget icon;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  State<_SourceItem> createState() => _SourceItemState();
}

class _SourceItemState extends State<_SourceItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bg = widget.selected
        ? scheme.primary.withValues(alpha: dark ? 0.2 : 0.11)
        : (_hovered ? scheme.onSurface.withValues(alpha: dark ? 0.06 : 0.045) : Colors.transparent);
    final fg = widget.selected ? scheme.primary : scheme.onSurface;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: hz(context, widget.label),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AppPressScale(
          scale: 0.975,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: AppMotion.dur(context, AppMotion.fast),
              curve: AppMotion.curve,
              height: 36,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 28,
                    child: Center(
                      child: IconTheme(data: IconThemeData(size: 19, color: widget.selected ? scheme.primary : scheme.onSurfaceVariant), child: widget.icon),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: AnimatedDefaultTextStyle(
                      duration: AppMotion.dur(context, AppMotion.fast),
                      curve: AppMotion.curve,
                      style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500, color: fg),
                      child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  if (widget.badge != null) widget.badge!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽侧栏「更新」行的未读角标：独立订阅 Hive 未读键，避免未读数变化时重建整棵 [HomeShell]。
class _SourceUnreadBadge extends StatelessWidget {
  const _SourceUnreadBadge(this.listenable);

  final ValueListenable<Box> listenable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Box>(
      valueListenable: listenable,
      builder: (_, _, _) {
        final unread = UpdateStore.unread();
        return AppCollapse(
          visible: unread > 0,
          axis: Axis.horizontal,
          duration: AppMotion.fast,
          reverseDuration: AppMotion.instant,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(9)),
            child: Text(
              unread > 0 ? '$unread' : '',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onPrimary, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        );
      },
    );
  }
}

/// 宽侧栏底部的「继续阅读」小卡：最近读的一本，点了直接进阅读器，长按进详情。
class _SidebarResume extends ConsumerWidget {
  const _SidebarResume();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder(
    valueListenable: Hive.box('session').listenable(keys: ['history2']),
    builder: (context, _, _) {
      final h = ReadingHistory.all().firstOrNull;
      if (h == null) return const SizedBox.shrink();
      return Consumer(
        builder: (context, ref, _) {
          ref.watch(volumeChangeForProvider(h.aid)); // 换了高清封面跟着换
          final cover = ref.read(volumeCoverQueueProvider).bookCover(h.aid, h.img);
          final scheme = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppPressScale(
              scale: 0.975,
              child: Material(
                color: scheme.surfaceContainerLowest,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: scheme.outline)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.push(Routes.reader(h.aid, h.cid)),
                  onLongPress: () => context.push(Routes.novel(h.aid)),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 45,
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))]),
                          clipBehavior: Clip.antiAlias,
                          child: CoverImage(cover, aid: h.aid, thumbnail: true, decodeSize: const Size(32, 45)),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('继续阅读', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary)),
                              const SizedBox(height: 1),
                              Text(LibraryStore.shown(h.aid, h.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                              Text(h.chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// 宽侧栏底部的账号行：头像、名字、UID，点开是账号菜单（无痕模式、换头像、退出登录）；右边一个设置齿轮。
/// 没登录时点名字直接去登录页。
class _SidebarAccount extends ConsumerWidget {
  const _SidebarAccount({required this.settingsSelected, required this.onSettings});

  final bool settingsSelected;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:username, :offline) = ref.watch(
      sessionProvider.select(
        (s) => s is SessionLoggedIn ? (username: s.user.username, offline: s.offline) : (username: null, offline: false),
      ),
    );
    final incognito = ref.watch(incognitoProvider);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 名字下面只在有状态时才显示一行：没登录、离线、无痕模式
    final sub = username == null ? '点击登录' : (incognito ? '无痕模式中' : (offline ? '离线' : null));
    final info = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          const AccountAvatar(radius: 15),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(username ?? '未登录', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: incognito ? scheme.primary : scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
    final account = username == null
        ? InkWell(borderRadius: BorderRadius.circular(8), onTap: () => context.push(Routes.login), child: info)
        : PopupMenuButton<String>(
            tooltip: hz(context, '账号'),
            position: PopupMenuPosition.over,
            offset: const Offset(0, -8),
            onSelected: (v) {
              switch (v) {
                case 'incognito':
                  ref.read(incognitoProvider.notifier).set(!incognito);
                case 'avatar':
                  avatarMenu(context, ref);
                case 'logout':
                  confirmLogout(context, ref);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'incognito',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('无痕模式'),
                  trailing: incognito ? Icon(Icons.check, size: 18, color: scheme.primary) : null,
                ),
              ),
              if (!isWebPreview) const PopupMenuItem(value: 'avatar', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.face_outlined), title: Text('更换头像'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'logout', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.logout, color: scheme.error), title: Text('退出登录', style: TextStyle(color: scheme.error)))),
            ],
            child: info,
          );
    return Row(
      children: [
        Expanded(child: Material(type: MaterialType.transparency, child: account)),
        IconButton(
          key: const ValueKey('sidebar-settings'),
          tooltip: hz(context, '设置'),
          isSelected: settingsSelected,
          onPressed: onSettings,
          style: IconButton.styleFrom(
            fixedSize: const Size(34, 34),
            minimumSize: const Size(34, 34),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            backgroundColor: settingsSelected ? scheme.primary.withValues(alpha: dark ? 0.2 : 0.11) : null,
          ),
          icon: Icon(Icons.settings_outlined, size: 19, color: scheme.onSurfaceVariant),
          selectedIcon: Icon(Icons.settings, size: 19, color: scheme.primary),
        ),
      ],
    );
  }
}
