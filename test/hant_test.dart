import 'dart:io';

import 'package:flutter/widgets.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/hant.dart';
import 'package:ark_novel/next/text.dart';

void main() {
  String read(String f) => File('assets/opencc/$f').readAsStringSync();
  final hant = Hant.parse(read('STCharacters.txt'), read('STPhrases.txt'), read('TWVariants.txt'), read('ArkFixes.txt'));

  test('词组优先，区分一简多繁', () {
    expect(hant.convert('头发'), '頭髮');
    expect(hant.convert('发现'), '發現');
    expect(hant.convert('后来她去了皇后的宫殿'), contains('後來'));
  });

  test('逐字转换，不在词表里的原样保留', () {
    expect(hant.convert('这是简体'), '這是簡體');
    expect(hant.convert('为了'), '為了'); // 台湾写法，不是「爲」
    expect(hant.convert('abc 123，「」\n'), 'abc 123，「」\n');
    expect(hant.convert('魔女'), '魔女');
  });

  test('转换前后长度不变，书签和进度位置通用', () {
    const text = '第一章\n　　少女轻轻地叹了口气，说：“我们回去吧。”这里的头发、面条、干净都要转对。';
    expect(hant.convert(text).length, text.length);
  });

  test('修正表：OpenCC 在小说里常见的误转', () {
    expect(hant.convert('不是只有你'), '不是只有你');
    expect(hant.convert('一只猫和两只脚'), '一隻貓和兩隻腳');
    expect(hant.convert('棒球后卫'), '棒球後衛');
    expect(hant.convert('她克制不住'), '她克制不住');
    expect(hant.convert('挨揍了'), '挨揍了');
    expect(hant.convert('台词'), '台詞');
    expect(hant.convert('彷佛'), '彷彿');
  });

  testWidgets('界面繁体：UiHant 下的 Text 转繁体，没有时原样', (tester) async {
    Widget app(Hant? h) => Directionality(
      textDirection: TextDirection.ltr,
      child: UiHant(hant: h, child: const Column(children: [Text('设置'), Text.rich(TextSpan(text: '书架', children: [TextSpan(text: '后来')]))])),
    );
    await tester.pumpWidget(app(null));
    expect(find.text('设置'), findsOneWidget);
    await tester.pumpWidget(app(hant));
    expect(find.text('設置'), findsOneWidget);
    expect(find.text('書架後來', findRichText: true), findsOneWidget);
  });
}
