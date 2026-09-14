import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clock/clock.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'support/harness.dart';

final _today = DateTime(2026, 9, 14);
final _boundary = GlobalKey();
Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('FOOD_POLISH_CAPTURE')) return;
  await tester.pumpAndSettle();
  final boundary =
      _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/food-entry-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  String locale = 'en',
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = scale == 1
      ? const Size(390, 844)
      : const Size(320, 568);
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: localizedApp(
        child,
        brightness: brightness,
        locale: Locale(locale),
        textScale: scale,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _product = MealAnalysisResult(
  mealName: 'Greek yoghurt with vanilla',
  brand: 'The Dairy',
  caloriesKcal: 120,
  estimatedGrams: 100,
  kcalPer100G: 120,
  protein: '10 g',
  carbs: '8 g',
  fat: '5 g',
  confidence: 'database',
  portionNotes: '',
);

class _Catalog implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async => _product;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [
    for (final (code, name, brand, kcal) in [
      ('1001', 'Greek yoghurt with vanilla', 'The Dairy', 120),
      ('1002', 'Natural Greek yoghurt', 'Everyday', 96),
      ('1003', 'Greek style yoghurt with honey', 'Breakfast Club', 142),
    ])
      ProductSearchResult.fromOpenFoodFacts({
        'code': code,
        'product_name': name,
        'brands': brand,
        'serving_quantity': 100,
        'nutriments': {
          'energy-kcal_100g': kcal,
          'proteins_100g': 10,
          'carbohydrates_100g': 8,
          'fat_100g': 5,
        },
      }),
  ];
}

