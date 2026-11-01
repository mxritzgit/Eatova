// The add sheet's own-food suggestions (2026-11-01) above the recents:
// "Often at dinner" with "Your usual dinner" below it, then "What still
// fits?". The rules behind the lists are in
// test/services/own_food_suggestions_test.dart; this pins the sheet: the
// order of the sections, that a "What still fits?" row logs nothing before
// its Add, and that the usual meal goes through the copy with its ids.

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
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import '../../support/harness.dart';
import '../../support/pinned_clock.dart';

class _SilentAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _SilentPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _NoProducts implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

MealAnalysisResult _food(String name, int kcal, String protein) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 100,
      kcalPer100G: kcal.toDouble(),
      protein: protein,
      carbs: '10 g',
      fat: '5 g',
      confidence: 'manual',
      portionNotes: '',
      sourceLabel: 'manual',
    );

FavoriteMeal _favorite(MealAnalysisResult result, {bool pinned = true}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: DateTime(2026, 10, 20),
      pinned: pinned,
    );

int _ids = 0;

LoggedMeal _log(MealAnalysisResult result, DateTime at, MealSlot slot) =>
    LoggedMeal(
      id: 'meal-${_ids++}',
      result: result,
      loggedAt: at,
      forcedSlot: slot,
    );

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  testWidgets('Abends: „Oft zum Abendessen“ mit dem üblichen Abendessen, '
      'darunter „Was passt noch?“, dann die Liste wie bisher', (tester) {
    return withClockAt(DateTime(2026, 11, 1, 19), () async {
      pinPhoneViewport(tester);
      final rice = _food('Reis', 180, '4 g');
      final curry = _food('Curry', 420, '30 g');
      final quark = _food('Quark', 200, '30 g');
      final diary = <LoggedMeal>[
        for (final day in [28, 29, 30]) ...[
          _log(rice, DateTime(2026, 10, day, 19), MealSlot.dinner),
          _log(curry, DateTime(2026, 10, day, 19, 1), MealSlot.dinner),
        ],
      ];
      final lunch = _log(
        _food('Suppe', 300, '12 g'),
        DateTime(2026, 11, 1, 12),
        MealSlot.lunch,
      );
      final favorites = [
        _favorite(quark),
        _favorite(_food('Lachs', 500, '45 g')), // over the 450 kcal left
        for (var i = 1; i <= 8; i++) _favorite(_food('Snack $i', 100, '$i g')),
        _favorite(_food('Brezel', 250, '7 g'), pinned: false),
      ];
      final added = <(MealAnalysisResult, MealSlot)>[];
      final copies = <(List<String>, DateTime, MealSlot?)>[];
      final l10n = (await pumpLocalizedContext(
        tester,
        AddMealSheet(
          slot: MealSlot.dinner,
          analyzer: _SilentAnalyzer(),
          productService: _NoProducts(),
          photoInput: _SilentPhotos(),
          favorites: favorites,
          existingMeals: [lunch],
          foodDate: DateTime(2026, 11, 1),
          diaryMeals: () => [lunch, ...diary],
          remainingKcal: 450,
          onCopyMeals: (ids, {required day, slot}) {
            copies.add((ids, day, slot));
            return const <String>[];
          },
          onAdd: (result, slot) {
            added.add((result, slot));
            return 'new-${added.length}';
          },
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
          onToggleFavorite: (_) {},
        ),
        reducedMotion: false,
        safeArea: false,
        settle: true,
      )).l10n;

      double top(Finder finder) => tester.getTopLeft(finder).dy;
      final frequentLabel = find.text(
        l10n.foodSectionFrequentInSlot('dinner').toUpperCase(),
      );
      final fitsLabel = find.text(l10n.foodSectionStillFits.toUpperCase());
      final recentsLabel = find.text(l10n.foodSectionRecentMeals.toUpperCase());
      expect(top(frequentLabel), lessThan(top(_key('own-food-usual'))));
      expect(top(_key('own-food-usual')), lessThan(top(fitsLabel)));
      expect(top(fitsLabel), lessThan(top(recentsLabel)));
      expect(find.text(l10n.foodStillFitsLeft(450)), findsOneWidget);

      // Curry and rice are the frequent dinner, so "still fits" leads with
      // the next most protein within 450 kcal: quark, not the salmon.
      final fitsRow = _key('own-food-fitting-0');
      expect(
        find.descendant(of: fitsRow, matching: find.text('Quark')),
        findsOneWidget,
      );
      expect(find.text('Lachs'), findsNothing);
      expect(_key('own-food-frequent-quick-0'), findsOneWidget);
      expect(
        _key('own-food-fitting-quick-0'),
        findsNothing,
        reason: 'ein Vorschlag fürs Restbudget hat kein Ein-Tipp-Plus',
      );

      await tester.ensureVisible(_key('own-food-usual'));
      await tester.tap(_key('own-food-usual'));
      await tester.pumpAndSettle();
      expect(copies, hasLength(1));
      expect(copies.single.$1, [diary[4].id, diary[5].id]);
      expect(copies.single.$2, DateTime(2026, 11, 1));
      expect(copies.single.$3, MealSlot.dinner);

      await tester.ensureVisible(fitsRow);
      await tester.tap(fitsRow);
      await tester.pumpAndSettle();
      expect(added, isEmpty, reason: 'Antippen öffnet nur die Portion');
      await tester.tap(_key('own-food-fitting-add-0'));
      await tester.pump();
      expect(added.single.$1.mealName, 'Quark');
      expect(added.single.$2, MealSlot.dinner);

      // The just-added check and the toast run out.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
