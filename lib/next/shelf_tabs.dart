import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'app_prefs.dart';
import 'library.dart';

/// 自动分组的标签 id：按书是否完结实时分，不存在书里
const ongoingShelfTab = 'auto:ongoing';
const doneShelfTab = 'auto:done';
const _autoNames = {'连载', '完结'};

/// 书架正在多选：外面的底部导航据此收起，让位给多选的操作条
final shelfSelecting = ValueNotifier<bool>(false);

/// 书架正在搜索：返回键先关搜索，外面不提示退出
final shelfSearching = ValueNotifier<bool>(false);

/// 某个标签页里的书：默认是全部，连载 / 完结按状态分（同名的自建分类并进来），其余是自建分类里的。
Iterable<LibBook> shelfBooksIn(LibraryState lib, String tabId) {
  bool inNamed(LibBook b, String name) => lib.cats.any((c) => c.name == name && b.cats.contains(c.id));
  return lib.books.values.where((b) => switch (tabId) {
    '' => true,
    ongoingShelfTab => !b.done && !inNamed(b, '完结') || inNamed(b, '连载'),
    doneShelfTab => b.done || inNamed(b, '完结'),
    final id => b.cats.contains(id),
  });
}

/// 某个标签页里有几本书（分类管理页用）
int booksInTab(LibraryState lib, String tabId) => shelfBooksIn(lib, tabId).length;

/// 全部标签（含隐藏的）：默认（全部书）、连载、完结，再加自己建的分类；顺序按拖动存的 shelfTabOrder，没存过的排后面。
List<LibCategory> allShelfTabs(List<LibCategory> cats) {
  // 自己建过同名的分类（比如"完结"）时合并：不再单独显示，里面的书并入自动标签
  final all = [const LibCategory('', '默认'), const LibCategory(ongoingShelfTab, '连载'), const LibCategory(doneShelfTab, '完结'), ...cats.where((c) => !_autoNames.contains(c.name))];
  final order = ((Hive.box('session').get('shelfTabOrder') as List?) ?? const []).cast<String>();
  int rank(LibCategory c) {
    final i = order.indexOf(c.id);
    return i < 0 ? order.length : i;
  }

  return [...all]..sort((a, b) => rank(a).compareTo(rank(b))); // sort 稳定，没存过的保持原顺序
}

/// 书架上显示的标签：去掉隐藏的；全隐藏了就留第一个
List<LibCategory> shelfTabs(List<LibCategory> cats, {List<String>? hidden}) {
  final all = allShelfTabs(cats);
  final off = hidden ?? AppPrefs.readList(P.hiddenTabs);
  final shown = all.where((c) => !off.contains(c.id)).toList();
  return shown.isEmpty ? all.take(1).toList() : shown;
}

/// 自建分类里和自动标签同名的不单独显示（并进自动标签）
bool isMergedCategory(LibCategory c) => _autoNames.contains(c.name);
