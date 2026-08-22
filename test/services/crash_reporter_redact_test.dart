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
  group('redactUserSegment · echte UUID wird redigiert', () {
    test('ersetzt das User-Segment durch <uid> und behaelt den Slot', () {
      expect(
        redactUserSegment('eatova.v1.logged_meals.$_uuid'),
        'eatova.v1.logged_meals.<uid>',
      );
    });

    test('kein einziger echter Cache-Key traegt danach noch die UUID', () {
      // The promise: WHICH slot broke stays visible, WHO the user is does not.
      for (final slot in _slots) {
        final redigiert = redactUserSegment('eatova.v1.$slot.$_uuid');

        expect(redigiert, isNot(contains(_uuid)),
            reason: 'Slot "$slot" leakt die volle UUID');
        expect(redigiert, isNot(contains('3f2504e0')),
            reason: 'Slot "$slot" leakt den UUID-Praefix — auch ein Teil '
                'davon ist ueber Reports hinweg eine stabile Kennung');
        expect(redigiert, contains(slot),
            reason: 'Der Slot-Name ist die einzige Information, die der '
                'Report noch traegt — er muss bleiben');
        expect(redigiert, endsWith('.<uid>'));
      }
    });

    test('ist idempotent — ein bereits redigierter Key bleibt stabil', () {
      const einmal = 'eatova.v1.outbox.<uid>';

      expect(redactUserSegment(einmal), einmal);
    });

    test('funktioniert auch fuer UUIDs ohne Bindestriche (32 Hex-Zeichen)',
        () {
      const kompakt = '3f2504e04f8911d39a0c0305e82c3301';

      expect(redactUserSegment('eatova.v1.stats.$kompakt'),
          'eatova.v1.stats.<uid>');
    });
  });

  group('redactUserSegment · Keys ohne User-Segment bleiben unveraendert', () {
    test('genau drei Abschnitte bleiben stehen', () {
      expect(redactUserSegment('eatova.v1.dek'), 'eatova.v1.dek');
    });

    test('zwei Abschnitte bleiben stehen', () {
      expect(redactUserSegment('eatova.v1'), 'eatova.v1');
    });

    test('ein Abschnitt ohne Punkt bleibt stehen', () {
      expect(redactUserSegment('flutter_secure_storage'),
          'flutter_secure_storage');
    });

    test('leerer Key bleibt leer und wirft nicht', () {
      expect(redactUserSegment(''), '');
    });
  });

  group('redactUserSegment · Rand- und Mehrfachfaelle', () {
    test('bei mehr als vier Abschnitten faellt NUR der letzte weg', () {
      // A future slot name containing a dot must not lose its prefix.
      expect(
        redactUserSegment('eatova.v2.sync.logged_meals.$_uuid'),
        'eatova.v2.sync.logged_meals.<uid>',
      );
    });

    test('leeres letztes Segment (Key endet auf Punkt) wird zu <uid>', () {
      expect(redactUserSegment('eatova.v1.stats.'), 'eatova.v1.stats.<uid>');
    });

    test('ein Key aus lauter Punkten wirft nicht', () {
      expect(redactUserSegment('....'), '....<uid>');
    });

    test('die Redigierung haengt an der Abschnittszahl, nicht an UUID-Form',
        () {
      // Pinned deliberately: the function does NOT check whether the last
      // segment looks like a UUID — four segments suffice. Over-redacting is
      // the safe direction, but it is a choice, not a side effect.
      expect(redactUserSegment('eatova.v1.profile.v2'),
          'eatova.v1.profile.<uid>');
    });

    test('vier Abschnitte sind die Untergrenze, drei nicht', () {
      expect(redactUserSegment('a.b.c.d'), 'a.b.c.<uid>');
      expect(redactUserSegment('a.b.c'), 'a.b.c');
    });
  });
}
