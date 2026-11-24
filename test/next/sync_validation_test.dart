import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/sync_validation.dart';

void main() {
  // 同步会发送的设置都必须在白名单里，否则对方会悄悄丢掉；从源码里找键，新增设置忘了登记时这里会失败。
  test('同步发送的每个可选设置都能通过校验', () {
    final prefs = File('lib/next/app_prefs.dart').readAsStringSync();
    final settings = File('lib/next/settings.dart').readAsStringSync();
    const notSynced = {'shelf.colsPortrait', 'shelf.colsLandscape', 'shelf.lastTab'};
    final keys = {
      for (final m in RegExp(r"static const \w+ = '((?:shelf|upd|ui|stats)\.\w+)'").allMatches(prefs))
        if (!notSynced.contains(m[1])) 'p.${m[1]}',
      'p.reader.volumeDone',
      for (final m in RegExp(r"'(r\.\w+)'").allMatches(settings)) m[1]!,
    };
    expect(keys, contains('p.ui.hant'));
    expect(keys, contains('p.stats.dailyGoal'));
    expect(keys, contains('p.stats.yearlyVolGoal'));
    final missing = [
      for (final k in keys)
        if (![true, 0, 1, 10, 0.0, 0.5, 2.0, 20.0, '', <String>[]].any((v) => syncPreference(k, v) != null)) k,
    ];
    expect(missing, isEmpty);
  });

  test('新增字体档位、3D 书架显示模式与按分类选项均能通过校验', () {
    expect(syncPreference('r.font', 3), 3);
    expect(syncPreference('r.font', 4), 4);
    expect(syncPreference('r.font', 5), isNull);
    expect(syncShelfOptions({'display': 4, 'sort': 7}), {'display': 4, 'sort': 7});
    expect(syncPreference('p.shelf.tab.auto:ongoing', {'display': 4, 'unread': 1}), {'display': 4, 'unread': 1});
  });

  test('自动阅读、背景纹理/透明度、页眉页脚字段与阅读目标范围校验', () {
    // 自动阅读速度与翻页秒数
    expect(syncPreference('r.autoScrollSpeed', 20), 20.0);
    expect(syncPreference('r.autoScrollSpeed', 220.0), 220.0);
    expect(syncPreference('r.autoScrollSpeed', 19.9), isNull);
    expect(syncPreference('r.autoScrollSpeed', 221), isNull);
    expect(syncPreference('r.autoTurnSeconds', 3), 3);
    expect(syncPreference('r.autoTurnSeconds', 30), 30);
    expect(syncPreference('r.autoTurnSeconds', 2), isNull);
    expect(syncPreference('r.autoTurnSeconds', 31), isNull);
    expect(syncPreference('r.autoTurnSeconds', 8.5), isNull);

    // 纸张纹理与自定义背景图浓度
    expect(syncPreference('r.bgTexture', 0), 0);
    expect(syncPreference('r.bgTexture', 3), 3);
    expect(syncPreference('r.bgTexture', -1), isNull);
    expect(syncPreference('r.bgTexture', 4), isNull);
    expect(syncPreference('r.bgImageOpacity', 0.05), 0.05);
    expect(syncPreference('r.bgImageOpacity', 0.85), 0.85);
    expect(syncPreference('r.bgImageOpacity', 0.04), isNull);
    expect(syncPreference('r.bgImageOpacity', 0.86), isNull);

    // 页眉页脚字段
    for (final k in ['r.headerLeft', 'r.headerRight', 'r.footerLeft', 'r.footerRight']) {
      expect(syncPreference(k, 0), 0, reason: k);
      expect(syncPreference(k, 6), 6, reason: k);
      expect(syncPreference(k, -1), isNull, reason: k);
      expect(syncPreference(k, 7), isNull, reason: k);
      expect(syncPreference(k, '1'), isNull, reason: k);
    }

    // 阅读目标
    expect(syncPreference('p.stats.dailyGoal', 0), 0);
    expect(syncPreference('p.stats.dailyGoal', 60), 60);
    expect(syncPreference('p.stats.dailyGoal', 1440), 1440);
    expect(syncPreference('p.stats.dailyGoal', -1), isNull);
    expect(syncPreference('p.stats.dailyGoal', 1441), isNull);
    expect(syncPreference('p.stats.yearlyVolGoal', 0), 0);
    expect(syncPreference('p.stats.yearlyVolGoal', 24), 24);
    expect(syncPreference('p.stats.yearlyVolGoal', 9999), 9999);
    expect(syncPreference('p.stats.yearlyVolGoal', -1), isNull);
    expect(syncPreference('p.stats.yearlyVolGoal', 10000), isNull);
  });
}
