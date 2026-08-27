// Fix run for review 2026-08-27, I-2 (widget level, no app shell): the
// analysis sheet hosts its own toast surface above the modal scrim. The
// 0-kcal guard, the add confirmation and the re-portion toast all fire while
// the sheet stays open — on the root messenger they painted UNDER the scrim
// and read as dead. Pattern: test/fixlauf_c_sheet_snack_widget_test.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

/// Photo-AI answer with the "0 = unknown" sentinel: the guard must refuse it
/// with a toast, not log it silently.
const MealAnalysisResult _ohneKalorien = MealAnalysisResult(
  mealName: 'Unklare Suppe',
  caloriesKcal: 0,
  estimatedGrams: 250,
  kcalPer100G: 0,
  protein: '0 g',
  carbs: '0 g',
  fat: '0 g',
  confidence: 'Niedrig',
  portionNotes: '',
  sourceLabel: 'Foto-KI',
);

const MealAnalysisResult _apfel = MealAnalysisResult(
  mealName: 'Apfel',
  caloriesKcal: 52,
  estimatedGrams: 100,
  kcalPer100G: 52,
  protein: '0 g',
  carbs: '14 g',
  fat: '0 g',
  confidence: 'Datenbank',
  portionNotes: '',
);

int _addCalls = 0;

/// Opens the sheet on its REAL modal route (scrim included) and resolves the
/// analysis once the sheet listens.
Future<void> _pumpOpenSheet(
  WidgetTester tester,
  MealAnalysisResult result,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _addCalls = 0;

  final completer = Completer<MealAnalysisResult>();
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const ValueKey('open'),
          onPressed: () => showMealAnalysisSheet(
            context,
            slot: MealSlot.snack,
            resultFuture: completer.future,
            previewImage: null,
            onAdd: (_, __) {
              _addCalls++;
              return 'id-1';
            },
            onUpdateMeal: (_, __) {},
            failureMessage: _de.foodAnalysisFailedMessage,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('analyse-sheet')), findsOneWidget);

  completer.complete(result);
  await tester.pumpAndSettle();
  expect(find.byType(MealResultCard), findsOneWidget);
}

Future<void> _tapAdd(WidgetTester tester) async {
  final add = find.byKey(const ValueKey('analyse-add-daily-button'));
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectToastInsideSheet(Finder toast) {
  expect(toast, findsOneWidget);
  expect(toast.hitTestable(), findsOneWidget,
      reason: 'unter dem Scrim waere der Toast sichtbar, aber tot');
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('analyse-sheet')),
      matching: toast,
    ),
    findsOneWidget,
    reason: 'der Toast gehoert in den Grund des Sheets, nicht ins Home',
  );
  expect(
    find.ancestor(of: toast, matching: find.byType(SnackHost)),
    findsOneWidget,
  );
}

void main() {
  setUp(SnackHost.debugResetHosts);

  testWidgets('der 0-kcal-Wächter toastet ÜBER dem Scrim und loggt nichts',
      (tester) async {
    await _pumpOpenSheet(tester, _ohneKalorien);

    await _tapAdd(tester);

    _expectToastInsideSheet(find.text(_de.foodMealWithoutCaloriesMessage));
    expect(_addCalls, 0, reason: 'der Wächter darf nicht loggen');
    // The sheet is still open — the user is meant to go to "adjust".
    expect(find.byKey(const ValueKey('analyse-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-adjust-button')),
        findsOneWidget);
  });

  testWidgets('der Erfolgs-Toast nach dem Hinzufügen liegt über dem Scrim',
      (tester) async {
    await _pumpOpenSheet(tester, _apfel);

    await _tapAdd(tester);

    _expectToastInsideSheet(find.text('52 kcal zu Snacks hinzugefügt.'));
    expect(_addCalls, 1);
  });

  testWidgets('der Host schluckt keine Taps: Toast unter der Karte, '
      'Schließen funktioniert', (tester) async {
    await _pumpOpenSheet(tester, _apfel);
    await _tapAdd(tester);

    final toast = tester.getRect(find.byType(SnackBar));
    final card = tester.getRect(
      find.byKey(const ValueKey('analyse-result-card')),
    );
    expect(toast.top, greaterThanOrEqualTo(card.bottom - 0.5),
        reason: 'der Toast deckt die Ergebniskarte');
    final sheet = tester.getRect(find.byKey(const ValueKey('analyse-sheet')));
    expect(toast.bottom, lessThanOrEqualTo(sheet.bottom + 0.5));

    await tester.tap(find.byKey(const ValueKey('analyse-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analyse-sheet')), findsNothing);
  });
}
