// Copying meals (review 2026-10-18, E1): "Repeat yesterday" per diary slot
// and "Copy to…" in the edit sheet. Both run through HomeStore's add commit:
// new ids, one mealInsert per copy, day by local-day key. The originals stay
// untouched, recents and favorites too, and the undo removes exactly the
// copies. Pure store logic without sync; the outbox side lives in
// meal_copy_outbox_test.dart.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

/// A plain Wednesday midday, far from midnight and DST edges.
final DateTime _now = DateTime(2026, 10, 14, 12, 30);
final DateTime _today = DateTime(2026, 10, 14);
final DateTime _yesterday = DateTime(2026, 10, 13);

Future<void> _at(DateTime now, Future<void> Function() body) =>
    withClock(Clock.fixed(now), body);

class _Snacks {
  final List<String> messages = <String>[];
  final List<SnackBarAction?> actions = <SnackBarAction?>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
    actions.add(action);
  }

  /// Taps the undo of the last toast and lets its commit run.
  Future<void> undoLast() async {
    actions.last!.onPressed();
    await pumpEventQueue();
  }
}

({HomeStore store, _Snacks snacks}) _setup() {
  final snacks = _Snacks();
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, snacks: snacks);
}

MealAnalysisResult _meal(String name, {int kcal = 300, String? imageUrl}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 250,
      kcalPer100G: kcal / 2.5,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'manual',
      imageUrl: imageUrl,
    );

/// Logs [name] on [day] into [slot] at the wall-clock time [hour]:[minute].
Future<String> _log(
  HomeStore store,
  String name, {
  required DateTime day,
  required MealSlot slot,
  int hour = 12,
  int minute = 30,
  int kcal = 300,
}) => withClock(
  Clock.fixed(DateTime(_now.year, _now.month, _now.day, hour, minute)),
  () => store.addResultToDailyTotal(
    _meal(name, kcal: kcal),
    slot: slot,
    foodDate: day,
  ),
);

LoggedMeal _byId(HomeStore store, String id) =>
    store.loggedMeals.singleWhere((m) => m.id == id);

/// Everything that identifies a logged meal, for before/after comparisons.
Map<String, Object?> _fingerprint(LoggedMeal meal) => <String, Object?>{
  'id': meal.id,
  'loggedAt': meal.loggedAt.toIso8601String(),
  'localDay': meal.localDay,
  'forcedSlot': meal.forcedSlot?.name,
  'result': mealResultToJson(meal.result),
};

