import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/paginator.dart';

void main() {
  test('按句号切句，引号并入句尾，太短的并入下一句', () {
    const text = '他说：“走吧。”然后离开了房间。\n哦。好的，我知道了。';
    final out = [for (final (s, e) in splitSentences(text)) text.substring(s, e)];
    expect(out, ['他说：“走吧。”', '然后离开了房间。', '哦。好的，我知道了。']);
  });

  test('没有句末标点也要读到结尾', () {
    const text = '最后一句没有标点';
    expect([for (final (s, e) in splitSentences(text)) text.substring(s, e)], [text]);
  });

  test('连续句末标点不拆碎，纯符号分隔线跳过不读', () {
    const text = '　　***\n“怎么会这样……！？”少女惊讶地抬起头。\n———\n下一幕开始了。';
    final out = [for (final (s, e) in splitSentences(text)) text.substring(s, e)];
    expect(out, ['“怎么会这样……！？”', '少女惊讶地抬起头。', '下一幕开始了。']);
  });

  test('codeUnit 扫描兼容空文本、纯空白、拉丁/日文假名/重音字母与括号尾标点', () {
    expect(splitSentences(''), isEmpty);
    expect(splitSentences('   \n　　\n  '), isEmpty);
    expect(splitSentences('———\n***\n......'), isEmpty);

    const mixed = 'あ！Café 123.\n「ありがとう！」Привет мир!（测试括号）然后继续读下去。';
    final out = [for (final (s, e) in splitSentences(mixed)) mixed.substring(s, e)];
    expect(out, ['あ！Café 123.\n', '「ありがとう！」', 'Привет мир!', '（测试括号）然后继续读下去。']);
  });
}
