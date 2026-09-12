import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

import '../../support/harness.dart';
import '../../support/food_navigation.dart';

// The redesigned section keeps full row targets and an explicit add action.
const double _breite = 390;

MealAnalysisResult _ergebnis() => const MealAnalysisResult(
  mealName: 'Haferbrei',
  caloriesKcal: 320,
  estimatedGrams: 250,
  kcalPer100G: 128,
  protein: '12 g',
  carbs: '48 g',
  fat: '6 g',
  confidence: 'high',
  portionNotes: '',
);

LoggedMeal _mahlzeit(String id) => LoggedMeal(
  id: id,
  result: _ergebnis(),
  loggedAt: DateTime(2026, 8, 21, 12, 30),
  forcedSlot: MealSlot.lunch,
);

Future<void> _pump(
  WidgetTester tester, {
  required bool mitEintrag,
  double textScale = 1.0,
  ValueChanged<MealSlot>? onAddToSlot,
  ValueChanged<String>? onRemoveMeal,
}) async {
  tester.view.physicalSize = const Size(_breite * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    DiaryMealCard(
      slot: MealSlot.lunch,
      entries: mitEintrag
          ? <DiaryEntry>[DiaryEntry(_mahlzeit('m1'), 0)]
          : const <DiaryEntry>[],
      onAddToSlot: onAddToSlot ?? (_) {},
      onRemoveMeal: onRemoveMeal,
    ),
    textScale: textScale,
    // Same 20/12 shell padding as the food tab in EatovaHomePage.
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  await tester.pump();
}

final Finder _knopf = find.byKey(const ValueKey('food-slot-add-lunch'));

void main() {
  // The geometry claims are only worth something with the real app fonts: the
  // headless test font is about twice as wide (see diary_meal_card_macros).
  setUpAll(() async {
    final archivo = FontLoader('Archivo');
    for (final datei in const <String>[
      'assets/fonts/Archivo-Regular.ttf',
      'assets/fonts/Archivo-Medium.ttf',
      'assets/fonts/Archivo-SemiBold.ttf',
      'assets/fonts/Archivo-Bold.ttf',
    ]) {
      archivo.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    final bricolage = FontLoader('BricolageGrotesque');
    for (final datei in const <String>[
      'assets/fonts/BricolageGrotesque-Bold.ttf',
      'assets/fonts/BricolageGrotesque-ExtraBold.ttf',
    ]) {
      bricolage.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    await Future.wait(<Future<void>>[archivo.load(), bricolage.load()]);
  });

  group('Mahlzeitenbereich', () {
    testWidgets('der ganze gefuellte Kopf klappt die Eintraege auf', (
      tester,
    ) async {
      await _pump(tester, mitEintrag: true);
      final toggle = find.byKey(const ValueKey('food-slot-toggle-lunch'));
      final target = tester.getRect(toggle);
      expect(target.width, greaterThan(300));
      expect(target.height, greaterThanOrEqualTo(44));
      expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
      await tester.tapAt(target.topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('food-history-entry-0')),
        findsOneWidget,
      );
    });

    testWidgets('Hinzufuegen hat ein grosses Ziel und bucht genau einmal', (
      tester,
    ) async {
      final booked = <MealSlot>[];
      await _pump(tester, mitEintrag: true, onAddToSlot: booked.add);
      await expandFoodEntries(tester);
      final target = tester.getRect(_knopf);
      expect(target.width, greaterThanOrEqualTo(44));
      expect(target.height, greaterThanOrEqualTo(44));
      await tester.tap(_knopf);
      await tester.pump();
      expect(booked, [MealSlot.lunch]);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('der leere Bereich bleibt bei $scale lesbar und antippbar', (
        tester,
      ) async {
        final booked = <MealSlot>[];
        await _pump(
          tester,
          mitEintrag: false,
          textScale: scale,
          onAddToSlot: booked.add,
        );
        final size = tester.getSize(_knopf);
        expect(size.width, greaterThan(300));
        expect(size.height, greaterThanOrEqualTo(44));
        await tester.tap(_knopf);
        await tester.pump();
        expect(booked, [MealSlot.lunch]);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('ohne Add-Callback bleiben vorhandene Eintraege lesbar', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        DiaryMealCard(
          slot: MealSlot.lunch,
          entries: [DiaryEntry(_mahlzeit('m1'), 0)],
        ),
      );
      await expandFoodEntries(tester);
      expect(_knopf, findsNothing);
      expect(
        find.byKey(const ValueKey('food-history-entry-0')),
        findsOneWidget,
      );
    });
  });

  group('Weitere Bedienelemente der Karte', () {
    testWidgets('Tagebuchzeile und Loeschaktion liegen ueber dem Boden', (
      tester,
    ) async {
      await _pump(tester, mitEintrag: true, onRemoveMeal: (_) {});

      await expandFoodEntries(tester);
      final zeile = find.byKey(const ValueKey('food-history-entry-0'));
      expect(
        tester
            .getSize(find.descendant(of: zeile, matching: find.byType(InkWell)))
            .height,
        greaterThanOrEqualTo(44.0),
      );

      await tester.drag(zeile, const Offset(-300, 0));
      await tester.pumpAndSettle();

      final loeschen = tester.getSize(
        find.byKey(const ValueKey('food-history-delete-0')),
      );
      expect(loeschen.width, greaterThanOrEqualTo(44.0));
      expect(loeschen.height, greaterThanOrEqualTo(44.0));
    });
  });
}
