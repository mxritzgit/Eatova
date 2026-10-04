import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';

import '../support/atomic_store_faults.dart';

void main() {
  test('zwei Engines koennen nur einen gemeinsamen Claim erhalten', () async {
    final db = InMemoryKeyValueStore();
    final first = SyncExecutionGuard(db);
    final second = SyncExecutionGuard(db);
    await first.activate('A', 'session-A');
    final claims = await Future.wait([
      first.tryClaim('A'),
      second.tryClaim('A'),
    ]);
    expect(claims.whereType<SyncExecutionClaim>(), hasLength(1));
    final winner = claims.whereType<SyncExecutionClaim>().single;
    expect(await winner.isCurrent(), isTrue);
    await winner.release();
    expect(await second.tryClaim('A'), isNotNull);
  });

  test(
    'Logout sperrt HTTP und CAS-Ack, auch nach Login desselben Nutzers',
    () async {
      final db = InMemoryKeyValueStore();
      final guard = SyncExecutionGuard(db);
      await guard.activate('A', 'old-session');
      final claim = (await guard.tryClaim('A'))!;
      await guard.invalidate('A', expectedSessionId: 'old-session');
      expect(await claim.isCurrent(), isFalse);
      await expectLater(
        db.writeBatch({'ack': 'deleted'}, expectedVersions: claim.guards),
        throwsA(isA<KeyValueConflict>()),
      );
      await guard.activate('A', 'new-session');
      expect(await claim.renew(), isFalse);
      expect(
        await guard.tryClaim('A', expectedSessionId: 'old-session'),
        isNull,
      );
      expect(
        await guard.tryClaim('A', expectedSessionId: 'new-session'),
        isNotNull,
      );
      expect(await db.getString('ack'), isNull);
    },
  );

  test(
    'abgelaufener Worker kann Claim des Nachfolgers weder loeschen noch ackn',
    () async {
      var now = DateTime.utc(2026, 9, 20, 12);
      await withClock(Clock(() => now), () async {
        final db = InMemoryKeyValueStore();
        final guard = SyncExecutionGuard(db);
        await guard.activate('A', 'session');
        final old = (await guard.tryClaim('A'))!;
        now = now.add(SyncExecutionGuard.leaseDuration);
        expect(await old.isCurrent(), isFalse);
        expect(await old.renew(), isFalse);
        final next = (await guard.tryClaim('A'))!;
        await old.release();
        expect(await next.isCurrent(), isTrue);
        await expectLater(
          db.writeBatch({'ack': 'bad'}, expectedVersions: old.guards),
          throwsA(isA<KeyValueConflict>()),
        );
      });
    },
  );

  test(
    'Lease eines gekillten Workers unter vorgestellter Uhr sperrt nach dem '
    'Zurueckstellen nicht laenger als eine Lease-Dauer',
    () async {
      // The device clock ran a day ahead, then NTP corrected it.
      var now = DateTime.utc(2026, 9, 21, 12);
      await withClock(Clock(() => now), () async {
        final db = InMemoryKeyValueStore();
        final guard = SyncExecutionGuard(db);
        await guard.activate('A', 'session');
        final dead = (await guard.tryClaim('A'))!;
        // The process holding it is killed: no release.
        now = DateTime.utc(2026, 9, 20, 12);
        final next = await SyncExecutionGuard(db).tryClaim('A');
        expect(
          next,
          isNotNull,
          reason:
              'ein Lease reicht nie weiter als eine Lease-Dauer ueber die '
              'Uhr hinaus, die ihn schrieb; sonst stuende die Zustellung '
              'einen Tag lang',
        );
        expect(await dead.isCurrent(), isFalse);
        expect(await next!.isCurrent(), isTrue);
        expect(
          await SyncExecutionGuard(db).tryClaim('A'),
          isNull,
          reason: 'ein frischer Lease sperrt weiterhin',
        );
      });
    },
  );

  test(
    'eine kleine Uhrkorrektur waehrend eines lebenden Leases gibt ihn nicht '
    'frei',
    () async {
      // NTP sets the clock back a second right after a worker claimed.
      var now = DateTime.utc(2026, 9, 20, 12);
      await withClock(Clock(() => now), () async {
        final db = InMemoryKeyValueStore();
        final guard = SyncExecutionGuard(db);
        await guard.activate('A', 'session');
        final live = (await guard.tryClaim('A'))!;
        now = now.subtract(const Duration(seconds: 1));
        expect(
          await SyncExecutionGuard(db).tryClaim('A'),
          isNull,
          reason: 'ein lebender Lease bleibt exklusiv',
        );
        expect(await live.isCurrent(), isTrue);
      });
    },
  );

  test(
    'Claimrenew fence aendert sich atomar und braucht dieselbe Session',
    () async {
      var now = DateTime.utc(2026, 9, 20);
      await withClock(Clock(() => now), () async {
        final db = InMemoryKeyValueStore();
        final guard = SyncExecutionGuard(db);
        await guard.activate('A', 'session');
        final claim = (await guard.tryClaim('A'))!;
        final before = claim.guards;
        now = now.add(const Duration(seconds: 50));
        expect(await claim.renew(), isTrue);
        now = now.add(const Duration(seconds: 20));
        expect(await claim.isCurrent(), isTrue);
        await expectLater(
          db.writeBatch({'ack': 'old'}, expectedVersions: before),
          throwsA(isA<KeyValueConflict>()),
        );
        await db.writeBatch({'ack': 'new'}, expectedVersions: claim.guards);
        await guard.activate('B', 'session-B');
        expect(await claim.renew(), isFalse);
      });
    },
  );

  test('alter Logout betrifft weder B noch neue Session von A', () async {
    final db = InMemoryKeyValueStore();
    final guard = SyncExecutionGuard(db);
    await guard.activate('B', 'session-B');
    await guard.invalidate('A', expectedSessionId: 'old-A');
    expect(await guard.tryClaim('B'), isNotNull);
    await guard.activate('A', 'new-A');
    await guard.invalidate('A', expectedSessionId: 'old-A');
    expect(await guard.tryClaim('A', expectedSessionId: 'new-A'), isNotNull);
  });

  test(
    'verspaeteter Authaufbau darf alten Nutzer nicht reaktivieren',
    () async {
      final db = InMemoryKeyValueStore();
      final guard = SyncExecutionGuard(db);
      await guard.activate('B', 'session-B');
      await guard.activate('A', 'old-A', isCurrentSession: () => false);
      expect(await guard.tryClaim('A'), isNull);
      expect(await guard.tryClaim('B'), isNotNull);
    },
  );

  test('AuthGate-Purge entzieht Session und schuetzt neue Anmeldung', () async {
    final db = InMemoryKeyValueStore();
    final guard = SyncExecutionGuard(db);
    await guard.activate('A', 'old');
    final claim = (await guard.tryClaim('A'))!;
    final fence = await guard.invalidateForPurge('A', expectedSessionId: 'old');
    expect(fence, isNotNull);
    expect(await claim.isCurrent(), isFalse);
    expect(await guard.tryClaim('A'), isNull);
    await guard.activate('A', 'new');
    await expectLater(
      db.writeBatch({'profile': null}, expectedVersions: fence!),
      throwsA(isA<KeyValueConflict>()),
    );
    expect(
      await guard.invalidateForPurge('A', expectedSessionId: 'old'),
      isNull,
    );
    expect(await guard.tryClaim('A', expectedSessionId: 'new'), isNotNull);
  });

  test('fehlende oder korrupte Metadaten erzeugen keinen Claim', () async {
    final db = InMemoryKeyValueStore();
    final guard = SyncExecutionGuard(db);
    expect(await guard.tryClaim('A'), isNull);
    await db.setString(syncSessionKey, 'invalid');
    await expectLater(guard.tryClaim('A'), throwsFormatException);
    expect(await db.getString(syncClaimKey('A')), isNull);
  });

  // The CAS retries below run between a guard's read and its write: another
  // engine commits through the raw store while the hook holds the write.
  group('Konflikt zwischen Lesen und CAS-Write', () {
    test('Logout, der mit einer Anmeldung von B kollidiert, laesst B aktiv',
        () async {
      final db = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(db);
      final stale = SyncExecutionGuard(faults);
      await stale.activate('A', 'session-A');
      var writes = 0;
      faults.beforeWrite = (_) async {
        if (writes++ == 0) {
          await SyncExecutionGuard(db).activate('B', 'session-B');
        }
      };

      await stale.invalidate('A', expectedSessionId: 'session-A');

      expect(writes, 1, reason: 'the retry re-reads B and must not write');
      final other = SyncExecutionGuard(db);
      expect(await other.hasActiveSession('B', 'session-B'), isTrue);
      expect(await other.tryClaim('B'), isNotNull);
    });

    test('Purge-Fence gegen neue Anmeldung desselben Kontos liefert keinen '
        'Fence und behaelt die neue Session', () async {
      final db = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(db);
      final stale = SyncExecutionGuard(faults);
      await stale.activate('A', 'old');
      var writes = 0;
      faults.beforeWrite = (_) async {
        if (writes++ == 0) await SyncExecutionGuard(db).activate('A', 'new');
      };

      final fence = await stale.invalidateForPurge(
        'A',
        expectedSessionId: 'old',
      );

      expect(fence, isNull);
      expect(writes, 1);
      expect(await SyncExecutionGuard(db).hasActiveSession('A', 'new'), isTrue);
    });

    test('verspaetete Anmeldung ueberschreibt nach dem Konflikt keine neuere '
        'Identitaet', () async {
      final db = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(db);
      var current = true;
      faults.beforeWrite = (_) async {
        // B signs in and A's login attempt stops being the current one.
        current = false;
        await SyncExecutionGuard(db).activate('B', 'session-B');
      };

      await SyncExecutionGuard(faults).activate(
        'A',
        'session-A',
        isCurrentSession: () => current,
      );

      final other = SyncExecutionGuard(db);
      expect(await other.hasActiveSession('B', 'session-B'), isTrue);
      expect(await other.hasActiveSession('A', 'session-A'), isFalse);
    });

    test('dauerhafte Konkurrenz endet nach vier Versuchen mit '
        'KeyValueConflict', () async {
      final db = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(db);
      var attempts = 0;
      faults.beforeWrite = (_) async {
        attempts++;
        await SyncExecutionGuard(db).activate('X', 'session-X-$attempts');
      };

      await expectLater(
        SyncExecutionGuard(faults).activate('A', 'session-A'),
        throwsA(isA<KeyValueConflict>()),
      );

      expect(attempts, 4, reason: 'bounded retry, no livelock');
      expect(
        await SyncExecutionGuard(db).hasActiveSession('A', 'session-A'),
        isFalse,
      );
    });

    test('renew verliert gegen einen parallelen Claimwechsel', () async {
      final db = InMemoryKeyValueStore();
      final faults = AtomicStoreFaults(db);
      final guard = SyncExecutionGuard(faults);
      await guard.activate('A', 'session-A');
      final claim = (await guard.tryClaim('A'))!;
      const takeover = '{"generation":"other","token":"t","expires_at":"x"}';
      faults.beforeWrite = (_) async {
        await db.writeBatch({syncClaimKey('A'): takeover});
      };

      expect(await claim.renew(), isFalse);

      faults.beforeWrite = null;
      expect(await claim.isCurrent(), isFalse);
      expect(await db.getString(syncClaimKey('A')), takeover);
    });
  });

  test('activate verlangt Nutzer und Session', () async {
    final guard = SyncExecutionGuard(InMemoryKeyValueStore());
    await expectLater(guard.activate('', 'session'), throwsArgumentError);
    await expectLater(guard.activate('A', ''), throwsArgumentError);
    expect(await guard.tryClaim(''), isNull);
  });

  group('syncSessionIdFromAccessToken', () {
    String token(Object? claims, {String? payload}) {
      final body = payload ??
          base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
      return 'header.$body.sig';
    }

    test('liest die session_id aus dem Payload', () {
      expect(syncSessionIdFromAccessToken(token({'session_id': 's-1'})), 's-1');
      final longest = 'x' * 256;
      expect(
        syncSessionIdFromAccessToken(token({'session_id': longest})),
        longest,
      );
    });

    test('kaputte oder fremde Tokens ergeben null statt einer Exception', () {
      expect(syncSessionIdFromAccessToken(''), isNull);
      expect(syncSessionIdFromAccessToken('a.b'), isNull);
      expect(syncSessionIdFromAccessToken('a.b.c.d'), isNull);
      expect(syncSessionIdFromAccessToken(token(null, payload: '@@@')), isNull);
      expect(
        syncSessionIdFromAccessToken(token(null, payload: 'bm90LWpzb24')),
        isNull,
        reason: 'valid base64 of "not-json"',
      );
      expect(syncSessionIdFromAccessToken(token(['session_id'])), isNull);
      expect(syncSessionIdFromAccessToken(token({'sub': 'A'})), isNull);
      expect(syncSessionIdFromAccessToken(token({'session_id': ''})), isNull);
      expect(syncSessionIdFromAccessToken(token({'session_id': 7})), isNull);
      expect(
        syncSessionIdFromAccessToken(token({'session_id': 'x' * 257})),
        isNull,
      );
    });
  });
}
