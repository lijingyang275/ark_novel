import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/common/wenku8_node.dart';
import '../app_prefs.dart';
import '../backup.dart';
import '../cache.dart';
import '../env.dart';
import '../image_cache.dart';
import '../incognito.dart';
import '../library.dart';
import '../router.dart';
import '../security.dart';
import '../session.dart';
import '../settings.dart';
import '../swipe.dart';
import '../theme.dart';
import '../theme_squire.dart';
import '../unlock.dart';
import '../widgets.dart';
import '../x_list.dart';
import '../text.dart';

/// 设置分成几组（Mihon 那样），主页能搜索：搜到的条目点一下跳到它所在的那一组。
enum SettingsSection {
  appearance('外观', Icons.palette_outlined, '主题、配色、语言、屏幕方向'),
  reading('阅读', Icons.book_outlined, '翻页、点击区域、预加载、屏幕、朗读'),
  shelf('书架', Icons.auto_stories_outlined, '封面角标、列数、分类管理'),
  update('更新', Icons.update_outlined, '检查频率、网络条件、检查范围'),
  data('数据与存储', Icons.inventory_2_outlined, '缓存、备份与恢复、同步'),
  unlock('书籍解锁', Icons.key_outlined, '受限书照常阅读'),
  security('安全与隐私', Icons.lock_outline, '生物识别锁、防截屏、无痕模式'),
  network('网络', Icons.language, '站点节点、代理、系统网络栈'),
  about('关于', Icons.info_outline, '版本信息');

  const SettingsSection(this.title, this.icon, this.summary);

  final String title;
  final IconData icon;
  final String summary;
}

/// 设置首页的分组：组和组之间一道细线
/// 设置首页的分组。「书籍解锁」是隐藏分组：关于页连点版本号 7 次后才会出现。
List<List<SettingsSection>> _homeGroups(bool unlockEntry) => [
  [SettingsSection.appearance, SettingsSection.reading, SettingsSection.shelf],
  [SettingsSection.update, SettingsSection.data],
  [if (unlockEntry) SettingsSection.unlock, SettingsSection.security, SettingsSection.network, SettingsSection.about],
];

