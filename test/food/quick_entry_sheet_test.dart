// E4 and E5 in the sheets: the quick-entry mode of the manual sheet, the
// scanned code it saves under, changing a quick entry's totals from the edit
// sheet, and the weightless row in recents. Large type at 320 px must not
// overflow.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/persisted_labels.dart';
import 'package:eatova/src/widgets/design/design.dart' show PrimaryActionButton;
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/harness.dart';

final DateTime _now = DateTime(2026, 10, 18, 19, 30);
const _code = '0036000291452';

class _Halter {
  MealAnalysisResult? result;
}

Widget _opener(
  _Halter halter, {
  String? barcode,
  MealAnalysisResult? initial,
}) => Builder(
  builder: (context) => Center(
    child: TextButton(
      key: const ValueKey('open-manual'),
      onPressed: () async {
        halter.result = await showManualMealSheet(
          context,
          barcode: barcode,
          initial: initial,
        );
      },
      child: const Text('open'),
    ),
  ),
);

Future<_Halter> _open(
  WidgetTester tester, {
  String? barcode,
  MealAnalysisResult? initial,
}) async {
  final halter = _Halter();
  await pumpLocalized(
    tester,
    _opener(halter, barcode: barcode, initial: initial),
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return halter;
}

PrimaryActionButton _save(WidgetTester tester) =>
    tester.widget<PrimaryActionButton>(
      find.byKey(const ValueKey('manual-meal-save')),
    );

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
  await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

MealAnalysisResult _quick() => MealAnalysisResult.quickEntry(
  name: 'Pizza Diavola',
  caloriesKcal: 1150,
  proteinG: 45,
  carbsG: 120.5,
);

void main() {
  group('Manuell-Blatt im Schnell-Modus', () {
    testWidgets('Name optional, kcal Pflicht, Werte als Gesamtwerte', (
      tester,
    ) async {
      final halter = await _open(tester);
      expect(find.text(deL10n.foodManualEntrySubtitle), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('manual-mode-quick')));
      await tester.pumpAndSettle();
      expect(find.text(deL10n.foodQuickSubtitle), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-meal-grams')), findsNothing);
      expect(find.byKey(const ValueKey('manual-portion-panel')), findsNothing);
      expect(_save(tester).onTap, isNull, reason: 'ohne kcal gesperrt');

      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal-total')),
        '1150',
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-carbs-total')),
        '120,5',
      );
      await tester.pump();
      expect(_save(tester).onTap, isNotNull, reason: 'Name ist optional');

      await _tapSave(tester);
      final r = halter.result!;
      expect(r.isQuickEntry, isTrue);
      expect(r.mealName, PersistedLabels.quickEntryName);
      expect(r.caloriesKcal, 1150);
      expect(r.estimatedGrams, 0);
      expect(r.carbs, '120,5 g');
      expect(r.protein, '-');
    });

    testWidgets('zu viel kcal wird abgelehnt, mit Tausendertrennzeichen', (
      tester,
    ) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('manual-mode-quick')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal-total')),
        '12000',
      );
      await tester.pump();
      expect(find.text('0–10.000 kcal'), findsOneWidget);
      expect(_save(tester).onTap, isNull);
    });

    testWidgets('der Umschalter vermischt keine Pro-100-g-Werte', (
      tester,
    ) async {
      final halter = await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')),
        'Quark',
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')),
        '67',
      );
      await tester.tap(find.byKey(const ValueKey('manual-mode-quick')));
      await tester.pumpAndSettle();
      expect(_fieldText(tester, 'manual-meal-kcal-total'), isEmpty);
      expect(_save(tester).onTap, isNull);

      await tester.tap(find.byKey(const ValueKey('manual-mode-per100')));
      await tester.pumpAndSettle();
      expect(_fieldText(tester, 'manual-meal-kcal100'), '67');
      await _tapSave(tester);
      expect(halter.result!.isQuickEntry, isFalse);
      expect(halter.result!.caloriesKcal, 67);
    });

    testWidgets('die Modus-Chips sagen dem Screenreader, welcher gilt', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _open(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('manual-mode-per100'))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );
      await tester.tap(find.byKey(const ValueKey('manual-mode-quick')));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('manual-mode-quick'))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );
      semantics.dispose();
    });
  });

  group('Barcode und Vorbelegung (E5)', () {
    testWidgets('ein uebergebener Code steht im Blatt und im Ergebnis', (
      tester,
    ) async {
      final halter = await _open(tester, barcode: _code);
      expect(
        find.text(deL10n.foodOwnProductBarcodeNote(_code)),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')),
        'Hofmilch',
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')),
        '64',
      );
      await tester.pump();
      await _tapSave(tester);

      final r = halter.result!;
      expect(r.barcode, _code);
      expect(r.isOwnProduct, isTrue);
      expect(r.resolvedSourceLabel(deL10n), 'Eigenes Produkt');
    });

    testWidgets('ein eigenes Produkt fuellt das Blatt zum Aendern vor', (
      tester,
    ) async {
      const own = MealAnalysisResult(
        mealName: 'Hofmilch',
        caloriesKcal: 160,
        estimatedGrams: 250,
        kcalPer100G: 64,
        protein: '8,5 g',
        carbs: '12 g',
        fat: '9 g',
        confidence: 'manual',
        portionNotes: 'manualEntryNote',
        sourceLabel: 'manual',
        barcode: _code,
        proteinPer100G: 3.4,
        carbsPer100G: 4.8,
        fatPer100G: 3.6,
      );
      await _open(tester, barcode: _code, initial: own);
      expect(_fieldText(tester, 'manual-meal-name'), 'Hofmilch');
      expect(_fieldText(tester, 'manual-meal-kcal100'), '64');
      expect(_fieldText(tester, 'manual-meal-grams'), '250');
      expect(_fieldText(tester, 'manual-meal-protein'), '3,4');
      expect(_fieldText(tester, 'manual-meal-fat'), '3,6');
    });

    testWidgets('ein Schnell-Eintrag oeffnet im Schnell-Modus vorbelegt', (
      tester,
    ) async {
      await _open(tester, initial: _quick());
      expect(find.text(deL10n.foodQuickSubtitle), findsOneWidget);
      expect(_fieldText(tester, 'manual-meal-name'), 'Pizza Diavola');
      expect(_fieldText(tester, 'manual-meal-kcal-total'), '1150');
      expect(_fieldText(tester, 'manual-meal-protein-total'), '45');
      expect(_fieldText(tester, 'manual-meal-carbs-total'), '120,5');
      expect(_fieldText(tester, 'manual-meal-fat-total'), isEmpty);
    });
  });

  testWidgets('Bearbeiten: Werte eines Schnell-Eintrags aendern', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      MealAnalysisResult? saved;
      final meal = LoggedMeal(
        id: 'meal-1',
        result: _quick(),
        loggedAt: _now,
        forcedSlot: MealSlot.dinner,
      );
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEditMealSheet(
                context,
                meal: meal,
                onUpdateMeal: (id, {result, slot, day}) {
                  saved = result;
                  return meal.copyWith(result: result);
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('edit-meal-adjust-button')),
        findsNothing,
      );
      expect(find.text(deL10n.foodQuickNoWeightHint), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('edit-meal-summary-figure')),
            )
            .data,
        '1150 kcal · 1 Portion',
      );

      await tester.tap(find.byKey(const ValueKey('edit-meal-quick-values')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal-total')),
        '900',
      );
      await tester.pump();
      await _tapSave(tester);

      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('edit-meal-summary-figure')),
            )
            .data,
        '900 kcal · 1 Portion',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('edit-meal-save-button')),
      );
      await tester.tap(find.byKey(const ValueKey('edit-meal-save-button')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.caloriesKcal, 900);
      expect(saved!.isQuickEntry, isTrue);
      expect(saved!.mealName, 'Pizza Diavola');
      expect(saved!.protein, '45 g');
    });
  });

  testWidgets(
    'Zuletzt-Zeile: ohne Gramm-Regler, eingetragen wird unveraendert',
    (tester) async {
      final logged = <MealAnalysisResult>[];
      await pumpLocalized(
        tester,
        Center(
          child: SizedBox(
            width: 360,
            child: MealSuggestionItem(
              result: _quick(),
              expanded: true,
              onTap: () {},
              onAdd: logged.add,
              addButtonKey: const ValueKey('quick-add'),
            ),
          ),
        ),
        safeArea: false,
        settle: true,
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.text(deL10n.foodQuickNoWeightHint), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-add')));
      await tester.pump();
      expect(logged.single.caloriesKcal, 1150);
      expect(logged.single.estimatedGrams, 0);
    },
  );

  group('grosse Schrift bei 320 px', () {
    renderMatrix(
      'Manuell-Blatt mit Barcode in beiden Modi',
      (tester, c) async {
        final halter = _Halter();
        await c.pump(
          tester,
          _opener(halter, barcode: _code),
          surfaceSize: const Size(320, 640),
          safeArea: false,
          settle: true,
        );
        await tester.tap(find.byKey(const ValueKey('open-manual')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('manual-meal-barcode-note')),
          findsOneWidget,
        );
        // Stacked chips at large type; the second one sits below the first.
        final per100 = tester.getRect(
          find.byKey(const ValueKey('manual-mode-per100')),
        );
        final quick = tester.getRect(
          find.byKey(const ValueKey('manual-mode-quick')),
        );
        expect(quick.top, greaterThanOrEqualTo(per100.bottom));
        await tester.tap(find.byKey(const ValueKey('manual-mode-quick')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('manual-meal-fat-total')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      locales: const [Locale('de'), Locale('en')],
      brightnesses: const [Brightness.dark],
      textScales: const [2.0],
    );

    renderMatrix(
      'Bearbeiten-Blatt eines Schnell-Eintrags',
      (tester, c) async {
        await withClock(Clock.fixed(_now), () async {
          final meal = LoggedMeal(
            id: 'meal-1',
            result: _quick(),
            loggedAt: _now,
            forcedSlot: MealSlot.dinner,
          );
          await c.pump(
            tester,
            Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showEditMealSheet(
                    context,
                    meal: meal,
                    onUpdateMeal: (id, {result, slot, day}) => meal,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            surfaceSize: const Size(320, 640),
            safeArea: false,
            settle: true,
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('edit-meal-quick-values')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      },
      brightnesses: const [Brightness.dark],
      textScales: const [2.0],
    );
  });
}
