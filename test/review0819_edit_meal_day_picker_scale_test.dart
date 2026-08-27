import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// Review 2026-08-19, finding 3: the day picker of the edit sheet overflowed at
// large system font sizes. A horizontal ListView gives its children a tight
// cross axis, so the strip height is the chip height; a hardcoded 58 px left
// 40 px for two scaling text lines.
//
// Measured geometrically rather than via the overflow exception: the sheet has
// other overflows at double text size, so an exception would prove nothing
// about this spot.
// ---------------------------------------------------------------------------

/// The value from the design, hardcoded before the fix.
const double entwurfshoehe = 58;

/// Vertical inner padding of a chip, top and bottom.
const double chipPolster = 9;

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Test-Bowl',
      caloriesKcal: 350,
      estimatedGrams: 350,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _loggedMeal() => LoggedMeal(
      id: 'meal-1',
      result: _result(),
      loggedAt: DateTime.now(),
      forcedSlot: MealSlot.breakfast,
    );

LoggedMeal? _update(
  String id, {
  MealAnalysisResult? result,
  MealSlot? slot,
  DateTime? day,
}) =>
    null;

Future<void> _openSheet(
  WidgetTester tester, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Overflows elsewhere in the sheet must not colour this test; only the
  // geometry of the day strip counts.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  // The harness puts the scaling above the Navigator, so it also reaches the
  // modal sheet route.
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showEditMealSheet(
            context,
            meal: _loggedMeal(),
            onUpdateMeal: _update,
          ),
          child: const Text('open'),
        ),
      ),
    ),
    reducedMotion: false,
    brightness: Brightness.light,
    textScale: textScale,
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bei Normalschrift bleibt der Streifen exakt der des Entwurfs',
      (tester) async {
    await _openSheet(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('edit-meal-day-picker'))).height,
      entwurfshoehe,
    );
  });

  testWidgets('bei doppelter Systemschrift waechst der Streifen mit',
      (tester) async {
    await _openSheet(tester, textScale: 2.0);

    expect(
      tester.getSize(find.byKey(const ValueKey('edit-meal-day-picker'))).height,
      greaterThan(entwurfshoehe),
      reason: 'eine feste Hoehe zwingt die Chips in eine Groesse, die ihre '
          'zwei Textzeilen nicht mehr fasst',
    );
  });

  testWidgets('bei doppelter Systemschrift bleiben beide Zeilen im Chip',
      (tester) async {
    await _openSheet(tester, textScale: 2.0);

    final chip = find.byKey(const ValueKey('edit-day-chip-0'));
    expect(chip, findsOneWidget);

    final zeilen = find.descendant(of: chip, matching: find.byType(Text));
    expect(zeilen, findsNWidgets(2), reason: 'Wochentag und Datum');

    final rahmen = tester.getRect(chip);
    final unterkante = tester.getRect(zeilen.last).bottom;

    expect(
      unterkante,
      lessThanOrEqualTo(rahmen.bottom - chipPolster),
      reason: 'Die Datumszeile laeuft unten aus dem Chip heraus '
          '(Chip $rahmen, Zeilenunterkante $unterkante)',
    );
  });
}
