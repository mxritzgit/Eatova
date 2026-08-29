// P8-03: the adjustment sheet ALWAYS pops a `List<MealComponent>` — for a
// result without an itemized breakdown it synthesizes exactly one component
// from the meal itself. Feeding that back through `adjustedToItems` gave a
// barcode product an `items` list, so a pure weight change made the card claim
// "BESTANDTEILE · 1" over a row that only repeated the product name, the
// portion line said "über Einzelposten angepasst" and the note claimed
// components had been confirmed.
//
// `mealPortionAdjustment` tells the two cases apart, so the weight-only round
// goes through `adjustedToGrams` (items stay empty) while a real breakdown
// keeps behaving exactly as before.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

/// Barcode hit WITHOUT components — 100 g / 300 kcal, so 150 g is exactly
/// 450 kcal and no rounding hides a mistake.
const MealAnalysisResult _produkt = MealAnalysisResult(
  mealName: 'Haferflocken · Kölln',
  caloriesKcal: 300,
  estimatedGrams: 100,
  kcalPer100G: 300,
  protein: '13 g',
  carbs: '59 g',
  fat: '7 g',
  confidence: 'database',
  portionNotes: 'offProductNote:{"barcode":"4000540000000"}',
  sourceLabel: 'OpenFoodFacts',
  barcode: '4000540000000',
);

/// Photo scan WITH real components — the counter-check: 200 g potatoes down to
/// 100 g must stay an itemized adjustment.
const MealAnalysisResult _teller = MealAnalysisResult(
  mealName: 'Teller mit Steak und Kartoffeln',
  caloriesKcal: 820,
  estimatedGrams: 500,
  kcalPer100G: 164,
  protein: '64 g',
  carbs: '42 g',
  fat: '38 g',
  confidence: 'medium',
  portionNotes: 'Test.',
  sourceLabel: 'photoAi',
  items: [
    MealComponent(
      name: 'Kartoffeln',
      grams: 200,
      caloriesKcal: 160,
      kcalPer100G: 80,
    ),
    MealComponent(
      name: 'Steak',
      grams: 300,
      caloriesKcal: 660,
      kcalPer100G: 220,
    ),
  ],
);

/// Captures the rescaled result the sheet hands back to the store.
MealAnalysisResult? _zuletztAktualisiert;

/// Opens the analysis sheet on its REAL modal route and resolves the analysis.
Future<void> _oeffneSheet(
  WidgetTester tester,
  MealAnalysisResult result,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _zuletztAktualisiert = null;

  // The adjust sheet's item rows overflow in this viewport (known, Paket D).
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

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
            onAdd: (_, __) => 'id-1',
            onUpdateMeal: (_, scaled) => _zuletztAktualisiert = scaled,
            failureMessage: _de.foodAnalysisFailedMessage,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  completer.complete(result);
  await tester.pumpAndSettle();
  expect(find.byType(MealResultCard), findsOneWidget);
}

