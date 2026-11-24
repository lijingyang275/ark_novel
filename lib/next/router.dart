import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'pages/bookmarks_page.dart';
import 'pages/bookshelf_page.dart';
import 'pages/categories_page.dart';
import 'pages/cache_book_page.dart';
import 'pages/characters_page.dart';
import 'pages/comments_page.dart';
import 'pages/discover_page.dart';
import 'pages/home_shell.dart';
import 'pages/library_pages.dart';
import 'pages/login_webview_page.dart';
import 'pages/login_page.dart';
import 'pages/novel_page.dart';
import 'pages/profile_page.dart';
import 'pages/report_page.dart';
import 'pages/rules_page.dart';
import 'pages/sync_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'pages/storage_page.dart';
import 'pages/stats_page.dart';
import 'pages/yearly_report_page.dart';
import 'pages/updates_page.dart';
import 'pages/volumes_page.dart';
import 'pages/wall_page.dart';
import 'pages/splash_page.dart';
import 'reader/reader_page.dart';
import 'routes.dart';
import 'session.dart';

export 'routes.dart';

/// 检查登录状态时停在启动页，检查完一律进主界面；登录页由用户按需 push 打开。
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<SessionState>(ref.read(sessionProvider));
  ref.listen(sessionProvider, (_, next) => refresh.value = next);
  ref.onDispose(refresh.dispose);

  String? pendingTarget;
  return GoRouter(
    // 登录状态本地就能定下来时直接进书架，连一帧启动页都不画
    initialLocation: ref.read(sessionProvider) is SessionChecking ? Routes.splash : Routes.bookshelf,
    refreshListenable: refresh,
    redirect: (context, state) {
      final checking = ref.read(sessionProvider) is SessionChecking;
      final onSplash = state.matchedLocation == Routes.splash;
      if (checking) {
        if (!onSplash) pendingTarget = state.uri.toString();
        return onSplash ? null : Routes.splash;
      }
      if (onSplash) {
        final target = pendingTarget ?? Routes.bookshelf;
        pendingTarget = null;
        return target;
      }
      return null;
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashPage()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginPage()),
      GoRoute(path: Routes.verify, builder: (_, state) => VerifyPage(url: state.uri.queryParameters['url'], host: state.uri.queryParameters['host'])),
      GoRoute(path: Routes.search, builder: (_, state) => SearchPage(author: state.uri.queryParameters['author'])),
      GoRoute(path: Routes.bookmarks, builder: (_, _) => const BookmarksPage()),
      GoRoute(path: '/report/:aid', builder: (_, state) => ReportPage(aid: state.pathParameters['aid']!, vol: int.tryParse(state.uri.queryParameters['v'] ?? ''))),
      GoRoute(path: Routes.stats, builder: (_, _) => const StatsPage()),
      GoRoute(path: '/stats/yearly', builder: (_, state) => YearlyReportPage(year: int.tryParse(state.uri.queryParameters['y'] ?? ''))),
      GoRoute(path: Routes.wall, builder: (_, _) => const WallPage()),
      // 卷册：整页只淡入淡出，让从书架飞过来的封面和摊开的各卷当主角
      GoRoute(
        path: '/volumes/:aid',
        pageBuilder: (_, state) => CustomTransitionPage(
          key: state.pageKey,
          transitionDuration: const Duration(milliseconds: 450),
          reverseTransitionDuration: const Duration(milliseconds: 380),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: CurveTween(curve: Curves.easeOut).animate(animation), child: child),
          child: VolumesPage(aid: state.pathParameters['aid']!),
        ),
      ),
      GoRoute(path: Routes.rules, builder: (_, _) => const RulesPage()),
      GoRoute(path: Routes.categories, builder: (_, _) => const CategoriesPage()),
      GoRoute(path: Routes.sync, builder: (_, _) => const SyncPage()),
      GoRoute(path: '/cache/:aid', builder: (_, state) => CacheBookPage(aid: state.pathParameters['aid']!)),
      GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
      GoRoute(path: Routes.cache, builder: (_, _) => const CachePage()),
      GoRoute(path: Routes.storage, builder: (_, _) => const StoragePage()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsPage()),
      GoRoute(
        path: '/settings/:section',
        builder: (_, state) => SettingsSectionPage(
          section: SettingsSection.values.firstWhere((s) => s.name == state.pathParameters['section'], orElse: () => SettingsSection.appearance),
          highlight: state.uri.queryParameters['q'],
        ),
      ),
      GoRoute(path: '/novel/:aid', builder: (_, state) => NovelPageView(aid: state.pathParameters['aid']!)),
      GoRoute(path: '/novel/:aid/characters', builder: (_, state) => CharactersPage(aid: state.pathParameters['aid']!)),
      GoRoute(path: '/novel/:aid/comments', builder: (_, state) => CommentsPage(aid: state.pathParameters['aid']!)),
      GoRoute(path: '/novel/:aid/comments/:rid', builder: (_, state) => RepliesPage(aid: state.pathParameters['aid']!, rid: state.pathParameters['rid']!)),
      GoRoute(
        path: '/reader/:aid/:cid',
        builder: (_, state) => ReaderPage(
          aid: state.pathParameters['aid']!,
          cid: state.pathParameters['cid']!,
          offset: int.tryParse(state.uri.queryParameters['offset'] ?? '') ?? (state.extra is int ? state.extra as int : null),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.bookshelf, builder: (_, _) => const BookshelfPage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.discover, builder: (_, _) => const DiscoverPage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.updates, builder: (_, _) => const UpdatesPage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.profile, builder: (_, _) => const ProfilePage())],
          ),
        ],
      ),
    ],
  );
});
