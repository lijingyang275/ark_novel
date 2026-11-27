import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/cover_trim.dart';

/// [w]×[h] 的图：[inside] 里是深色的"封面"，外面是白底
CoverPixels _image(int w, int h, Rect inside) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final dark = inside.contains(Offset(x + 0.5, y + 0.5));
      rgba[i] = dark ? 40 : 250;
      rgba[i + 1] = dark ? 60 : 250;
      rgba[i + 2] = dark ? 90 : 248;
      rgba[i + 3] = 255;
    }
  }
  return CoverPixels(rgba, w, h);
}

void main() {
  const full = Rect.fromLTWH(0, 0, 1, 1);

  test('左边一条白边：收掉，其余三边不动', () {
    final px = _image(100, 140, const Rect.fromLTRB(10, 0, 100, 140));
    final r = px.trim(full);
    expect(r.left, closeTo(0.11, 0.001)); // 10 像素白边再多收 1 像素
    expect(r.top, 0);
    expect(r.right, 1);
    expect(r.bottom, 1);
  });

  test('四周一圈白边都收掉', () {
    final px = _image(100, 140, const Rect.fromLTRB(8, 6, 92, 134));
    final r = px.trim(full);
    expect(r, const Rect.fromLTRB(0.09, 7 / 140, 0.91, 133 / 140));
  });

  test('没有白边：原样返回', () {
    expect(_image(100, 140, const Rect.fromLTWH(0, 0, 100, 140)).trim(full), full);
  });

  test('只有一两个像素的白边也收掉（放大显示就是一条白线）', () {
    // 86 第一卷：底下两行白
    final r = _image(100, 140, const Rect.fromLTRB(0, 0, 100, 138)).trim(full);
    expect(r, const Rect.fromLTRB(0, 0, 1, 137 / 140));
    expect(_image(100, 140, const Rect.fromLTRB(1, 0, 100, 140)).trim(full).left, closeTo(0.02, 0.001));
  });

  test('整张白底的图：每边最多收 maxTrim，不会削没', () {
    final px = _image(100, 100, Rect.zero);
    final r = px.trim(full, maxTrim: 0.15);
    expect(r.left, closeTo(0.16, 0.001));
    expect(r.right, closeTo(0.84, 0.001));
  });

  test('只看裁剪框里那块：框外的白底不管', () {
    // 左半边白，右半边封面；框从 42% 开始，左边带了 8 像素的白
    final px = _image(100, 100, const Rect.fromLTRB(50, 0, 100, 100));
    final r = px.trim(const Rect.fromLTRB(0.42, 0, 1, 1));
    expect(r.left, closeTo(0.51, 0.001));
    expect(r.right, 1);
  });

  test('trimAsync 通过 TransferableTypedData 跨 Isolate 去白边与同步结果一致', () async {
    final px = _image(100, 140, const Rect.fromLTRB(8, 6, 92, 134));
    final asyncRect = await px.trimAsync(full);
    expect(asyncRect, px.trim(full));
  });
}
