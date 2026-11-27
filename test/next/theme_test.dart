import 'dart:io';
import 'dart:math' as math;

import 'package:ark_novel/next/color_picker.dart';
import 'package:ark_novel/next/pages/splash_page.dart';
import 'package:ark_novel/next/routes.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:ark_novel/next/theme.dart';
import 'package:ark_novel/next/theme_art.dart';
import 'package:ark_novel/next/theme_doodle.dart';
import 'package:ark_novel/next/theme_squire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

double _contrastRatio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ark_theme_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('buildAppTheme 对比度与 ColorScheme 完整性', () {
    for (final palette in appPalettes) {
      for (final (label, brightness, pureBlack) in [
        ('浅色', Brightness.light, false),
        ('深色', Brightness.dark, false),
        ('深色纯黑', Brightness.dark, true),
      ]) {
        test('${palette.name} / $label', () {
          final theme = buildAppTheme(brightness, palette, pureBlack);
          final s = theme.colorScheme;
          final dark = brightness == Brightness.dark;

          // 主按钮文字对比度：深色模式全员满足 WCAG AA >= 4.5:1；浅色饱和按钮满足大字/按钮 >= 3.0:1
          final primaryCr = _contrastRatio(s.primary, s.onPrimary);
          expect(primaryCr, greaterThanOrEqualTo(dark ? 4.5 : 3.0), reason: '${palette.name}/$label primary vs onPrimary = ${primaryCr.toStringAsFixed(2)}');

          // 次强调色文字对比度
          expect(_contrastRatio(s.secondary, s.onSecondary), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label secondary vs onSecondary');

          // 错误色：无论在背景/卡片上还是配合 onError，均需满足 WCAG AA >= 4.5:1
          expect(_contrastRatio(s.error, s.onError), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label error vs onError');
          expect(_contrastRatio(s.error, s.surface), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label error vs surface');
          expect(_contrastRatio(s.error, s.surfaceContainer), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label error vs surfaceContainer');

          // 普通主题深色缓存角标（Badge 默认文字取 onError、背景取 secondary）可读
          if (dark && palette.secondary == null) {
            expect(_contrastRatio(s.secondary, s.onError), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label cache badge secondary vs onError');
          }

          // 无痕模式顶栏 tertiaryContainer：需与 surface/card 区分，且 onTertiaryContainer 与 onSurface 均清晰可读
          expect(s.tertiaryContainer, isNot(equals(s.surface)));
          expect(s.tertiaryContainer, isNot(equals(s.surfaceContainer)));
          expect(_contrastRatio(s.tertiaryContainer, s.onTertiaryContainer), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label tertiaryContainer vs onTertiaryContainer');
          expect(_contrastRatio(s.tertiaryContainer, s.onSurface), greaterThanOrEqualTo(4.5), reason: '${palette.name}/$label tertiaryContainer vs onSurface');

          // 分段容器 / 预览框底色 surfaceContainerHighest：不能融化在页面或卡片底色里
          expect(s.surfaceContainerHighest, isNot(equals(s.surface)));
          expect(s.surfaceContainerHighest, isNot(equals(s.surfaceContainer)));
          expect(_contrastRatio(s.surfaceContainerHighest, s.onSurface), greaterThanOrEqualTo(4.5));
          expect(_contrastRatio(s.surfaceContainerHighest, s.onSurfaceVariant), greaterThanOrEqualTo(4.5));

          // 基础正文与次要文字
          expect(_contrastRatio(s.surface, s.onSurface), greaterThanOrEqualTo(7.0));
          expect(_contrastRatio(s.surfaceContainer, s.onSurface), greaterThanOrEqualTo(7.0));
          expect(_contrastRatio(s.surface, s.onSurfaceVariant), greaterThanOrEqualTo(4.5));
          expect(_contrastRatio(s.surfaceContainer, s.onSurfaceVariant), greaterThanOrEqualTo(4.5));

          // 全局按钮最小尺寸不再为无限宽
          final filledMin = theme.filledButtonTheme.style?.minimumSize?.resolve({});
          final outlinedMin = theme.outlinedButtonTheme.style?.minimumSize?.resolve({});
          expect(filledMin, const Size(64, 48));
          expect(outlinedMin, const Size(64, 48));
        });
      }
    }
  });

  testWidgets('RuinsNavIcon.shouldRepaint 在 gold 或 bg 变化时返回 true', (tester) async {
    CustomPainter painterOf(WidgetTester t) => t.widget<CustomPaint>(find.descendant(of: find.byType(RuinsNavIcon), matching: find.byType(CustomPaint))).painter!;

    final base = buildAppTheme(Brightness.light, appPalettes.last);
    await tester.pumpWidget(Theme(data: base, child: const Center(child: RuinsNavIcon(0, selected: true))));
    final p0 = painterOf(tester);

    // 仅改变 secondary（gold）
    final diffGold = base.copyWith(colorScheme: base.colorScheme.copyWith(secondary: Colors.teal));
    await tester.pumpWidget(Theme(data: diffGold, child: const Center(child: RuinsNavIcon(0, selected: true))));
    final pGold = painterOf(tester);
    expect(pGold.shouldRepaint(p0), isTrue);

    // 仅改变 surface（bg）
    final diffBg = base.copyWith(colorScheme: base.colorScheme.copyWith(surface: Colors.grey));
    await tester.pumpWidget(Theme(data: diffBg, child: const Center(child: RuinsNavIcon(0, selected: true))));
    final pBg = painterOf(tester);
    expect(pBg.shouldRepaint(p0), isTrue);

    // 完全一致时不重绘
    expect(p0.shouldRepaint(p0), isFalse);
  });

  testWidgets('ColorPickerField：未选色块无细边、外部改色同步输入框、含无障碍语义', (tester) async {
    final c1 = ruleColors[0];
    final c2 = ruleColors[5];

    Widget buildPicker(int color) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: ColorPickerField(color: color, onChanged: (_) {})),
    );

    await tester.pumpWidget(buildPicker(c1));

    // 校验选中色块有 3px 边框，未选色块无边框（border == null，不再画 1px 细边）
    final swatchContainers = tester.widgetList<Container>(find.descendant(of: find.byType(ColorPickerField), matching: find.byType(Container))).where((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.shape == BoxShape.circle;
    }).toList();
    expect(swatchContainers.length, ruleColors.length);
    for (final c in swatchContainers) {
      final d = c.decoration! as BoxDecoration;
      if (d.color == Color(c1)) {
        expect(d.border, isNotNull);
      } else {
        expect(d.border, isNull);
      }
    }

    // 校验 Semantics(label, selected, button)
    final semantics = tester.widgetList<Semantics>(find.descendant(of: find.byType(ColorPickerField), matching: find.byType(Semantics))).where((s) => s.properties.label?.startsWith('颜色 #') ?? false).toList();
    expect(semantics.length, ruleColors.length);
    expect(semantics.where((s) => s.properties.selected == true).length, 1);
    expect(semantics.every((s) => s.properties.button == true), isTrue);

    // 展开调色盘后，外部更新 color，didUpdateWidget 应同步色值输入框
    await tester.tap(find.text('调色盘'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, (c1 & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase());

    await tester.pumpWidget(buildPicker(c2));
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, (c2 & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase());
  });

  test('Routes 常量与拼装方法可独立使用', () {
    expect(Routes.bookshelf, '/bookshelf');
    expect(Routes.novel('123'), '/novel/123');
    expect(Routes.reader('1', '2'), '/reader/1/2');
    expect(Routes.reader('1', '2', offset: 42), '/reader/1/2?offset=42');
    expect(Routes.report('7', vol: 3), '/report/7?v=3');
    expect(Routes.settingsSection('appearance', highlight: '深色'), '/settings/appearance?q=%E6%B7%B1%E8%89%B2');
  });

  testWidgets('RuinsScene 拆分静动态 RepaintBoundary，PennantBadge/PennantRule/DoodleRule 均带 RepaintBoundary', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, appPalettes.last),
        home: const Scaffold(
          body: Column(
            children: [
              SizedBox(width: 300, height: 140, child: RuinsScene(animate: true, ceiling: 0)),
              SizedBox(width: 300, height: 100, child: RuinsScene(animate: false, ceiling: 0.5)),
              PennantBadge('3', color: Colors.amber, textColor: Colors.black),
              PennantRule(line: Colors.brown, flag: Colors.amber),
              DoodleRule(motif: Motif.bubbles, line: Colors.blue, accent: Colors.orange),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    final scenes = find.byType(RuinsScene);
    // ceiling == 0 含静态天空、动态云、静态遗迹、动态旗 4 个独立 RepaintBoundary
    expect(find.descendant(of: scenes.at(0), matching: find.byType(RepaintBoundary)), findsNWidgets(4));
    // ceiling > 0 无旗帜层，3 个独立 RepaintBoundary
    expect(find.descendant(of: scenes.at(1), matching: find.byType(RepaintBoundary)), findsNWidgets(3));

    expect(find.descendant(of: find.byType(PennantBadge), matching: find.byType(RepaintBoundary)), findsOneWidget);
    expect(find.descendant(of: find.byType(PennantRule), matching: find.byType(RepaintBoundary)), findsOneWidget);
    expect(find.descendant(of: find.byType(DoodleRule), matching: find.byType(RepaintBoundary)), findsOneWidget);
  });

  testWidgets('SplashPage 与主题插画 Image.asset 均传入 ResizeImage cacheWidth/cacheHeight', (tester) async {
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final annaPalette = appPalettes.firstWhere((p) => p.art == 'anna');
    final art = characterArtOf(annaPalette)!;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light, annaPalette),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SplashPage()),
              DoodleBanner(art: art, height: 120),
              ThemeArt.navIcon(annaPalette, 0, selected: true)!,
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, greaterThanOrEqualTo(3));
    for (final img in images) {
      expect(img.image, isA<ResizeImage>(), reason: 'Image.asset 应设置 cacheWidth/cacheHeight 限制纹理尺寸');
    }
  });
}
