// Copying meals in the UI (review 2026-10-18, E1): the diary's "Repeat
// yesterday" row appears only in an empty slot whose counterpart on the day
// before has entries; "Copy to…" in the edit sheet opens a sheet with day and
// slot. Both survive 2x text at 320 px.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_copy_sheet.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

import '../support/harness.dart';

/// A plain Wednesday midday, far from midnight and DST edges.
final DateTime _now = DateTime(2026, 10, 14, 12, 30);
final DateTime _today = DateTime(2026, 10, 14);
final DateTime _yesterday = DateTime(2026, 10, 13);

Future<void> _at(Future<void> Function() body) =>
    withClock(Clock.fixed(_now), body);

MealAnalysisResult _result(String name, int kcal) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 250,
  kcalPer100G: kcal / 2.5,
  protein: '20 g',
  carbs: '30 g',
  fat: '8 g',
  confidence: 'Hoch',
  portionNotes: '',
  sourceLabel: 'manual',
);

LoggedMeal _logged(
  String id,
  String name,
  int kcal, {
  required DateTime day,
  required MealSlot slot,
  int hour = 8,
}) => LoggedMeal(
  id: id,
  result: _result(name, kcal),
  loggedAt: DateTime(day.year, day.month, day.day, hour),
  forcedSlot: slot,
  localDay: localDayKey(day),
);

final List<LoggedMeal> _yesterdayMeals = [
  _logged('y1', 'Kaffee', 20, day: _yesterday, slot: MealSlot.breakfast),
  _logged('y2', 'Müsli', 420, day: _yesterday, slot: MealSlot.breakfast),
  _logged('y3', 'Pasta', 600, day: _yesterday, slot: MealSlot.lunch, hour: 13),
];

final List<LoggedMeal> _todayMeals = [
  _logged('t1', 'Salat', 350, day: _today, slot: MealSlot.lunch, hour: 12),
];

class _Repeats {
  final List<(MealSlot, DateTime)> calls = <(MealSlot, DateTime)>[];
  Completer<void>? gate;

  Future<void> call(MealSlot slot, DateTime day) async {
    calls.add((slot, day));
    await gate?.future;
  }
}

Future<void> _pumpDiary(
  WidgetTester tester, {
  DateTime? selectedDate,
  List<LoggedMeal>? loggedMeals,
  List<LoggedMeal>? previousDayMeals,
  _Repeats? repeats,
  bool dayLoadFailed = false,
  double textScale = 1.0,
  Size? surfaceSize,
}) async {
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: 0,
      selectedDate: selectedDate ?? _today,
      loggedMeals: loggedMeals ?? _todayMeals,
      previousDayMeals: previousDayMeals ?? _yesterdayMeals,
      onRepeatSlot: repeats?.call,
      dayLoadFailed: dayLoadFailed,
    ),
    textScale: textScale,
    surfaceSize: surfaceSize,
  );
  await tester.pumpAndSettle();
}

Finder _repeatRow(MealSlot slot) =>
    find.byKey(ValueKey('food-slot-repeat-${slot.name}'));

class _Copies {
  final List<(List<String>, DateTime, MealSlot?)> calls =
      <(List<String>, DateTime, MealSlot?)>[];
  int updates = 0;

  Future<List<String>> copy(
    List<String> ids, {
    required DateTime day,
    MealSlot? slot,
  }) async {
    calls.add((ids, day, slot));
    return const <String>['copy-1'];
  }

  LoggedMeal? update(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) {
    updates++;
    return null;
  }
}

