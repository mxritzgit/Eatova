import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';

import 'outbox/outbox_test_helpers.dart';

// Crossing midnight during a network round trip must not change the source
// day. The transaction books meal and streak from the persisted meal row.
Future<
  ({HomeStore store, FakeServer server, LocalCache cache, SnackCapture snacks})
>
_logAcrossMidnight() {
  var now = DateTime(2026, 8, 14, 23, 59, 58);
  return withClock(Clock(() => now), () async {
    final server = FakeServer()..enforceTrackingDaySourceProof = true;
    final s = setup(geteilterServer: server);
    await boot(s.store);
    server.holdMealWrites();
    final saved = s.store.addResultToDailyTotal(mealResult('Spaet-Bowl'));
    await pumpUntil(() => server.operations('mealInsert').isNotEmpty);
    expect(
      server.operations('mealInsert'),
      hasLength(1),
      reason: 'Vorbedingung: die Antwort wartet noch vor Mitternacht',
    );
    expect(server.mealRows, isEmpty);
    now = DateTime(2026, 8, 15, 0, 0, 3);
    server.releaseMealWrites();
    await saved;
    await s.store.syncPendingWrites();
    return s;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Streak-Tag stammt auch ueber Mitternacht von der Mahlzeit, ohne '
      'unzustellbare Tages-Op', () async {
    final s = await _logAcrossMidnight();
    final payload =
        (jsonDecode(s.server.operations('mealInsert').single.body)
                as Map)['p_payload']
            as Map;
    expect((payload['row'] as Map)['local_day'], '2026-08-14');
    expect(payload['track_day'], isTrue);
    expect(s.server.mealRows.values.single['local_day'], '2026-08-14');
    expect(s.server.trackedDay, '2026-08-14');
    expect(s.store.lifetimeStats.lastTrackedDate, DateTime(2026, 8, 14));
    expect(s.server.mealsCounted, 1);
    // Midnight leaves no undeliverable day operation behind.
    expect(s.server.trackingDayRejections, isEmpty);
    expect(s.server.operations('trackingDay'), isEmpty);
    expect(s.store.pendingOutbox, isEmpty);
    expect(await s.cache.readOutbox(), isEmpty);
  });

  test(
    'Nachtrag laesst Streak unangetastet und bewahrt den Quelltag',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 8, 14, 12)), () async {
        final s = setup();
        await boot(s.store);
        await s.store.addResultToDailyTotal(
          mealResult('Nachtrag'),
          foodDate: DateTime(2026, 8, 13),
        );
        final payload =
            (jsonDecode(s.server.operations('mealInsert').single.body)
                    as Map)['p_payload']
                as Map;
        expect((payload['row'] as Map)['local_day'], '2026-08-13');
        expect(payload['track_day'], isFalse);
        expect(s.server.operations('trackingDay'), isEmpty);
        expect(s.server.trackedDay, isNull);
        expect(s.server.mealsCounted, 1);
        expect(s.store.pendingOutbox, isEmpty);
      });
    },
  );

  // R2-02: a sheet started on today and confirmed after midnight books onto
  // its day, and that day still counts as tracked (at most one day late).
  group('Sheet ueber Mitternacht (startedToday)', () {
    Future<Map<dynamic, dynamic>> logLate({
      required DateTime opened,
      required DateTime confirmed,
      required DateTime foodDate,
      required String lastTracked,
      required FakeServer server,
    }) {
      var now = opened;
      return withClock(Clock(() => now), () async {
        server
          ..enforceTrackingDaySourceProof = true
          ..trackedDay = lastTracked;
        final s = setup(geteilterServer: server);
        await boot(s.store);
        now = confirmed;
        await s.store.addResultToDailyTotal(
          mealResult('Spaet-Bowl'),
          foodDate: foodDate,
          startedToday: true,
        );
        await s.store.syncPendingWrites();
        expect(s.store.pendingOutbox, isEmpty);
        return (jsonDecode(server.operations('mealInsert').single.body)
                as Map)['p_payload']
            as Map;
      });
    }

    for (final (label, day) in [
      ('11./12.10.', DateTime(2026, 10, 11)),
      // The 25-hour day: Europe/Berlin falls back at 03:00.
      ('25./26.10. (Zeitumstellung)', DateTime(2026, 10, 25)),
    ]) {
      test('$label: der begonnene Tag zaehlt noch als getrackt', () async {
        final server = FakeServer();
        final payload = await logLate(
          opened: DateTime(day.year, day.month, day.day, 23, 59, 50),
          confirmed: DateTime(day.year, day.month, day.day + 1, 0, 0, 5),
          foodDate: day,
          lastTracked: localDayKey(DateTime(day.year, day.month, day.day - 1)),
          server: server,
        );
        expect((payload['row'] as Map)['local_day'], localDayKey(day));
        expect(payload['track_day'], isTrue);
        expect(server.trackedDay, localDayKey(day));
        expect(server.trackingDayRejections, isEmpty);
      });
    }

    test('zwei Tage spaeter zaehlt der Tag nicht mehr', () async {
      final server = FakeServer();
      final payload = await logLate(
        opened: DateTime(2026, 10, 10, 23, 59, 50),
        confirmed: DateTime(2026, 10, 12, 0, 0, 5),
        foodDate: DateTime(2026, 10, 10),
        lastTracked: '2026-10-09',
        server: server,
      );
      expect((payload['row'] as Map)['local_day'], '2026-10-10');
      expect(payload['track_day'], isFalse);
      expect(server.trackedDay, '2026-10-09');
    });
  });
}
