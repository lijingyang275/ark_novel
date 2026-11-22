import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reader/reader_body.dart';

void main() {
  const size = Size(300, 600);
  TapAction at(int zone, int invert, double x, double y, {bool paged = true}) => tapActionAt(zone, invert, Offset(x * size.width, y * size.height), size, paged: paged);

  test('默认：翻页模式左右两边翻页，滚动模式一律只呼出菜单', () {
    expect(at(0, 0, 0.1, 0.5), TapAction.prev);
    expect(at(0, 0, 0.9, 0.5), TapAction.next);
    expect(at(0, 0, 0.5, 0.5), TapAction.menu);
    expect(at(0, 0, 0.1, 0.5, paged: false), TapAction.menu);
    expect(at(1, 0, 0.1, 0.1, paged: false), TapAction.menu);
    expect(at(2, 0, 0.9, 0.5, paged: false), TapAction.menu);
    expect(at(3, 0, 0.1, 0.5, paged: false), TapAction.menu);
  });

  test('L 型：上和左中上一页，下和右中下一页', () {
    expect(at(1, 0, 0.5, 0.1), TapAction.prev);
    expect(at(1, 0, 0.1, 0.5), TapAction.prev);
    expect(at(1, 0, 0.9, 0.5), TapAction.next);
    expect(at(1, 0, 0.5, 0.9), TapAction.next);
    expect(at(1, 0, 0.5, 0.5), TapAction.menu);
  });

  test('Kindle 式、边缘式、只呼出菜单', () {
    expect(at(2, 0, 0.5, 0.1), TapAction.menu);
    expect(at(2, 0, 0.1, 0.5), TapAction.prev);
    expect(at(2, 0, 0.9, 0.5), TapAction.next);
    expect(at(3, 0, 0.1, 0.1), TapAction.next);
    expect(at(3, 0, 0.5, 0.9), TapAction.prev);
    expect(at(3, 0, 0.5, 0.5), TapAction.menu);
    expect(at(4, 0, 0.1, 0.9), TapAction.menu);
  });

  test('反转：水平反转把左右镜像，垂直反转把上下镜像', () {
    expect(at(0, 1, 0.1, 0.5), TapAction.next);
    expect(at(0, 1, 0.9, 0.5), TapAction.prev);
    expect(at(1, 2, 0.5, 0.1), TapAction.next);
    expect(at(1, 3, 0.9, 0.9), TapAction.prev);
  });
}
