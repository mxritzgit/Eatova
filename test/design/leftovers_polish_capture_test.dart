// Visual evidence for the 2026-10-03 follow-up to the design polish: the
// analysis sheet header and the recipe slot picker with the shared slot tile,
// the weight-adjust sheet with the shared handle, and the toggle in its three
// states.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/leftovers-*.png; without it the suite still checks that
// every surface renders without an exception or overflow.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/recipes_design_fixtures.dart';

const _skyr = MealAnalysisResult(
  mealName: 'Skyr, natural',
  caloriesKcal: 158,
  estimatedGrams: 250,
  kcalPer100G: 63,
  protein: '28 g',
  carbs: '10 g',
  fat: '0.5 g',
  confidence: '',
  portionNotes: '',
);

/// Pumps a launcher button at the reference geometry and taps it.
Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('analysis sheet header', (tester) async {
    await _host(
      tester,
      (context) => showMealAnalysisSheet(
        context,
        slot: MealSlot.dinner,
        resultFuture: Future<MealAnalysisResult>.value(_skyr),
        previewImage: null,
        onAdd: (_, __) => 'id',
        onUpdateMeal: (_, __) {},
        failureMessage: 'failed',
      ),
    );
    expect(find.byKey(const ValueKey('analyse-sheet-close')), findsOneWidget);
    expect(
      tester.widget<SlotIconTile>(find.byType(SlotIconTile)).slot,
      MealSlot.dinner,
    );
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'leftovers-analysis');
  });

  testWidgets('weight-adjust sheet', (tester) async {
    await _host(tester, (context) => showWeightAdjustmentSheet(context, _skyr));
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'leftovers-adjust');
  });

  testWidgets('recipe slot picker', (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 18, 30)), () async {
      await pumpDesignRecipes(tester);
      final card = find.byKey(
        ValueKey('recipe-shelf-lean-${designOwnRecipes.first.slug}'),
      );
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('recipe-add-button'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget,
      );
      for (final slot in MealSlot.values) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('recipe-meal-picker-${slot.name}')),
            matching: find.byWidgetPredicate(
              (w) => w is SlotIconTile && w.slot == slot,
            ),
          ),
          findsOneWidget,
          reason: slot.name,
        );
      }
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'leftovers-recipe-picker');
    });
  });

  testWidgets('toggle states', (tester) async {
    pinDesignViewport(tester);
    await tester.pumpWidget(
      designCaptureBoundary(
        localizedApp(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 80, 20, 0),
            child: SettingsGroup(
              label: 'Toggles',
              children: <Widget>[
                for (final (title, value, enabled) in [
                  ('On', true, true),
                  ('Off', false, true),
                  ('Off, locked', false, false),
                  ('On, locked', true, false),
                ])
                  SettingsRow(
                    title: title,
                    chevron: false,
                    trailing: AppToggle(
                      value: value,
                      enabled: enabled,
                      onChanged: (_) {},
                    ),
                  ),
              ],
            ),
          ),
          locale: const Locale('en'),
          safeArea: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'leftovers-toggles');
  });
}
