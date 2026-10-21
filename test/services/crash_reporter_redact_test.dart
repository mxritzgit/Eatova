// G3: `redactUserSegment` keeps user UUIDs out of Sentry and had no tests, so
// a revert to `storageKey: key` would have shipped stable user ids while every
// test stayed green. It lives in secure_cache_store.dart, but its only caller
// is the crash-report path — hence the test file here.
//
// Contract: the LAST dot segment of a key with MORE than three segments
// becomes `<uid>`; keys with at most three segments stay unchanged. The
// decision hangs on the segment count, NOT on the UUID shape.

import 'package:eatova/src/services/secure_cache_store.dart'
    show redactUserSegment;
import 'package:flutter_test/flutter_test.dart';

/// A real Supabase user UUID (v4, hyphenated, no dots).
const String _uuid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';

/// The nine slot names from local_cache.dart:131-149.
const List<String> _slots = <String>[
  'profile',
  'daily',
  'stats',
  'notifications_enabled',
  'logged_meals',
  'favorites',
  'weight_log',
  'outbox',
  'pending_stats',
];

void main() {
  test('every real cache key keeps its slot and loses the user id', () {
    // The promise: WHICH slot broke stays visible, WHO the user is does not.
    for (final slot in _slots) {
      final redigiert = redactUserSegment('eatova.v1.$slot.$_uuid');
      expect(redigiert, 'eatova.v1.$slot.<uid>');
      expect(redigiert, isNot(contains('3f2504e0')),
          reason: 'even a UUID prefix is a stable id across reports');
    }
    expect(redactUserSegment('eatova.v1.stats.3f2504e04f8911d39a0c0305e82c3301'),
        'eatova.v1.stats.<uid>');
    // Idempotent, and a future slot name with a dot keeps its prefix.
    expect(redactUserSegment('eatova.v1.outbox.<uid>'), 'eatova.v1.outbox.<uid>');
    expect(redactUserSegment('eatova.v2.sync.logged_meals.$_uuid'),
        'eatova.v2.sync.logged_meals.<uid>');
  });

  test('keys with at most three segments stay unchanged', () {
    for (final key in <String>[
      'eatova.v1.dek',
      'eatova.v1',
      'flutter_secure_storage',
      '',
      'a.b.c',
    ]) {
      expect(redactUserSegment(key), key);
    }
  });

  test('redaction follows the segment count, not the UUID shape', () {
    // Over-redacting is the safe direction, but it is a choice, not a side
    // effect: four segments suffice, whatever the last one holds.
    expect(redactUserSegment('eatova.v1.profile.v2'), 'eatova.v1.profile.<uid>');
    expect(redactUserSegment('a.b.c.d'), 'a.b.c.<uid>');
    expect(redactUserSegment('eatova.v1.stats.'), 'eatova.v1.stats.<uid>');
    expect(redactUserSegment('....'), '....<uid>');
  });
}