/// 能搜到的设置项：(标题, 所在分组, 额外关键词)
const _items = <(String, SettingsSection, String)>[
  ('主题', SettingsSection.appearance, '深色 浅色 夜间 跟随系统'),
  ('配色', SettingsSection.appearance, '主题色 颜色'),
  ('屏幕方向', SettingsSection.appearance, '横屏 竖屏 旋转'),
  ('界面繁体', SettingsSection.appearance, '繁体 繁體 简繁 台湾 语言 language'),
  ('正文繁体', SettingsSection.appearance, '繁体 繁體 简繁 台湾 正文'),
  ('翻页方式', SettingsSection.reading, '滚动 滑动 仿真 覆盖'),
  ('正则规则', SettingsSection.reading, '替换 去广告 高亮 备注'),
  ('点击区域', SettingsSection.reading, '翻页 点击 反转 双页 动画'),
  ('音量键翻页', SettingsSection.reading, '音量 按键'),
  ('预加载章节', SettingsSection.reading, '预加载 提前 下载 wi-fi 全本 缓存'),
  ('自动跳过已读章节', SettingsSection.reading, '跳过 章节 标题'),
  ('屏幕常亮', SettingsSection.reading, '锁屏 沉浸式 状态栏 页脚'),
  ('字号', SettingsSection.reading, '字体 大小'),
  ('朗读语速', SettingsSection.reading, '听书 tts'),
  ('章节列表手势', SettingsSection.reading, '左滑 右滑 已读 书签 滑动'),
  ('卷末庆祝卡片', SettingsSection.reading, '仪式 读完 打分 庆祝'),
  ('纯黑深色', SettingsSection.appearance, 'AMOLED 纯黑 省电 oled'),
  ('插画动效', SettingsSection.appearance, '遗迹 晴空 动画 云'),
  ('继续阅读按钮', SettingsSection.shelf, '书架 封面 播放'),
  ('继续阅读条', SettingsSection.shelf, '书架 顶部 最近阅读 上次'),
  ('未读角标', SettingsSection.shelf, '数字 角标 徽标'),
  ('缓存角标', SettingsSection.shelf, '数字 角标 已缓存'),
  ('显示分类书籍数量', SettingsSection.shelf, '分类 标签 计数 数量'),
  ('按分类分别设置', SettingsSection.shelf, '筛选 排序 显示 标签'),
  ('书架列数', SettingsSection.shelf, '网格 竖屏 横屏 每行'),
  ('新书默认分类', SettingsSection.shelf, '加入书架 分类 询问'),
  ('分类管理', SettingsSection.shelf, '新建 删除 排序'),
  ('自动检查更新', SettingsSection.update, '间隔 小时 每天 每周'),
  ('仅在 Wi-Fi 下检查', SettingsSection.update, '网络 流量 限制'),
  ('仅在充电时检查', SettingsSection.update, '电量 限制'),
  ('跳过已完结的书', SettingsSection.update, '更新 连载'),
  ('跳过未开始阅读的书', SettingsSection.update, '更新'),
  ('跳过还有未读章节的书', SettingsSection.update, '更新'),
  ('仅检查以下分类', SettingsSection.update, '更新 包含'),
  ('排除以下分类', SettingsSection.update, '更新 不检查'),
  ('图片缓存', SettingsSection.data, '封面 插图 清除 存储'),
  ('章节缓存', SettingsSection.data, '正文 清除 存储 自动清理'),
  ('备份', SettingsSection.data, '导出 导入 恢复'),
  ('同步', SettingsSection.data, '坚果云 webdav 多设备'),
  ('书籍解锁', SettingsSection.unlock, '受限 下架 版权 解锁 阅读 TXT'),
  ('App 接口', SettingsSection.unlock, '接口 API 中继 插图'),
  ('生物识别锁', SettingsSection.security, '指纹 面容 密码 锁定'),
  ('防截屏', SettingsSection.security, '录屏 最近任务 隐私'),
  ('无痕模式', SettingsSection.security, '不记录 历史 进度'),
  ('站点节点', SettingsSection.network, 'wenku8.net wenku8.cc'),
  ('HTTP 代理', SettingsSection.network, '梯子 proxy'),
  ('系统网络栈', SettingsSection.network, 'cloudflare tls'),
  ('版本', SettingsSection.about, '关于'),
];

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    ref.watch(appPrefsProvider); // 连点版本号显示「书籍解锁」后，首页分组和搜索结果要跟着变
    final scheme = Theme.of(context).colorScheme;
    final unlockEntry = AppPrefs.unlockEntry;
    final q = _q.trim().toLowerCase();
    final hits = q.isEmpty
        ? const <(String, SettingsSection, String)>[]
        : _items.where((e) => (unlockEntry || e.$2 != SettingsSection.unlock) && '${e.$1} ${e.$3} ${e.$2.title}'.toLowerCase().contains(q)).toList();
    void open(SettingsSection s) => context.push(Routes.settingsSection(s.name));
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: contentWidth(
        ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // 圆角搜索条，和页面底色只差一点
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                decoration: InputDecoration(
                  hint: Text('搜索设置', maxLines: 1, overflow: TextOverflow.ellipsis),
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: scheme.onSurface.withValues(alpha: 0.06),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: scheme.primary)),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            if (q.isNotEmpty) ...[
              if (hits.isEmpty) const XNote('没有匹配的设置'),
              for (final (title, section, _) in hits) XEntry(icon: section.icon, title: title, subtitle: '在「${section.title}」里', onTap: () => open(section)),
            ] else
              for (final (i, group) in _homeGroups(unlockEntry).indexed) ...[
                if (i > 0) const XDivider(),
                for (final s in group) XEntry(icon: s.icon, title: s.title, subtitle: s.summary, onTap: () => open(s)),
              ],
          ],
        ),
      ),
    );
  }
}

