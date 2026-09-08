import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/trend_service.dart';

import 'fixlauf_a_helpers.dart' show StummerFotoStore;
import 'outbox/outbox_test_helpers.dart';

const _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  onboardingCompleted: true,
);
final _now = DateTime(2026, 9, 8, 12);

/// Holds only the first stats response; the shared server retains RPC dedup.
class _HeldStatsServer extends FakeServer {
  _HeldStatsServer({this.applyBeforeReply = false});

  final bool applyBeforeReply;
  final Completer<bool> reply = Completer<bool>();
  String? heldRequestId;

  @override
  http.Client client() {
    final delegate = super.client();
    return MockClient((request) async {
      Future<http.Response> forward() async {
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await delegate.send(copy));
      }

      if (request.url.path.endsWith('/rpc/increment_lifetime_stats') &&
          heldRequestId == null) {
        heldRequestId =
            (jsonDecode(request.body) as Map)['p_request_id'] as String;
        final landed = applyBeforeReply ? await forward() : null;
        if (!await reply.future) throw http.ClientException('connection lost');
        return landed ?? await forward();
      }
      return forward();
    });
  }
}

void _bootInFakeTime(HomeStore store, FakeAsync async) {
  store.start();
  async.flushMicrotasks();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
  expect(store.bootLoadInFlight, isFalse);
  expect(store.profile.onboardingCompleted, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => RecipeImageStore.instance = StummerFotoStore());
  tearDown(RecipeImageStore.resetInstance);
  tearDown(TrendTotalsCache.instance.invalidate);

  for (final alreadyLanded in [false, true]) {
    test('laufender Stats-Flush bleibt beim Logout bis zur Deadline erhalten '
        '(serverseitig gebucht: $alreadyLanded)', () {
      fakeAsync((async) {
        final server = _HeldStatsServer(applyBeforeReply: alreadyLanded)
          ..profileRow = serverProfileRow(_profile);
        final kv = InMemoryKeyValueStore();
        final first = setup(
          kv: kv,
          geteilterServer: server,
          disposeClient: false,
        );
        _bootInFakeTime(first.store, async);
        first.store.addResultToDailyTotal(mealResult('Bowl'));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 600));
        async.flushMicrotasks();
        expect(
          server.heldRequestId,
          isNotNull,
          reason: 'der Debounce hat den Flush VOR dem Logout gestartet',
        );
        expect(first.store.pendingOutbox, isEmpty);

        var signedOut = false;
        first.store.signOutCleanup().then((_) => signedOut = true);
        async.flushMicrotasks();
        async.elapse(kSignOutDeliveryBudget + const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(signedOut, isTrue, reason: 'Logout bleibt zeitlich begrenzt');

        ({int meals, int weightLogs, String? requestId})? pending;
        first.cache.readPendingStatsDeltas().then((value) => pending = value);
        async.flushMicrotasks();
        expect(pending?.meals, 1);
        expect(pending?.requestId, server.heldRequestId);
        expect(
          kv.snapshot.keys,
          isNot(contains('eatova.v1.profile.user-outbox')),
        );

        // A late failed response must not re-add the deadline's bundle.
        server.reply.complete(false);
        async.flushMicrotasks();
        first.cache.readPendingStatsDeltas().then((value) => pending = value);
        async.flushMicrotasks();
        expect(pending?.meals, 1);

        final second = setup(
          kv: kv,
          geteilterServer: server,
          disposeClient: false,
        );
        _bootInFakeTime(second.store, async);
        expect(
          server.mealsCounted,
          1,
          reason: 'Restart liefert genau einmal, auch bei verlorener Antwort',
        );
        expect(server.statsRequestIds.last, server.heldRequestId);
      }, initialTime: _now);
    });
  }

  test('laufender Stats-Flush wird vor Logout erfolgreich bestaetigt', () {
    fakeAsync((async) {
      final server = _HeldStatsServer()
        ..profileRow = serverProfileRow(_profile);
      final s = setup(geteilterServer: server, disposeClient: false);
      _bootInFakeTime(s.store, async);
      s.store.addResultToDailyTotal(mealResult('Bowl'));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 600));
      async.flushMicrotasks();
      expect(server.heldRequestId, isNotNull);

      var signedOut = false;
      s.store.signOutCleanup().then((_) => signedOut = true);
      async.flushMicrotasks();
      expect(signedOut, isFalse);
      server.reply.complete(true);
      async.flushMicrotasks();
      expect(signedOut, isTrue);
      expect(server.mealsCounted, 1);
      ({int meals, int weightLogs, String? requestId})? pending;
      s.cache.readPendingStatsDeltas().then((value) => pending = value);
      async.flushMicrotasks();
      expect(
        pending,
        isNull,
        reason: 'bestaetigte Deltas brauchen beim Logout keinen Sync-Slot',
      );
    }, initialTime: _now);
  });

  for (final deletion in [false, true]) {
    test('Trend-Cache aus laufendem Replay wird nach Zustellung verworfen '
        '(Delete: $deletion)', () async {
      await withClock(Clock.fixed(_now), () async {
        final server = FakeServer()..profileRow = serverProfileRow(_profile);
        final s = setup(geteilterServer: server);
        await bootUntilIdle(s.store);
        server.offline = !deletion;
        final id = s.store.addResultToDailyTotal(mealResult('Bowl'));
        await settle();
        if (deletion) {
          server.offline = true;
          s.store.removeLoggedMeal(id);
          await settle();
        }
        expect(s.store.pendingOutbox, isNotEmpty);
        final previousWrites = server.requests
            .where(
              (r) => r.url.path.endsWith('/logged_meals') && r.method != 'GET',
            )
            .length;
        server.offline = false;
        server.holdMealWrites();
        s.store.flushPendingWrites();
        await pumpUntil(
          () =>
              server.requests
                  .where(
                    (r) =>
                        r.url.path.endsWith('/logged_meals') &&
                        r.method != 'GET',
                  )
                  .length >
              previousWrites,
        );
        expect(
          server.mealRows.containsKey(id),
          deletion,
          reason: 'Replay ist am echten HTTP-Write aufgehalten',
        );

        final stale = <TrendDayTotals>[
          if (deletion)
            TrendDayTotals(
              day: _now,
              kcal: 300,
              proteinG: 30,
              carbsG: 40,
              fatG: 10,
            ),
        ];
        await TrendTotalsCache.instance.read(
          userId: 'user-outbox',
          load: () async => stale,
        );
        expect(TrendTotalsCache.instance.debugHasEntry, isTrue);

        server.releaseMealWrites();
        await settle();
        expect(server.mealRows.containsKey(id), !deletion);
        var fetchedAgain = false;
        await TrendTotalsCache.instance.read(
          userId: 'user-outbox',
          load: () async {
            fetchedAgain = true;
            return const <TrendDayTotals>[];
          },
        );
        expect(
          fetchedAgain,
          isTrue,
          reason: 'der waehrend Replay geladene Serverstand ist jetzt veraltet',
        );
      });
    });
  }
}
