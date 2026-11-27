import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/next/cover_color.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:ark_novel/next/read_state.dart';
import 'package:ark_novel/next/pages/volumes_page.dart';
import 'package:ark_novel/next/progress.dart';
import 'package:ark_novel/next/volume_covers.dart';
import 'package:ark_novel/next/volumes.dart';

CatVolume vol(String t, List<String> chapters) => CatVolume(title: t, chapters: [for (final c in chapters) CatChapter(title: c.startsWith('i') ? '插图' : '第$c章', cid: c)]);

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('ark_vol_test');
    Hive.init(tmp.path);
    await Hive.openBox('session');
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('一卷的正文章节全读了才算读完（插图章不算），标回未读就不算了', () async {
    await Volumes.saveCatalogue('1', [vol('第一卷', ['i1', 'a', 'b']), vol('第二卷', ['c'])]);
    expect(Volumes.of('1').first.illus, 'i1');
    expect(Volumes.done('1'), isEmpty);

    await ReadState.setRead('1', ['a', 'b'], true);
    expect(Volumes.done('1').keys, ['第一卷']);
    expect(Volumes.allDone().single.$3.title, '第一卷');

    await ReadState.setRead('1', ['b'], false);
    expect(Volumes.done('1'), isEmpty);
  });

  test('卷封面：第一张是横版展开图（连书脊、封底）就用后面第一张竖着的', () async {
    final sizes = {'spread': const Size(2000, 700), 'cover': const Size(700, 1000), 'insert': const Size(700, 1000)};
    Future<Size> sizeOf(String url) async => sizes[url]!;
    expect(await chooseCover(['spread', 'cover', 'insert'], sizeOf), 'cover');
    expect(await chooseCover(['cover', 'spread'], sizeOf), 'cover');
    expect(await chooseCover(['spread'], sizeOf), 'spread'); // 全是横的就还用第一张
    expect(await chooseCover([], sizeOf), '');
  });

  test('封面背景色：取主色调、压低饱和度、调暗', () {
    final red = Uint8List.fromList([for (var i = 0; i < 16; i++) ...[220, 40, 40, 255]]);
    final hsl = HSLColor.fromColor(tintFrom(red));
    expect(hsl.hue, closeTo(0, 1));
    expect(hsl.saturation, closeTo(0.35, 0.01));
    expect(hsl.lightness, closeTo(0.38, 0.01));
    // 白底上的一点颜色不会被冲成纯灰
    final mostlyWhite = Uint8List.fromList([for (var i = 0; i < 15; i++) ...[250, 250, 250, 255], 40, 80, 220, 255]);
    expect(HSLColor.fromColor(tintFrom(mostlyWhite)).hue, closeTo(225, 20));
  });

  test('自选封面的裁剪框：写进地址再读出来；没有裁剪框原样返回', () {
    const url = 'https://pic.777743.xyz/1/1/1.jpg';
    expect(splitCrop(url), (url: url, crop: null));
    final r = splitCrop(withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)));
    expect(r.url, url);
    expect(r.crop, const Rect.fromLTWH(0.5, 0, 0.5, 1));
    // 自动去白边的记成 #trim=，读出来一样
    final t = splitCrop(withCrop(url, const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true));
    expect(t.url, url);
    expect(t.crop, const Rect.fromLTWH(0.1, 0, 0.8, 1));
  });

  test('提升清晰度的标记 #sr：和裁剪框一起写、一起读，读出来的地址是干净的', () {
    const url = 'https://pic.777743.xyz/1/1/1.jpg';
    final cropped = withSr(withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)), true);
    expect(wantsSr(cropped), isTrue);
    expect(splitCrop(cropped), (url: url, crop: const Rect.fromLTWH(0.5, 0, 0.5, 1)));
    expect(withSr(url, true), '$url#sr');
    expect(splitCrop(withSr(url, true)), (url: url, crop: null));
    expect(withSr(cropped, false), withCrop(url, const Rect.fromLTWH(0.5, 0, 0.5, 1)));
  });

  test('cropRgba 只取裁剪框里的像素', () {
    // 2x2：左边红、右边蓝，取右半边只剩蓝
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 0, 255, 255]);
    expect(cropRgba(rgba, 2, 2, const Rect.fromLTWH(0.5, 0, 0.5, 1)), [0, 0, 255, 255, 0, 0, 255, 255]);
  });

  test('正在读第几卷：进度所在的卷读完了（手动标的）就往后找没读完的，全读完为 -1', () async {
    await Volumes.saveCatalogue('2', [vol('一', ['a']), vol('二', ['b']), vol('三', ['c'])]);
    expect(readingVolume('2'), -1); // 没读过
    await ReadingProgress.save('2', 'a', 0);
    expect(readingVolume('2'), 0);
    await ReadState.setRead('2', ['a'], true);
    expect(readingVolume('2'), 1);
    await ReadState.setRead('2', ['b', 'c'], true);
    expect(readingVolume('2'), -1);
  });

  test('清理图片时留下的卷封面：书架上显示的第一卷、手动挑过或裁过的；其余卷可以删', () async {
    await Volumes.saveCatalogue('5', [vol('一', ['i1', 'a']), vol('二', ['i2', 'b']), vol('三', ['i3', 'c']), vol('四', ['i4', 'd'])]);
    await Volumes.setCover('5', '一', 'u1');
    await Volumes.setCover('5', '二', 'u2');
    await Volumes.setCover('5', '三', 'u3', picked: true);
    await Volumes.setCover('5', '四', withCrop('u4', const Rect.fromLTWH(0, 0, 0.5, 1))); // 以前裁过的，没有标记
    expect(Volumes.keptCovers(['5']), unorderedEquals(['u1', 'u3', withCrop('u4', const Rect.fromLTWH(0, 0, 0.5, 1))]));
    await Volumes.setCover('5', '二', withCrop('u2', const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true)); // 自动去白边的不算手动挑的
    expect(Volumes.keptCovers(['5']), isNot(contains(withCrop('u2', const Rect.fromLTWH(0.1, 0, 0.8, 1), auto: true))));
    expect(Volumes.keptCovers([]), isNot(contains('u1'))); // 不在书架上了，第一卷也不留
    await Volumes.resetCover('5', '三');
    expect(Volumes.keptCovers(['5']), isNot(contains('u3')));
  });

  test('先更新正文（无插图记为 ""）后补上插图章：自动清掉旧空封面记录，手动挑过的不动', () async {
    await Volumes.saveCatalogue('6', [vol('第一卷', ['i1', 'a']), vol('第二卷', ['b'])]);
    await Volumes.setCover('6', '第一卷', 'cover1');
    await Volumes.setCover('6', '第二卷', ''); // 当时还没有插图章，记成了 ''
    expect(Volumes.cover('6', '第二卷'), '');

    // 后来第二卷补上了插图章 i2
    await Volumes.saveCatalogue('6', [vol('第一卷', ['i1', 'a']), vol('第二卷', ['b', 'i2'])]);
    expect(Volumes.cover('6', '第二卷'), isNull); // 自动清掉，等待重新取封面

    // 如果是用户手动挑过的封面，即使插图章变化也保留用户挑的
    await Volumes.setCover('6', '第二卷', 'custom#crop=0,0,0.5,1', picked: true);
    await Volumes.saveCatalogue('6', [vol('第一卷', ['i1', 'a']), vol('第二卷', ['b', 'i2_new'])]);
    expect(Volumes.cover('6', '第二卷'), 'custom#crop=0,0,0.5,1');
  });

  test('Volumes 内存只读缓存按 Hive 引用复用，写入或外部直接写 Box 后自动失效；ReadState.readView 零拷贝只读', () async {
    await Volumes.saveCatalogue('7', [vol('第一卷', ['a', 'b'])]);
    final v1 = Volumes.of('7');
    final v2 = Volumes.of('7');
    expect(identical(v1, v2), isTrue);
    expect(() => v1.add(const Vol('x', [], null)), throwsUnsupportedError);

    await Volumes.setCover('7', '第一卷', 'u1');
    final c1 = Volumes.covers('7');
    final c2 = Volumes.covers('7');
    expect(identical(c1, c2), isTrue);
    await Hive.box('session').put('vcover2:7', {'第一卷': 'u2'});
    final c3 = Volumes.covers('7');
    expect(identical(c1, c3), isFalse);
    expect(c3['第一卷'], 'u2');

    await ReadState.setRead('7', ['a', 'b'], true);
    final d1 = Volumes.done('7');
    final d2 = Volumes.done('7');
    expect(identical(d1, d2), isTrue);
    final r1 = ReadState.readView('7');
    final r2 = ReadState.readView('7');
    expect(identical(r1, r2), isTrue);
    expect(() => r1.add('c'), throwsUnsupportedError);
  });

  test('Volumes 按 aid 细粒度通知：单本书变更只刷新对应 aid 订阅者，全局广播可刷新全部并支持自动释放', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var hitsA = 0;
    var hitsB = 0;
    var hitsGlobal = 0;
    final subA = c.listen(volumeChangeForProvider('aidA'), (_, _) => hitsA++);
    final subB = c.listen(volumeChangeForProvider('aidB'), (_, _) => hitsB++);
    final subG = c.listen(volumeChangesProvider, (_, _) => hitsGlobal++);

    await Volumes.saveCatalogue('aidA', [vol('第一卷', ['c1'])]);
    await Volumes.setCover('aidA', '第一卷', 'https://img.example/a.jpg');
    await Future<void>.delayed(Duration.zero);
    expect(hitsA, greaterThanOrEqualTo(1));
    expect(hitsB, 0);
    expect(hitsGlobal, greaterThanOrEqualTo(1));

    final aBefore = hitsA;
    final bBefore = hitsB;
    await Volumes.setRating('aidB', '第一卷', 5);
    await Future<void>.delayed(Duration.zero);
    expect(hitsA, aBefore);
    expect(hitsB, bBefore + 1);

    // 全局广播（Volumes.changes.value++）同步通知所有已订阅 aid
    final aPrev = hitsA;
    final bPrev = hitsB;
    Volumes.changes.value++;
    await Future<void>.delayed(Duration.zero);
    expect(hitsA, aPrev + 1);
    expect(hitsB, bPrev + 1);

    subA.close();
    subB.close();
    subG.close();
  });

  test('Volumes.metaChanges 与封面变更分离；tintFrom 直接按 crop 采样结果与 cropRgba 一致', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var metaHits = 0;
    final subMeta = c.listen(volumeMetaChangesProvider, (_, _) => metaHits++);

    await Volumes.saveCatalogue('aidMeta', [vol('第一卷', ['c1'])]);
    await Future<void>.delayed(Duration.zero);
    final metaBeforeCover = metaHits;
    await Volumes.setCover('aidMeta', '第一卷', 'https://img.example/m.jpg');
    await Future<void>.delayed(Duration.zero);
    expect(metaHits, metaBeforeCover); // 仅封面变化不触发 metaChanges

    await Volumes.setRating('aidMeta', '第一卷', 4);
    await Future<void>.delayed(Duration.zero);
    expect(metaHits, metaBeforeCover + 1);

    await ReadState.setRead('aidMeta', ['c1'], true);
    await Future<void>.delayed(Duration.zero);
    expect(metaHits, metaBeforeCover + 2);
    subMeta.close();

    // tintFrom 直接带 crop 区域采样与 cropRgba 结果一致
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 0, 255, 255]);
    const rect = Rect.fromLTWH(0.5, 0, 0.5, 1);
    expect(tintFrom(rgba, w: 2, h: 2, crop: rect), tintFrom(cropRgba(rgba, 2, 2, rect)));
  });
}
