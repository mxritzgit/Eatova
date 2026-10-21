// The seven-day block in HomeStore.coachContext (C2, 2026-10-18): built from
// local state on send, placed before the per-slot and food lines, and within
// the server's cap (MAX_USER_CONTEXT_CHARS, mirrored as kCoachContextCapChars)
// so that only the food list can ever be cut.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import '../outbox/outbox_test_helpers.dart'
    show boot, mealResult, serverProfileRow, settle, setup, testProfile;

/// Sunday 18 October 2026, 19:30; the week is Sunday 11 .. Saturday 17.
final DateTime _now = DateTime(2026, 10, 18, 19, 30);
final DateTime _yesterday = DateTime(2026, 10, 17);

const _week = 'Letzte 7 Tage ohne heute (11.10.–17.10.): ';
const _slots = 'Pro Mahlzeit heute: ';
const _foods = 'Heute gegessene Lebensmittel';

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

MealAnalysisResult _meal(String name, int kcal, {String protein = '30 g'}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: kcal / 3,
      protein: protein,
      carbs: '50 g',
      fat: '20 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _logged(
  String id,
  DateTime at,
  int kcal, {
  String? localDay,
  String protein = '30 g',
}) => LoggedMeal(
  id: id,
  result: _meal('Essen $id', kcal, protein: protein),
  loggedAt: at,
  localDay: localDay,
);

/// 21 daily weigh-ins ending yesterday, losing 0.05 kg a day.
WeightLog _dailyWeighIns() => WeightLog.capped([
  for (var n = 1; n <= 21; n++)
    WeightLogEntry(
      timestamp: DateTime(2026, 10, 18 - n, 7),
      weightKg: 90 + 0.05 * n,
    ),
]);

