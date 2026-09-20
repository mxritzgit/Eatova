import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_cache.dart';

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

  test('Streak-Tag stammt auch ueber Mitternacht von der Mahlzeit', () async {
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
  });

  test('Mitternacht hinterlaesst keine unzustellbare Tages-Op', () async {
    final s = await _logAcrossMidnight();
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
}
