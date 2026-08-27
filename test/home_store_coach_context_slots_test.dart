import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Coach context with macros PER MEAL SLOT (2026-08-21): a per-slot line with
// kcal, P/C/F and entry count sits after the open macros and before the food
// list.
//
// That order is part of the contract: the edge function truncates
// `user_context` at MAX_USER_CONTEXT_CHARS (guardrails.ts) from the END, so
// only the food list may be cut.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
  );
  addTearDown(store.dispose);
  return store;
}

MealAnalysisResult _meal(
  String name, {
  required int kcal,
  required String protein,
  required String carbs,
  required String fat,
}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: kcal / 3,
      protein: protein,
      carbs: carbs,
      fat: fat,
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// Five dinners summing to 980 kcal, P 62 g, C 90 g, F 35 g. Protein carries a
/// decimal (5 x 12.4) so the rounding path is exercised.
final List<MealAnalysisResult> _fuenfAbendessen = [
  _meal('Hähnchenbrust mit Reis und Brokkoli',
      kcal: 200, protein: '12.4 g', carbs: '18 g', fat: '7 g'),
  _meal('Vollkornbrot mit Hüttenkäse und Tomate',
      kcal: 200, protein: '12.4 g', carbs: '18 g', fat: '7 g'),
  _meal('Lachsfilet mit Süßkartoffel und Spinat',
      kcal: 200, protein: '12.4 g', carbs: '18 g', fat: '7 g'),
  _meal('Griechischer Joghurt mit Honig und Walnüssen',
      kcal: 200, protein: '12.4 g', carbs: '18 g', fat: '7 g'),
  _meal('Proteinshake mit Banane',
      kcal: 180, protein: '12.4 g', carbs: '18 g', fat: '7 g'),
];

const _abendessenZeile =
    'Abendessen 980 kcal (P 62 g, K 90 g, F 35 g, 5 Einträge)';
const _slotPrefix = 'Pro Mahlzeit heute: ';
const _listePrefix = 'Heute gegessene Lebensmittel';

/// Thursday 19:30, inside the dinner window of the time heuristic; the tests
/// still pass the slot explicitly, as the sheet does.
final _heute = DateTime(2026, 8, 20, 19, 30);
final _gestern = DateTime(2026, 8, 19);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('coachContext: Makros pro Mahlzeit-Slot', () {
    test('fuenf Abendessen -> eine Slot-Zeile mit Summen und Eintragszahl', () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        for (final m in _fuenfAbendessen) {
          store.addResultToDailyTotal(m, slot: MealSlot.dinner);
        }

        final ctx = store.coachContext;
        // The line names ONLY the filled slot and runs straight into the food
        // list: no zero-kcal slots, no empty sentence.
        expect(ctx, contains('$_slotPrefix$_abendessenZeile. $_listePrefix'));
      });
    });

    test('steht NACH den offenen Makros und VOR der Essensliste', () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        for (final m in _fuenfAbendessen) {
          store.addResultToDailyTotal(m, slot: MealSlot.dinner);
        }

        final ctx = store.coachContext;
        final makros = ctx.indexOf('Makros heute noch offen');
        final slots = ctx.indexOf(_slotPrefix);
        final liste = ctx.indexOf(_listePrefix);
        expect(makros, greaterThanOrEqualTo(0));
        expect(slots, greaterThan(makros));
        expect(liste, greaterThan(slots),
            reason: 'die Server-Kappung darf nur die Essensliste treffen');
      });
    });

    test('ohne Mahlzeiten fehlt die Zeile komplett', () {
      withClock(Clock.fixed(_heute), () {
        final ctx = _store().coachContext;
        expect(ctx, isNot(contains(_slotPrefix)));
        expect(ctx, isNot(contains(_listePrefix)));
        // The core values still show.
        expect(ctx, contains('Makros heute noch offen'));
      });
    });

    test('mehrere Slots in Tagesreihenfolge, Singular bei einem Eintrag', () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        // Logged against day order (dinner first): the line must still read in
        // slot order, not newest-first like loggedMeals.
        for (final m in _fuenfAbendessen) {
          store.addResultToDailyTotal(m, slot: MealSlot.dinner);
        }
        store.addResultToDailyTotal(
          _meal('Pasta Bolognese',
              kcal: 610, protein: '38 g', carbs: '70 g', fat: '20 g'),
          slot: MealSlot.lunch,
        );
        // 12.6 + 12.6 = 25.2 -> 25 g: grams are rounded.
        store.addResultToDailyTotal(
          _meal('Haferflocken mit Milch',
              kcal: 220, protein: '12.6 g', carbs: '25 g', fat: '6 g'),
          slot: MealSlot.breakfast,
        );
        store.addResultToDailyTotal(
          _meal('Banane und Quark',
              kcal: 200, protein: '12.6 g', carbs: '25 g', fat: '6 g'),
          slot: MealSlot.breakfast,
        );

        expect(
          store.coachContext,
          contains('${_slotPrefix}Frühstück 420 kcal (P 25 g, K 50 g, F 12 g, '
              '2 Einträge); Mittagessen 610 kcal (P 38 g, K 70 g, F 20 g, '
              '1 Eintrag); $_abendessenZeile. $_listePrefix'),
        );
      });
    });

    test('Nachtrag fuer gestern zaehlt nicht in die heutigen Slot-Summen', () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        store.addResultToDailyTotal(
          _meal('Pizza', kcal: 900, protein: '40 g', carbs: '100 g', fat: '35 g'),
          slot: MealSlot.dinner,
          foodDate: _gestern,
        );
        store.addResultToDailyTotal(
          _meal('Müsli', kcal: 300, protein: '10 g', carbs: '50 g', fat: '8 g'),
          slot: MealSlot.breakfast,
        );

        final ctx = store.coachContext;
        expect(
          ctx,
          contains('${_slotPrefix}Frühstück 300 kcal (P 10 g, K 50 g, F 8 g, '
              '1 Eintrag). $_listePrefix'),
        );
        expect(ctx, isNot(contains('Abendessen 900')));
      });
    });

    test('typischer Kontext mit fuenf Abendessen bleibt unter dem Server-Cap',
        () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        for (final m in _fuenfAbendessen) {
          store.addResultToDailyTotal(m, slot: MealSlot.dinner);
        }
        final ctx = store.coachContext;
        expect(ctx.length, lessThan(kCoachContextCapChars),
            reason: 'Kontext hat ${ctx.length} Zeichen: $ctx');
      });
    });

    test(
        'auch mit vier vollen Slots und langer Essensliste ueberlebt die '
        'Slot-Zeile die Server-Kappung', () {
      withClock(Clock.fixed(_heute), () {
        final store = _store();
        // Worst realistic case: all four slots filled, more entries than
        // `maxFoods`, over-long names, four-digit kcal.
        const langerName =
            'Überbackene Süßkartoffel-Gnocchi mit Gorgonzola und Rucola';
        for (final slot in MealSlot.values) {
          for (var i = 0; i < 3; i++) {
            store.addResultToDailyTotal(
              _meal(langerName,
                  kcal: 1234, protein: '123.4 g', carbs: '234 g', fat: '99 g'),
              slot: slot,
            );
          }
        }

        final ctx = store.coachContext;
        // Exactly what the server keeps after truncation.
        final behalten = ctx.substring(
            0, ctx.length.clamp(0, kCoachContextCapChars));
        final slotStart = ctx.indexOf(_slotPrefix);
        final slotEnde = ctx.indexOf('. $_listePrefix', slotStart);
        expect(slotStart, greaterThanOrEqualTo(0));
        expect(slotEnde, greaterThan(slotStart));
        final slotZeile = ctx.substring(slotStart, slotEnde + 1);
        expect(behalten, contains(slotZeile),
            reason: 'Slot-Zeile (${slotZeile.length} Zeichen, endet bei '
                '${slotEnde + 1}) muss vollstaendig vor dem Cap stehen');
        expect(slotZeile, contains('Frühstück 3702 kcal'));
        expect(slotZeile, contains('Snacks 3702 kcal'));
        expect(slotZeile, contains('3 Einträge'));
      });
    });

    // The store only MIRRORS the server limit; a stale mirror would make the
    // length tests above worthless. That comparison against guardrails.ts is a
    // source-text rule and lives in test/repo_rules_test.dart.
  });
}