void main() {
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final family in ['Archivo', 'BricolageGrotesque']) {
      final loader = FontLoader(family);
      for (final weight
          in family == 'Archivo'
              ? ['Regular', 'Medium', 'SemiBold', 'Bold']
              : ['Bold', 'ExtraBold']) {
        loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
      }
      await loader.load();
    }
  });

  testWidgets(
    'search results keep product identity and save the shown portion',
    (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final logged = <MealAnalysisResult>[];
        await _mount(
          tester,
          MealAnalysisScreen(
            dailyConsumedKcal: 0,
            selectedDate: _today,
            productService: _Catalog(),
            onAddMeal: (result, slot) {
              logged.add(result);
              return 'logged';
            },
          ),
        );
        await tester.tap(_key('food-search'));
        await tester.pumpAndSettle();
        await tester.enterText(
          _key('kcal-product-search-input'),
          'Greek yoghurt',
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(find.byType(MealSuggestionItem), findsNWidgets(3));
        await _capture(tester, 'search-results');
        await tester.tap(find.text('Greek yoghurt with vanilla'));
        await tester.pumpAndSettle();
        final portion = find.descendant(
          of: _key('kcal-product-suggestion-0'),
          matching: find.byType(TextField),
        );
        await tester.enterText(portion, '250');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await _capture(tester, 'search-portion');
        await tester.ensureVisible(_key('kcal-product-suggestion-add-0'));
        await tester.tap(_key('kcal-product-suggestion-add-0'));
        await tester.pumpAndSettle();
        expect(
          logged.single.mealName,
          'Greek yoghurt with vanilla · The Dairy',
        );
        expect(logged.single.caloriesKcal, 300);
        expect(logged.single.estimatedGrams, 250);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'product density uses the same authoritative energy as its portion',
    (tester) async {
      const result = MealAnalysisResult(
        mealName: 'Test product',
        caloriesKcal: 300,
        estimatedGrams: 200,
        kcalPer100G: 90,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'database',
        portionNotes: '',
      );
      await _mount(
        tester,
        MealSuggestionItem(
          result: result,
          productPresentation: true,
          expanded: true,
          onTap: () {},
          onAdd: (_) {},
        ),
      );
      expect(find.text('150 kcal / 100 g'), findsOneWidget);
      expect(find.text('300 kcal'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    for (final locale in ['de', 'en']) {
      for (final scale in [1.0, 2.0]) {
        final id = '${brightness.name}-$locale-$scale';
        testWidgets('manual draft, slot and computed portion survive $id', (
          tester,
        ) async {
          var slot = MealSlot.lunch;
          MealAnalysisResult? saved;
          await _mount(
            tester,
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showManualMealSheet(
                    context,
                    initialName: 'Greek yoghurt',
                    initialSlot: slot,
                    onSlotChanged: (value) => slot = value,
                    contextLabel: '14.09.2026',
                  );
                },
                child: const Text('Open'),
              ),
            ),
            brightness: brightness,
            locale: locale,
            scale: scale,
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final title = tester.renderObject<RenderParagraph>(
            _key('manual-meal-title'),
          );
          expect(
            title.getMinIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(title.size.width + .1),
            reason: 'The enlarged title keeps whole words readable.',
          );
          await _capture(tester, 'manual-start-$id');
          await tester.enterText(_key('manual-meal-kcal100'), '120');
          await tester.enterText(_key('manual-meal-protein'), '10,5');
          await tester.enterText(_key('manual-meal-grams'), '250');
          await tester.ensureVisible(_key('manual-slot-open'));
          await tester.tap(_key('manual-slot-open'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(_key('manual-slot-dinner'));
          await tester.tap(_key('manual-slot-dinner'));
          await tester.pumpAndSettle();
          expect(slot, MealSlot.dinner);
          expect(saved, isNull);
          expect(
            tester.widget<TextField>(_key('manual-meal-name')).controller!.text,
            'Greek yoghurt',
          );
          expect(
            tester
                .widget<TextField>(_key('manual-meal-protein'))
                .controller!
                .text,
            '10,5',
          );
          await tester.ensureVisible(_key('manual-meal-name'));
          await _capture(tester, 'manual-$id');
          if (scale == 2) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 220);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(_key('manual-meal-save'));
          await tester.pumpAndSettle();
          expect(_key('manual-meal-save').hitTestable(), findsOneWidget);
          await _capture(tester, 'manual-portion-$id');
          await tester.tap(_key('manual-meal-save'));
          await tester.pumpAndSettle();
          expect(saved!.caloriesKcal, 300);
          expect(saved!.protein, '26,3 g');
          expect(saved!.estimatedGrams, 250);
          expect(tester.takeException(), isNull);
        });

        testWidgets(
          'calendar drafts, today and confirmation remain usable $id',
          (tester) async {
            DateTime? selected;
            await _mount(
              tester,
              Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showFoodDatePicker(
                      context,
                      initialDate: DateTime(2026, 9, 11),
                      firstDate: DateTime(2024, 9, 14),
                      today: _today,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
              brightness: brightness,
              locale: locale,
              scale: scale,
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            final day = find.descendant(
              of: find.byType(CalendarDatePicker),
              matching: find.text('10'),
            );
            await tester.ensureVisible(day);
            await tester.tap(day);
            await tester.pumpAndSettle();
            final number = tester.renderObject<RenderParagraph>(day);
            expect(
              number.getMaxIntrinsicWidth(double.infinity),
              lessThanOrEqualTo(number.size.width + .1),
              reason:
                  'Both digits must remain visible at the requested text size.',
            );
            expect(selected, isNull);
            await _capture(tester, 'calendar-$id');
            expect(_key('food-date-confirm').hitTestable(), findsOneWidget);
            await tester.tap(_key('food-date-today'));
            await tester.pumpAndSettle();
            expect(selected, isNull);
            expect(
              tester
                  .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
                  .initialDate,
              _today,
            );
            await tester.tap(_key('food-date-confirm'));
            await tester.pumpAndSettle();
            expect(selected, _today);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets('product identity, portion, favorites and validation $id', (
          tester,
        ) async {
          final saved = <MealAnalysisResult>[];
          var expanded = false;
          var favorite = false;
          await _mount(
            tester,
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
              child: StatefulBuilder(
                builder: (context, setState) => MealSuggestionItem(
                  result: _product,
                  productPresentation: true,
                  expanded: expanded,
                  onTap: () => setState(() => expanded = !expanded),
                  onAdd: saved.add,
                  addButtonKey: const ValueKey('product-add'),
                  favoriteButtonKey: const ValueKey('product-favorite'),
                  isFavorite: favorite,
                  onToggleFavorite: (_) => setState(() => favorite = !favorite),
                ),
              ),
            ),
            brightness: brightness,
            locale: locale,
            scale: scale,
          );
          expect(find.text('The Dairy'), findsOneWidget);
          expect(find.text('120 kcal / 100 g'), findsOneWidget);
          await _capture(tester, 'product-$id');
          await tester.tap(_key('product-favorite'));
          await tester.pumpAndSettle();
          expect(favorite, isTrue);
          expect(expanded, isFalse);
          await tester.tap(find.text(_product.mealName));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '250');
          await tester.pumpAndSettle();
          expect(find.text('300 kcal'), findsOneWidget);
          await tester.ensureVisible(_key('product-add'));
          await _capture(tester, 'product-portion-$id');
          await tester.enterText(find.byType(TextField), '0');
          await tester.pumpAndSettle();
          expect(
            tester.widget<FilledButton>(_key('product-add')).onPressed,
            isNull,
          );
          await tester.enterText(find.byType(TextField), '250');
          await tester.pumpAndSettle();
          await tester.ensureVisible(_key('product-add'));
          await tester.tap(_key('product-add'));
          await tester.pumpAndSettle();
          expect(saved.single.caloriesKcal, 300);
          expect(saved.single.protein, '25 g');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('manual picker dismissal preserves the current meal', (
    tester,
  ) async {
    await _mount(tester, const ManualMealSheet(initialSlot: MealSlot.lunch));
    await tester.tap(_key('manual-slot-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('manual-slot-close'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
      MealSlot.lunch,
    );
  });

  testWidgets(
    'calendar close cancels; date input rejects future and saves valid day',
    (tester) async {
      DateTime? result;
      await _mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showFoodDatePicker(
                context,
                initialDate: _today,
                firstDate: DateTime(2024, 9, 14),
                today: _today,
              );
            },
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(_key('food-date-close'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(_key('food-date-input-toggle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '09/15/2026');
      await tester.tap(_key('food-date-confirm'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(InputDatePickerFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '09/10/2026');
      await tester.tap(_key('food-date-input-toggle'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .initialDate,
        DateTime(2026, 9, 10),
      );
      expect(result, isNull);
      await tester.tap(_key('food-date-confirm'));
      await tester.pumpAndSettle();
      expect(result, DateTime(2026, 9, 10));
      expect(tester.takeException(), isNull);
    },
  );
}
