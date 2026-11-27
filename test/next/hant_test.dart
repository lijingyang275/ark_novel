import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder;
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/text.dart';
import 'package:flutter/widgets.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String f) => File('assets/opencc/$f').readAsStringSync();
  Uint8List readGzBytes() => File('assets/opencc/STPhrases.txt.gz').readAsBytesSync();
  String readPhrases() => utf8.decode(GZipDecoder().decodeBytes(readGzBytes()));

  test('Hant.parseAsync 与 Hant.parseAsyncGz 后台 Isolate 解析结果与同步 Hant.parse 完全一致', () async {
    final chars = read('STCharacters.txt');
    final phrasesGz = readGzBytes();
    final phrases = utf8.decode(GZipDecoder().decodeBytes(phrasesGz));
    final tw = read('TWVariants.txt');
    final fixes = read('ArkFixes.txt');
    final syncHant = Hant.parse(chars, phrases, tw, fixes);
    final asyncHant = await Hant.parseAsync(chars, phrases, tw, fixes);
    final asyncGzHant = await Hant.parseAsyncGz(chars, phrasesGz, tw, fixes);

    const samples = [
      '头发、发现、后来她去了皇后的宫殿',
      '不是只有你，一只猫和两只脚，棒球后卫',
      '她克制不住，挨揍了，台词，彷佛，为了',
      '第一章\n　　少女轻轻地叹了口气，说：“我们回去吧。”abc 123',
    ];
    for (final s in samples) {
      final expected = syncHant.convert(s);
      expect(asyncHant.convert(s), expected, reason: s);
      expect(asyncGzHant.convert(s), expected, reason: s);
      expect(asyncGzHant.convert(s).length, s.length);
    }
  });

  test('紧凑 Trie 最长匹配、前缀回退、覆盖优先级与 _post 触发字符优化', () {
    final h = Hant.parse(
      '发\t發\n只\t隻\n克\t剋\n制\t制\n三\t叁\n四\t肆\n六\t陆\n',
      '发现\t發現\n发\t誤\n一二三四五六\t壹貳參肆伍陸\n一二\t壹貳\n一二三四\t甲乙丙丁\n',
      '陆\t陸\n',
      '一二\t覆蓋\n=剋制\t克制\n',
    );
    // 完整最长命中
    expect(h.convert('一二三四五六'), '壹貳參肆伍陸');
    // 前缀走到「一二三四五」后中断，正确回退到次长有效节点「一二三四」，后接单字「五」「六」（六再走 TWVariants）
    expect(h.convert('一二三四五七'), '甲乙丙丁五七');
    // 前缀「一二三」回退到「一二」（且 ArkFixes 覆盖原词组）+ 单字「三」
    expect(h.convert('一二三'), '覆蓋叁');
    // 长度为 1 的 phrase 条目不进入 Trie，走单字表
    expect(h.convert('发'), '發');
    // 命中 _post 触发字符「剋」
    expect(h.convert('克制'), '克制');
    // 原文本身已是繁体「剋制」且无字符变更时依然触发 _post
    expect(h.convert('剋制'), '克制');
    // 不含触发字符，跳过 _post
    expect(h.convert('发现'), '發現');
    // 无需变更时直接返回相同字符串实例
    const ascii = 'Hello Ark Novel 12345';
    expect(identical(h.convert(ascii), ascii), isTrue);
  });

  test('真 LRU 缓存淘汰顺序与 2000 字 / 64K 总字符上限受控释放', () {
    final h = Hant.parse('发\t發\n', '');
    final a = 'a' * 1500;
    final b = 'b' * 1500;
    final c = 'c' * 1500;
    h.convert(a);
    h.convert(b);
    h.convert(c);
    // 再次命中 a，应移到尾部（最新）
    h.convert(a);
    expect(h.cacheKeysForTest, [b, c, a]);

    // 超过 2000 字的长文本不进缓存
    final huge = '发' * 2001;
    expect(h.convert(huge), '發' * 2001);
    expect(h.cacheLength, 3);

    // 连续写入大量 1500 字文本，总字符数严格受控在 64K 以内
    for (var i = 0; i < 60; i++) {
      h.convert('发${i.toString().padLeft(4, '0')}${'x' * 1495}');
    }
    expect(h.cacheChars, lessThanOrEqualTo(64 * 1024));
    expect(h.cacheLength, greaterThan(0));
  });

  test('Hant.unload 清空静态缓存实例', () {
    final h = Hant.parse('发\t發\n', readPhrases().substring(0, 200));
    Hant.loaded = h;
    expect(Hant.loaded, isNotNull);
    Hant.unload();
    expect(Hant.loaded, isNull);
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
