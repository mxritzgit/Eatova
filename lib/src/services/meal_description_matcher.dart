// Matches a described meal against the user's foods and the product
// database, and the editable draft the review step shows.
// Contract: docs/MEAL-DESCRIBE.md.

import '../models/described_meal.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/meal_component.dart';
import '../models/model_limits.dart';
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

  int get caloriesKcal => (selected.kcalPer100G * grams / 100).round();

  /// Macros in grams for [grams]; null means unknown, not 0 g.
  double? get proteinG => _forGrams(selected.proteinPer100G);
  double? get carbsG => _forGrams(selected.carbsPer100G);
  double? get fatG => _forGrams(selected.fatPer100G);

  double? _forGrams(double? per100G) =>
      per100G == null ? null : per100G * grams / 100;

  /// The same line with another portion.
  DraftFoodItem withGrams(int grams) => DraftFoodItem(
    described: described,
    selected: selected,
    candidates: candidates,
    grams: clampPortionGrams(grams, fallback: this.grams),
  );

  /// The same line with another candidate. A stated countable amount ("1
  /// Scheibe") follows the new candidate's serving size when it has one.
  DraftFoodItem withCandidate(DraftCandidate candidate) => DraftFoodItem(
    described: described,
    selected: candidate,
    candidates: candidates,
    grams: portionGramsFor(described, candidate) ?? grams,
  );

  /// The diary component; the brand joins the name unless already in it.
  MealComponent toComponent() {
    final brand = selected.brand?.trim();
    final title = selected.title.trim();
    final named =
        brand == null ||
            brand.isEmpty ||
            title.toLowerCase().contains(brand.toLowerCase())
        ? title
        : '$title ($brand)';
    return MealComponent(
      name: clampMealName(named, fallback: described.name),
      grams: grams,
      caloriesKcal: caloriesKcal,
      kcalPer100G: selected.kcalPer100G,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
    );
  }
}

/// Grams for [item] when it uses [candidate]: a stated countable amount
/// times the candidate's serving size, else null (keep the current grams).
int? portionGramsFor(DescribedFoodItem item, DraftCandidate candidate) {
  final serving = candidate.servingGrams;
  if (serving == null || item.gramsSource != DescribedGramsSource.stated) {
    return null;
  }
  final count = countableAmount(item.amountText);
  if (count == null) return null;
  return clampPortionGrams(serving * count);
}

/// The count of a countable amount ("1 Scheibe", "zwei Stück", "½ Portion"),
/// or null for weights and volumes ("200 g", "300 ml").
double? countableAmount(String? amountText) {
  final text = amountText?.trim().toLowerCase();
  if (text == null || text.isEmpty) return null;
  final match = _countable.firstMatch(text);
  if (match == null) return null;
  final number = match.group(1)!.replaceAll(',', '.');
  return _countWords[number] ?? double.tryParse(number);
}

final RegExp _countable = RegExp(
  r'^(\d+(?:[.,]\d+)?|½|ein|eine|einen|einem|einer|zwei|drei|vier|fünf|'
  r'halbe?|a|an|one|two|three|four|five|half)\s+'
  r'(scheiben?|stücke?|stück|portionen?|gläser|glas|becher|riegel|tassen?|'
  r'eier|ei|brötchen|äpfel|apfel|bananen?|dosen?|packungen?|'
  r'slices?|pieces?|servings?|portions?|glass(?:es)?|cups?|bars?|eggs?|'
  r'rolls?|apples?|bananas?|cans?|packs?)(?=[\s.,;]|$)',
  unicode: true,
);

const Map<String, double> _countWords = {
  '½': .5,
  'halb': .5,
  'halbe': .5,
  'half': .5,
  'ein': 1,
  'eine': 1,
  'einen': 1,
  'einem': 1,
  'einer': 1,
  'a': 1,
  'an': 1,
  'one': 1,
  'zwei': 2,
  'two': 2,
  'drei': 3,
  'three': 3,
  'vier': 4,
  'four': 4,
  'fünf': 5,
  'five': 5,
};

/// The editable result of a match; immutable, every edit returns a copy.
class MealDescriptionDraft {
  const MealDescriptionDraft({required this.meal, required this.items});

  final DescribedMeal meal;
  final List<DraftFoodItem> items;

  MealSlot? get slotHint => meal.slotHint;

  int get caloriesKcal =>
      items.fold<int>(0, (sum, item) => sum + item.caloriesKcal);

  MealDescriptionDraft replaceItem(int index, DraftFoodItem item) =>
      MealDescriptionDraft(
        meal: meal,
        items: [
          for (var i = 0; i < items.length; i++) i == index ? item : items[i],
        ],
      );

  MealDescriptionDraft removeItem(int index) => MealDescriptionDraft(
    meal: meal,
    items: [
      for (var i = 0; i < items.length; i++)
        if (i != index) items[i],
    ],
  );

  /// The loggable result: one component per line, totals summed from them.
  MealAnalysisResult toResult() => meal.base.adjustedToItems([
    for (final item in items) item.toComponent(),
  ]);
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
