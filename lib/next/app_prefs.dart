import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:hive_ce_flutter/hive_flutter.dart';

/// 书架、自动更新、安全这几组零散的设置，都记在本地 `p.<名字>` 里。
/// 界面里按需用 `ref.watch(appPref(P.xxx, fallback))` / `ref.watch(appPrefList(P.xxx))` / `ref.watch(appPrefProvider(P.xxx))` 细粒度监听，
/// 或 `ref.watch(appPrefsProvider)` 之后用 [AppPrefs.get] 读；写统一用 `ref.read(appPrefsProvider.notifier).set`；
/// 不经 Riverpod 的地方（自动更新、启动清理）用静态的 [AppPrefs.read]。
class AppPrefs extends Notifier<int> {
  static int _rev = 0;

  static Box get _box => Hive.box('session');

  static T read<T>(String key, T fallback) {
    final v = _box.get('p.$key');
    return v is T ? v : fallback;
  }

  /// 存的是列表时按字符串列表读（Hive 读出来是 `List<dynamic>`）
  static List<String> readList(String key) => ((_box.get('p.$key') as List?) ?? const []).cast<String>();

  static Future<void> write(String key, Object? value) => _box.putAll({'p.$key': value, ?_syncGroup(key): DateTime.now().millisecondsSinceEpoch});

  @override
  int build() => ++_rev;

  T get<T>(String key, T fallback) => read(key, fallback);

  void set(String key, Object? value) {
    write(key, value);
    state = ++_rev;
  }

  /// 这个设置属于哪组可选同步（改了就更新那组的时间）；不跨设备同步的返回 null。
  static String? _syncGroup(String key) => switch (key) {
    P.colsPortrait || P.colsLandscape || P.lastTab => null,
    P.volumeDone => 'sync:readerTs',
    _ when key.startsWith('shelf.') || key.startsWith('upd.') || key.startsWith('stats.') => 'sync:prefsTs',
    _ when key.startsWith('ui.') => 'sync:appearanceTs',
    _ => null,
  };
}

final appPrefsProvider = NotifierProvider<AppPrefs, int>(AppPrefs.new);

class _AppPrefNotifier extends Notifier<Object?> {
  _AppPrefNotifier(this.key);

  final String key;

  @override
  Object? build() {
    ref.watch(appPrefsProvider);
    return _snapshot(AppPrefs._box.get('p.$key'));
  }

  @override
  bool updateShouldNotify(Object? previous, Object? next) => !_prefEquals(previous, next);
}

Object? _snapshot(Object? v) => switch (v) {
  List l => List<Object?>.unmodifiable(l.map(_snapshot)),
  Map m => Map<Object?, Object?>.unmodifiable({for (final e in m.entries) e.key: _snapshot(e.value)}),
  _ => v,
};

bool _prefEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_prefEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_prefEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  return a == b;
}

/// 按 key 细粒度监听单个偏好（原始值不可变快照，List/Map 按内容深比较）；仅在该 key 实际变化时通知下游。
final appPrefProvider = NotifierProvider.autoDispose.family<_AppPrefNotifier, Object?, String>(_AppPrefNotifier.new);

/// 按 key 细粒度监听带类型回退的偏好值（例：`ref.watch(appPref(P.resumeBar, true))`）。
ProviderListenable<T> appPref<T>(String key, T fallback) => appPrefProvider(key).select((v) => v is T ? v : fallback);

/// 按 key 细粒度监听字符串列表偏好（例：`ref.watch(appPrefList(P.hiddenTabs))`）。
ProviderListenable<List<String>> appPrefList(String key) =>
    appPrefProvider(key).select((v) => v is List ? List<String>.unmodifiable(v.cast<String>()) : const <String>[]);

/// 设置名（集中放一处，免得拼错）
class P {
  P._();

