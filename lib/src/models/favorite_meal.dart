import 'barcode.dart';
import 'meal_analysis_result.dart';

class FavoriteMeal {
  const FavoriteMeal({
    required this.id,
    required this.result,
    required this.addedAt,
    this.pinned = false,
  });

  /// How many auto-recents the store keeps (E3, 2026-10-18; was 5).
  ///
  /// Each recent is a synced `favorite_meals` row, and every recent pushed
  /// out of the cap costs a favoriteDelete op plus a permanent receipt
  /// (docs/OFFLINE_SYNC.md). Least-recently-used eviction never evicts more
  /// at a larger cap, so 30 lowers that cost: a varied week of meals stops
  /// churning, and the raise itself writes nothing. 30 keeps the boot read
  /// (`MealsSync.favoritesLimit` = 200) clear for 170 pinned favorites.
  static const int maxAutoRecents = 30;

  final String id;
  final MealAnalysisResult result;
  final DateTime addedAt;

  /// True = pinned by the user, false = auto-recent. Capping to the last N
  /// only affects auto-recents; pinned favorites are kept forever.
  final bool pinned;

  FavoriteMeal copyWith({
    bool? pinned,
    DateTime? addedAt,
    MealAnalysisResult? result,
  }) {
    return FavoriteMeal(
      id: id,
      result: result ?? this.result,
      addedAt: addedAt ?? this.addedAt,
      pinned: pinned ?? this.pinned,
    );
  }

  /// [next] with the photo of [other] when [next] has none and both are the
  /// same product (same barcode), else [next] itself (same instance). A
  /// favorite never loses its product photo to a rewrite from a photo-less
  /// result, and an old photo-less favorite picks one up from a search hit of
  /// the same product. Name-keyed entries never trade photos: an AI scan
  /// called "Banane" is not the packaged product of that name.
  static MealAnalysisResult keepImage(
    MealAnalysisResult next,
    MealAnalysisResult? other,
  ) {
    final photo = other?.imageUrl;
    if (next.imageUrl != null || photo == null) return next;
    final code = next.barcode;
    final otherCode = other?.barcode;
    if (code == null ||
        code.isEmpty ||
        otherCode == null ||
        canonicalBarcode(code) != canonicalBarcode(otherCode)) {
      return next;
    }
    return next.withImageUrl(photo);
  }

  static const String _barcodePrefix = 'barcode:';

  static String idFor(MealAnalysisResult result) {
    final barcode = result.barcode;
    if (barcode != null && barcode.isNotEmpty) {
      return '$_barcodePrefix$barcode';
    }
    return 'name:${result.mealName.toLowerCase().trim()}';
  }

  /// [id] with its barcode in [canonicalBarcode] form; name keys unchanged.
  /// A 12-digit key written before FOOD-6 and the GTIN-13 key of the same
  /// product share it.
  static String canonicalId(String id) {
    if (!id.startsWith(_barcodePrefix)) return id;
    final code = id.substring(_barcodePrefix.length);
    return '$_barcodePrefix${canonicalBarcode(code)}';
  }

  /// The entry of [favorites] that stands for [result]: the one under its own
  /// key, else the same product stored under the other UPC-A spelling.
  ///
  /// Stored keys are not migrated (FOOD-6), so a favorite pinned from a
  /// 12-digit Android scan must still answer a 13-digit one. Writers keep
  /// the found entry's [id].
  static FavoriteMeal? findFor(
    Iterable<FavoriteMeal> favorites,
    MealAnalysisResult result,
  ) {
    final id = idFor(result);
    final canonical = canonicalId(id);
    FavoriteMeal? otherSpelling;
    for (final favorite in favorites) {
      if (favorite.id == id) return favorite;
      if (otherSpelling == null && canonicalId(favorite.id) == canonical) {
        otherSpelling = favorite;
      }
    }
    return otherSpelling;
  }
}
