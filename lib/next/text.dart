import 'dart:ui' as ui show TextHeightBehavior;

import 'package:flutter/widgets.dart' as w;
import 'package:flutter/widgets.dart' hide Text;

import 'hant.dart';

/// 界面繁体的开关：放在应用根上，[hant] 不为 null 时下面所有的 [Text] 都转成繁体（台湾写法）。
class UiHant extends InheritedWidget {
  const UiHant({super.key, required this.hant, required super.child});

  final Hant? hant;

  static Hant? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UiHant>()?.hant;

  @override
  bool updateShouldNotify(UiHant old) => old.hant != hant;
}

/// 代替 Flutter 的 Text，用法完全一样：界面繁体打开时显示前转成繁体。
/// 用的文件写 `import 'package:flutter/material.dart' hide Text;` 再 import 这个文件。
/// 阅读器正文不走这里（用的是 TextSpan），只受阅读设置里的「繁体」控制。
class Text extends StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final ui.TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    final h = UiHant.of(context);
    final label = semanticsLabel == null ? null : h?.convert(semanticsLabel!) ?? semanticsLabel;
    if (textSpan != null) {
      return w.Text.rich(h == null ? textSpan! : hantSpan(textSpan!, h), style: style, strutStyle: strutStyle, textAlign: textAlign, textDirection: textDirection, locale: locale, softWrap: softWrap, overflow: overflow, textScaler: textScaler, maxLines: maxLines, semanticsLabel: label, semanticsIdentifier: semanticsIdentifier, textWidthBasis: textWidthBasis, textHeightBehavior: textHeightBehavior, selectionColor: selectionColor);
    }
    return w.Text(h?.convert(data!) ?? data!, style: style, strutStyle: strutStyle, textAlign: textAlign, textDirection: textDirection, locale: locale, softWrap: softWrap, overflow: overflow, textScaler: textScaler, maxLines: maxLines, semanticsLabel: label, semanticsIdentifier: semanticsIdentifier, textWidthBasis: textWidthBasis, textHeightBehavior: textHeightBehavior, selectionColor: selectionColor);
  }
}

/// 把一段 TextSpan 里的文字都转成繁体；WidgetSpan 原样保留（里面的 Text 自己会转）。
InlineSpan hantSpan(InlineSpan span, Hant h) {
  if (span is! TextSpan) return span;
  return TextSpan(
    text: span.text == null ? null : h.convert(span.text!),
    children: span.children?.map((c) => hantSpan(c, h)).toList(),
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel == null ? null : h.convert(span.semanticsLabel!),
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

/// 只收字符串的地方（底栏标签、tooltip、选中文字菜单）用这个转。
String hz(BuildContext context, String s) => UiHant.of(context)?.convert(s) ?? s;
