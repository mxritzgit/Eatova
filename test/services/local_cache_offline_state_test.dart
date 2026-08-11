import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

// DATA-7: der LocalCache spiegelt jetzt auch Tagebuch (loggedMeals),
// Favoriten, Gewichts-Log, die Write-Outbox und die pendenden Lifetime-
// Stats-Deltas — damit ein Kaltstart ohne Netz nicht mit leerem Tagebuch
// startet und kein Write einen App-Kill verliert. Diese Tests sichern die
// Roundtrips, die defensive Korrupt-Behandlung und dass clear() ALLE neuen
// Slots (PII!) mit raeumt.

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
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result(),
      loggedAt: DateTime(2026, 8, 5, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-05',
    );

FitnessRecipe _recipe(String slug, {String title = 'Eigene Bowl'}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: 'Eigenes Rezept',
      portion: '1 Teller',
      ingredients: 'Reis\nHaehnchen',
      preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
      professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
      imageAsset: '',
      caloriesKcal: 600,
      proteinG: 50,
      carbsG: 60,
      fatG: 15,
      estimatedGrams: 400,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

LocalCache _cache(InMemoryKeyValueStore store, [String userId = 'user-1']) =>
    LocalCache(store, userId);

void main() {
  group('LocalCache Tagebuch/Favoriten/Gewicht', () {
    test('loggedMeals roundtrippen verlustfrei (Slot, localDay, Result)',
        () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeLoggedMeals([_meal('m-1'), _meal('m-2')]);

      final back = await cache.readLoggedMeals();
      expect(back, hasLength(2));
      expect(back![0].id, 'm-1');
      expect(back[0].forcedSlot, MealSlot.lunch);
      expect(back[0].localDay, '2026-08-05');
      expect(back[0].loggedAt, DateTime(2026, 8, 5, 12, 30));
      expect(back[0].result.caloriesKcal, 300);
      expect(back[0].result.mealName, 'Bowl');
    });

    test('favorites roundtrippen inkl. pinned', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeFavorites([
        FavoriteMeal(
          id: 'name:bowl',
          result: _result(),
          addedAt: DateTime(2026, 8, 5, 13),
          pinned: true,
        ),
      ]);

      final back = await cache.readFavorites();
      expect(back, hasLength(1));
      expect(back!.single.id, 'name:bowl');
      expect(back.single.pinned, isTrue);
      expect(back.single.addedAt, DateTime(2026, 8, 5, 13));
    });

    test('weightLog roundtrippt in Reihenfolge', () async {
      final cache = _cache(InMemoryKeyValueStore());
      final log = WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 1, 7), weightKg: 82.0),
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]);
      await cache.writeWeightLog(log);

      final back = await cache.readWeightLog();
      expect(back, isNotNull);
      expect(back!.entries, hasLength(2));
      expect(back.latest!.weightKg, 81.4);
      expect(back.entries.first.timestamp, DateTime(2026, 8, 1, 7));
    });

    test('leerer Cache -> ueberall null', () async {
      final cache = _cache(InMemoryKeyValueStore());
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(await cache.readUserRecipes(), isNull);
    });

    test('korrupter Eintrag -> null statt Crash', () async {
      final store = InMemoryKeyValueStore({
        'eatova.v1.logged_meals.user-1': '{ kein json',
        'eatova.v1.weight_log.user-1': '{"items":[{"t":"quatsch"}]}',
        // Eine Rezept-Zeile OHNE slug: FitnessRecipe.fromRow wirft dafuer
        // bewusst (der slug ist der Upsert-Konflikt-Schluessel und darf nie
        // erfunden werden, Sentinel-Rest S4) — der Slot faellt als Ganzes aus.
        'eatova.v1.user_recipes.user-1': '{"items":[{"title":"Ohne Slug"}]}',
      });
      final cache = _cache(store);
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readUserRecipes(), isNull);
    });
  });

  // Luecke A: Eigen-Rezepte waren die einzige Nutzer-Sammlung ohne
  // Cache-Slot — ihr einziges Netz war die Outbox. Ein Kaltstart ohne Netz
  // zeigte deshalb NIE Eigen-Rezepte, auch laengst synchronisierte nicht.
  group('LocalCache Eigen-Rezepte (Luecke A)', () {
    test('roundtrippen verlustfrei inkl. Kategorien und Makros', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes([
        _recipe('user_1717500000000', title: 'Eigene Protein-Bowl'),
        _recipe('user_1717500000001'),
      ]);

      final back = await cache.readUserRecipes();
      expect(back, hasLength(2));
      expect(back![0].slug, 'user_1717500000000');
      expect(back[0].title, 'Eigene Protein-Bowl');
      expect(back[0].ingredients, 'Reis\nHaehnchen');
      expect(back[0].caloriesKcal, 600);
      expect(back[0].proteinG, 50);
      expect(back[0].carbsG, 60);
      expect(back[0].fatG, 15);
      expect(back[0].estimatedGrams, 400);
      expect(back[0].categories, <String>['Eigene']);
      expect(back[1].slug, 'user_1717500000001');
    });

    test(
        'ein gecachtes Rezept ist von einem geladenen nicht zu unterscheiden '
        '(userCreated + Profi-Hinweis)', () async {
      // Das Wire-Format ist die Serverzeile (toRow/fromRow) — beide Felder
      // fuehrt die Tabelle nicht, fromRow setzt sie. Waere hier ein eigenes
      // Format entstanden, saehe ein Rezept nach dem Offline-Kaltstart anders
      // aus als nach dem Online-Boot (kein Loeschen-Knopf, weil die UI an
      // userCreated haengt).
      //
      // Seit dem Inhalte-PR (2026-08-11, Platzhalter-Fix) setzt `fromRow`
      // professionalHint NEUTRAL ('') statt fest deutsch — der Roundtrip
      // ueberschreibt den `_recipe()`-Fixture-Wert also unabhaengig davon,
      // was reingeschrieben wurde (dieselbe Zusicherung wie vorher: die
      // Tabelle fuehrt die Spalte nicht, fromRow gewinnt immer). Die Anzeige
      // loest die leere Zeichenkette erst spaeter ueber
      // `FitnessRecipe.displayProfessionalHint` in die aktuelle Locale auf.
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes([_recipe('user_1')]);

      final back = (await cache.readUserRecipes())!.single;
      expect(back.userCreated, isTrue);
      expect(back.professionalHint, '');
    });

    test('leere Liste ist NICHT dasselbe wie kein Cache', () async {
      // Wichtig fuer die Boot-Hydration: `[]` heisst „der Nutzer hat keine
      // Eigen-Rezepte", `null` heisst „nichts gespeichert" — nur Letzteres
      // darf den Server-Stand unangetastet lassen.
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeUserRecipes(const <FitnessRecipe>[]);
      expect(await cache.readUserRecipes(), isEmpty);
    });

    test('Slot ist pro userId getrennt', () async {
      final store = InMemoryKeyValueStore();
      await _cache(store, 'user-a').writeUserRecipes([_recipe('user_1')]);
      expect(await _cache(store, 'user-b').readUserRecipes(), isNull);
    });
  });

  group('LocalCache Outbox + Stats-Deltas', () {
    test('Outbox roundtrippt; korrupte Einzel-Ops werden uebersprungen',
        () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writeOutbox([
        SyncOp.mealInsert(_meal('m-1'), trackDay: true),
        SyncOp.mealDelete('m-2'),
      ]);

      final back = await cache.readOutbox();
      expect(back, hasLength(2));
      expect(back![0].kind, SyncOpKind.mealInsert);
      expect(back[0].trackDay, isTrue);
      expect(back[0].meal!.id, 'm-1');
      expect(back[1].kind, SyncOpKind.mealDelete);

      // Ein unbekannter Op-Kind in der Mitte reisst die Queue nicht mit.
      final store = InMemoryKeyValueStore({
        'eatova.v1.outbox.user-1':
            '{"items":[{"kind":"zeitmaschine","entity_id":"x"},'
                '{"kind":"mealDelete","entity_id":"m-9","payload":{}}]}',
      });
      final partial = await _cache(store).readOutbox();
      expect(partial, hasLength(1));
      expect(partial!.single.entityId, 'm-9');
    });

    test('pendende Stats-Deltas roundtrippen', () async {
      final cache = _cache(InMemoryKeyValueStore());
      await cache.writePendingStatsDeltas(meals: 3, weightLogs: 1);

      final back = await cache.readPendingStatsDeltas();
      expect(back, isNotNull);
      expect(back!.meals, 3);
      expect(back.weightLogs, 1);
    });
  });

  group('LocalCache Housekeeping (DATA-7)', () {
    test('clear() raeumt auch Tagebuch, Favoriten, Gewicht, Outbox und Deltas',
        () async {
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeLoggedMeals([_meal('m-1')]);
      await cache.writeFavorites([
        FavoriteMeal(
            id: 'name:bowl', result: _result(), addedAt: DateTime(2026, 8, 5)),
      ]);
      await cache.writeWeightLog(WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]));
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);
      await cache.writeUserRecipes([_recipe('user_1')]);

      await cache.clear();

      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(await cache.readUserRecipes(), isNull);
      expect(store.snapshot, isEmpty,
          reason: 'kein PII-Rest in den SharedPreferences');
    });

    test('clear(preserveOutbox: true) haelt genau Outbox + Stats-Deltas',
        () async {
      // A2: Ausloggen darf ungesyncte Mahlzeiten nicht vernichten. Die beiden
      // Sync-Slots ueberleben den Logout und spielen beim naechsten Login
      // DESSELBEN Users nach; alles andere (PII-Spiegel) muss weg.
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeProfile(const UserProfile(weightKg: 90));
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 3));
      await cache.writeNotificationsEnabled(true);
      await cache.writeLoggedMeals([_meal('m-1')]);
      await cache.writeFavorites([
        FavoriteMeal(
            id: 'name:bowl', result: _result(), addedAt: DateTime(2026, 8, 5)),
      ]);
      await cache.writeWeightLog(WeightLog(entries: [
        WeightLogEntry(timestamp: DateTime(2026, 8, 5, 7), weightKg: 81.4),
      ]));
      await cache.writeOutbox([SyncOp.mealInsert(_meal('m-2'), trackDay: true)]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);
      await cache.writeUserRecipes([_recipe('user_1')]);

      await cache.clear(preserveOutbox: true);

      // Die zwei Sync-Slots stehen noch — inklusive Inhalt.
      final outbox = await cache.readOutbox();
      expect(outbox, hasLength(1));
      expect(outbox!.single.entityId, 'm-2');
      expect((await cache.readPendingStatsDeltas())!.meals, 1);

      // Alles andere ist geraeumt.
      expect(await cache.readProfile(), isNull);
      expect(await cache.readLifetimeStats(), isNull);
      expect(await cache.readNotificationsEnabled(), isNull);
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readFavorites(), isNull);
      expect(await cache.readWeightLog(), isNull);
      // Eigen-Rezepte sind Nutzerinhalt (Zutaten, Mengen) — sie fallen unter
      // dieselbe M-1-Begruendung wie das Tagebuch und ueberleben den Logout
      // NICHT. Ihr noch nicht zugestellter Write liegt in der Outbox.
      expect(await cache.readUserRecipes(), isNull);
      expect(
        store.snapshot.keys.toSet(),
        {'eatova.v1.outbox.user-1', 'eatova.v1.pending_stats.user-1'},
        reason: 'genau die zwei Sync-Slots, kein PII-Rest',
      );
    });

    test('clear() ohne Argument raeumt weiterhin auch die Outbox', () async {
      // Der Default darf sich NICHT aendern — bestehende Aufrufer
      // (Konto-Loeschung) verlassen sich darauf.
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      await cache.writeOutbox([SyncOp.mealDelete('m-2')]);
      await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0);

      await cache.clear();

      expect(await cache.readOutbox(), isNull);
      expect(await cache.readPendingStatsDeltas(), isNull);
      expect(store.snapshot, isEmpty);
    });

    test('Slots sind pro userId getrennt', () async {
      final store = InMemoryKeyValueStore();
      await _cache(store, 'user-a').writeLoggedMeals([_meal('m-1')]);
      expect(await _cache(store, 'user-b').readLoggedMeals(), isNull);
    });
  });
}
