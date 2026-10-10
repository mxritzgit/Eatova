// Matches a described meal against the user's foods and the product
// database, and the editable draft the review step shows.
// Contract: docs/MEAL-DESCRIBE.md.

import '../models/described_meal.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/meal_component.dart';
import 'open_food_facts_product_service.dart';

/// Where a draft line's numbers come from.
enum DraftItemOrigin { favorite, product, estimate }

/// One food a draft line can use. Values are per 100 g so the line can be
/// re-portioned without asking the source again.
class DraftCandidate {
  const DraftCandidate({
    required this.origin,
    required this.title,
    required this.kcalPer100G,
    this.brand,
    this.proteinPer100G,
    this.carbsPer100G,
    this.fatPer100G,
    this.servingGrams,
    this.barcode,
  });

  final DraftItemOrigin origin;
  final String title;
  final String? brand;
  final double kcalPer100G;

  /// Null means unknown, not 0 g.
  final double? proteinPer100G;
  final double? carbsPer100G;
  final double? fatPer100G;

  /// One serving or piece in grams, when the source states it.
  final int? servingGrams;

  /// Product barcode, for products only.
  final String? barcode;
}

/// One line of the draft: the described food, the chosen candidate and the
/// alternatives the user can switch to.
class DraftFoodItem {
  const DraftFoodItem({
    required this.described,
    required this.selected,
    required this.candidates,
    required this.grams,
  });

  final DescribedFoodItem described;
  final DraftCandidate selected;

  /// Best first, at most four, always including the model's estimate, so a
  /// line never ends up without numbers.
  final List<DraftCandidate> candidates;

  final int grams;

  bool get isEstimate => selected.origin == DraftItemOrigin.estimate;

  int get caloriesKcal => throw UnimplementedError('DraftFoodItem.caloriesKcal');

  /// The same line with another portion.
  DraftFoodItem withGrams(int grams) =>
      throw UnimplementedError('DraftFoodItem.withGrams');

  /// The same line with another candidate. A stated countable amount ("1
  /// Scheibe") follows the new candidate's serving size when it has one.
  DraftFoodItem withCandidate(DraftCandidate candidate) =>
      throw UnimplementedError('DraftFoodItem.withCandidate');

  MealComponent toComponent() =>
      throw UnimplementedError('DraftFoodItem.toComponent');
}

/// The editable result of a match; immutable, every edit returns a copy.
class MealDescriptionDraft {
  const MealDescriptionDraft({required this.meal, required this.items});

  final DescribedMeal meal;
  final List<DraftFoodItem> items;

  MealSlot? get slotHint => meal.slotHint;

  int get caloriesKcal =>
      throw UnimplementedError('MealDescriptionDraft.caloriesKcal');

  MealDescriptionDraft replaceItem(int index, DraftFoodItem item) =>
      throw UnimplementedError('MealDescriptionDraft.replaceItem');

  MealDescriptionDraft removeItem(int index) =>
      throw UnimplementedError('MealDescriptionDraft.removeItem');

  /// The loggable result: one component per line, totals summed from them.
  MealAnalysisResult toResult() =>
      throw UnimplementedError('MealDescriptionDraft.toResult');
}

/// Builds the draft for a described meal.
abstract class MealDescriptionMatcher {
  Future<MealDescriptionDraft> match(DescribedMeal meal);
}

/// Production matcher: favorites and recents first, then
/// [ProductLookupService.searchProducts], all lines in parallel under one
/// time budget. A search that fails or runs out of time leaves the line on
/// its estimate; the match itself never fails because of a search.
class ProductMealDescriptionMatcher implements MealDescriptionMatcher {
  const ProductMealDescriptionMatcher({
    required this.products,
    required this.favorites,
  });

  final ProductLookupService products;

  /// Read at match time, so the newest favorites count.
  final List<FavoriteMealSnapshot> Function() favorites;

  @override
  Future<MealDescriptionDraft> match(DescribedMeal meal) =>
      throw UnimplementedError('ProductMealDescriptionMatcher.match');
}

/// The parts of a favorite or recent the matcher needs. The owner of this
/// file maps `FavoriteMeal` to it (or replaces it with `FavoriteMeal`).
class FavoriteMealSnapshot {
  const FavoriteMealSnapshot({required this.result, this.lastGrams});

  final MealAnalysisResult result;
  final int? lastGrams;
}
