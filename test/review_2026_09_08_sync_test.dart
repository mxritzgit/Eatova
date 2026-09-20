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
import 'package:eatova/src/services/sync_outbox.dart';

import 'fixlauf_a_helpers.dart' show StummerFotoStore;
import 'outbox/outbox_test_helpers.dart';

const _profile = UserProfile(
  weightKg: 80,
  heightCm: 180,
  onboardingCompleted: true,
);
final _now = DateTime(2026, 9, 8, 12);

/// Holds the first atomic meal/counter response; receipts stay on the server.
class _HeldInsertServer extends FakeServer {
  _HeldInsertServer({this.applyBeforeReply = false});

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

      if (request.url.path.endsWith('/rpc/apply_sync_operation') &&
          (jsonDecode(request.body) as Map)['p_kind'] == 'mealInsert' &&
          heldRequestId == null) {
        heldRequestId =
            (jsonDecode(request.body) as Map)['p_operation_id'] as String;
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
    test('Logout behaelt atomaren Meal/Counter-Intent bis zum bestaetigten Ack '
        '(serverseitig gebucht: $alreadyLanded)', () {
      fakeAsync((async) {
        final server = _HeldInsertServer(applyBeforeReply: alreadyLanded)
          ..profileRow = serverProfileRow(_profile);
        final kv = InMemoryKeyValueStore();
        final first = setup(
          kv: kv,
          geteilterServer: server,
          disposeClient: false,
          disposeStore: false,
        );
        _bootInFakeTime(first.store, async);
        String? mealId;
        first.store
            .addResultToDailyTotal(mealResult('Bowl'))
            .then((id) => mealId = id);
        async.flushMicrotasks();
        async.elapse(kSyncDeliveryWindow);
        async.flushMicrotasks();
        expect(
          mealId,
          isNotNull,
          reason: 'lokal bestaetigtes Speichern wartet nicht auf HTTP',
        );
        expect(server.heldRequestId, isNotNull);
        final queuedIds = first.store.pendingOutbox
            .map((op) => op.operationId)
            .toSet();
        expect(first.store.pendingOutbox.map((op) => op.kind), [
          SyncOpKind.mealInsert,
          SyncOpKind.favoriteUpsert,
        ]);
        expect(server.mealsCounted, alreadyLanded ? 1 : 0);

        var signedOut = false;
        first.store.signOutCleanup().then((_) => signedOut = true);
        async.flushMicrotasks();
        async.elapse(kSignOutDeliveryBudget + const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(signedOut, isTrue, reason: 'Logout bleibt zeitlich begrenzt');
        List<SyncOp>? pending;
        first.cache.readOutbox().then((value) => pending = value);
        async.flushMicrotasks();
        expect(pending!.map((op) => op.operationId).toSet(), queuedIds);
        expect(
          pending!
              .singleWhere((op) => op.kind == SyncOpKind.mealInsert)
              .operationId,
          server.heldRequestId,
        );
        expect(
          kv.snapshot.keys,
          isNot(contains('eatova.v1.profile.user-outbox')),
        );

        server.reply.complete(false);
        async.flushMicrotasks();
        first.cache.readOutbox().then((value) => pending = value);
        async.flushMicrotasks();
        expect(
          pending!.map((op) => op.operationId).toSet(),
          queuedIds,
          reason: 'spaeter Fehler dupliziert den Intent nicht',
        );
        first.store.dispose();
        final second = setup(
          kv: kv,
          geteilterServer: server,
          disposeClient: false,
        );
        _bootInFakeTime(second.store, async);
        expect(server.mealRows.keys, [mealId]);
        expect(
          server.mealsCounted,
          1,
          reason:
              'Restart liefert Meal und Counter genau einmal, auch bei verlorenem Ack',
        );
        final ids = server
            .operations('mealInsert')
            .map((r) => (jsonDecode(r.body) as Map)['p_operation_id'])
            .toSet();
        expect(ids, {server.heldRequestId});
        expect(second.store.pendingOutbox, isEmpty);
      }, initialTime: _now);
    });
  }

  test(
    'vor Logout bestaetigter atomarer Meal/Counter-Commit braucht kein Replay',
    () {
      fakeAsync((async) {
        final server = _HeldInsertServer()
          ..profileRow = serverProfileRow(_profile);
        final s = setup(geteilterServer: server, disposeClient: false);
        _bootInFakeTime(s.store, async);
        var saved = false;
        s.store
            .addResultToDailyTotal(mealResult('Bowl'))
            .then((_) => saved = true);
        async.flushMicrotasks();
        expect(server.heldRequestId, isNotNull);
        expect(saved, isFalse);
        server.reply.complete(true);
        async.flushMicrotasks();
        expect(saved, isTrue);
        expect(server.mealsCounted, 1);
        expect(s.store.pendingOutbox, isEmpty);
        var signedOut = false;
        s.store.signOutCleanup().then((_) => signedOut = true);
        async.flushMicrotasks();
        expect(signedOut, isTrue);
        List<SyncOp>? pending;
        s.cache.readOutbox().then((value) => pending = value);
        async.flushMicrotasks();
        expect(pending, isEmpty);
        expect(server.operations('mealInsert'), hasLength(1));
      }, initialTime: _now);
    },
  );

  for (final deletion in [false, true]) {
    test('Trend-Cache aus laufendem Replay wird nach Zustellung verworfen '
        '(Delete: $deletion)', () async {
      await withClock(Clock.fixed(_now), () async {
        final server = FakeServer()..profileRow = serverProfileRow(_profile);
        final s = setup(geteilterServer: server);
        await bootUntilIdle(s.store);
        server.offline = !deletion;
        final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
        await settle();
        if (deletion) {
          server.offline = true;
          await s.store.removeLoggedMeal(id);
          await settle();
        }
        expect(s.store.pendingOutbox, isNotEmpty);
        final kind = deletion ? 'mealDelete' : 'mealInsert';
        final previousWrites = server.operations(kind).length;
        server.offline = false;
        server.holdMealWrites();
        s.store.flushPendingWrites();
        await pumpUntil(() => server.operations(kind).length > previousWrites);
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
