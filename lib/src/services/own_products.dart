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
    lookup.then((_) => false, onError: isFinalBarcodeAnswer);

/// One scanned code for the result sheet: the user's own product (E5)
/// answers at once, otherwise the database, again on the sheet's "Try
/// again" ([retry]). [latest] is the attempt the sheet ended on.
class BarcodeLookup {
  BarcodeLookup(this._service, this.code, {this.own})
    : latest = own != null
          ? Future<MealAnalysisResult>.value(own)
          : _service.lookupBarcode(code) {
    // Offline the lookup fails before the sheet listens, which must not
    // surface as an unhandled zone error.
    latest.ignore();
  }

  final ProductLookupService _service;
  final String code;
  final MealAnalysisResult? own;
  Future<MealAnalysisResult> latest;

  /// A fresh lookup for the sheet's retry; null for an own product, which
  /// never fails.
  Future<MealAnalysisResult> Function()? get retry =>
      own != null ? null : () => latest = _service.lookupBarcode(code);

  /// What the manual form starts from after the sheet's "Add manually": the
  /// code to remember the entry under ([barcodeLookupMissedProduct]) and the
  /// product's name when the database knows it without nutrition values.
  Future<({String? barcode, String? name})> manualEntry() async {
    if (own != null) return (barcode: code, name: null);
    final remember = await barcodeLookupMissedProduct(latest);
    final name = await latest.then<String?>(
      (_) => null,
      onError: (Object error) => error is ProductWithoutNutritionException
          ? error.knownProductName
          : null,
    );
    return (barcode: remember ? code : null, name: name);
  }
}
