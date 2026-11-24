import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
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
import '../reader/reader_body.dart' show TapZoneDiagram;
import '../reader/reader_chrome.dart' show ReaderChromeField;
import '../routes.dart';
import '../security.dart';
import '../session.dart';
import '../settings.dart';
import '../swipe.dart';
import '../sync.dart' show refreshAllSyncedProviders;
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
  unlock('妙妙小工具', Icons.auto_fix_high_outlined, '遇到无法正常阅读的书？'),
  security('安全与隐私', Icons.lock_outline, '生物识别锁、防截屏、无痕模式'),
  network('网络', Icons.language, '站点节点、代理、系统网络栈'),
  about('关于', Icons.info_outline, '版本信息');

  const SettingsSection(this.title, this.icon, this.summary);

  final String title;
  final IconData icon;
  final String summary;
}

/// 设置首页的分组：组和组之间一道细线
const _homeGroups = [
  [SettingsSection.appearance, SettingsSection.reading, SettingsSection.shelf],
  [SettingsSection.update, SettingsSection.data],
  [SettingsSection.unlock, SettingsSection.security, SettingsSection.network, SettingsSection.about],
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
  ('页眉与页脚', SettingsSection.reading, '页眉 页脚 剩余时间 进度 电量 章节名 书名'),
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
  ('妙妙小工具', SettingsSection.unlock, '无法阅读 书籍解锁 受限 下架 版权 导入 口令'),
  ('备用接口', SettingsSection.unlock, '接口 API 插图 测试'),
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
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final addon = ref.watch(unlockAddonProvider);
    final q = _q.trim().toLowerCase();
    final hits = q.isEmpty
        ? const <(String, SettingsSection, String)>[]
        : _items.where((e) => (addon?.api != null || e.$1 != '备用接口') && '${e.$1} ${e.$3} ${e.$2.title}'.toLowerCase().contains(q)).toList();
    void open(SettingsSection s, [String? item]) {
      final direct = switch (item) {
        '正则规则' => Routes.rules,
        '分类管理' => Routes.categories,
        '同步' => Routes.sync,
        _ => null,
      };
      context.push(direct ?? Routes.settingsSection(s.name, highlight: item));
    }
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
                controller: _search,
                decoration: InputDecoration(
                  hint: Text('搜索设置', maxLines: 1, overflow: TextOverflow.ellipsis),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          tooltip: hz(context, '清空搜索'),
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _q = '');
                          },
                        ),
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
              for (final (title, section, _) in hits) XEntry(icon: section.icon, title: title, subtitle: '在「${section.title}」里', onTap: () => open(section, title)),
            ] else
              for (final (i, group) in _homeGroups.indexed) ...[
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
  const SettingsSectionPage({super.key, required this.section, this.highlight});

  final SettingsSection section;
  final String? highlight;

  @override
  ConsumerState<SettingsSectionPage> createState() => _SectionState();
}

class _SectionState extends ConsumerState<SettingsSectionPage> {
  final _hlKey = GlobalKey();
  bool _highlightOn = false;
  Timer? _hlTimer;
  bool _exportingBackup = false;
  bool _importingBackup = false;
  bool _testingApi = false;
  String? _proxyDraft;