/// A full week with four-digit days, two of them partial, as the longest
/// realistic block (the weight rate included).
List<LoggedMeal> _fullWeek() => [
  for (var n = 1; n <= 7; n++)
    _logged(
      'w$n',
      DateTime(2026, 10, 18 - n, 13),
      n.isEven ? 1012 + n : 2345 + n,
      protein: '${100 + n}.4 g',
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('steht nach den Kernwerten und vor Slot-Zeile und Essensliste; '
      'heute zaehlt nicht mit', () async {
    await withClock(Clock.fixed(_now), () async {
      final store = _store();
      await store.addResultToDailyTotal(
        _meal('Nudeln', 1800),
        slot: MealSlot.dinner,
        foodDate: _yesterday,
      );
      await store.addResultToDailyTotal(
        _meal('Salat', 500),
        slot: MealSlot.dinner,
      );

      final ctx = store.coachContext;
      final core = ctx.indexOf('Makros heute noch offen');
      final week = ctx.indexOf(_week);
      final slots = ctx.indexOf(_slots);
      final foods = ctx.indexOf(_foods);
      expect(core, greaterThanOrEqualTo(0));
      expect(week, greaterThan(core));
      expect(slots, greaterThan(week));
      expect(foods, greaterThan(slots));
      // Today's 500 kcal stay out of the week, yesterday's 1800 count.
      expect(ctx, contains('${_week}1 von 7 Tagen erfasst.'));
      expect(ctx, contains('Sa 1800.'));
      expect(ctx, contains('Heute gegessen: 500 von'));
    });
  });

  test('Tage nach Local-Day-Key: der gespeicherte Tag gewinnt, Grenzen '
      'auf die Minute', () {
    withClock(Clock.fixed(_now), () {
      final store = _store();
      store.loggedMeals = [
        // 00:30 today on this clock, but logged on the 17th in a zone one
        // hour behind: the persisted local day wins.
        _logged(
          'a',
          DateTime(2026, 10, 18, 0, 30),
          700,
          localDay: '2026-10-17',
        ),
        // A legacy row without a key: its local time decides.
        _logged('b', DateTime(2026, 10, 17, 23, 30), 1500),
        // One minute before the window, and its first minute.
        _logged('c', DateTime(2026, 10, 10, 23, 59), 900),
        _logged('d', DateTime(2026, 10, 11, 0, 1), 1200),
      ];
      final ctx = store.coachContext;
      expect(ctx, contains('${_week}2 von 7 Tagen erfasst.'));
      expect(
        ctx,
        contains(
          'kcal je Tag (– = nichts erfasst): So 1200, Mo –, Di –, Mi –, '
          'Do –, Fr –, Sa 2200.',
        ),
      );
    });
  });

  test('ein Eintrag, der noch in der Outbox steckt, fehlt nicht (TRN-9)', () {
    return withClock(Clock.fixed(_now), () async {
      final a = setup();
      a.server.profileRow = serverProfileRow(testProfile());
      await boot(a.store);
      a.server.offline = true;

      await a.store.addResultToDailyTotal(
        mealResult('Nachtrag', kcal: 1800),
        slot: MealSlot.dinner,
        foodDate: _yesterday,
      );
      await settle();

      expect(
        a.store.pendingOutbox.where((op) => op.kind == SyncOpKind.mealInsert),
        hasLength(1),
        reason: 'Vorbedingung: der Eintrag wartet noch auf die Zustellung',
      );
      expect(
        a.server.mealRows,
        isEmpty,
        reason:
            'Vorbedingung: der Server (und damit jede Trend-Zeile) kennt '
            'ihn nicht',
      );
      final ctx = a.store.coachContext;
      expect(ctx, contains('${_week}1 von 7 Tagen erfasst.'));
      expect(ctx, contains('Sa 1800.'));
    });
  });

  test('bindet Gewichtsverlauf und Aktivitaetsbonus der Vortage', () {
    withClock(Clock.fixed(_now), () {
      final store = _store();
      store.weightLog = _dailyWeighIns();
      store.dailyActivity = {'2026-10-17': (steps: 10000, kcal: 300)};
      store.loggedMeals = [_logged('y', DateTime(2026, 10, 17, 13), 2400)];
      final ctx = store.coachContext;
      // Default profile: 2200 kcal goal, plus 300 kcal credited yesterday.
      expect(
        ctx,
        contains(
          'Der eine erfasste Tag: 2400 kcal '
          '(Ziel Ø 2500 kcal inkl. Aktivitätsbonus)',
        ),
      );
      expect(
        ctx,
        contains(
          'Gewichtstrend über 21 Tage: −0,35 kg/Woche '
          '(±0,25 kg/Woche; 21 Wiegetage).',
        ),
      );
      // No training history in this store: no count rather than a zero.
      expect(ctx, isNot(contains('Trainings in der App')));
    });
  });

  group('Laenge und Reihenfolge gegen den Server-Cap', () {
    test('typischer Kontext mit voller Woche passt komplett unter den Cap', () {
      return withClock(Clock.fixed(_now), () async {
        final store = _store();
        store.weightLog = _dailyWeighIns();
        store.loggedMeals = _fullWeek();
        for (final name in ['Hähnchen mit Reis', 'Skyr mit Beeren']) {
          await store.addResultToDailyTotal(
            _meal(name, 600),
            slot: MealSlot.lunch,
          );
        }
        final ctx = store.coachContext;
        expect(
          ctx.length,
          lessThan(kCoachContextCapChars),
          reason: 'Kontext hat ${ctx.length} Zeichen: $ctx',
        );
      });
    });

    test('schlimmster realistischer Fall: Wochenblock und Slot-Zeile '
        'vollstaendig, und die zehn Lebensmittel ueberleben den Cap', () {
      return withClock(Clock.fixed(_now), () async {
        final store = _store();
        store.weightLog = _dailyWeighIns();
        store.loggedMeals = _fullWeek();
        // All four slots, more entries than `maxFoods`, over-long names,
        // four-digit kcal.
        const longName =
            'Überbackene Süßkartoffel-Gnocchi mit Gorgonzola und Rucola';
        for (final slot in MealSlot.values) {
          for (var i = 0; i < 3; i++) {
            await store.addResultToDailyTotal(
              _meal(longName, 1234, protein: '123.4 g'),
              slot: slot,
            );
          }
        }

        final ctx = store.coachContext;
        final kept = ctx.substring(
          0,
          ctx.length.clamp(0, kCoachContextCapChars),
        );
        final week = ctx.substring(ctx.indexOf(_week), ctx.indexOf(_slots));
        expect(week, contains('davon 3 unter 50 %'));
        expect(week, contains('Gewichtstrend über 21 Tage'));
        expect(kept, contains(week));
        final slotEnd = ctx.indexOf('. $_foods');
        expect(kept, contains(ctx.substring(ctx.indexOf(_slots), slotEnd + 1)));
        // The food list is the only part the cap may touch, and at 2000
        // characters it does not: all ten names and the closing "…" stay.
        expect(
          ctx.length,
          lessThanOrEqualTo(kCoachContextCapChars),
          reason: 'Kontext hat ${ctx.length} Zeichen',
        );
        expect(kept, endsWith(' ….'));
        // Names are shortened to 39 characters plus "…".
        expect(
          RegExp(RegExp.escape(longName.substring(0, 39))).allMatches(kept),
          hasLength(10),
          reason: 'alle zehn gezeigten Namen bleiben erhalten',
        );
      });
    });
  });
}