List<String> _namesIn(HomeStore store, DateTime day, MealSlot slot) => [
  for (final meal
      in store.mealsForFoodDate(day).toList()
        ..sort((a, b) => a.loggedAt.compareTo(b.loggedAt)))
    if (meal.slot == slot) meal.result.mealName,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Kopieren nach …', () {
    test(
      'die Kopie hat eine neue ID, gleiche Portion und Naehrwerte — das '
      'Original bleibt unveraendert',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Haferbrei',
          day: _yesterday,
          slot: MealSlot.breakfast,
        );
        final before = _fingerprint(_byId(s.store, id));

        final copies = await s.store.copyLoggedMeals(
          [id],
          day: _today,
          slot: MealSlot.breakfast,
        );

        expect(copies, hasLength(1));
        expect(copies.single, isNot(id));
        expect(s.store.loggedMeals, hasLength(2));
        expect(
          _fingerprint(_byId(s.store, id)),
          before,
          reason: 'die Kopie darf das Original nicht verschieben oder aendern',
        );
        expect(s.store.mealsForFoodDate(_yesterday).single.id, id);

        final copy = _byId(s.store, copies.single);
        expect(copy.localDay, localDayKey(_today));
        expect(copy.slot, MealSlot.breakfast);
        expect(copy.loggedAt, DateTime(2026, 10, 14, 12, 30));
        expect(
          mealResultToJson(copy.result),
          before['result'],
          reason: 'Portion und Naehrwerte kommen unveraendert mit',
        );
        expect(s.store.consumedKcalForFoodDate(_today), 300);
        expect(s.store.consumedKcalForFoodDate(_yesterday), 300);
        expect(s.store.dailyConsumedKcal, 300);
        expect(s.snacks.messages.last, 'Mahlzeit für heute kopiert.');
      }),
    );

    test(
      'Tag- und Slotwechsel: die Kopie landet auf dem Zieltag im Zielslot',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Bowl',
          day: _today,
          slot: MealSlot.lunch,
        );
        final threeDaysAgo = DateTime(2026, 10, 11);

        final copies = await s.store.copyLoggedMeals(
          [id],
          day: threeDaysAgo,
          slot: MealSlot.snack,
        );

        final copy = _byId(s.store, copies.single);
        expect(copy.localDay, '2026-10-11');
        expect(copy.slot, MealSlot.snack);
        expect(copy.forcedSlot, MealSlot.snack);
        expect(_namesIn(s.store, threeDaysAgo, MealSlot.snack), ['Bowl']);
        expect(_namesIn(s.store, _today, MealSlot.lunch), ['Bowl']);
        expect(_byId(s.store, id).slot, MealSlot.lunch);
        expect(s.snacks.messages.last, 'Mahlzeit für den 11.10. kopiert.');

        // Without a slot each copy keeps its own.
        final again = await s.store.copyLoggedMeals([id], day: _yesterday);
        expect(_byId(s.store, again.single).slot, MealSlot.lunch);
        expect(s.snacks.messages.last, 'Mahlzeit für gestern kopiert.');
      }),
    );

    test(
      'Zaehler wie beim Eintragen: jede Kopie zaehlt, nur heute bucht die '
      'Serie',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Bowl',
          day: _yesterday,
          slot: MealSlot.lunch,
        );
        expect(s.store.lifetimeStats.mealsLogged, 1);
        expect(s.store.lifetimeStats.currentStreak, 0);

        await s.store.copyLoggedMeals([id], day: DateTime(2026, 10, 12));
        expect(s.store.lifetimeStats.mealsLogged, 2);
        expect(
          s.store.lifetimeStats.currentStreak,
          0,
          reason: 'ein Nachtrag fuer einen vergangenen Tag bucht keine Serie',
        );

        await s.store.copyLoggedMeals([id], day: _today);
        expect(s.store.lifetimeStats.mealsLogged, 3);
        expect(s.store.lifetimeStats.currentStreak, 1);
        expect(s.store.lifetimeStats.lastTrackedDate, _today);
      }),
    );

    test(
      'die Zukunft und verschwundene Eintraege werden abgelehnt',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Bowl',
          day: _today,
          slot: MealSlot.lunch,
        );

        await expectLater(
          s.store.copyLoggedMeals([id], day: DateTime(2026, 10, 15)),
          throwsArgumentError,
        );
        await expectLater(
          s.store.copyLoggedMeals(['gibt-es-nicht'], day: _today),
          throwsStateError,
        );
        expect(s.store.loggedMeals, hasLength(1));
      }),
    );

    test(
      'Recents und Favoriten bleiben, wie sie sind',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Bowl',
          day: _yesterday,
          slot: MealSlot.lunch,
        );
        await _log(s.store, 'Salat', day: _yesterday, slot: MealSlot.dinner);
        final favorites = s.store.favorites;

        await s.store.copyLoggedMeals([id], day: _today);

        expect(
          identical(s.store.favorites, favorites),
          isTrue,
          reason: 'die Kopie schiebt nichts in die Recents',
        );
      }),
    );

    test(
      'das Produktfoto ist eine geteilte URL: Loeschen des Originals laesst '
      'die Kopie samt Foto stehen',
      () => _at(_now, () async {
        final s = _setup();
        const photo = 'https://images.openfoodfacts.org/images/products/1.jpg';
        final id = await withClock(
          Clock.fixed(_now),
          () => s.store.addResultToDailyTotal(
            _meal('Joghurt', imageUrl: photo),
            slot: MealSlot.snack,
            foodDate: _yesterday,
          ),
        );
        final copies = await s.store.copyLoggedMeals([id], day: _today);

        await s.store.removeLoggedMeal(id);

        expect(s.store.loggedMeals.map((m) => m.id), copies);
        expect(_byId(s.store, copies.single).result.imageUrl, photo);
      }),
    );
  });

  group('Gestern wiederholen', () {
    test(
      'kopiert alle Eintraege genau dieses Slots in ihrer Reihenfolge',
      () => _at(_now, () async {
        final s = _setup();
        await _log(
          s.store,
          'Kaffee',
          day: _yesterday,
          slot: MealSlot.breakfast,
          hour: 7,
          kcal: 20,
        );
        await _log(
          s.store,
          'Muesli',
          day: _yesterday,
          slot: MealSlot.breakfast,
          hour: 8,
          kcal: 420,
        );
        await _log(s.store, 'Pasta', day: _yesterday, slot: MealSlot.lunch);
        final yesterdayBefore = [
          for (final m in s.store.mealsForFoodDate(_yesterday)) _fingerprint(m),
        ];
        final mealsBefore = s.store.lifetimeStats.mealsLogged;

        final copies = await s.store.repeatPreviousDaySlot(
          MealSlot.breakfast,
          _today,
        );

        expect(copies, hasLength(2));
        expect(_namesIn(s.store, _today, MealSlot.breakfast), [
          'Kaffee',
          'Muesli',
        ]);
        expect(_namesIn(s.store, _today, MealSlot.lunch), isEmpty);
        expect(s.store.consumedKcalForFoodDate(_today), 440);
        expect([
          for (final m in s.store.mealsForFoodDate(_yesterday)) _fingerprint(m),
        ], yesterdayBefore);
        expect(s.store.lifetimeStats.mealsLogged, mealsBefore + 2);
        expect(s.store.lifetimeStats.lastTrackedDate, _today);
        expect(s.snacks.messages.last, '2 Einträge von gestern übernommen.');
      }),
    );

    test(
      'eine Kopie auf heute liegt nie in der Zukunft und behaelt die Reihenfolge',
      () => _at(_now, () async {
        final s = _setup();
        await _log(
          s.store,
          'Brot',
          day: _yesterday,
          slot: MealSlot.dinner,
          hour: 11,
        );
        await _log(
          s.store,
          'Pasta',
          day: _yesterday,
          slot: MealSlot.dinner,
          hour: 19,
        );
        await _log(
          s.store,
          'Eis',
          day: _yesterday,
          slot: MealSlot.dinner,
          hour: 19,
          minute: 45,
        );

        final ids = await s.store.repeatPreviousDaySlot(
          MealSlot.dinner,
          _today,
        );

        final copies = [for (final id in ids) _byId(s.store, id)];
        expect(copies.every((c) => !c.loggedAt.isAfter(_now)), isTrue);
        expect(
          copies.singleWhere((c) => c.result.mealName == 'Brot').loggedAt,
          DateTime(2026, 10, 14, 11, 30),
        );
        expect(_namesIn(s.store, _today, MealSlot.dinner), [
          'Brot',
          'Pasta',
          'Eis',
        ]);
        expect(copies.every((c) => c.localDay == localDayKey(_today)), isTrue);
      }),
    );

    test(
      'ein Doppeltipp kopiert einmal, ein gefuellter Slot gar nicht',
      () => _at(_now, () async {
        final s = _setup();
        await _log(
          s.store,
          'Muesli',
          day: _yesterday,
          slot: MealSlot.breakfast,
        );

        final first = s.store.repeatPreviousDaySlot(MealSlot.breakfast, _today);
        final second = s.store.repeatPreviousDaySlot(
          MealSlot.breakfast,
          _today,
        );
        expect(await first, hasLength(1));
        expect(await second, isEmpty);
        expect(
          await s.store.repeatPreviousDaySlot(MealSlot.breakfast, _today),
          isEmpty,
        );
        expect(_namesIn(s.store, _today, MealSlot.breakfast), ['Muesli']);
      }),
    );

    test(
      'auf einem vergangenen Tag kommt der Vortag dieses Tages',
      () => _at(_now, () async {
        final s = _setup();
        final dayBefore = DateTime(2026, 10, 12);
        await _log(s.store, 'Toast', day: dayBefore, slot: MealSlot.dinner);
        await _log(s.store, 'Heute', day: _yesterday, slot: MealSlot.lunch);

        final copies = await s.store.repeatPreviousDaySlot(
          MealSlot.dinner,
          _yesterday,
        );

        expect(_namesIn(s.store, _yesterday, MealSlot.dinner), ['Toast']);
        expect(_byId(s.store, copies.single).localDay, '2026-10-13');
        expect(s.snacks.messages.last, '1 Eintrag vom Vortag übernommen.');
        expect(
          s.store.lifetimeStats.currentStreak,
          0,
          reason: 'ein vergangener Tag ist ein Nachtrag',
        );
      }),
    );

    test(
      'ein nicht vollstaendig geladener Vortag wird nicht angeboten',
      () => _at(_now, () async {
        final s = _setup();
        // Outside the 35-day boot window and never loaded on demand.
        final old = DateTime(2026, 9, 1);
        await _log(s.store, 'Alt', day: old, slot: MealSlot.lunch);
        await _log(s.store, 'Gestern', day: _yesterday, slot: MealSlot.lunch);

        expect(s.store.previousFoodDayComplete(DateTime(2026, 9, 2)), isFalse);
        expect(s.store.repeatableMealsBefore(DateTime(2026, 9, 2)), isEmpty);
        await expectLater(
          s.store.repeatPreviousDaySlot(MealSlot.lunch, DateTime(2026, 9, 2)),
          throwsStateError,
        );
        expect(s.store.previousFoodDayComplete(_today), isTrue);
        expect(
          s.store.repeatableMealsBefore(_today).map((m) => m.result.mealName),
          ['Gestern'],
        );
      }),
    );
  });

  group('Rueckgaengig', () {
    test(
      'entfernt genau die Kopien — Originale und spaetere Eintraege bleiben',
      () => _at(_now, () async {
        final s = _setup();
        await _log(
          s.store,
          'Kaffee',
          day: _yesterday,
          slot: MealSlot.breakfast,
        );
        await _log(
          s.store,
          'Muesli',
          day: _yesterday,
          slot: MealSlot.breakfast,
        );
        final copies = await s.store.repeatPreviousDaySlot(
          MealSlot.breakfast,
          _today,
        );
        final undo = s.snacks.actions.last!;
        final later = await _log(
          s.store,
          'Suppe',
          day: _today,
          slot: MealSlot.lunch,
        );
        final ids = s.store.loggedMeals.map((m) => m.id).toSet();

        undo.onPressed();
        await pumpEventQueue();

        expect(
          s.store.loggedMeals.map((m) => m.id).toSet(),
          ids.difference(copies.toSet()),
        );
        expect(_byId(s.store, later).result.mealName, 'Suppe');
        expect(s.store.mealsForFoodDate(_yesterday), hasLength(2));
        expect(s.store.consumedKcalForFoodDate(_today), 300);

        // A second tap changes nothing.
        undo.onPressed();
        await pumpEventQueue();
        expect(s.store.loggedMeals, hasLength(3));
      }),
    );

    test(
      'nach dem Kopieren nach … entfernt es nur die Kopie',
      () => _at(_now, () async {
        final s = _setup();
        final id = await _log(
          s.store,
          'Bowl',
          day: _yesterday,
          slot: MealSlot.lunch,
        );
        final before = _fingerprint(_byId(s.store, id));
        await s.store.copyLoggedMeals([id], day: _today);

        await s.snacks.undoLast();

        expect(s.store.loggedMeals.map(_fingerprint), [before]);
      }),
    );
  });
}