  // 书架
  static const resumeButton = 'shelf.resume'; // bool，封面上的"继续阅读"按钮
  static const unreadBadge = 'shelf.unreadBadge'; // bool
  static const cacheBadge = 'shelf.cacheBadge'; // bool
  static const tabCounts = 'shelf.tabCounts'; // bool，标签后面显示书数
  static const perCat = 'shelf.perCat'; // bool，每个标签单独的筛选 / 排序 / 显示
  static const colsPortrait = 'shelf.colsPortrait'; // int，0 自动
  static const colsLandscape = 'shelf.colsLandscape'; // int，0 自动
  static const defaultCat = 'shelf.defaultCat'; // String，'ask' 每次问，'' 不放进分类，其余是分类 id
  static const hiddenTabs = 'shelf.hiddenTabs'; // List<String> 书架上不显示的标签 id
  static const lastTab = 'shelf.lastTab'; // String 上次停在的标签 id
  static const resumeBar = 'shelf.resumeBar'; // bool 书架顶上的「继续阅读」条
  static const coverTrim = 'shelf.coverTrim'; // bool 框封面时自动去掉四周的白边
  static const coverSr = 'shelf.coverSr'; // int 提升清晰度：0 自动（长边不到 600 像素的图），1 手动（框封面时选）

  // 发现
  static const discoverRank = 'discover.rank'; // String 上次的排行榜
  static const discoverTag = 'discover.tag'; // String 上次的分类标签
  static const discoverTagSort = 'discover.tagSort'; // String 上次的分类排序
  static const hideShelved = 'discover.hideShelved'; // bool 排行、分类里不显示已在书架上的书

  // 自动更新
  static const updInterval = 'upd.interval'; // int 小时，0 不自动
  static const updWifi = 'upd.wifi'; // bool 只在 Wi-Fi 下自动更新
  static const updCharging = 'upd.charging'; // bool 只在充电时自动更新
  static const updSkipDone = 'upd.skipDone'; // bool 跳过已完结的
  static const updSkipNotStarted = 'upd.skipNotStarted'; // bool 跳过还没开始读的
  static const updSkipUnread = 'upd.skipUnread'; // bool 跳过还有未读章节的
  static const updInclude = 'upd.include'; // List<String> 只更新这些分类，空是不限
  static const updExclude = 'upd.exclude'; // List<String> 不更新这些分类

  // 外观
  static const pureBlack = 'ui.pureBlack'; // bool 深色时用 AMOLED 纯黑底
  static const uiHant = 'ui.hant'; // bool 界面用繁体（台湾写法），阅读正文另有开关
  static const sceneMotion = 'ui.sceneMotion'; // bool 插画主题的云和旗子动起来

  // 阅读
  static const volumeDone = 'reader.volumeDone'; // bool 读完一卷时弹庆祝卡片

  // 阅读目标与统计
  static const statsDailyGoal = 'stats.dailyGoal'; // int 每日阅读目标分钟数（0 未开启）
  static const statsYearlyVolGoal = 'stats.yearlyVolGoal'; // int 年度目标读完卷数（0 未开启）

  // 数据
  static const autoClear = 'data.autoClear'; // bool 每次打开 App 自动清理读过时缓存的章节

  // 妙妙小工具（运行期扩展）
  static const unlock = 'unlock.enabled'; // bool 总开关
  static const unlockApi = 'unlock.api'; // bool 先试备用接口（带插图），不行再用整本文本通道

  // 安全
  static const lock = 'sec.lock'; // bool 生物识别锁
  static const lockAfter = 'sec.lockAfter'; // int 分钟，0 立即
  static const secure = 'sec.secure'; // int 0 关 1 始终 2 仅无痕时

  // 同步可选项（核心数据始终同步；这些设备习惯项由用户自选是否跨设备同步）
  static const syncAvatar = 'sync.avatar'; // bool 同步自定义头像（默认开）
  static const syncShelfPrefs = 'sync.shelfPrefs'; // bool 同步书架与更新偏好（默认关）
  static const syncReaderPrefs = 'sync.readerPrefs'; // bool 同步阅读器排版设置（默认关）
  static const syncAppearance = 'sync.appearance'; // bool 同步外观与主题（默认关）
}