  @override
  void initState() {
    super.initState();
    final hl = widget.highlight;
    if (hl != null && hl.isNotEmpty) {
      _highlightOn = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _hlKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic, alignment: 0.25);
        }
        _hlTimer = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) setState(() => _highlightOn = false);
        });
      });
    }
  }

  @override
  void dispose() {
    _hlTimer?.cancel();
    super.dispose();
  }

  Widget _hl(String tag, Widget child) {
    if (widget.highlight != tag) return child;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      key: _hlKey,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _highlightOn ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appPrefsProvider);
    final scheme = Theme.of(context).colorScheme;
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
    final hl = widget.highlight;
    return Scaffold(
      appBar: AppBar(title: Text(widget.section.title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hl != null && hl.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    children: [
                      Icon(Icons.my_location_outlined, size: 16, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('搜索定位：$hl', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary))),
                    ],
                  ),
                ),
              ...children,
            ],
          ),
        ),
        ),
      ),
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
      _hl('主题', XSegments<ThemeMode>(value: mode, options: const {ThemeMode.system: '跟随系统', ThemeMode.light: '浅色', ThemeMode.dark: '深色'}, onChanged: (v) => ref.read(themeModeProvider.notifier).set(v))),
      _hl('纯黑深色', _switch('纯黑深色', P.pureBlack, true, subtitle: '适合 OLED 屏幕')),
      const XDivider(),
      const XGroupTitle('配色'),
      // 一排色点：点一下换，选中的外面一圈
      _hl(
        '配色',
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              for (final (i, p) in appPalettes.indexed)
                Semantics(
                  button: true,
                  selected: palette == i,
                  label: p.name,
                  child: GestureDetector(
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
                ),
            ],
          ),
        ),
      ),
      if (appPalettes[palette].scene) _hl('插画动效', _switch('插画动效', P.sceneMotion, true)),
      const XDivider(),
      const XGroupTitle('语言'),
      _hl('界面繁体', XSwitch(title: '界面繁体', value: _prefs.get(P.uiHant, false), onChanged: (v) => _prefs.set(P.uiHant, v))),
      _hl(
        '正文繁体',
        XSwitch(
          title: '正文繁体',
          subtitle: '用 OpenCC 词表在本机转换，偶有误转',
          value: ref.watch(readerPrefsProvider.select((p) => p.hant)),
          onChanged: (v) => ref.read(readerPrefsProvider.notifier).update(ref.read(readerPrefsProvider).copyWith(hant: v)),
        ),
      ),
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) ...[
        const XDivider(),
        const XGroupTitle('屏幕方向'),
        _hl('屏幕方向', XSegments<int>(value: ref.watch(orientationProvider), options: const {0: '竖屏', 1: '自动旋转', 2: '横屏'}, onChanged: (v) => ref.read(orientationProvider.notifier).set(v))),
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
      _hl('翻页方式', XChoice<int>(title: '翻页方式', value: prefs.mode, options: const {0: '上下滚动', 1: '左右滑动', 2: '仿真翻页', 3: '覆盖翻页'}, onChanged: (v) => set(prefs.copyWith(mode: v)))),
      if (prefs.mode == 1) XSwitch(title: '翻页动画', value: prefs.pageAnim, onChanged: (v) => set(prefs.copyWith(pageAnim: v))),
      XSwitch(title: '宽屏双页', subtitle: '宽屏时并排两页', value: prefs.dual, onChanged: (v) => set(prefs.copyWith(dual: v))),
      _hl('点击区域', XChoice<int>(title: '点击区域', value: prefs.tapZone, options: tapZones, onChanged: (v) => set(prefs.copyWith(tapZone: v)))),
      if (prefs.tapZone != 4) XChoice<int>(title: '反转点击区域', value: prefs.tapInvert, options: const {0: '不反转', 1: '左右反转', 2: '上下反转', 3: '全部反转'}, onChanged: (v) => set(prefs.copyWith(tapInvert: v))),
      if (prefs.mode != 0) TapZoneDiagram(zone: prefs.tapZone, invert: prefs.tapInvert),
      if (android) ...[
        _hl('音量键翻页', XSwitch(title: '音量键翻页', subtitle: prefs.volumeInvert ? '+ 下一页，− 上一页' : '− 下一页，+ 上一页', value: prefs.volumeKeys, onChanged: (v) => set(prefs.copyWith(volumeKeys: v)))),
        if (prefs.volumeKeys) XSwitch(title: '反转音量键', value: prefs.volumeInvert, onChanged: (v) => set(prefs.copyWith(volumeInvert: v))),
      ],
      const XDivider(),
      const XGroupTitle('章节'),
      _hl('自动跳过已读章节', XSwitch(title: '自动跳过已读章节', value: prefs.skipRead, onChanged: (v) => set(prefs.copyWith(skipRead: v)))),
      XSwitch(title: '切换章节时显示标题', value: prefs.chapterToast, onChanged: (v) => set(prefs.copyWith(chapterToast: v))),
      _hl('预加载章节', XChoice<int>(title: '预加载章节', value: prefs.prefetch, options: const {0: '关闭', 1: '后 1 章', 2: '后 2 章', 3: '后 3 章', 5: '后 5 章'}, onChanged: (v) => set(prefs.copyWith(prefetch: v)))),
      if (prefs.prefetch > 0) XSwitch(title: '仅在 Wi-Fi 下预加载', value: prefs.prefetchWifi, onChanged: (v) => set(prefs.copyWith(prefetchWifi: v))),
      if (prefs.prefetch > 0) XSwitch(title: '全本缓存正文', value: prefs.prefetchBook, onChanged: (v) => set(prefs.copyWith(prefetchBook: v))),
      const XDivider(),
      const XGroupTitle('屏幕'),
      _hl('屏幕常亮', XSwitch(title: '屏幕常亮', value: prefs.keepScreenOn, onChanged: (v) => set(prefs.copyWith(keepScreenOn: v)))),
      XSwitch(title: '沉浸式阅读', value: prefs.fullscreen, onChanged: (v) => set(prefs.copyWith(fullscreen: v))),
      XSwitch(title: '页脚信息', value: prefs.showStatus, onChanged: (v) => set(prefs.copyWith(showStatus: v))),
      _hl(
        '页眉与页脚',
        Column(
          children: [
            XChoice<int>(title: '页眉左侧', value: prefs.headerLeft, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(headerLeft: v))),
            XChoice<int>(title: '页眉右侧', value: prefs.headerRight, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(headerRight: v))),
            XChoice<int>(title: '页脚左侧', value: prefs.footerLeft, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(footerLeft: v))),
            XChoice<int>(title: '页脚右侧', value: prefs.footerRight, options: ReaderChromeField.labels, onChanged: (v) => set(prefs.copyWith(footerRight: v))),
          ],
        ),
      ),
      const XDivider(),
      const XGroupTitle('文字'),
      _hl(
        '字号',
        XSlider(
          title: '字号',
          label: '${prefs.fontSize.round()}',
          slider: Slider(min: 14, max: 32, divisions: 18, value: prefs.fontSize, onChanged: (v) => set(prefs.copyWith(fontSize: v))),
        ),
      ),
      _link('正则规则', '用正则替换正文（去广告、统一用字），或给人名等关键词着色、添加备注', () => context.push(Routes.rules)),
      const XDivider(),
      const XGroupTitle('朗读'),
      _hl(
        '朗读语速',
        XSlider(
          title: '语速',
          label: prefs.ttsRate.toStringAsFixed(1),
          slider: Slider(min: 0.1, max: 1.5, divisions: 14, value: prefs.ttsRate.clamp(0.1, 1.5), onChanged: (v) => set(prefs.copyWith(ttsRate: v))),
        ),
      ),
      const XDivider(),
      const XGroupTitle('章节列表手势'),
      _hl('章节列表手势', XChoice<SwipeAct>(title: '右滑操作', value: swipe.right, options: {for (final a in SwipeAct.values) a: a.label}, onChanged: (a) => ref.read(swipePrefsProvider.notifier).set(right: a))),
      XChoice<SwipeAct>(title: '左滑操作', value: swipe.left, options: {for (final a in SwipeAct.values) a: a.label}, onChanged: (a) => ref.read(swipePrefsProvider.notifier).set(left: a)),
      const XDivider(),
      const XGroupTitle('卷末'),
      _hl('卷末庆祝卡片', _switch('卷末庆祝卡片', P.volumeDone, true)),
    ];
  }

  // ---- 书架 ----

  List<Widget> _shelf() {
    final cats = ref.watch(libraryProvider).cats;
    final def = _prefs.get(P.defaultCat, 'ask');
    return [
      const XGroupTitle('封面'),
      _hl('继续阅读按钮', _switch('继续阅读按钮', P.resumeButton, true)),
      _hl('未读角标', _switch('未读章数角标', P.unreadBadge, true)),
      _hl('缓存角标', _switch('已缓存章数角标', P.cacheBadge, false)),
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
      _hl('继续阅读条', _switch('继续阅读条', P.resumeBar, true, subtitle: '最近读的一本，往下滑书架时自动收起')),
      const XDivider(),
      const XGroupTitle('分类标签'),
      _hl('显示分类书籍数量', _switch('显示分类书籍数量', P.tabCounts, false)),
      _hl('按分类分别设置', _switch('按分类分别设置', P.perCat, false, help: '筛选、排序和显示方式按分类分别保存；关闭后所有分类共用一套。')),
      const XDivider(),
      const XGroupTitle('列数'),
      _hl('书架列数', XChoice<int>(title: '竖屏', value: _prefs.get(P.colsPortrait, 0), options: {0: '自动', for (var i = 2; i <= 8; i++) i: '$i 列'}, onChanged: (v) => _prefs.set(P.colsPortrait, v))),
      XChoice<int>(title: '横屏', value: _prefs.get(P.colsLandscape, 0), options: {0: '自动', for (var i = 2; i <= 10; i++) i: '$i 列'}, onChanged: (v) => _prefs.set(P.colsLandscape, v)),
      const XDivider(),
      const XGroupTitle('分类'),
      _hl(
        '新书默认分类',
        XChoice<String>(
          title: '新书默认分类',
          // 选过的分类后来被删了，就当"每次询问"
          value: def == 'ask' || def.isEmpty || cats.any((c) => c.id == def) ? def : 'ask',
          options: {'ask': '每次询问', '': '不分类', for (final c in cats) c.id: c.name},
          onChanged: (v) => _prefs.set(P.defaultCat, v),
        ),
      ),
      _link('分类管理', '新建、重命名、删除和排序', () => context.push(Routes.categories)),
    ];
  }

  // ---- 更新 ----

  List<Widget> _update() {
    return [
      const XGroupTitle('自动检查'),
      _hl('自动检查更新', XChoice<int>(title: '检查间隔', value: _prefs.get(P.updInterval, 1), options: const {0: '不自动检查', 1: '每小时', 6: '每 6 小时', 12: '每 12 小时', 24: '每天', 48: '每 2 天', 168: '每周'}, onChanged: (v) => _prefs.set(P.updInterval, v))),
      _hl('仅在 Wi-Fi 下检查', _switch('仅在 Wi-Fi 下检查', P.updWifi, false)),
      _hl('仅在充电时检查', _switch('仅在充电时检查', P.updCharging, false)),
      const XDivider(),
      const XGroupTitle('检查范围'),
      _hl('跳过已完结的书', _switch('跳过已完结的书', P.updSkipDone, false)),
      _hl('跳过未开始阅读的书', _switch('跳过未开始阅读的书', P.updSkipNotStarted, false)),
      _hl('跳过还有未读章节的书', _switch('跳过还有未读章节的书', P.updSkipUnread, false, help: '只检查已经读到最新章节的书。')),
      _hl('仅检查以下分类', _link('仅检查以下分类', _catNames(P.updInclude), () => _pickCats(P.updInclude, '仅检查以下分类（不选则不限）'))),
      _hl('排除以下分类', _link('排除以下分类', _catNames(P.updExclude), () => _pickCats(P.updExclude, '排除以下分类'))),
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
    if (_exportingBackup) return;
    setState(() => _exportingBackup = true);
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(await Backup.export())]));
    } catch (e) {
      if (mounted) _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exportingBackup = false);
    }
  }

  Future<void> _importBackup() async {
    if (_importingBackup) return;
    setState(() => _importingBackup = true);
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
      refreshAllSyncedProviders(ref);
      _snack('已恢复备份${n > 0 ? '，补回 $n 本书' : ''}');
    } catch (e) {
      if (mounted) _snack('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _importingBackup = false);
    }
  }

  Widget? _busySpinner(bool busy) => busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null;

  List<Widget> _data() {
    return [
      const XGroupTitle('存储'),
      if (!isWebPreview) _link('存储空间', '各部分占用、按书清理', () => context.push(Routes.storage).then((_) => mounted ? setState(() {}) : null)),
      if (!isWebPreview)
        _hl(
          '图片缓存',
          FutureBuilder<int>(
            future: ref.read(imageStoreProvider).diskBytes(),
            builder: (context, snap) => XTile(
              title: '清除图片缓存',
              subtitle: snap.hasData ? '封面与插图，共 ${(snap.data! / (1 << 20)).toStringAsFixed(1)} MB' : '正在计算…',
              onTap: () => _confirm('清除图片缓存？', '离线缓存中的插图也会被清除，联网后会重新下载。', '清除', () => ref.read(imageStoreProvider).clearDisk()),
            ),
          ),
        ),
      _hl(
        '章节缓存',
        XTile(
          title: '清除章节缓存',
          subtitle: '约 ${ChapterCache.totalLabel()}，不含离线缓存的整本',
          onTap: () => _confirm('清除章节缓存？', '阅读时自动缓存的章节将被删除，再次打开时重新下载；阅读报告中按卷统计的字数可能减少。', '清除', () async {
            final n = await ChapterCache.clearAuto();
            if (mounted) _snack('已清除 $n 章');
          }),
        ),
      ),
      _switch('启动时自动清理章节缓存', P.autoClear, false),
      _link('离线缓存', '管理整本下载的书', () => context.push(Routes.cache)),
      const XDivider(),
      const XGroupTitle('备份与恢复'),
      _hl('备份', XTile(title: '导出完整备份', subtitle: _exportingBackup ? '正在打包备份…' : null, trailing: _busySpinner(_exportingBackup), onTap: _exportingBackup ? null : _exportBackup)),
      XTile(title: '导入备份', subtitle: _importingBackup ? '正在恢复备份…' : null, trailing: _busySpinner(_importingBackup), onTap: _importingBackup ? null : _importBackup),
      const XDivider(),
      const XGroupTitle('多设备'),
      _link('同步', '通过 WebDAV（如坚果云）在多台设备间同步阅读进度、书签和统计', () => context.push(Routes.sync)),
    ];
  }

  // ---- 妙妙小工具 ----

  static const _authorEmail = 'chenshi22150@gmail.com';

  Future<void> _testAppApi() async {
    if (_testingApi) return;
    setState(() => _testingApi = true);
    try {
      final msg = await ref.read(unlockServiceProvider).testApi();
      if (mounted) _snack(msg);
    } catch (e) {
      if (mounted) _snack('测试失败：$e');
    } finally {
      if (mounted) setState(() => _testingApi = false);
    }
  }

  Future<void> _importAddonFromFile() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      final path = picked?.path;
      if (path == null || !mounted) return;
      final bytes = await File(path).readAsBytes();
      final cfg = await ref.read(unlockAddonProvider.notifier).importBytes(bytes);
      if (mounted) _snack('已导入：${cfg.name} v${cfg.version}');
    } catch (e) {
      if (mounted) _snack('导入失败：$e');
    }
  }

  Future<void> _importAddonFromClipboard() async {
    final notifier = ref.read(unlockAddonProvider.notifier);
    final existing = ref.read(unlockAddonProvider);
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    // 尚未安装时剪贴板里直接是合法口令就一键导入；已有扩展时先弹框确认，避免误点把现用扩展覆盖掉
    if (existing == null && clip.isNotEmpty) {
      try {
        final cfg = await notifier.importText(clip);
        if (mounted) _snack('已导入：${cfg.name} v${cfg.version}');
        return;
      } catch (_) {}
    }
    if (!mounted) return;

    final ctrl = TextEditingController(text: clip);
    String? error;
    var submitting = false;
    final imported = await showDialog<UnlockAddonConfig>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (innerContext, setLocal) => AlertDialog(
          title: const Text('导入口令或配置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: '粘贴 arktool:// 口令或 JSON 配置',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: submitting ? null : () => Navigator.pop(dialogContext), child: const Text('取消')),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      setLocal(() {
                        submitting = true;
                        error = null;
                      });
                      try {
                        final cfg = await notifier.importText(ctrl.text);
                        if (dialogContext.mounted) Navigator.pop(dialogContext, cfg);
                      } catch (e) {
                        if (innerContext.mounted) {
                          setLocal(() {
                            submitting = false;
                            error = '$e';
                          });
                        }
                      }
                    },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (imported != null && mounted) {
      _snack('已导入：${imported.name} v${imported.version}');
    }
  }

  Future<void> _removeAddon() => _confirm(
    '移除妙妙小工具？',
    '移除后将清除本机导入的扩展配置，之后可随时重新导入。',
    '移除',
    () => ref.read(unlockAddonProvider.notifier).remove(),
  );

  List<Widget> _unlock() {
    final addon = ref.watch(unlockAddonProvider);
    if (addon == null) {
      return [
        _hl('妙妙小工具', const XNote('遇到无法正常阅读的书籍？试试导入妙妙小工具扩展包。\n感兴趣的话，可以联系作者获取。')),
        XTile(
          title: '作者邮箱',
          subtitle: _authorEmail,
          trailing: const Icon(Icons.copy_outlined, size: 18),
          onTap: () {
            Clipboard.setData(const ClipboardData(text: _authorEmail));
            _snack('已复制邮箱：$_authorEmail');
          },
        ),
        const XDivider(),
        const XGroupTitle('导入扩展包'),
        XTile(
          leading: const Icon(Icons.file_open_outlined),
          title: '从文件导入',
          subtitle: '选择 .arktool 或 .json 文件',
          onTap: _importAddonFromFile,
        ),
        XTile(
          leading: const Icon(Icons.content_paste_outlined),
          title: '从剪贴板导入口令',
          subtitle: '读取剪贴板中的 arktool:// 口令或 JSON',
          onTap: _importAddonFromClipboard,
        ),
      ];
    }
    final on = _prefs.get(P.unlock, true);
    final apiRule = addon.api;
    return [
      XTile(
        leading: const Icon(Icons.extension_outlined),
        title: '${addon.name} · v${addon.version}',
        subtitle: addon.description.isEmpty ? '已导入本地运行期扩展' : addon.description,
      ),
      _hl(
        '妙妙小工具',
        XSwitch(
          title: '启用妙妙小工具',
          value: on,
          onChanged: (v) => _prefs.set(P.unlock, v),
          help: '遇到网站不给正文的书籍时，打开章节自动改从扩展通道读取，并支持整本缓存后照常阅读。',
        ),
      ),
      if (on && apiRule != null) ...[
        _hl(
          '备用接口',
          XSwitch(
            title: apiRule.label ?? '优先使用备用接口',
            value: _prefs.get(P.unlockApi, true),
            onChanged: (v) => _prefs.set(P.unlockApi, v),
            help: apiRule.description ?? '接口能用时正文可带插图；失效时自动回退到整本文本通道。',
          ),
        ),
        XTile(
          title: '测试备用接口',
          subtitle: _testingApi ? '正在测试备用接口…' : null,
          trailing: _busySpinner(_testingApi),
          onTap: _testingApi ? null : _testAppApi,
        ),
      ],
      const XDivider(),
      const XGroupTitle('管理'),
      XTile(
        leading: const Icon(Icons.file_open_outlined),
        title: '从文件更新 / 替换',
        subtitle: '选择新的 .arktool 或 .json 文件',
        onTap: _importAddonFromFile,
      ),
      XTile(
        leading: const Icon(Icons.content_paste_outlined),
        title: '从剪贴板口令更新 / 替换',
        subtitle: '读取新的 arktool:// 口令或 JSON',
        onTap: _importAddonFromClipboard,
      ),
      XTile(
        leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
        title: '移除当前工具',
        onTap: _removeAddon,
      ),
    ];
  }

  // ---- 安全与隐私 ----

  List<Widget> _security() {
    final incognito = ref.watch(incognitoProvider);
    return [
      const XGroupTitle('应用锁'),
      if (lockSupported) ...[
        _hl(
          '生物识别锁',
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
        ),
        if (_prefs.get(P.lock, false)) XChoice<int>(title: '离开多久后锁定', value: _prefs.get(P.lockAfter, 0), options: const {0: '立即', 1: '1 分钟', 5: '5 分钟', 15: '15 分钟', 30: '30 分钟'}, onChanged: (v) => _prefs.set(P.lockAfter, v)),
      ] else
        _hl('生物识别锁', const XNote('当前平台不支持生物识别锁')),
      if (secureScreenSupported) ...[
        const XDivider(),
        const XGroupTitle('防截屏'),
        _hl('防截屏', XSegments<int>(value: _prefs.get(P.secure, 0), options: const {0: '关', 1: '始终', 2: '仅无痕时'}, onChanged: (v) => _prefs.set(P.secure, v))),
      ],
      const XDivider(),
      const XGroupTitle('无痕'),
      _hl('无痕模式', XSwitch(title: '无痕模式', help: '开启期间不记录阅读进度、历史、已读章节和统计。', value: incognito, onChanged: (v) => ref.read(incognitoProvider.notifier).set(v))),
    ];
  }

  // ---- 网络 ----

  List<Widget> _network() {
    final store = ref.watch(sessionStoreProvider);
    if (isWebPreview) return [const XNote('网页预览无需设置')];
    final scheme = Theme.of(context).colorScheme;
    final proxy = ref.watch(proxyProvider);
    final isApple = !kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS);
    final hasProxy = (_proxyDraft ?? proxy).isNotEmpty;
    return [
      const XGroupTitle('站点节点'),
      _hl('站点节点', XSegments<Wenku8Node>(value: ref.watch(nodeProvider), options: const {Wenku8Node.wwwWenku8Net: 'wenku8.net', Wenku8Node.wwwWenku8Cc: 'wenku8.cc'}, onChanged: (v) => ref.read(nodeProvider.notifier).set(v))),
      const XDivider(),
      const XGroupTitle('连接'),
      _hl(
        'HTTP 代理',
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: TextFormField(
            initialValue: store.proxy,
            decoration: const InputDecoration(label: Text('HTTP 代理'), hint: Text('127.0.0.1:7890（无需填写 http://）', maxLines: 1, overflow: TextOverflow.ellipsis)),
            onChanged: (v) {
              final clean = v.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').trim();
              if (_proxyDraft != clean) setState(() => _proxyDraft = clean);
              ref.read(proxyProvider.notifier).setLater(clean);
            },
          ),
        ),
      ),
      if (isApple && hasProxy)
        Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'macOS / iOS 上内置验证页（WebView）走系统代理而非此处配置的 App 内代理。Cloudflare 验证与出口 IP 绑定，请确保系统代理与 App 内代理保持同一出口 IP，否则验证通过后仍可能失效。',
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: scheme.onTertiaryContainer),
                ),
              ),
            ],
          ),
        )
      else if (isApple)
        const XNote('macOS / iOS 验证页走系统代理；如填写 App 内代理，请保持与系统代理出口 IP 一致。'),
      _hl(
        '系统网络栈',
        XSwitch(
          title: '系统网络栈',
          subtitle: '切换后立即生效，设置了代理时不启用',
          help: '用系统的网络层发请求，TLS 指纹和浏览器一致，不容易被 Cloudflare 拦截。设置了代理时不生效。',
          value: ref.watch(nativeNetProvider),
          onChanged: (v) => ref.read(nativeNetProvider.notifier).set(v),
        ),
      ),
    ];
  }

  // ---- 关于 ----

  List<Widget> _about() => [
    _hl(
      '版本',
      FutureBuilder(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => XTile(
          title: 'Ark Novel',
          subtitle: '轻小说文库第三方客户端 · MIT${snap.hasData ? ' · v${snap.data!.version}+${snap.data!.buildNumber}' : ''}',
        ),
      ),
    ),
    XTile(
      title: '开源许可',
      subtitle: '用到的开源库和内置字体（霞鹜文楷、思源宋体）的许可',
      onTap: () => showLicensePage(context: context, applicationName: 'Ark Novel'),
    ),
  ];
}
