import 'package:ark_novel/next/diag_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(DiagLog.clear);

  test('sanitizeDiagnosticText redacts credentials, cookies, tokens, and home paths', () {
    const raw =
        'GET https://alice:s3cr3t@dav.example.com/dav/ Authorization: Basic YWxpY2U6c2VjcmV0 '
        'jieqiUserInfo=abc123; cf_clearance=xyz987 savedPass=myPass123 '
        'path=/Users/alice/Documents/app.db win=C:\\Users\\bob\\AppData\\Local\\hive';
    final clean = sanitizeDiagnosticText(raw);
    expect(clean, isNot(contains('alice')));
    expect(clean, isNot(contains('s3cr3t')));
    expect(clean, isNot(contains('YWxpY2U6c2VjcmV0')));
    expect(clean, isNot(contains('abc123')));
    expect(clean, isNot(contains('xyz987')));
    expect(clean, isNot(contains('myPass123')));
    expect(clean, isNot(contains('bob')));
    expect(clean, contains('https://***:***@dav.example.com/dav/'));
    expect(clean, contains('/Users/<redacted>/Documents/app.db'));
    expect(clean, contains(r'<drive>:\Users\<redacted>\AppData\Local\hive'));
  });

  test('DiagLog keeps bounded ring buffer and dumps sanitized report', () {
    for (var i = 0; i < DiagLog.maxEntries + 25; i++) {
      DiagLog.info('test', 'entry-$i');
    }
    expect(DiagLog.entries.length, DiagLog.maxEntries);
    expect(DiagLog.entries.first, contains('entry-25'));
    expect(DiagLog.entries.last, contains('entry-${DiagLog.maxEntries + 24}'));

    final dump = DiagLog.dump(
      extraError: StateError('failed at /Users/secretuser/box.hive'),
      meta: {'Device': 'd123', 'Url': 'https://u:p@dav.test/'},
    );
    expect(dump, contains('Ark Novel Diagnostic Report'));
    expect(dump, isNot(contains('secretuser')));
    expect(dump, isNot(contains('u:p@')));
  });
}
