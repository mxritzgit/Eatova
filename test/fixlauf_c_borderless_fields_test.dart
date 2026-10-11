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

/// WCAG contrast ratio of two opaque colours.
double _kontrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

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

      // Normal entry starts at rest; a deliberate tap lifts the field.
      expect(tester.widget<TextField>(input).focusNode?.hasFocus, isFalse);
      var capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'Hairline an der Suchleiste');
      expect(capsule.color, t.field);
      await tester.tap(input);
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, input);
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

      // The label fields off the panel keep the plain field language.
      final kcal = find.byKey(const ValueKey('manual-meal-kcal100'));
      expect(_capsuleOf(tester, kcal).color, t.field);

      // The portion field sits on the brandSurface panel, where field and
      // fieldFocus all but vanished (1.00:1 light) and focus even moved the
      // fill toward the panel (review 2026-10-11). It rests on `bg` and
      // focuses to `surf`: off the panel, and a visible step apart.
      var capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull, reason: 'Hairline am Gramm-Feld');
      expect(capsule.color, t.bg);
      expect(_kontrast(capsule.color!, t.brandSurface), greaterThan(1.12));

      await tester.tap(grams);
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull);
      expect(capsule.color, t.surf, reason: 'Fokus = Flächen-Aufhellung');
      expect(_kontrast(capsule.color!, t.bg), greaterThan(1.05));
      // The old fieldFocus measured 1.04:1 on the dark panel: focused, the
      // field melted into it.
      expect(
        _kontrast(capsule.color!, t.brandSurface),
        greaterThan(1.2),
        reason: 'der fokussierte Grund bleibt klar vom Panel abgesetzt',
      );

      // Out of range -> error text below AND a danger tint on the surface,
      // still no border.
      await tester.enterText(grams, '99999');
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, grams);
      expect(capsule.border, isNull);
      expect(
        capsule.color,
        Color.alphaBlend(t.danger.withValues(alpha: 0.2), t.surf),
        reason: 'Fehler schlägt Fokus',
      );
      // 12 % danger on the dark bg stayed a near-black well, 1.16:1 to the
      // resting field and 1.08:1 to the focused one (review 2026-10-11):
      // only the line below marked the error.
      expect(_kontrast(capsule.color!, t.bg), greaterThan(1.2));
      expect(_kontrast(capsule.color!, t.surf), greaterThan(1.2));
      expect(_kontrast(t.ink2, capsule.color!), greaterThanOrEqualTo(4.5));
      expect(find.textContaining('1'), findsWidgets);
      final errorText = find.text(
        AppLocalizations.of(tester.element(grams))
            .recipesRangeErrorGrams(1, 10000),
      );
      expect(errorText, findsOneWidget);
    });
  }
}
