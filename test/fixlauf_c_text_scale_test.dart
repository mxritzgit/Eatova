// Fix run for review 2026-08-27, F3-05: the add-meal sheet, its slot
// selector and the manual-entry sheet used fixed heights (46/46/56) that
// left no room for large system text. Now `minHeight`, the slot segments
// scale with the text like the edit sheet's day picker. Overflows are
// collected and reported, not swallowed — they are the subject here.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

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

Widget _app(Widget home, double scale) => MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Above the navigator, so modal routes scale too.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

/// Phone viewport plus an overflow collector; returns the collected list.
List<String> _rig(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
  return overflows;
}

Future<List<String>> _pumpAddSheet(WidgetTester tester, double scale) async {
  final overflows = _rig(tester);
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: AddMealSheet(
          slot: MealSlot.snack,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: [
            FavoriteMeal(
              id: FavoriteMeal.idFor(_apfel),
              result: _apfel,
              addedAt: DateTime(2026, 8, 20),
              pinned: true,
            ),
          ],
          existingMeals: [
            LoggedMeal(
              id: 'm-1',
              result: _apfel,
              loggedAt: DateTime.now(),
              forcedSlot: MealSlot.snack,
            ),
          ],
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
          onRemoveMeal: (_) {},
        ),
      ),
      scale,
    ),
  );
  await tester.pumpAndSettle();
  return overflows;
}

Future<List<String>> _openManualSheet(WidgetTester tester, double scale) async {
  final overflows = _rig(tester);
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showManualMealSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      scale,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('manual-meal-save')), findsOneWidget);
  return overflows;
}

void main() {
  for (final scale in const <double>[1.3, 2.0]) {
    testWidgets('Add-Sheet rendert bei textScale $scale ohne Overflow',
        (tester) async {
      final overflows = await _pumpAddSheet(tester, scale);
      expect(overflows, isEmpty, reason: overflows.join('\n'));

      // Search capsule: at least the design height, taller when needed.
      final capsule =
          tester.getSize(find.byKey(const ValueKey('kcal-product-search-card')));
      expect(capsule.height, greaterThanOrEqualTo(46 + 8));
      final input =
          tester.getRect(find.byKey(const ValueKey('kcal-product-search-input')));
      final card =
          tester.getRect(find.byKey(const ValueKey('kcal-product-search-card')));
      expect(input.top, greaterThanOrEqualTo(card.top - 0.5));
      expect(input.bottom, lessThanOrEqualTo(card.bottom + 0.5));

      // Manual-entry row grows with its label instead of clipping it.
      final row = find.byKey(const ValueKey('manual-entry-button'));
      final label = find.descendant(of: row, matching: find.byType(Text));
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(tester.getSize(label).height),
      );
    });

    testWidgets('Slot-Wähler skaliert seine Segmente bei textScale $scale',
        (tester) async {
      await _pumpAddSheet(tester, scale);
      final expected = (56 * scale).clamp(56.0, 80.0);
      final segment =
          tester.getSize(find.byKey(const ValueKey('slot-select-snack')));
      expect(segment.height, moreOrLessEquals(expected, epsilon: 0.5));
      // The label stays inside its segment.
      final text = find.descendant(
        of: find.byKey(const ValueKey('slot-select-snack')),
        matching: find.byType(Text),
      );
      expect(
        tester.getRect(text).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('slot-select-snack'))).bottom +
              0.5,
        ),
      );
    });

    testWidgets('Manuell-Sheet rendert bei textScale $scale ohne Overflow',
        (tester) async {
      final overflows = await _openManualSheet(tester, scale);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });
  }

  testWidgets('bei Normalschrift bleibt der Slot-Wähler exakt 56 hoch',
      (tester) async {
    await _pumpAddSheet(tester, 1.0);
    expect(
      tester.getSize(find.byKey(const ValueKey('slot-select-snack'))).height,
      56,
    );
    expect(find.byType(SlotSelector), findsOneWidget);
  });
}
