import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../avatar.dart';
import '../env.dart';
import '../incognito.dart';
import '../router.dart';
import '../session.dart';
import '../settings.dart';
import '../app_prefs.dart';
import '../stats.dart';
import '../theme.dart';
import '../theme_doodle.dart';
import '../theme_squire.dart';
import '../volumes.dart';
import '../widgets.dart';
import '../x_list.dart';
import '../text.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('退出后以游客身份浏览，书架等功能需要重新登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) await ref.read(sessionProvider.notifier).logout();
  }

  void _avatarMenu(BuildContext context, WidgetRef ref) {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final custom = ref.watch(avatarProvider);
    final palette = appPalettes[ref.watch(paletteProvider)];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = session is SessionLoggedIn ? session.user : null;

    final name = user?.username ?? '未登录';
    final sub = user == null ? '点击登录' : (session is SessionLoggedIn && session.offline ? 'UID ${user.uid} · 离线' : 'UID ${user.uid}');
    final useCustom = custom != null && !isWebPreview;
    final initial = Text(name.characters.firstOrNull ?? '?', style: theme.textTheme.titleLarge);
    final avatar = CircleAvatar(
      radius: 28,
      backgroundColor: scheme.surfaceContainer,
      foregroundImage: useCustom ? FileImage(File(custom)) : null,
      // 网站头像走 App 的图片通道（Flutter 自带的 NetworkImage 会被 Cloudflare 403）；取不到时露出下面的首字
      child: useCustom || user == null || user.avatar.isEmpty
          ? initial
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(child: initial),
                ClipOval(child: NetImage(user.avatar.replaceFirst('http://', 'https://'))),
              ],
            ),
    );

    final tappableAvatar = isWebPreview || user == null ? avatar : GestureDetector(onTap: () => _avatarMenu(context, ref), child: avatar);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: user == null ? () => context.push(Routes.login) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface)),
              Text(sub, style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
            ],
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
                        child: SizedBox(height: 132, width: double.infinity, child: RuinsScene(animate: AppPrefs.read(P.sceneMotion, true))),
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
              XNavRow(icon: Icons.insights_outlined, title: '阅读统计', onTap: () => context.push(Routes.stats)),
              XNavRow(icon: Icons.collections_bookmark_outlined, title: '书籍墙', onTap: () => context.push(Routes.wall)),
              XNavRow(icon: Icons.history, title: '阅读历史', onTap: () => context.push(Routes.history)),
              XNavRow(icon: Icons.bookmark_border, title: '书签', onTap: () => context.push(Routes.bookmarks)),
              XNavRow(icon: Icons.download_outlined, title: '离线缓存', onTap: () => context.push(Routes.cache)),
              const XDivider(),
              XNavRow(
                icon: Icons.visibility_off_outlined,
                title: '无痕模式',
                big: false,
                onTap: () => ref.read(incognitoProvider.notifier).set(!ref.read(incognitoProvider)),
                trailing: Switch(value: ref.watch(incognitoProvider), onChanged: (v) => ref.read(incognitoProvider.notifier).set(v)),
              ),
              XNavRow(icon: Icons.settings_outlined, title: '设置', big: false, onTap: () => context.push(Routes.settings)),
              if (user != null) XNavRow(icon: Icons.logout, title: '退出登录', big: false, color: scheme.error, onTap: () => _confirmLogout(context, ref)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 名字下面那行数字，写法照 X 的「64 正在关注　1 关注者」：数字粗体、说明灰色，点了进阅读统计。
/// 每分钟刷新一次（这页一直留在后台）。
class _StatsLine extends ConsumerStatefulWidget {
  const _StatsLine();

  @override
  ConsumerState<_StatsLine> createState() => _StatsLineState();
}

class _StatsLineState extends ConsumerState<_StatsLine> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  static String _short(int sec) => sec >= 3600 ? '${(sec / 3600).toStringAsFixed(sec >= 36000 ? 0 : 1)} 小时' : '${(sec / 60).ceil()} 分钟';

  @override
  Widget build(BuildContext context) {
    ref.watch(volumeChangesProvider);
    final scheme = Theme.of(context).colorScheme;
    final perDay = ReadingStats.perDay();
    final today = perDay[ReadingStats.dayKey(DateTime.now())] ?? 0;
    final total = perDay.values.fold(0, (a, b) => a + b);
    TextSpan item(String value, String label) => TextSpan(
      children: [
        TextSpan(text: value, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface)),
        TextSpan(text: ' $label　', style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
    );
    return GestureDetector(
      onTap: () => context.push(Routes.stats),
      child: Text.rich(
        TextSpan(style: const TextStyle(fontSize: 14), children: [item(_short(today), '今天'), item(_short(total), '累计'), item('${Volumes.allDone().length}', '卷读完')]),
      ),
    );
  }
}
