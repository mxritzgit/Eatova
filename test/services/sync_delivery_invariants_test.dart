import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' show mealResult, userRecipe;
import '../support/atomic_store_faults.dart';

const _owner = '71000000-0000-4000-8000-000000000001';
const _queueKey = 'eatova.v1.outbox.$_owner';
final _now = DateTime.utc(2026, 9, 20, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'wire request is committed before start and reused after model changes',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final raw = InMemoryKeyValueStore();
        final controlled = AtomicStoreFaults(raw);
        final cache = LocalCache(controlled, _owner);
        final op = SyncOp.recipeUpsert(
          userRecipe('user_wire', title: 'Frozen'),
          expectedRevision: 3,
        );
        await cache.commitSyncOperations([op]);
        controlled.beforeWrite = (changes) async {
          if (changes.containsKey(_queueKey)) {
            throw StateError('disk unavailable');
          }
        };
        await expectLater(
          cache.startSyncOperation(op.operationId),
          throwsStateError,
        );
        final unstarted =
            (await cache.readMutationSnapshot()).operations.single;
        expect(unstarted.deliveryStarted, isFalse);
        expect(unstarted.wirePayload, isNull);
        expect(unstarted.operationId, op.operationId);

        controlled.beforeWrite = null;
        final started = (await cache.startSyncOperation(op.operationId))!;
        expect(started.deliveryStarted, isTrue);
        expect(started.wireSchema, 1);
        expect((started.wirePayload!['recipe'] as Map)['title'], 'Frozen');
        final originalWire = jsonEncode(started.wirePayload);
        expect(
          () => (started.wirePayload!['recipe'] as Map)['title'] = 'Changed',
          throwsUnsupportedError,
        );

        // A newer app may interpret the local model differently. It must not
        // regenerate the request already identified by this operation UUID.
        final persisted =
            jsonDecode(jsonEncode(started.toJson())) as Map<String, dynamic>;
        ((persisted['payload'] as Map)['recipe'] as Map)['title'] = 'New model';
        await raw.setString(
          _queueKey,
          jsonEncode({
            'items': [persisted],
          }),
        );
        final reboot = LocalCache(raw, _owner);
        await reboot.recordSyncFailure(
          op.operationId,
          countAttempt: true,
          blockedReason: SyncBlockedReason.rejected,
        );
        await reboot.retryBlockedSyncOperations();
        final replay = (await reboot.startSyncOperation(op.operationId))!;
        expect(replay.recipe!.title, 'New model');
        expect(replay.operationId, op.operationId);
        expect(jsonEncode(replay.wirePayload), originalWire);
        expect(replay.attempts, 1);
        expect(() => replay.rebaseRecipe(revision: 4), throwsStateError);
      });
    },
  );

  test(
    'legacy started entry freezes once without replacing operation identity',
    () async {
      await withClock(Clock.fixed(_now), () async {
        final raw = InMemoryKeyValueStore();
        final op = SyncOp.weightInsert(
          id: '72000000-0000-4000-8000-000000000001',
          weightKg: 80,
          recordedAt: _now,
        );
        await raw.setString(
          _queueKey,
          jsonEncode({
            'items': [
              {...op.toJson(), 'delivery_started': true, 'attempts': 2},
            ],
          }),
        );
        final cache = LocalCache(raw, _owner);
        final migrated = (await cache.startSyncOperation(op.operationId))!;
        expect(migrated.operationId, op.operationId);
        expect(migrated.attempts, 2);
        expect(migrated.wireSchema, 1);
        expect(
          (migrated.wirePayload!['row'] as Map)['recorded_at'],
          _now.toIso8601String(),
        );
        final reboot = LocalCache(raw, _owner);
        expect(
          (await reboot.startSyncOperation(op.operationId))!.toJson(),
          migrated.toJson(),
        );
      });
    },
  );

  test('new offline timestamps retain their instant before first dispatch', () {
    withClock(Clock.fixed(_now), () {
      final local = _now.toLocal();
      final meal = SyncOp.mealInsert(
        LoggedMeal(id: 'meal', result: mealResult('Meal'), loggedAt: local),
        trackDay: true,
      );
      final favorite = SyncOp.favoriteUpsert(
        FavoriteMeal(
          id: 'favorite',
          result: mealResult('Meal'),
          addedAt: local,
        ),
      );
      final weight = SyncOp.weightInsert(
        id: 'weight',
        weightKg: 80,
        recordedAt: local,
      );
      expect(
        (meal.payload['meal'] as Map)['logged_at'],
        _now.toIso8601String(),
      );
      expect(
        (favorite.payload['favorite'] as Map)['added_at'],
        _now.toIso8601String(),
      );
      expect(weight.payload['recorded_at'], _now.toIso8601String());
      expect(meal.meal!.loggedAt, local);
      expect(favorite.favorite!.addedAt, local);
      expect(weight.recordedAt, local);
      expect(meal.meal!.slot, mealSlotForHour(local.hour));
      expect(
        (meal.payload['meal'] as Map)['forced_slot'],
        mealSlotForHour(local.hour).name,
      );
      expect(
        meal.meal!.effectiveLocalDay,
        LoggedMeal(
          id: 'meal',
          result: mealResult('Meal'),
          loggedAt: local,
        ).effectiveLocalDay,
      );
    });
  });

  test(
    'unreadable or future frozen wire schema never becomes a new request',
    () async {
      final raw = InMemoryKeyValueStore();
      final op = SyncOp.mealDelete('meal');
      for (final wire in [
        {'wire_schema': 1},
        {'wire_payload': <String, dynamic>{}},
        {'wire_schema': 2, 'wire_payload': <String, dynamic>{}},
        {'wire_schema': 1, 'wire_payload': 'corrupted'},
      ]) {
        final saved = jsonEncode({
          'items': [
            {...op.toJson(), ...wire},
          ],
        });
        await raw.setString(_queueKey, saved);
        final cache = LocalCache(raw, _owner);
        await expectLater(
          cache.startSyncOperation(op.operationId),
          throwsFormatException,
        );
        expect(await raw.getString(_queueKey), saved);
      }
    },
  );

  for (final pendingCopy in [false, true]) {
    test(
      'replayed conflict receipt removes deleted copy, newer intent=$pendingCopy',
      () async {
        await withClock(Clock.fixed(_now), () async {
          final cache = LocalCache(InMemoryKeyValueStore(), _owner);
          final op = SyncOp.recipeUpsert(
            userRecipe('user_original', title: 'Offline'),
            expectedRevision: 1,
          );
          final canonical = userRecipe(
            'user_original',
            title: 'Other device',
          ).copyWith(serverRevision: 8);
          final copy = userRecipe(
            'user_conflict_${op.operationId}',
            title: 'Offline',
          ).copyWith(serverRevision: 1, conflictOf: op.entityId);
          await cache.commitSyncOperations([op]);
          // A prior boot saw the copy after the original response was lost.
          await cache.writeUserRecipes([canonical, copy]);
          if (pendingCopy) {
            await cache.commitSyncOperations([
              SyncOp.recipeUpsert(
                copy.copyWith(title: 'New local draft'),
                expectedRevision: 1,
              ),
            ]);
          }
          final client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient(
              (request) async => http.Response(
                jsonEncode({
                  'operation_id': op.operationId,
                  'kind': op.kind.name,
                  'entity_id': op.entityId,
                  'result': {
                    'recipe_mutation': {
                      'outcome': 'conflictSaved',
                      'current_revision': 8,
                      'current_deleted': false,
                      'current_recipe': canonical.toRow(),
                      'saved_recipe': copy.toRow(),
                    },
                  },
                  'current_state': {
                    'recipe': {
                      'slug': canonical.slug,
                      'revision': 8,
                      'deleted': false,
                      'recipe': canonical.toRow(),
                    },
                    'saved_recipe': {
                      'slug': copy.slug,
                      'revision': 2,
                      'deleted': true,
                      'recipe': null,
                    },
                  },
                }),
                200,
                request: request,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
          addTearDown(client.dispose);
          final result = await dispatchSyncOp(
            EatovaSync.forUser(client, _owner),
            op,
          );
          await cache.acknowledgeSyncOperation(op.operationId, result);
          final reboot = LocalCache(cache.atomicStore!, _owner);
          final recipes = (await reboot.readUserRecipes())!;
          expect(
            recipes.where((r) => r.slug == canonical.slug).single.title,
            'Other device',
          );
          expect(
            recipes
                .where((r) => r.slug == copy.slug)
                .map((r) => r.title)
                .toList(),
            pendingCopy ? ['New local draft'] : isEmpty,
          );
          expect(
            (await reboot.readSyncOperations()).any(
              (entry) => entry.operationId == op.operationId,
            ),
            isFalse,
          );
          expect(result.recipeBaseRevision, 1);
          expect(result.recipeBaseSlug, copy.slug);
        });
      },
    );
  }
}
