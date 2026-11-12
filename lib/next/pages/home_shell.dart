import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:home_widget/home_widget.dart';

import '../app_prefs.dart';
import '../cache.dart';
import '../env.dart';
import '../image_cache.dart';
import '../incognito.dart';
import '../library.dart';
import '../reading_widget.dart';
import '../pages/bookshelf_page.dart' show shelfSearching, shelfSelecting;
import '../router.dart';
import '../session.dart';
import '../settings.dart';
import '../sync.dart';
import '../theme.dart';
import '../theme_art.dart';
import '../updates.dart';
import '../volumes.dart';
import '../text.dart';

/// 主界面框架：窄屏底部导航，宽屏（平板、电脑、网页）左侧导航。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  Timer? _timer;
  DateTime _lastBack = DateTime(0);

  // 桌面小组件：阅读历史、更新变了过一会儿写一次；冷启动时的点击只处理一次（换账号重建主界面时别再跳）
  Timer? _widgetTimer;
  ValueListenable<Box>? _widgetWatch;
  StreamSubscription<Uri?>? _widgetClicks;
  static bool _widgetLaunchHandled = false;

  StatefulNavigationShell get shell => widget.shell;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRemovedElsewhere()); // 主界面重建前就记下的
    Future.microtask(_syncAndCheck);
    Sync.auto();
    // 清缓存、压图这些不急的活等主界面稳定了再做，不和第一屏抢 CPU 和磁盘
    _maintenance = Timer(const Duration(seconds: 6), _tidy);
    _timer = Timer.periodic(const Duration(hours: 1), (_) {
      _checkUpdates();
      Sync.auto();
    });
    if (ReadingWidget.supported) {
      _widgetWatch = Hive.box('session').listenable(keys: ['history2', 'updates', 'updates:seen'])..addListener(_scheduleWidget);
      Volumes.changes.addListener(_scheduleWidget); // 封面取到了、换了
      _scheduleWidget();
      if (!_widgetLaunchHandled) {
        HomeWidget.initiallyLaunchedFromHomeWidget().then((uri) {
          // 主界面可能刚建好又被换掉（登录状态变化），等真正处理了才记下
          if (!mounted || _widgetLaunchHandled) return;
          _widgetLaunchHandled = true;
          _openFromWidget(uri);
        }, onError: (_) {});
      }
      _widgetClicks = HomeWidget.widgetClicked.listen(_openFromWidget, onError: (_) {});
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
    context.push(r);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Sync.changes.removeListener(_onSyncChanged);
    LibraryStore.removedElsewhere.removeListener(_onRemovedElsewhere);
    _timer?.cancel();
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
      Sync.auto();
      if (ReadingWidget.supported) _pushWidget();
    } else if (state == AppLifecycleState.resumed) {
      Sync.auto();
      ref.read(libraryProvider.notifier).sync(); // 距上次不到 30 分钟会跳过
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

  void _go(int index) => shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    if (ReadingWidget.supported) {
      // 换了配色、深浅色，小组件跟着换
      ref.listen(paletteProvider, (_, _) => _scheduleWidget());
      ref.listen(themeModeProvider, (_, _) => _scheduleWidget());
    }
    ref.listen(sessionProvider, (prev, next) {
      if (prev is! SessionLoggedIn && next is SessionLoggedIn && !next.offline) _syncAndCheck();
    });
    ref.watch(updateProvider);
    final session = ref.watch(sessionProvider);
    final needsVerify = (session is SessionLoggedIn && session.needsVerify) || (session is SessionLoggedOut && session.needsVerify);
    final offline = (session is SessionLoggedIn && session.offline) || needsVerify;
    final unread = UpdateStore.unread();
    final palette = appPalettes[ref.watch(paletteProvider)];
    final incognito = ref.watch(incognitoProvider);
    Widget icon(int i, bool selected) {
      final (outlined, filled, label, artIndex) = _items[i];
      final art = ThemeArt.navIcon(palette, artIndex, selected: selected) ?? Icon(selected ? filled : outlined);
      return label == '更新' && unread > 0 ? Badge(label: Text('$unread'), child: art) : art;
    }

    final body = Column(
      children: [
        if (offline)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: InkWell(
              onTap: () => needsVerify ? context.push(Routes.verify) : ref.read(sessionProvider.notifier).restore(),
              child: SafeArea(
                bottom: false,
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Row(children: [const Icon(Icons.cloud_off_outlined, size: 16), const SizedBox(width: 8), Expanded(child: Text(needsVerify ? '被网站的验证拦住了，点这里去验证' : '离线模式，显示的是已保存的内容，点这里重新连接', style: const TextStyle(fontSize: 12)))])),
              ),
            ),
          ),
        if (incognito)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: InkWell(
              onTap: () => ref.read(incognitoProvider.notifier).set(false),
              child: SafeArea(
                bottom: false,
                top: !offline,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(children: [const Icon(Icons.visibility_off_outlined, size: 16), const SizedBox(width: 8), const Expanded(child: Text('无痕模式：不记录阅读进度和历史，点这里关闭', style: TextStyle(fontSize: 12)))]),
                ),
              ),
            ),
          ),
        // 提示条已经让开了状态栏，下面的页面就别再留一次
        Expanded(child: MediaQuery.removePadding(context: context, removeTop: offline || incognito, child: shell)),
      ],
    );
    final wide = MediaQuery.sizeOf(context).width >= 720;
    // 不在书架页时按返回先回书架；在书架页 2 秒内连按两次才退出
    Widget back(Widget child) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (shell.currentIndex != 0) return _go(0);
        if (shelfSelecting.value || shelfSearching.value) return; // 书架自己先退出多选 / 搜索
        final now = DateTime.now();
        if (now.difference(_lastBack) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _lastBack = now;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('再按一次退出'), duration: Duration(seconds: 2)));
      },
      child: child,
    );
    if (wide) {
      return back(Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: _go,
              groupAlignment: 0.0,
              labelType: NavigationRailLabelType.all,
              backgroundColor: Theme.of(context).colorScheme.surface,
              indicatorColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
              destinations: [
                for (final (i, item) in _items.indexed) NavigationRailDestination(icon: icon(i, false), selectedIcon: icon(i, true), label: Text(item.$3)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      ));
    }
    return back(Scaffold(
      body: body,
      // 书架多选时收起底部导航，让位给多选的操作条
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: shelfSelecting,
        builder: (context, selecting, _) => selecting && shell.currentIndex == 0
            ? const SizedBox.shrink()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(),
                  NavigationBar(
                    selectedIndex: shell.currentIndex,
                    onDestinationSelected: _go,
                    destinations: [for (final (i, item) in _items.indexed) NavigationDestination(icon: icon(i, false), selectedIcon: icon(i, true), label: hz(context, item.$3))],
                  ),
                ],
              ),
      ),
    ));
  }
}
