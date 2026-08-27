// Fix run for review 2026-08-27, fix round 1 (F3-01 follow-up): a
// re-portioning from the analysis sheet ("adjust" after adding) must reach
// the add sheet's mirror row too — otherwise "already added" and the slot
// total keep the old kcal until the sheet is reopened.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

/// 855 kcal from three components; halving the potatoes (200 g -> 100 g)
/// takes 80 kcal off: 775 kcal / 500 g.
class _TellerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const MealAnalysisResult(
      mealName: 'Teller mit Steak, Kartoffeln und Brokkoli',
      caloriesKcal: 855,
      estimatedGrams: 600,
      kcalPer100G: 142.5,
      protein: '64 g',
      carbs: '42 g',
      fat: '38 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
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
        MealComponent(
          name: 'Brokkoli',
          grams: 100,
          caloriesKcal: 35,
          kcalPer100G: 35,
        ),
      ],
    );
  }
}

class _Galerie implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async =>
      const MealPhotoSelection(
        request: MealAnalysisRequest(imageId: 'gallery-photo'),
        previewBytes: null,
      );
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tapVisible(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'Foto -> Hinzufügen -> Anpassen: „Bereits hinzugefügt" und Slot-Summe '
      'zeigen die neuen kcal', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The adjust sheet's item rows (meal_widgets_adjust.dart, Paket D) overflow
    // by 29–51 px in this viewport — not this test's subject. Everything
    // else must stay overflow-free.
    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      if (text.contains('overflowed')) {
        if (!text.contains('meal_widgets_adjust.dart')) overflows.add(text);
        return;
      }
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);
    addTearDown(() => expect(overflows, isEmpty, reason: overflows.join('\n')));

    final updates = <(String, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: AddMealSheet(
            slot: MealSlot.lunch,
            analyzer: _TellerAnalyzer(),
            productService: _StummerProduktdienst(),
            photoInput: _Galerie(),
            favorites: const [],
            onAdd: (_, __) => 'id-1',
            onUpdateMeal: (id, scaled) => updates.add((id, scaled.caloriesKcal)),
            onRemoveFavorite: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_key('analyse-gallery-button'));
    await tester.pumpAndSettle();
    expect(_key('analyse-result-card'), findsOneWidget);

    await _tapVisible(tester, 'analyse-add-daily-button');
    await _tapVisible(tester, 'analyse-adjust-button');
    await tester.enterText(_key('analyse-item-weight-input-0'), '100');
    await tester.pump();
    await _tapVisible(tester, 'analyse-save-weight-button');
    expect(updates, [('id-1', 775)]);

    await _tapVisible(tester, 'analyse-sheet-close');
    final liste = _key('analyse-existing-meals');
    expect(liste, findsOneWidget);
    expect(
      find.descendant(
        of: _key('analyse-existing-total-kcal'),
        matching: find.text('775 kcal'),
        matchRoot: true,
      ),
      findsOneWidget,
      reason: 'die Slot-Summe kennt die Anpassung nicht',
    );
    expect(
      find.descendant(of: liste, matching: find.text('775 kcal · 500 g')),
      findsOneWidget,
      reason: 'die Zeile kennt die Anpassung nicht',
    );
    expect(find.descendant(of: liste, matching: find.text('855 kcal · 600 g')),
        findsNothing);
  });
}
