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
      for (final m in RegExp(r"static const \w+ = '((?:shelf|upd|ui)\.\w+)'").allMatches(prefs))
        if (!notSynced.contains(m[1])) 'p.${m[1]}',
      'p.reader.volumeDone',
      for (final m in RegExp(r"'(r\.\w+)'").allMatches(settings)) m[1]!,
    };
    expect(keys, contains('p.ui.hant'));
    final missing = [
      for (final k in keys)
        if (![true, 0, 1, 0.0, 2.0, 20.0, '', <String>[]].any((v) => syncPreference(k, v) != null)) k,
    ];
    expect(missing, isEmpty);
  });
}
