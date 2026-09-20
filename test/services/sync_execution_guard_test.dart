import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';

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
}
