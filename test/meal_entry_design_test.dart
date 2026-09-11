import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:eatova/src/theme/meal_slot_style.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_entry_methods.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';
import 'support/harness.dart';

class _Photos implements MealPhotoInput {
  final sources = <ImageSource>[];
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    sources.add(source);
    return null;
  }
}

class _Analyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw StateError('No analysis before photo confirmation');
}

class _Products implements ProductLookupService {
  Completer<List<ProductSearchResult>>? pending;
  int searches = 0;
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searches++;
    return pending == null ? [] : await pending!.future;
  }
}

const _meal = MealAnalysisResult(
  mealName: 'Skyr',
  caloriesKcal: 200,
  estimatedGrams: 200,
  kcalPer100G: 100,
  protein: '20 g',
  carbs: '12 g',
  fat: '4 g',
  confidence: '',
  portionNotes: '',
);
final _date = DateTime(2026, 9, 9);
Finder _key(String value) => find.byKey(ValueKey(value));
Finder get _input => _key('kcal-product-search-input');

Future<void> _open(
  WidgetTester tester, {
  bool searchMode = false,
  _Photos? photos,
  _Products? products,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('de'),
  double scale = 1,
  double width = 393,
  bool keyboard = false,
}) async {
  tester.view.physicalSize = Size(width, 852);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard ? 300 : 0);
  addTearDown(tester.view.reset);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showAddMealSheet(
          context,
          slot: MealSlot.lunch,
          foodDate: _date,
          searchMode: searchMode,
          analyzer: _Analyzer(),
          photoInput: photos ?? _Photos(),
          productService: products ?? _Products(),
          favorites: [
            for (var i = 0; i < 5; i++)
              FavoriteMeal(
                id: 'favorite-$i',
                result: _meal,
                addedAt: _date,
                pinned: true,
              ),
          ],
          onAdd: (_, __) => 'id',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
        ),
        child: const Text('open'),
      ),
    ),
    brightness: brightness,
    locale: locale,
    textScale: scale,
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final searchMode in [false, true]) {
    testWidgets('keyboard focus follows entry intent: search=$searchMode', (
      tester,
    ) async {
      await _open(tester, searchMode: searchMode);
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, searchMode);
      expect(
        _key('analyse-camera-button'),
        searchMode ? findsNothing : findsOneWidget,
      );
      final context = tester.element(_input);
      final date = MaterialLocalizations.of(context).formatMediumDate(_date);
      expect(
        tester.widget<Text>(_key('add-meal-date-context')).data,
        '$date · ${MealSlot.lunch.label(context.l10n)}',
      );
      await tester.tap(_input);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
    });
  }

  testWidgets(
    'capture choices call the intended photo source without logging',
    (tester) async {
      final photos = _Photos();
      await _open(tester, photos: photos);
      for (final source in [ImageSource.camera, ImageSource.gallery]) {
        final action = _key(
          source == ImageSource.camera
              ? 'analyse-camera-button'
              : 'analyse-gallery-button',
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(photos.sources.last, source);
        expect(_key('add-meal-sheet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(photos.sources, [ImageSource.camera, ImageSource.gallery]);
    },
  );

  testWidgets(
    'clear cancels a pending search and restores choices at the selected slot',
    (tester) async {
      final products = _Products()
        ..pending = Completer<List<ProductSearchResult>>();
      await _open(tester, products: products);
      await tester.tap(_key('slot-select-dinner'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('favorite-pinned-2'));
      await tester.pumpAndSettle();
      await tester.enterText(_input, 'Skyr');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(products.searches, 1);
      expect(find.byType(MealEntryMethods), findsNothing);
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: _key('add-meal-sheet-scroll'),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.pixels, 0);
      await tester.tap(_key('kcal-product-search-clear'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
      expect(
        tester.widget<SlotSelector>(find.byType(SlotSelector)).selected,
        MealSlot.dinner,
      );
      expect(find.byType(MealEntryMethods), findsOneWidget);
      expect(_key('product-search-spinner'), findsNothing);
      products.pending!.complete([
        const ProductSearchResult(
          code: 'stale',
          title: 'Old result',
          subtitle: '',
          kcalPer100G: 100,
          result: _meal,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(_key('kcal-product-suggestion-0'), findsNothing);
      expect(scroll.position.pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      testWidgets(
        'all entry paths reachable at 320px, 2x text and keyboard: $brightness $locale',
        (tester) async {
          await _open(
            tester,
            brightness: brightness,
            locale: locale,
            width: 320,
            scale: 2,
            keyboard: true,
          );
          final sheet = tester.getRect(_key('add-meal-sheet'));
          expect(sheet.top, greaterThanOrEqualTo(44));
          expect(sheet.bottom, lessThanOrEqualTo(552));
          for (final key in [
            'slot-select-dinner',
            'analyse-camera-button',
            'analyse-gallery-button',
            'analyse-barcode-button',
            'manual-entry-button',
            'favorite-pinned-0',
          ]) {
            final action = _key(key);
            // A large-text card can exceed the keyboard's remaining viewport.
            // Its label must still be reachable and tappable while scrolling.
            final label = find
                .descendant(of: action, matching: find.byType(Text))
                .first;
            await tester.ensureVisible(label);
            await tester.pumpAndSettle();
            expect(label.hitTestable(), findsOneWidget, reason: key);
            expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
            expect(tester.takeException(), isNull);
          }
          expect(_key('add-meal-sheet-close').hitTestable(), findsOneWidget);
          expect(_input.hitTestable(), findsOneWidget);
        },
      );
    }
  }

  for (final reduce in [false, true]) {
    testWidgets(
      'method buttons support semantics and reduced motion: $reduce',
      (tester) async {
        var calls = 0;
        final semantics = tester.ensureSemantics();
        await pumpLocalized(
          tester,
          MealEntryMethods(
            onCamera: () => calls++,
            onGallery: () => calls++,
            onBarcode: () => calls++,
          ),
          reducedMotion: reduce,
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        final action = _key('analyse-camera-button');
        expect(tester.getSemantics(action).label, contains('Foto aufnehmen'));
        final gesture = await tester.startGesture(tester.getCenter(action));
        await tester.pump(const Duration(milliseconds: 150));
        final scale = find.ancestor(
          of: action,
          matching: find.byType(AnimatedScale),
        );
        expect(tester.widget<AnimatedScale>(scale).scale, reduce ? 1 : .985);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(tester.widget<AnimatedScale>(scale).scale, 1);
        for (final key in [
          'analyse-gallery-button',
          'analyse-barcode-button',
        ]) {
          await tester.tap(_key(key));
          await tester.pumpAndSettle();
        }
        expect(calls, 3);
        semantics.dispose();
      },
    );
  }
}