class SettingsSectionPage extends ConsumerStatefulWidget {
  const SettingsSectionPage({super.key, required this.section});

  final SettingsSection section;

  @override
  ConsumerState<SettingsSectionPage> createState() => _SectionState();
}

class _SectionState extends ConsumerState<SettingsSectionPage> {
  @override
  Widget build(BuildContext context) {
    ref.watch(appPrefsProvider);
    // 隐藏入口：直接输路由也进不来，提示去哪里打开
    if (widget.section == SettingsSection.unlock && !AppPrefs.unlockEntry) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.section.title)),
        body: contentWidth(ListView(children: const [XNote('书籍解锁入口是隐藏的。在「设置 → 关于」里连点版本号 7 次可以显示；默认关闭。')])),
      );
    }
    final children = switch (widget.section) {
      SettingsSection.appearance => _appearance(),
      SettingsSection.reading => _reading(),
      SettingsSection.shelf => _shelf(),
      SettingsSection.update => _update(),
      SettingsSection.data => _data(),
      SettingsSection.unlock => _unlock(),
      SettingsSection.security => _security(),
      SettingsSection.network => _network(),
      SettingsSection.about => _about(),
    };
    return Scaffold(
      appBar: AppBar(title: Text(widget.section.title)),
      body: contentWidth(ListView(padding: const EdgeInsets.only(bottom: 32), children: children)),
    );
  }

  // ---- 小零件 ----

  AppPrefs get _prefs => ref.read(appPrefsProvider.notifier);

  Widget _switch(String title, String key, bool fallback, {String? subtitle, String? help}) => XSwitch(title: title, subtitle: subtitle, help: help, value: _prefs.get(key, fallback), onChanged: (v) => _prefs.set(key, v));

  /// 能点进下一页的：右边一个箭头
  Widget _link(String title, String? subtitle, VoidCallback onTap) => XTile(
    title: title,
    subtitle: subtitle,
    onTap: onTap,
    trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
  );

  /// 多选分类（更新页的"只检查 / 不检查这些分类"）
  Future<void> _pickCats(String key, String title) async {
    final cats = ref.read(libraryProvider).cats;
    if (cats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有分类，请先在「分类管理」中新建')));
      return;
    }
    final chosen = {...AppPrefs.readList(key)};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in cats) CheckboxListTile(contentPadding: EdgeInsets.zero, title: Text(c.name), value: chosen.contains(c.id), onChanged: (v) => setLocal(() => v! ? chosen.add(c.id) : chosen.remove(c.id))),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, chosen.toList()), child: const Text('确定'))],
        ),
      ),
    );
    if (result != null) _prefs.set(key, result);
  }

  String _catNames(String key) {
    final ids = AppPrefs.readList(key);
    if (ids.isEmpty) return '不限';
    final cats = ref.read(libraryProvider).cats;
    return ids.map((id) => cats.where((c) => c.id == id).firstOrNull?.name).whereType<String>().join('、');
  }

  // ---- 外观 ----

  List<Widget> _appearance() {
    final mode = ref.watch(themeModeProvider);
    final palette = ref.watch(paletteProvider);
    final scheme = Theme.of(context).colorScheme;
    return [
      const XGroupTitle('主题'),
      XSegments<ThemeMode>(value: mode, options: const {ThemeMode.system: '跟随系统', ThemeMode.light: '浅色', ThemeMode.dark: '深色'}, onChanged: (v) => ref.read(themeModeProvider.notifier).set(v)),
      _switch('纯黑深色', P.pureBlack, true, subtitle: '适合 OLED 屏幕'),
      const XDivider(),
      const XGroupTitle('配色'),
      // 一排色点：点一下换，选中的外面一圈
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            for (final (i, p) in appPalettes.indexed)
              GestureDetector(
                onTap: () => ref.read(paletteProvider.notifier).set(i),
                child: SizedBox(
                  width: 60,
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: palette == i ? scheme.onSurface : Colors.transparent, width: 2)),
                        // 插画主题的色点直接是一小块插画
                        child: p.scene ? const ClipOval(child: RuinsScene(animate: false, horizon: 0.8)) : DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: p.accentLight)),
                      ),
                      const SizedBox(height: 4),
                      Text(p.name.split('·').first, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: palette == i ? FontWeight.w700 : null, color: palette == i ? scheme.onSurface : scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      if (appPalettes[palette].scene) _switch('插画动效', P.sceneMotion, true),
      const XDivider(),
      const XGroupTitle('语言'),
      XSwitch(title: '界面繁体', value: _prefs.get(P.uiHant, false), onChanged: (v) => _prefs.set(P.uiHant, v)),
      XSwitch(
        title: '正文繁体',
        subtitle: '用 OpenCC 词表在本机转换，偶有误转',
        value: ref.watch(readerPrefsProvider.select((p) => p.hant)),
        onChanged: (v) => ref.read(readerPrefsProvider.notifier).update(ref.read(readerPrefsProvider).copyWith(hant: v)),
      ),
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) ...[
        const XDivider(),
        const XGroupTitle('屏幕方向'),
        XSegments<int>(value: ref.watch(orientationProvider), options: const {0: '竖屏', 1: '自动旋转', 2: '横屏'}, onChanged: (v) => ref.read(orientationProvider.notifier).set(v)),
      ],
    ];
  }

  // ---- 阅读 ----

  List<Widget> _reading() {
    final prefs = ref.watch(readerPrefsProvider);
    final swipe = ref.watch(swipePrefsProvider);
    void set(ReaderPrefs p) => ref.read(readerPrefsProvider.notifier).update(p);
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    const tapZones = {0: '默认', 1: 'L 形', 2: 'Kindle 式', 3: '边缘式', 4: '仅呼出菜单'};
    return [
      const XGroupTitle('翻页'),
      XChoice<int>(title: '翻页方式', value: prefs.mode, options: const {0: '上下滚动', 1: '左右滑动', 2: '仿真翻页', 3: '覆盖翻页'}, onChanged: (v) => set(prefs.copyWith(mode: v))),
      if (prefs.mode == 1) XSwitch(title: '翻页动画', value: prefs.pageAnim, onChanged: (v) => set(prefs.copyWith(pageAnim: v))),
      XSwitch(title: '宽屏双页', subtitle: '宽屏时并排两页', value: prefs.dual, onChanged: (v) => set(prefs.copyWith(dual: v))),
      XChoice<int>(title: '点击区域', value: prefs.tapZone, options: tapZones, onChanged: (v) => set(prefs.copyWith(tapZone: v))),
      if (prefs.tapZone != 4) XChoice<int>(title: '反转点击区域', value: prefs.tapInvert, options: const {0: '不反转', 1: '左右反转', 2: '上下反转', 3: '全部反转'}, onChanged: (v) => set(prefs.copyWith(tapInvert: v))),
      if (android) ...[
        XSwitch(title: '音量键翻页', subtitle: prefs.volumeInvert ? '+ 下一页，− 上一页' : '− 下一页，+ 上一页', value: prefs.volumeKeys, onChanged: (v) => set(prefs.copyWith(volumeKeys: v))),
        if (prefs.volumeKeys) XSwitch(title: '反转音量键', value: prefs.volumeInvert, onChanged: (v) => set(prefs.copyWith(volumeInvert: v))),
      ],
      const XDivider(),
      const XGroupTitle('章节'),
      XSwitch(title: '自动跳过已读章节', value: prefs.skipRead, onChanged: (v) => set(prefs.copyWith(skipRead: v))),
      XSwitch(title: '切换章节时显示标题', value: prefs.chapterToast, onChanged: (v) => set(prefs.copyWith(chapterToast: v))),
      XChoice<int>(title: '预加载章节', value: prefs.prefetch, options: const {0: '关闭', 1: '后 1 章', 2: '后 2 章', 3: '后 3 章', 5: '后 5 章'}, onChanged: (v) => set(prefs.copyWith(prefetch: v))),
      if (prefs.prefetch > 0) XSwitch(title: '仅在 Wi-Fi 下预加载', value: prefs.prefetchWifi, onChanged: (v) => set(prefs.copyWith(prefetchWifi: v))),
      if (prefs.prefetch > 0) XSwitch(title: '全本缓存正文', value: prefs.prefetchBook, onChanged: (v) => set(prefs.copyWith(prefetchBook: v))),
      const XDivider(),
      const XGroupTitle('屏幕'),
      XSwitch(title: '屏幕常亮', value: prefs.keepScreenOn, onChanged: (v) => set(prefs.copyWith(keepScreenOn: v))),
      XSwitch(title: '沉浸式阅读', value: prefs.fullscreen, onChanged: (v) => set(prefs.copyWith(fullscreen: v))),
      XSwitch(title: '页脚信息', value: prefs.showStatus, onChanged: (v) => set(prefs.copyWith(showStatus: v))),
      const XDivider(),
      const XGroupTitle('文字'),
      XSlider(
        title: '字号',
        label: '${prefs.fontSize.round()}',
        slider: Slider(min: 14, max: 32, divisions: 18, value: prefs.fontSize, onChanged: (v) => set(prefs.copyWith(fontSize: v))),
      ),
      _link('正则规则', '用正则替换正文（去广告、统一用字），或给人名等关键词着色、添加备注', () => context.push(Routes.rules)),
      const XDivider(),
      const XGroupTitle('朗读'),
      XSlider(
        title: '语速',
        label: prefs.ttsRate.toStringAsFixed(1),
        slider: Slider(min: 0.1, max: 1.0, divisions: 9, value: prefs.ttsRate, onChanged: (v) => set(prefs.copyWith(ttsRate: v))),
      ),
      const XDivider(),
      const XGroupTitle('章节列表手势'),
      XChoice<SwipeAct>(title: '右滑操作', value: swipe.right, options: {for (final a in SwipeAct.values) a: a.label}, onChanged: (a) => ref.read(swipePrefsProvider.notifier).set(right: a)),
      XChoice<SwipeAct>(title: '左滑操作', value: swipe.left, options: {for (final a in SwipeAct.values) a: a.label}, onChanged: (a) => ref.read(swipePrefsProvider.notifier).set(left: a)),
      const XDivider(),
      const XGroupTitle('卷末'),
      _switch('卷末庆祝卡片', P.volumeDone, true),
    ];
  }

  // ---- 书架 ----

  List<Widget> _shelf() {
    final cats = ref.watch(libraryProvider).cats;
    final def = _prefs.get(P.defaultCat, 'ask');
    return [
      const XGroupTitle('封面'),
      _switch('继续阅读按钮', P.resumeButton, true),
      _switch('未读章数角标', P.unreadBadge, true),
      _switch('已缓存章数角标', P.cacheBadge, false),
      if (ImageStore.srSupported)
        XChoice<int>(
          title: '提升清晰度',
          subtitle: _prefs.get(P.coverSr, 1) == 0 ? '小于 600 像素的图自动放大' : '框封面时自己选',
          value: _prefs.get(P.coverSr, 1),
          options: const {0: '自动', 1: '手动'},
          onChanged: (v) {
            _prefs.set(P.coverSr, v);
            ref.read(imageStoreProvider).srVersion.value++;
          },
        ),
      const XDivider(),
      const XGroupTitle('书架顶部'),
      _switch('继续阅读条', P.resumeBar, true, subtitle: '最近读的一本，往下滑书架时自动收起'),
      const XDivider(),
      const XGroupTitle('分类标签'),
      _switch('显示分类书籍数量', P.tabCounts, false),
      _switch('按分类分别设置', P.perCat, false, help: '筛选、排序和显示方式按分类分别保存；关闭后所有分类共用一套。'),
      const XDivider(),
      const XGroupTitle('列数'),
      XChoice<int>(title: '竖屏', value: _prefs.get(P.colsPortrait, 0), options: {0: '自动', for (var i = 2; i <= 8; i++) i: '$i 列'}, onChanged: (v) => _prefs.set(P.colsPortrait, v)),
      XChoice<int>(title: '横屏', value: _prefs.get(P.colsLandscape, 0), options: {0: '自动', for (var i = 2; i <= 10; i++) i: '$i 列'}, onChanged: (v) => _prefs.set(P.colsLandscape, v)),
      const XDivider(),
      const XGroupTitle('分类'),
      XChoice<String>(
        title: '新书默认分类',
        // 选过的分类后来被删了，就当"每次询问"
        value: def == 'ask' || def.isEmpty || cats.any((c) => c.id == def) ? def : 'ask',
        options: {'ask': '每次询问', '': '不分类', for (final c in cats) c.id: c.name},
        onChanged: (v) => _prefs.set(P.defaultCat, v),
      ),
      _link('分类管理', '新建、重命名、删除和排序', () => context.push(Routes.categories)),
    ];
  }

  // ---- 更新 ----

  List<Widget> _update() {
    return [
      const XGroupTitle('自动检查'),
      XChoice<int>(title: '检查间隔', value: _prefs.get(P.updInterval, 1), options: const {0: '不自动检查', 1: '每小时', 6: '每 6 小时', 12: '每 12 小时', 24: '每天', 48: '每 2 天', 168: '每周'}, onChanged: (v) => _prefs.set(P.updInterval, v)),
      _switch('仅在 Wi-Fi 下检查', P.updWifi, false),
      _switch('仅在充电时检查', P.updCharging, false),
      const XDivider(),
      const XGroupTitle('检查范围'),
      _switch('跳过已完结的书', P.updSkipDone, false),
      _switch('跳过未开始阅读的书', P.updSkipNotStarted, false),
      _switch('跳过还有未读章节的书', P.updSkipUnread, false, help: '只检查已经读到最新章节的书。'),
      _link('仅检查以下分类', _catNames(P.updInclude), () => _pickCats(P.updInclude, '仅检查以下分类（不选则不限）')),
      _link('排除以下分类', _catNames(P.updExclude), () => _pickCats(P.updExclude, '排除以下分类')),
    ];
  }

  // ---- 数据与存储 ----

  Future<void> _confirm(String title, String content, String ok, Future<void> Function() run) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(ok))],
      ),
    );
    if (yes == true) {
      await run();
      if (mounted) setState(() {});
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _exportBackup() async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(await Backup.export())]));
    } catch (e) {
      if (mounted) _snack('导出失败：$e');
    }
  }

  Future<void> _importBackup() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['zip', 'json']);
      if (picked == null || !mounted) return;
      if (picked.path!.endsWith('.zip')) {
        await _confirm('恢复备份', '本机的书架、进度、统计和设置都会换成备份里的内容，登录信息不变。恢复后 App 会关闭，请重新打开。', '恢复', () async {
          await Backup.importZip(picked.path!);
          exit(0);
        });
        return;
      }
      final n = await Backup.restore(utf8.decode(await File(picked.path!).readAsBytes()));
      if (!mounted) return;
      ref.invalidate(libraryProvider);
      ref.invalidate(readerPrefsProvider);
      ref.invalidate(swipePrefsProvider);
      ref.invalidate(appPrefsProvider);
      _snack('已恢复备份${n > 0 ? '，补回 $n 本书' : ''}。部分设置需重启 App 后生效');
    } catch (e) {
      if (mounted) _snack('恢复失败：$e');
    }
  }

  List<Widget> _data() {
    return [
      const XGroupTitle('存储'),
      if (!isWebPreview) _link('存储空间', '各部分占用、按书清理', () => context.push(Routes.storage).then((_) => mounted ? setState(() {}) : null)),
      if (!isWebPreview)
        FutureBuilder<int>(
          future: ref.read(imageStoreProvider).diskBytes(),
          builder: (context, snap) => XTile(
            title: '清除图片缓存',
            subtitle: snap.hasData ? '封面与插图，共 ${(snap.data! / (1 << 20)).toStringAsFixed(1)} MB' : '正在计算…',
            onTap: () => _confirm('清除图片缓存？', '离线缓存中的插图也会被清除，联网后会重新下载。', '清除', () => ref.read(imageStoreProvider).clearDisk()),
          ),
        ),
      XTile(
        title: '清除章节缓存',
        subtitle: '约 ${ChapterCache.totalLabel()}，不含离线缓存的整本',
        onTap: () => _confirm('清除章节缓存？', '阅读时自动缓存的章节将被删除，再次打开时重新下载；阅读报告中按卷统计的字数可能减少。', '清除', () async {
          final n = await ChapterCache.clearAuto();
          if (mounted) _snack('已清除 $n 章');
        }),
      ),
      _switch('启动时自动清理章节缓存', P.autoClear, false),
      _link('离线缓存', '管理整本下载的书', () => context.push(Routes.cache)),
      const XDivider(),
      const XGroupTitle('备份与恢复'),
      XTile(title: '导出完整备份', onTap: _exportBackup),
      XTile(title: '导入备份', onTap: _importBackup),
      const XDivider(),
      const XGroupTitle('多设备'),
      _link('同步', '通过 WebDAV（如坚果云）在多台设备间同步阅读进度、书签和统计', () => context.push(Routes.sync)),
    ];
  }

  // ---- 书籍解锁 ----

  /// 用「文学少女」（aid=1）探测文库 App 接口还能不能取到目录。
  Future<void> _testAppApi() async {
    _snack('正在请求文库 App 接口…');
    try {
      final volumes = await ref.read(appApiProvider).catalogue('1').timeout(const Duration(seconds: 25));
      if (mounted) _snack(volumes.isEmpty ? '接口有响应，但没有解析出目录' : 'App 接口可用：解析到 ${volumes.length} 卷');
    } catch (e) {
      if (mounted) _snack('App 接口不可用：$e');
    }
  }

  List<Widget> _unlock() {
    final on = _prefs.get(P.unlock, true);
    return [
      XSwitch(
        title: '启用书籍解锁',
        value: on,
        onChanged: (v) => _prefs.set(P.unlock, v),
        help: '网站不给正文的受限书（「因版权问题，文库不再提供该小说的阅读」），打开章节时自动改从文库 App 接口取；接口不可用就下载这本书的全本 TXT，按网站目录拆好存进离线缓存，之后照常阅读。TXT 不带插图，插图章节会显示一句说明。',
      ),
      if (on) ...[
        XSwitch(
          title: '优先使用文库 App 接口',
          value: _prefs.get(P.unlockApi, true),
          onChanged: (v) => _prefs.set(P.unlockApi, v),
          help: '接口能用时正文带插图；经社区中继 wenku8-relay.mewx.org，经常失效，失效时自动改用全本 TXT。',
        ),
        XTile(title: '测试 App 接口', onTap: _testAppApi),
      ],
      XTile(
        title: '隐藏这个入口',
        onTap: () => _confirm('隐藏书籍解锁？', '同时关闭解锁。在「关于」里连点版本号 7 次可以重新显示。', '隐藏', () async {
          _prefs.set(P.unlock, false);
          _prefs.set(P.unlockShown, false);
          if (mounted) Navigator.of(context).maybePop();
        }),
      ),
    ];
  }

  // ---- 安全与隐私 ----

  List<Widget> _security() {
    final incognito = ref.watch(incognitoProvider);
    return [
      const XGroupTitle('应用锁'),
      if (lockSupported) ...[
        XSwitch(
          title: '生物识别锁',
          subtitle: '指纹、面容或锁屏密码',
          value: _prefs.get(P.lock, false),
          onChanged: (v) async {
            if (!await authenticate(v ? '确认开启 Ark Novel 的锁' : '确认关闭 Ark Novel 的锁')) {
              if (mounted) _snack('验证未通过，或此设备未设置锁屏密码 / 生物识别');
              return;
            }
            _prefs.set(P.lock, v);
          },
        ),
        if (_prefs.get(P.lock, false)) XChoice<int>(title: '离开多久后锁定', value: _prefs.get(P.lockAfter, 0), options: const {0: '立即', 1: '1 分钟', 5: '5 分钟', 15: '15 分钟', 30: '30 分钟'}, onChanged: (v) => _prefs.set(P.lockAfter, v)),
      ] else
        const XNote('当前平台不支持生物识别锁'),
      if (secureScreenSupported) ...[
        const XDivider(),
        const XGroupTitle('防截屏'),
        XSegments<int>(value: _prefs.get(P.secure, 0), options: const {0: '关', 1: '始终', 2: '仅无痕时'}, onChanged: (v) => _prefs.set(P.secure, v)),
      ],
      const XDivider(),
      const XGroupTitle('无痕'),
      XSwitch(title: '无痕模式', help: '开启期间不记录阅读进度、历史、已读章节和统计。', value: incognito, onChanged: (v) => ref.read(incognitoProvider.notifier).set(v)),
    ];
  }

  // ---- 网络 ----

  List<Widget> _network() {
    final store = ref.watch(sessionStoreProvider);
    if (isWebPreview) return [const XNote('网页预览无需设置')];
    return [
      const XGroupTitle('站点节点'),
      XSegments<Wenku8Node>(value: ref.watch(nodeProvider), options: const {Wenku8Node.wwwWenku8Net: 'wenku8.net', Wenku8Node.wwwWenku8Cc: 'wenku8.cc'}, onChanged: (v) => ref.read(nodeProvider.notifier).set(v)),
      const XDivider(),
      const XGroupTitle('连接'),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: TextFormField(
          initialValue: store.proxy,
          decoration: const InputDecoration(label: Text('HTTP 代理'), hint: Text('127.0.0.1:7890', maxLines: 1, overflow: TextOverflow.ellipsis)),
          onChanged: ref.read(proxyProvider.notifier).setLater,
        ),
      ),
      XSwitch(
        title: '系统网络栈',
        subtitle: '重启后生效',
        help: '用系统的网络层发请求，TLS 指纹和浏览器一致，不容易被 Cloudflare 拦截。设置了代理时不生效。',
        value: store.nativeNet,
        onChanged: (v) async {
          await store.setNativeNet(v);
          if (mounted) setState(() {});
        },
      ),
    ];
  }

  // ---- 关于 ----

  int _versionTaps = 0;
  DateTime _lastVersionTap = DateTime.fromMillisecondsSinceEpoch(0);

  /// 像安卓开发者模式：在「关于」里连点版本号 7 次，显示隐藏的「书籍解锁」入口（功能本身仍然默认关闭）。
  void _tapVersion() {
    if (AppPrefs.unlockEntry) return;
    final now = DateTime.now();
    if (now.difference(_lastVersionTap) > const Duration(seconds: 2)) _versionTaps = 0;
    _lastVersionTap = now;
    _versionTaps++;
    final left = 7 - _versionTaps;
    if (left > 0) {
      if (left <= 3) _snack('再点 $left 次显示「书籍解锁」');
      return;
    }
    _versionTaps = 0;
    _prefs.set(P.unlockShown, true);
    _snack('已显示「书籍解锁」入口：设置 → 书籍解锁（默认关闭，需要手动开启）');
  }

  List<Widget> _about() => [
    FutureBuilder(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) => XTile(
        title: 'Ark Novel',
        subtitle: '轻小说文库第三方客户端 · MIT${snap.hasData ? ' · v${snap.data!.version}+${snap.data!.buildNumber}' : ''}',
        onTap: AppPrefs.unlockEntry ? null : _tapVersion,
      ),
    ),
    XTile(
      title: '开源许可',
      subtitle: '用到的开源库和内置字体（霞鹜文楷、思源宋体）的许可',
      onTap: () => showLicensePage(context: context, applicationName: 'Ark Novel'),
    ),
  ];
}
