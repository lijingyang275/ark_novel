import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/meta_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Backup local key guard protects credentials and device-only keys', () {
    const mustBeLocal = [
      'cookie',
      'ua',
      'savedUser',
      'savedPass',
      'savedPassMoved',
      'userHtml',
      'proxy',
      'nativeNet',
      'sync:url',
      'sync:user',
      'sync:pass',
      'sync:folder',
      'sync:device',
      'sync:last',
      'lib:ops',
      'cf:www.wenku8.cc',
      'cf:ts:www.wenku8.cc',
      'unlock:txt:123',
    ];
    for (final k in mustBeLocal) {
      expect(Backup.isLocalKey(k), isTrue, reason: '$k must stay local and never enter backup');
    }
  });

  test('Backup cache key guard matches MetaCache.isCacheKey and keeps user data backed up', () {
    const mustBeCache = ['ccolor', 'bgm:100', 'bgm_info:100', 'bgm_chars:100'];
    for (final k in mustBeCache) {
      expect(Backup.isCacheKey(k), isTrue, reason: '$k should be treated as regenerable cache');
      expect(MetaCache.isCacheKey(k), isTrue);
    }

    const mustBeBackedUp = [
      'lib:books',
      'lib:cats',
      'bookmarks',
      'highlights',
      'rules',
      'history2',
      'progress:100',
      'read:100',
      'vcover2:100',
      'r.fontSize',
      'r.letterSpacing',
      'r.paragraphSpacing',
      'chars:100',
      'notes:100',
    ];
    for (final k in mustBeBackedUp) {
      expect(Backup.isLocalKey(k), isFalse, reason: '$k should be included in full backup');
      expect(Backup.isCacheKey(k), isFalse, reason: '$k should not be excluded as cache');
    }
  });
}
