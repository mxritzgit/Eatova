// "Woche vorschlagen" (2026-11-01): the preview writes nothing; "Übernehmen"
// adds every row in one local commit, offline too, and never touches or
// doubles an entry that was planned before or meanwhile.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

/// Records, for every write that touches the outbox, how many plan upserts
/// it then holds: a partial commit would show up as an intermediate count.
class _OutboxLog extends InMemoryKeyValueStore {
  final planOps = <int>[];

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) {
    final raw = changes['eatova.v1.outbox.A'];
    if (raw != null) {
      planOps.add(
        ((jsonDecode(raw) as Map)['items'] as List)
            .where((op) => op['kind'] == 'mealPlanUpsert')
            .length,
      );
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  testWidgets('die Vorschau schreibt nichts; Übernehmen schreibt alle Zeilen '
      'in einem Commit und lässt Geplantes stehen, auch inzwischen '
      'Geplantes', (tester) async {
    // Monday 07:30: the whole week is open.
    await withClock(Clock.fixed(DateTime(2026, 11, 2, 7, 30)), () async {
      final storage = _OutboxLog();
      final cache = LocalCache(storage, 'A');
      late SupabaseClient client;
      late HomeStore store;
      late PlannedMeal planned;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async => throw http.ClientException('offline')),
        );
        store = HomeStore(
          sync: EatovaSync.forUser(client, 'A'),
          debugCache: cache,
          health: const NoopHealthService(),
          notificationService: const NoopNotificationService(),
          initialUserName: 'Fixture',
          emitSnack: h.SnackCapture().call,
        );
        await cache.writeProfile(
          const UserProfile(onboardingCompleted: true, dailyKcalGoal: 2100),
        );
        await h.bootUntilIdle(store);
        await h.pumpUntil(() => !store.mealPlansLoading);
        planned = PlannedMeal.create(
          recipe: recipeCatalogDe.first,
          day: DateTime(2026, 11, 3),
          slot: MealSlot.lunch,
        );
        await store.savePlannedMeal(planned);
      });
      addTearDown(() async {
        store.dispose();
        await client.dispose();
      });
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        surfaceSize: const Size(393, 852),
      );
      final written = storage.planOps.length;

      // Open, edit and close: nothing is written.
      await tester.tap(_key('meal-plan-suggest'));
      await tester.pumpAndSettle();
      expect(_key('meal-plan-suggest-sheet'), findsOneWidget);
      expect(_key('meal-plan-suggest-row-2026-11-03-lunch'), findsNothing,
          reason: 'the planned slot is not offered again');
      await tester.tap(_key('meal-plan-suggest-close'));
      await tester.pumpAndSettle();
      expect(storage.planOps, hasLength(written));
      expect(store.plannedMeals, hasLength(1));

      // Remove one row; while the preview is open, another device plans
      // Monday's dinner. Apply then writes the other 18 (21 minus the
      // planned, the removed and the raced one).
      await tester.tap(_key('meal-plan-suggest'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        _key('meal-plan-suggest-remove-2026-11-02-lunch'),
      );
      await tester.tap(_key('meal-plan-suggest-remove-2026-11-02-lunch'));
      await tester.pumpAndSettle();
      expect(storage.planOps, hasLength(written));
      final raced = PlannedMeal.create(
        recipe: recipeCatalogDe.first,
        day: DateTime(2026, 11, 2),
        slot: MealSlot.dinner,
      );
      await tester.runAsync(() => store.savePlannedMeal(raced));
      final before = storage.planOps.length;
      await tester.runAsync(() async {
        await tester.tap(_key('meal-plan-suggest-apply'));
        await h.pumpUntil(() => store.plannedMeals.length > 2);
        await h.settle();
      });
      await tester.pumpAndSettle();

      expect(store.plannedMeals, hasLength(20));
      expect(
        storage.planOps.skip(before).toSet(),
        {20},
        reason: 'one commit holds all 18, no write holds part of them',
      );
      List<PlannedMeal> at(String day, MealSlot slot) => [
        for (final p in store.plannedMeals)
          if (p.day == day && p.slot == slot) p,
      ];
      expect(at('2026-11-03', MealSlot.lunch).single.id, planned.id);
      expect(at('2026-11-02', MealSlot.dinner).single.id, raced.id);
      expect(at('2026-11-02', MealSlot.lunch), isEmpty, reason: 'removed');
      expect(_key('meal-plan-suggest-sheet'), findsNothing);
      expect(find.textContaining('18 Mahlzeiten'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
