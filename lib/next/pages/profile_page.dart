import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../avatar.dart';
import '../env.dart';
import '../incognito.dart';
import '../motion.dart';
import '../routes.dart';
import '../session.dart';
import '../settings.dart';
import '../app_prefs.dart';
import '../stats.dart';
import '../theme.dart';
import '../theme_doodle.dart';
import '../theme_squire.dart';
import '../volumes.dart';
import '../widgets.dart';
import 'home_shell.dart' show openLibraryPage;
import '../x_list.dart';
import '../text.dart';

/// 退出登录前确认（「我的」页和宽侧栏的账号菜单共用）
Future<void> confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('退出后转为游客模式。本机书架、阅读进度、统计与离线缓存都会保留；站内搜索、评论和在线书架同步需要重新登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) await ref.read(sessionProvider.notifier).logout();
}

/// 换头像：从相册选，或恢复网站头像
void avatarMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(context);
                ref.read(avatarProvider.notifier).pick();
              },
            ),
            if (ref.read(avatarProvider) != null)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复网站头像'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(avatarProvider.notifier).clear();
                },
              ),
          ],
        ),
      ),
    );
}

/// 账号头像：自己选的头像优先，其次网站头像，都没有时显示名字首字
class AccountAvatar extends ConsumerWidget {
  const AccountAvatar({super.key, this.radius = 28});

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider.select((s) => s is SessionLoggedIn ? (username: s.user.username, avatar: s.user.avatar) : null));
    final custom = ref.watch(avatarProvider);
    final theme = Theme.of(context);
    final name = user?.username ?? '未登录';
    final useCustom = custom != null && !isWebPreview;
    final decodePx = (radius * 2 * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(64, 512);
    final initial = Text(name.characters.firstOrNull ?? '?', style: radius >= 24 ? theme.textTheme.titleLarge : TextStyle(fontSize: radius * 0.85, fontWeight: FontWeight.w600));
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      foregroundImage: useCustom ? ResizeImage.resizeIfNeeded(decodePx, null, FileImage(File(custom))) : null,
      // 网站头像走 App 的图片通道（Flutter 自带的 NetworkImage 会被 Cloudflare 403）；取不到时露出下面的首字
      child: useCustom || user == null || user.avatar.isEmpty
          ? initial
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(child: initial),
                ClipOval(child: NetImage(user.avatar.replaceFirst('http://', 'https://'), decodeSize: Size.square(radius * 2))),
              ],
            ),
    );
  }
}

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(
      sessionProvider.select(
        (s) => s is SessionLoggedIn ? (uid: s.user.uid, username: s.user.username, userLevel: s.user.userLevel, offline: s.offline) : null,
      ),
    );
    final palette = appPalettes[ref.watch(paletteProvider)];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final name = user?.username ?? '未登录';
    final sub = user == null
        ? '点击登录'
        : [
            'UID ${user.uid}',
            if (user.userLevel.isNotEmpty) user.userLevel,
            if (user.offline) '离线',
          ].join(' · ');
    const avatar = AccountAvatar();

    final VoidCallback? onAvatarTap = user == null ? () => context.push(Routes.login) : (isWebPreview ? null : () => avatarMenu(context, ref));
    final tappableAvatar = onAvatarTap == null
        ? avatar
        : Semantics(
            button: true,
            label: hz(context, user == null ? '去登录' : '更换头像'),
            child: AppPressScale(
              scale: 0.94,
              child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onAvatarTap, child: avatar)),
            ),
          );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: user == null ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            onTap: user == null ? () => context.push(Routes.login) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface)),
                Text(sub, style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        const _StatsLine(),
      ],
    );

    // X 侧边栏的样子：头像在左上，名字粗体大字，下面灰色 UID 和一行数字；角色主题时立绘站在右边。
    // 插画主题换成 X 个人页的样子：上面一张插画横幅，头像压在横幅下沿
    final art = characterArtOf(palette);
    final header = palette.scene || art != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (art != null)
                      DoodleBanner(art: art)
                    else
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(height: 132, width: double.infinity, child: RuinsScene(animate: ref.watch(appPref(P.sceneMotion, true)))),
                      ),
                    Positioned(
                      left: 12,
                      bottom: -30,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
                        child: Padding(padding: const EdgeInsets.all(3), child: tappableAvatar),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(20, 40, 12, 4), child: info),
            ],
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tappableAvatar, const SizedBox(height: 10), info]),
          );

    return Scaffold(
      body: SafeArea(
        child: contentWidth(
          ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            children: [
              header,
              const XDivider(),
              XNavRow(icon: Icons.insights_outlined, title: '阅读统计', onTap: () => openLibraryPage(context, Routes.stats)),
              XNavRow(icon: Icons.collections_bookmark_outlined, title: '书籍墙', onTap: () => openLibraryPage(context, Routes.wall)),
              XNavRow(icon: Icons.history, title: '阅读历史', onTap: () => openLibraryPage(context, Routes.history)),
              XNavRow(icon: Icons.bookmark_border, title: '书签', onTap: () => openLibraryPage(context, Routes.bookmarks)),
              XNavRow(icon: Icons.download_outlined, title: '离线缓存', onTap: () => openLibraryPage(context, Routes.cache)),
              const XDivider(),
              XNavRow(
                icon: Icons.visibility_off_outlined,
                title: '无痕模式',
                big: false,
                onTap: () => ref.read(incognitoProvider.notifier).set(!ref.read(incognitoProvider)),
                trailing: Switch(value: ref.watch(incognitoProvider), onChanged: (v) => ref.read(incognitoProvider.notifier).set(v)),
              ),
              // 宽屏侧栏底部已经有「设置」，这里不再重复
              if (MediaQuery.sizeOf(context).width < 720) XNavRow(icon: Icons.settings_outlined, title: '设置', big: false, onTap: () => context.go(Routes.settings)),
              if (user != null) XNavRow(icon: Icons.logout, title: '退出登录', big: false, color: scheme.error, onTap: () => confirmLogout(context, ref)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 名字下面那行数字，写法照 X 的「64 正在关注　1 关注者」：数字粗体、说明灰色，点了进阅读统计。
class _StatsLine extends ConsumerWidget {
  const _StatsLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(volumeChangesProvider);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: ReadingStats.changes,
      builder: (context, _, _) {
        final perDay = ReadingStats.perDay();
        final today = perDay[ReadingStats.dayKey(DateTime.now())] ?? 0;
        final total = perDay.values.fold(0, (a, b) => a + b);
        TextSpan item(String value, String label) => TextSpan(
          children: [
            TextSpan(text: value, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface)),
            TextSpan(text: ' $label　', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        );
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => openLibraryPage(context, Routes.stats),
            child: Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
                children: [
                  item(ReadingStats.formatDuration(today, compact: true), '今天'),
                  item(ReadingStats.formatDuration(total, compact: true), '累计'),
                  item('${Volumes.allDone().length}', '卷读完'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
