import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/sync_outbox.dart';

// DATA-7 Write-Outbox: SyncOp ist das persistierbare Wire-Format fuer
// fehlgeschlagene Sync-Writes. Diese Tests sichern:
//   1. Jede Op-Art roundtrippt verlustfrei durch toJson/tryFromJson.
//   2. Korrupte/unbekannte Eintraege liefern null statt zu crashen.
//   3. enqueueCoalesced haelt die Queue kurz, OHNE die Reihenfolge pro
//      Entitaet (insert -> update -> delete) zu brechen.

MealAnalysisResult _result({String name = 'Bowl', int kcal = 300}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 350,
      kcalPer100G: 85.7,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Testportion.',
      items: const [
        MealComponent(name: 'Reis', grams: 150, caloriesKcal: 195),
      ],
      sourceLabel: 'Foto-KI',
      barcode: '4001234',
      brand: 'Testmarke',
    );

LoggedMeal _meal(String id, {int kcal = 300}) => LoggedMeal(
      id: id,
      result: _result(kcal: kcal),
      loggedAt: DateTime(2026, 8, 5, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-05',
    );

void main() {
  group('SyncOp Serialisierung', () {
    test('mealInsert roundtrippt inkl. Meal-Payload und track_day', () {
      final op = SyncOp.mealInsert(_meal('m-1'), trackDay: true);
      final back = SyncOp.tryFromJson(op.toJson());

      expect(back, isNotNull);
      expect(back!.kind, SyncOpKind.mealInsert);
      expect(back.entityId, 'm-1');
      expect(back.entityKey, 'meal:m-1');
      expect(back.trackDay, isTrue);
      final meal = back.meal!;
      expect(meal.id, 'm-1');
      expect(meal.loggedAt, DateTime(2026, 8, 5, 12, 30));
      expect(meal.forcedSlot, MealSlot.lunch);
      expect(meal.localDay, '2026-08-05');
      expect(meal.result.caloriesKcal, 300);
      expect(meal.result.items.single.name, 'Reis');
      expect(meal.result.barcode, '4001234');
    });

    test('mealUpsert/mealDelete roundtrippen', () {
      final upsert = SyncOp.tryFromJson(SyncOp.mealUpsert(_meal('m-2')).toJson());
      expect(upsert!.kind, SyncOpKind.mealUpsert);
      expect(upsert.trackDay, isFalse);
      expect(upsert.meal!.id, 'm-2');

      final delete = SyncOp.tryFromJson(SyncOp.mealDelete('m-3').toJson());
      expect(delete!.kind, SyncOpKind.mealDelete);
      expect(delete.entityId, 'm-3');
      expect(delete.entityKey, 'meal:m-3');
    });

    test('weightInsert roundtrippt id + kg + Zeitstempel', () {
      final ts = DateTime(2026, 8, 6, 7, 45, 12, 345);
      final op = SyncOp.weightInsert(id: 'w-1', weightKg: 81.4, recordedAt: ts);
      final back = SyncOp.tryFromJson(op.toJson());

      expect(back!.kind, SyncOpKind.weightInsert);
      expect(back.entityId, 'w-1');
      expect(back.entityKey, 'weight:w-1');
      expect(back.weightKg, 81.4);
      expect(back.recordedAt, ts);
    });

    test('favoriteUpsert/-Delete roundtrippen inkl. pinned', () {
      final fav = FavoriteMeal(
        id: 'barcode:4001234',
        result: _result(),
        addedAt: DateTime(2026, 8, 5, 13),
        pinned: true,
      );
      final back = SyncOp.tryFromJson(SyncOp.favoriteUpsert(fav).toJson());
      expect(back!.kind, SyncOpKind.favoriteUpsert);
      expect(back.favorite!.id, 'barcode:4001234');
      expect(back.favorite!.pinned, isTrue);
      expect(back.favorite!.addedAt, DateTime(2026, 8, 5, 13));

      final del = SyncOp.tryFromJson(
          SyncOp.favoriteDelete('barcode:4001234').toJson());
      expect(del!.entityKey, 'favorite:barcode:4001234');
    });

    test('recipeUpsert/-Delete roundtrippen ueber toRow/fromRow', () {
      const recipe = FitnessRecipe(
        slug: 'user_123',
        title: 'Eigenes Rezept',
        description: 'Test',
        portion: '1 Portion',
        ingredients: '- 100 g Test',
        preparation: '1. Testen.',
        professionalHint: 'Selbst angelegt.',
        imageAsset: '',
        caloriesKcal: 420,
        proteinG: 33,
        carbsG: 44,
        fatG: 11,
        estimatedGrams: 350,
        categories: <String>['Eigene'],
        userCreated: true,
      );
      final back = SyncOp.tryFromJson(SyncOp.recipeUpsert(recipe).toJson());
      expect(back!.kind, SyncOpKind.recipeUpsert);
      expect(back.entityKey, 'recipe:user_123');
      final r = back.recipe!;
      expect(r.slug, 'user_123');
      expect(r.title, 'Eigenes Rezept');
      expect(r.caloriesKcal, 420);
      expect(r.userCreated, isTrue);

      final del = SyncOp.tryFromJson(SyncOp.recipeDelete('user_123').toJson());
      expect(del!.kind, SyncOpKind.recipeDelete);
    });

    test('korrupte Eintraege liefern null statt Crash', () {
      expect(SyncOp.tryFromJson(const {}), isNull);
      expect(SyncOp.tryFromJson(const {'kind': 'zeitmaschine'}), isNull);
      expect(
        SyncOp.tryFromJson(const {'kind': 'mealInsert'}),
        isNull,
        reason: 'ohne entity_id ist die Op nicht zuordenbar',
      );
      // Kaputter Payload: Op selbst bleibt lesbar, der Meal-Zugriff ist null
      // (der Replay laesst so eine Op still verfallen).
      final op = SyncOp.tryFromJson(const {
        'kind': 'mealInsert',
        'entity_id': 'm-x',
        'payload': {'meal': 'kein-objekt'},
      });
      expect(op, isNotNull);
      expect(op!.meal, isNull);
    });
  });

  group('enqueueCoalesced', () {
    test('wiederholtes Upsert derselben Entitaet ersetzt den Payload', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 300)));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 500)));

      expect(queue, hasLength(1));
      expect(queue.single.meal!.result.caloriesKcal, 500);
    });

    test('mealUpsert auf pendenden mealInsert behaelt Kind + track_day', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(
          queue, SyncOp.mealInsert(_meal('m-1', kcal: 300), trackDay: true));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 500)));

      expect(queue, hasLength(1));
      expect(queue.single.kind, SyncOpKind.mealInsert,
          reason: 'die Stats-Zaehlung des Erst-Inserts darf nicht verlorengehen');
      expect(queue.single.trackDay, isTrue);
      expect(queue.single.meal!.result.caloriesKcal, 500);
    });

    test('Delete wird angehaengt, nie koalesziert (FIFO pro Entitaet)', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(
          queue, SyncOp.mealInsert(_meal('m-1'), trackDay: false));
      queue = enqueueCoalesced(queue, SyncOp.mealDelete('m-1'));

      expect(queue.map((o) => o.kind),
          [SyncOpKind.mealInsert, SyncOpKind.mealDelete]);
    });

    test('Upsert NACH Delete (Undo) wird dahinter angehaengt', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealDelete('m-1'));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1')));

      expect(queue.map((o) => o.kind),
          [SyncOpKind.mealDelete, SyncOpKind.mealUpsert]);
    });

    test('fremde Entitaeten bleiben unberuehrt', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1')));
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-2')));

      expect(queue, hasLength(2));
    });

    test('appendOnly (Replay laeuft) haengt IMMER an', () {
      var queue = <SyncOp>[];
      queue = enqueueCoalesced(queue, SyncOp.mealUpsert(_meal('m-1', kcal: 300)));
      queue = enqueueCoalesced(
        queue,
        SyncOp.mealUpsert(_meal('m-1', kcal: 500)),
        appendOnly: true,
      );

      expect(queue, hasLength(2),
          reason: 'die gerade abgespielte Op darf nicht mutiert werden');
    });
  });
}