Future<void> _tippen(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// "Hinzufügen", then "Anpassen", set the first weight and apply.
Future<void> _anpassenAuf(WidgetTester tester, String gramm) async {
  await _tippen(tester, 'analyse-add-daily-button');
  await _tippen(tester, 'analyse-adjust-button');
  await tester.enterText(
    find.byKey(const ValueKey('analyse-item-weight-input-0')),
    gramm,
  );
  await tester.pumpAndSettle();
  await _tippen(tester, 'analyse-save-weight-button');
}

void main() {
  setUp(SnackHost.debugResetHosts);

  testWidgets(
      'Produkt ohne Bestandteile: reine Gewichtsänderung zeigt keine '
      '„BESTANDTEILE · 1"', (tester) async {
    await _oeffneSheet(tester, _produkt);
    await _anpassenAuf(tester, '150');

    // Die Karte behauptet keine Zerlegung, die es nie gab.
    expect(find.text(_de.foodIngredientsCountLabel(1)), findsNothing);
    expect(find.byKey(const ValueKey('analyse-item-breakdown')), findsNothing);
    expect(find.text(_de.foodPortionItemizedAdjusted(150)), findsNothing);
    expect(find.text(_de.foodPortionManuallyAdjusted(150)), findsOneWidget);

    // Der Toast nennt den Weg — und der war das Gesamtgewicht.
    expect(find.text(_de.foodPortionAdjustedUpdated(150)), findsOneWidget);
    expect(find.text(_de.foodPortionAdjustedItemsUpdated(150)), findsNothing);

    // Und die Zahlen stimmen weiterhin: 100 g/300 kcal -> 150 g/450 kcal.
    final aktualisiert = _zuletztAktualisiert;
    expect(aktualisiert, isNotNull);
    expect(aktualisiert!.estimatedGrams, 150);
    expect(aktualisiert.caloriesKcal, 450);
    expect(aktualisiert.items, isEmpty);
    expect(aktualisiert.hasItemizedBreakdown, isFalse);
    // Der Info-Absatz „Einzelne Bestandteile wurden manuell bestätigt…" darf
    // für ein reines Gewicht nicht entstehen.
    expect(aktualisiert.portionNotes, contains('Manuell angepasst'));
    expect(aktualisiert.portionNotes, isNot(contains('Bestandteile')));
  });

  testWidgets(
      'Gegenprobe: echte Bestandteile bleiben eine Einzelposten-Anpassung',
      (tester) async {
    await _oeffneSheet(tester, _teller);
    expect(find.byKey(const ValueKey('analyse-item-breakdown')), findsOneWidget);

    // Kartoffeln 200 g -> 100 g: 80 kcal weniger, 740 kcal / 400 g.
    await _anpassenAuf(tester, '100');

    expect(find.text(_de.foodIngredientsCountLabel(2)), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-item-breakdown')), findsOneWidget);
    expect(find.text(_de.foodPortionItemizedAdjusted(400)), findsOneWidget);
    expect(find.text(_de.foodPortionAdjustedItemsUpdated(400)), findsOneWidget);
    expect(find.text(_de.foodPortionAdjustedUpdated(400)), findsNothing);

    final aktualisiert = _zuletztAktualisiert;
    expect(aktualisiert, isNotNull);
    expect(aktualisiert!.estimatedGrams, 400);
    expect(aktualisiert.caloriesKcal, 740);
    expect(aktualisiert.items, hasLength(2));
    expect(aktualisiert.hasItemizedBreakdown, isTrue);
  });

  group('mealPortionAdjustment', () {
    test('Abbruch und leere Liste ergeben null', () {
      expect(mealPortionAdjustment(_produkt, null), isNull);
      expect(mealPortionAdjustment(_produkt, const <MealComponent>[]), isNull);
    });

    test('nur der synthetisierte Posten zurück = reine Gewichtsanpassung', () {
      final applied = mealPortionAdjustment(_produkt, [
        _produkt.asSingleComponent.adjustedToGrams(150),
      ]);
      expect(applied, isNotNull);
      expect(applied!.isWeightOnly, isTrue);
      expect(applied.result.items, isEmpty);
      expect(applied.result.estimatedGrams, 150);
    });

    test('unverändert bestätigen bleibt ebenfalls eine Gewichtsanpassung', () {
      final applied = mealPortionAdjustment(_produkt, [
        _produkt.asSingleComponent.adjustedToGrams(100),
      ]);
      expect(applied!.isWeightOnly, isTrue);
      expect(applied.result.items, isEmpty);
      expect(applied.result.caloriesKcal, _produkt.caloriesKcal);
    });

    test(
        'ein selbst angelegter Posten anstelle des synthetisierten ist eine '
        'echte Zerlegung', () {
      final applied = mealPortionAdjustment(_produkt, const [
        MealComponent(
          name: 'Haferflocken · Kölln',
          grams: 150,
          caloriesKcal: 700,
          kcalPer100G: 466.7,
        ),
      ]);
      expect(applied!.isWeightOnly, isFalse);
      expect(applied.result.items, hasLength(1));
      expect(applied.result.caloriesKcal, 700);
    });

    // P8-03b: der Vergleich liess proteinG/carbsG/fatG aus. Ein Posten mit
    // exakt gleichem Namen und exakt proportionalen kcal, aber eigenen Makros,
    // unterschied sich in nichts anderem — er lief über den Gewichtsweg,
    // `items` blieb leer und die getippten Nährwerte waren still weg.
    test('eigene Makros am synthetischen Posten sind eine echte Zerlegung', () {
      final basis = _produkt.asSingleComponent.adjustedToGrams(100);
      final applied = mealPortionAdjustment(_produkt, [
        MealComponent(
          name: basis.name,
          grams: basis.grams,
          caloriesKcal: basis.caloriesKcal,
          kcalPer100G: basis.kcalPer100G,
          proteinG: 5,
          carbsG: 5,
          fatG: 5,
        ),
      ]);

      expect(
        applied!.isWeightOnly,
        isFalse,
        reason: 'Über den Gewichtsweg fallen die Makros ersatzlos weg.',
      );
      expect(applied.result.items, hasLength(1));
      expect(applied.result.protein, '5 g');
      expect(applied.result.carbs, '5 g');
      expect(applied.result.fat, '5 g');
    });

    test('ohne Makros bleibt der identische Posten reine Gewichtsanpassung', () {
      final applied = mealPortionAdjustment(_produkt, [
        _produkt.asSingleComponent.adjustedToGrams(180),
      ]);
      expect(applied!.isWeightOnly, isTrue);
      expect(applied.result.items, isEmpty);
      expect(applied.result.estimatedGrams, 180);
    });

    test('ein Ergebnis MIT Posten geht nie über den Gewichtsweg', () {
      final applied = mealPortionAdjustment(_teller, [_teller.items.first]);
      expect(applied!.isWeightOnly, isFalse);
      expect(applied.result.hasItemizedBreakdown, isTrue);
    });
  });
}
