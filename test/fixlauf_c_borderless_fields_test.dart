// Fix run for review 2026-08-27, F3-03: the add sheet's search bar and the
// manual-entry fields still drew a hairline (`Border.all(t.line)`). Repo rule:
// input fields are borderless soft capsules — focus lightens the surface,
// an error tints it, and the error text below stays.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

import 'support/harness.dart';

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

/// `reducedMotion: false` keeps the motion behaviour from before the harness
/// migration; the sheets' AnimatedSize re-dirties itself at duration 0.
Widget _app(Widget body, Brightness brightness) => localizedApp(
      body,
      brightness: brightness,
      reducedMotion: false,
      safeArea: false,
    );

void _telefon(WidgetTester tester) => pinPhoneViewport(tester);

/// The nearest decorated capsule around [inner].
BoxDecoration _capsuleOf(WidgetTester tester, Finder inner) {
  final containers = find.ancestor(of: inner, matching: find.byType(Container));
  for (final element in containers.evaluate()) {
    final decoration = (element.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration;
    }
  }
  throw StateError('keine dekorierte Kapsel um $inner');
}

AppTokens _tokens(WidgetTester tester, Finder inner) =>
    AppTokens.of(tester.element(inner));

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Suchleiste des Add-Sheets ist rahmenlos ($brightness)',
        (tester) async {
      _telefon(tester);
      await tester.pumpWidget(
        _app(
          AddMealSheet(
            slot: MealSlot.snack,
            analyzer: _StummerAnalyzer(),
            productService: _StummerProduktdienst(),
            photoInput: _StummeFotoquelle(),
            favorites: const [],
            onAdd: (_, __) => 'id-1',
            onUpdateMeal: (_, __) {},
            onRemoveFavorite: (_) {},
          ),
          brightness,
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byKey(const ValueKey('kcal-product-search-input'));
      final t = _tokens(tester, input);

      // autofocus: the field starts focused -> lifted surface.
      expect(tester.widget<TextField>(input).focusNode?.hasFocus, isTrue);
      var capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'Hairline an der Suchleiste');
      expect(capsule.color, t.fieldFocus);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull);
      expect(capsule.color, t.field);
    });

    testWidgets('Felder des Manuell-Sheets: rahmenlos, Fokus hellt, Fehler tönt '
        '($brightness)', (tester) async {
      _telefon(tester);
      await tester.pumpWidget(_app(const ManualMealSheet(), brightness));
      await tester.pumpAndSettle();

      final grams = find.byKey(const ValueKey('manual-meal-grams'));
      final t = _tokens(tester, grams);

      var capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull, reason: 'Hairline am Gramm-Feld');
      expect(capsule.color, t.field);

      await tester.tap(grams);
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull);
      expect(capsule.color, t.fieldFocus, reason: 'Fokus = Flächen-Aufhellung');

      // Out of range -> error text below AND a danger tint on the surface,
      // still no border.
      await tester.enterText(grams, '99999');
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull);
      expect(capsule.color, t.fieldError, reason: 'Fehler schlägt Fokus');
      expect(find.textContaining('1'), findsWidgets);
      final errorText = find.text(
        AppLocalizations.of(tester.element(grams))
            .recipesRangeErrorGrams(1, 10000),
      );
      expect(errorText, findsOneWidget);
    });
  }
}
