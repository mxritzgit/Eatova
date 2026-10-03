import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// Review 2026-08-19, finding 3: the day picker of the edit sheet overflowed at
// large system font sizes. Since 2026-10-03 the sheet uses Today's 7-day
// strip; the guarantee stays: weekday and day number stay inside their cell.
//
// Measured geometrically rather than via the overflow exception: an exception
// elsewhere in the sheet would prove nothing about this spot.
// ---------------------------------------------------------------------------

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
}) => null;

Future<void> _openSheet(WidgetTester tester, {double textScale = 1.0}) async {
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
  for (final scale in [1.0, 2.0]) {
    testWidgets('bei ${scale}x Schrift bleiben Wochentag und Zahl im Tag', (
      tester,
    ) async {
      await _openSheet(tester, textScale: scale);

      final heute = find.byKey(
        ValueKey<String>('today-day-${localDayKey(DateTime.now())}'),
      );
      expect(heute, findsOneWidget);
      final zeilen = find.descendant(of: heute, matching: find.byType(Text));
      expect(zeilen, findsNWidgets(2), reason: 'Wochentag und Zahl');

      final rahmen = tester.getRect(heute);
      for (final zeile in zeilen.evaluate()) {
        final r = tester.getRect(find.byWidget(zeile.widget));
        expect(
          rahmen.contains(r.topLeft) &&
              rahmen.contains(r.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: 'Zeile $r ragt aus dem Tag $rahmen',
        );
      }
      expect(rahmen.height, greaterThanOrEqualTo(44), reason: 'Tap-Ziel');
    });
  }
}
