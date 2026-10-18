import '../models/barcode.dart';
import '../models/favorite_meal.dart';
import '../models/meal_analysis_result.dart';
import 'open_food_facts_product_service.dart';

/// The user's own product for a scanned [code] (E5), or null.
///
/// Own products are favorites the user entered by hand for a barcode the
/// product database did not know ([MealAnalysisResult.isOwnProduct]). They
/// live in the synced favorites of the account, so no table of their own is
/// needed. Pinned entries win over recents; both UPC-A spellings match
/// (FOOD-6), so a code stored from a 12-digit Android scan answers a 13-digit
/// one.
MealAnalysisResult? ownProductFor(
  Iterable<FavoriteMeal> favorites,
  String code,
) {
  final wanted = canonicalBarcode(code);
  if (wanted.isEmpty) return null;
  MealAnalysisResult? recent;
  for (final favorite in favorites) {
    final result = favorite.result;
    final barcode = result.barcode;
    if (!result.isOwnProduct ||
        barcode == null ||
        canonicalBarcode(barcode) != wanted) {
      continue;
    }
    if (favorite.pinned) return result;
    recent ??= result;
  }
  return recent;
}

/// Whether a finished barcode [lookup] said the product is unknown or has no
/// usable energy value, the two cases where an entry by hand is worth
/// remembering under its code. A network or service failure says nothing
/// about the product, so the manual entry there stays a one-off.
Future<bool> barcodeLookupMissedProduct(Future<MealAnalysisResult> lookup) =>
    lookup.then(
      (_) => false,
      onError: (Object error) =>
          error is ProductNotFoundException ||
          error is ProductWithoutNutritionException,
    );
