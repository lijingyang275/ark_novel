import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/reading_widget.dart';
import 'package:ark_novel/next/routes.dart';

void main() {
  test('点桌面小组件打开的链接对应到 App 里的页面', () {
    expect(ReadingWidget.route(Uri.parse('ark://reader/123/456')), Routes.reader('123', '456'));
    expect(ReadingWidget.route(Uri.parse('ark://updates')), Routes.updates);
    expect(ReadingWidget.route(Uri.parse('ark://shelf')), Routes.bookshelf);
    expect(ReadingWidget.route(Uri.parse('ark://reader/123')), isNull);
    expect(ReadingWidget.route(null), isNull);
  });
}