Future<void> _openEditSheet(
  WidgetTester tester,
  _Copies copies, {
  bool withCopy = true,
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showEditMealSheet(
            context,
            meal: _yesterdayMeals[1],
            onUpdateMeal: copies.update,
            onCopyMeals: withCopy ? copies.copy : null,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _inCopySheet(Finder matching) => find.descendant(
  of: find.byKey(const ValueKey('meal-copy-sheet')),
  matching: matching,
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Gestern wiederholen im Tagebuch', () {
    testWidgetsRobust(
      'erscheint nur im leeren Slot, dessen Vortag Eintraege hat',
      (tester) => _at(() async {
        final semantics = tester.ensureSemantics();
        final repeats = _Repeats();
        await _pumpDiary(tester, repeats: repeats);

        expect(_repeatRow(MealSlot.breakfast), findsOneWidget);
        expect(
          _repeatRow(MealSlot.lunch),
          findsNothing,
          reason: 'heute steht schon etwas im Mittagessen',
        );
        expect(
          _repeatRow(MealSlot.dinner),
          findsNothing,
          reason: 'gestern gab es kein Abendessen',
        );
        expect(_repeatRow(MealSlot.snack), findsNothing);
        expect(find.text('Gestern wiederholen'), findsOneWidget);
        expect(find.text('2 Einträge · 440 kcal'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            'Frühstück vom Vortag wiederholen: 2 Einträge, 440 kcal',
          ),
          findsOneWidget,
        );

        await _tapVisible(tester, _repeatRow(MealSlot.breakfast));
        expect(repeats.calls, [(MealSlot.breakfast, _today)]);
        semantics.dispose();
      }),
    );

    testWidgetsRobust(
      'ohne Callback, auf einem nicht geladenen Tag und ohne Vortag kein '
      'Angebot',
      (tester) => _at(() async {
        await _pumpDiary(tester);
        expect(find.text('Gestern wiederholen'), findsNothing);

        await _pumpDiary(tester, repeats: _Repeats(), dayLoadFailed: true);
        expect(find.text('Gestern wiederholen'), findsNothing);

        await _pumpDiary(
          tester,
          repeats: _Repeats(),
          previousDayMeals: const <LoggedMeal>[],
        );
        expect(find.text('Gestern wiederholen'), findsNothing);
      }),
    );

    testWidgetsRobust(
      'auf einem vergangenen Tag heisst es Vortag wiederholen',
      (tester) => _at(() async {
        final repeats = _Repeats();
        final shown = DateTime(2026, 10, 10);
        await _pumpDiary(
          tester,
          selectedDate: shown,
          loggedMeals: const <LoggedMeal>[],
          previousDayMeals: [
            _logged(
              'p1',
              'Toast',
              300,
              day: DateTime(2026, 10, 9),
              slot: MealSlot.dinner,
              hour: 19,
            ),
          ],
          repeats: repeats,
        );

        expect(find.text('Vortag wiederholen'), findsOneWidget);
        expect(find.text('1 Eintrag · 300 kcal'), findsOneWidget);
        await _tapVisible(tester, _repeatRow(MealSlot.dinner));
        expect(repeats.calls, [(MealSlot.dinner, shown)]);
      }),
    );

    testWidgetsRobust(
      'waehrend des Kopierens dreht ein Spinner und ein zweiter Tipp zaehlt '
      'nicht',
      (tester) => _at(() async {
        final repeats = _Repeats()..gate = Completer<void>();
        await _pumpDiary(tester, repeats: repeats);
        final row = _repeatRow(MealSlot.breakfast);
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();

        await tester.tap(row);
        await tester.pump();
        expect(find.byType(AppSpinner), findsOneWidget);
        await tester.tap(row);
        await tester.pump();
        expect(repeats.calls, hasLength(1));

        repeats.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(AppSpinner), findsNothing);
      }),
    );

    testWidgets('grosse Schrift (2x, 320 px) laeuft nicht ueber', (
      tester,
    ) async {
      await _at(() async {
        final overflows = await collectOverflows(() async {
          await _pumpDiary(
            tester,
            repeats: _Repeats(),
            textScale: 2.0,
            surfaceSize: const Size(320, 640),
          );
          await tester.ensureVisible(_repeatRow(MealSlot.breakfast));
          await tester.pumpAndSettle();
        });
        expect(overflows, isEmpty, reason: describeOverflows(overflows));
        expect(_repeatRow(MealSlot.breakfast), findsOneWidget);
      });
    });
  });

  group('Kopieren nach … im Bearbeiten-Blatt', () {
    testWidgetsRobust(
      'kopiert mit Tag und Slot, das Original wird nicht gespeichert',
      (tester) => _at(() async {
        final copies = _Copies();
        await _openEditSheet(tester, copies);

        await _tapVisible(
          tester,
          find.byKey(const ValueKey('edit-meal-copy-button')),
        );
        expect(find.byKey(const ValueKey('meal-copy-sheet')), findsOneWidget);
        expect(find.text('Mahlzeit kopieren'), findsOneWidget);
        expect(find.text('Das Original bleibt unverändert.'), findsOneWidget);
        // The meal's own slot is preselected.
        expect(
          tester
              .widget<SlotSelector>(
                find.byKey(const ValueKey('meal-copy-slot-select')),
              )
              .selected,
          MealSlot.breakfast,
        );

        await _tapVisible(
          tester,
          _inCopySheet(find.byKey(const ValueKey('copy-slot-select-snack'))),
        );
        await _tapVisible(
          tester,
          _inCopySheet(
            find.byKey(ValueKey('today-day-${localDayKey(_yesterday)}')),
          ),
        );
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('meal-copy-confirm')),
        );

        expect(copies.calls, hasLength(1));
        final (ids, day, slot) = copies.calls.single;
        expect(ids, ['y2']);
        expect(day, _yesterday);
        expect(slot, MealSlot.snack);
        expect(copies.updates, 0, reason: 'das Original bleibt, wie es ist');
        expect(find.byKey(const ValueKey('meal-copy-sheet')), findsNothing);
        expect(find.byKey(const ValueKey('edit-meal-sheet')), findsNothing);
      }),
    );

    testWidgetsRobust(
      'der Tag ist mit heute vorbelegt; Schliessen kopiert nichts',
      (tester) => _at(() async {
        final copies = _Copies();
        await _openEditSheet(tester, copies);
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('edit-meal-copy-button')),
        );

        await _tapVisible(
          tester,
          find.byKey(const ValueKey('meal-copy-close')),
        );
        expect(copies.calls, isEmpty);
        expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);

        await _tapVisible(
          tester,
          find.byKey(const ValueKey('edit-meal-copy-button')),
        );
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('meal-copy-confirm')),
        );
        expect(copies.calls.single.$2, _today);
        expect(copies.calls.single.$3, MealSlot.breakfast);
      }),
    );

    testWidgetsRobust(
      'bei ungespeicherten Aenderungen ist Kopieren gesperrt und sagt warum',
      (tester) => _at(() async {
        final copies = _Copies();
        await _openEditSheet(tester, copies);
        final button = find.byKey(const ValueKey('edit-meal-copy-button'));
        expect(tester.widget<SoftPillButton>(button).onTap, isNotNull);

        await _tapVisible(
          tester,
          find.byKey(const ValueKey('edit-slot-select-lunch')),
        );

        expect(tester.widget<SoftPillButton>(button).onTap, isNull);
        expect(find.text('Speichere zuerst deine Änderungen.'), findsOneWidget);
      }),
    );

    testWidgetsRobust(
      'ohne Kopier-Callback gibt es keinen Knopf',
      (tester) => _at(() async {
        await _openEditSheet(tester, _Copies(), withCopy: false);
        expect(
          find.byKey(const ValueKey('edit-meal-copy-button')),
          findsNothing,
        );
      }),
    );

    testWidgets('das Kopieren-Blatt haelt 2x Schrift bei 320 px aus', (
      tester,
    ) async {
      await _at(() async {
        final copies = _Copies();
        final overflows = await collectOverflows(() async {
          await pumpLocalized(
            tester,
            Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showMealCopySheet(
                    context,
                    meal: _yesterdayMeals[1],
                    onCopy: (day, slot) async {
                      await copies.copy(['y2'], day: day, slot: slot);
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            textScale: 2.0,
            surfaceSize: const Size(320, 640),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await _tapVisible(
            tester,
            find.byKey(const ValueKey('meal-copy-confirm')),
          );
        });
        expect(overflows, isEmpty, reason: describeOverflows(overflows));
        expect(copies.calls, hasLength(1));
      });
    });

    testWidgets('der Kopieren-Knopf im Bearbeiten-Blatt haelt 2x Schrift aus', (
      tester,
    ) async {
      await _at(() async {
        final copies = _Copies();
        final overflows = await collectOverflows(() async {
          await pumpLocalized(
            tester,
            Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showEditMealSheet(
                    context,
                    meal: _yesterdayMeals[1],
                    onUpdateMeal: copies.update,
                    onCopyMeals: copies.copy,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            textScale: 2.0,
            surfaceSize: const Size(320, 640),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await _tapVisible(
            tester,
            find.byKey(const ValueKey('edit-slot-select-lunch')),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('edit-meal-copy-save-first')),
          );
          await tester.pumpAndSettle();
        });
        expect(overflows, isEmpty, reason: describeOverflows(overflows));
      });
    });
  });
}
