import 'dart:io';

import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/text.dart';
import 'package:flutter/widgets.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String f) => File('assets/opencc/$f').readAsStringSync();

  test('Hant.parseAsync 后台 Isolate 解析结果与同步 Hant.parse 完全一致', () async {
    final chars = read('STCharacters.txt');
    final phrases = read('STPhrases.txt');
    final tw = read('TWVariants.txt');
    final fixes = read('ArkFixes.txt');
    final syncHant = Hant.parse(chars, phrases, tw, fixes);
    final asyncHant = await Hant.parseAsync(chars, phrases, tw, fixes);

    const samples = [
      '头发、发现、后来她去了皇后的宫殿',
      '不是只有你，一只猫和两只脚，棒球后卫',
      '她克制不住，挨揍了，台词，彷佛，为了',
      '第一章\n　　少女轻轻地叹了口气，说：“我们回去吧。”abc 123',
    ];
    for (final s in samples) {
      expect(asyncHant.convert(s), syncHant.convert(s), reason: s);
      expect(asyncHant.convert(s).length, s.length);
    }
  });

  test('首字分桶词长最长优先匹配与 _post 触发字符优化', () {
    final h = Hant.parse(
      '发\t發\n只\t隻\n克\t剋\n制\t制\n',
      '发现\t發現\n发\t發\n一二三四五六\t壹貳參肆伍陸\n一二\t壹貳\n',
      '',
      '=剋制\t克制\n',
    );
    expect(h.convert('一二三四五六'), '壹貳參肆伍陸');
    expect(h.convert('一二三'), '壹貳三');
    expect(h.convert('克制'), '克制'); // 命中 _post 触发字符「剋」
    expect(h.convert('发现'), '發現'); // 不含触发字符，跳过 _post
  });

  test('hantSpan 在文字无需变更时直接复用原 TextSpan', () {
    final h = Hant.parse('发\t發\n现\t現\n', '');
    const unchanged = TextSpan(text: 'abc 123', children: [TextSpan(text: 'XYZ')]);
    expect(identical(hantSpan(unchanged, h), unchanged), isTrue);

    const changed = TextSpan(text: 'abc', children: [TextSpan(text: '发现')]);
    final out = hantSpan(changed, h) as TextSpan;
    expect(identical(out, changed), isFalse);
    expect((out.children!.single as TextSpan).text, '發現');
  });
}
