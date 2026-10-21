import 'dart:math' as math;

import 'barcode.dart';
import 'meal_analysis_result.dart';
import 'model_limits.dart';
import 'persisted_labels.dart';

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

  /// The natural key of [result]: its barcode, else its name. A second,
  /// different food of the same name is stored under [freshIdFor] instead,
  /// so look entries up with [findFor], never by this key alone.
  static String idFor(MealAnalysisResult result) {
    final barcode = result.barcode;
    if (barcode != null && barcode.isNotEmpty) {
      return '$_barcodePrefix$barcode';
    }
    return 'name:${result.mealName.toLowerCase().trim()}';
  }

  /// Energy gap still counted as the same food under one name, relative to
  /// the larger value: estimates of one dish drift by that much, while a
  /// latte (18 kcal/100 g) and a black coffee (1 kcal/100 g) do not.
  static const double sameFoodTolerance = 0.2;

  /// Absolute floors of that gap, so tiny values do not split: per 100 g,
  /// and per serving for entries without a weight.
  static const double _densityFloor = 5;
  static const double _servingFloor = 20;

  /// Whether [a] and [b] stand for the same food, the rule behind every
  /// lookup: the same product by barcode (both UPC-A spellings), else the
  /// same name with a similar energy ([sameFoodTolerance]) of the same kind
  /// (per 100 g, or per serving without a weight). Unnamed quick entries are
  /// only the same with equal values, so they never overwrite each other.
  static bool sameFood(MealAnalysisResult a, MealAnalysisResult b) {
    final codeA = _code(a);
    final codeB = _code(b);
    if (codeA != null || codeB != null) return codeA == codeB;
    if (_nameKey(a) != _nameKey(b)) return false;
    final unnamedA = _isUnnamedQuickEntry(a);
    if (unnamedA || _isUnnamedQuickEntry(b)) {
      return unnamedA == _isUnnamedQuickEntry(b) &&
          a.caloriesKcal == b.caloriesKcal &&
          a.protein == b.protein &&
          a.carbs == b.carbs &&
          a.fat == b.fat;
    }
    final gap = _energyGap(a, b);
    return gap != null && gap <= 1;
  }

  /// Gap between the energies of [a] and [b] in units of the allowed gap,
  /// or null when they are not of the same kind.
  static double? _energyGap(MealAnalysisResult a, MealAnalysisResult b) {
    final densityA = _density(a);
    final densityB = _density(b);
    if ((densityA == null) != (densityB == null)) return null;
    final (x, y, floor) = densityA != null
        ? (densityA, densityB!, _densityFloor)
        : (_perServingKcal(a), _perServingKcal(b), _servingFloor);
    final allowed = math.max(floor, sameFoodTolerance * math.max(x, y));
    return (x - y).abs() / allowed;
  }

  /// kcal per 100 g, a measured 0 included; null without a weight.
  static double? _density(MealAnalysisResult r) {
    final density = r.effectiveKcalPer100G;
    if (density != null) return density;
    return r.explicitZeroKcal && r.estimatedGrams > 0 && r.kcalPer100G == 0
        ? 0
        : null;
  }

  static double _perServingKcal(MealAnalysisResult r) =>
      r.caloriesKcal.toDouble();

  static String? _code(MealAnalysisResult r) {
    final code = r.barcode;
    return code == null || code.isEmpty ? null : canonicalBarcode(code);
  }

  static String _nameKey(MealAnalysisResult r) =>
      r.mealName.toLowerCase().trim();

  static bool _isUnnamedQuickEntry(MealAnalysisResult r) =>
      r.isQuickEntry && r.mealName == PersistedLabels.quickEntryName;

  /// A key for [result] that no entry of [favorites] holds yet: [idFor], or
  /// for another food of an existing name that name with `#2`, `#3`, …
  static String freshIdFor(
    Iterable<FavoriteMeal> favorites,
    MealAnalysisResult result,
  ) {
    final base = idFor(result);
    final taken = {for (final f in favorites) canonicalId(f.id)};
    if (!taken.contains(canonicalId(base)) ||
        base.startsWith(_barcodePrefix)) {
      return base;
    }
    final stem = truncateToChars(
      base,
      FavoriteMealLimits.favoriteKeyMaxChars - 8,
    );
    for (var n = 2; ; n++) {
      final candidate = '$stem#$n';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  /// The key [result] is stored under in [favorites]: the entry that
  /// stands for it ([findFor]), else a [freshIdFor].
  static String keyFor(
    Iterable<FavoriteMeal> favorites,
    MealAnalysisResult result,
  ) => findFor(favorites, result)?.id ?? freshIdFor(favorites, result);

  /// The entry after [result] was logged at [at]: [old] (the [findFor]
  /// match) marked used, or a new auto-recent under [id].
  ///
  /// A recent takes the logged result, the last portion used. A pinned
  /// favorite keeps what the user saved and only moves up as used; an own
  /// product (E5) is the exception, its values are the user's own and a
  /// corrected entry corrects it.
  static FavoriteMeal logged(
    MealAnalysisResult result, {
    required FavoriteMeal? old,
    required String id,
    required DateTime at,
  }) {
    final keepSaved = old != null && old.pinned && !result.isOwnProduct;
    return FavoriteMeal(
      id: old?.id ?? id,
      result: keepSaved
          ? keepImage(old.result, result)
          : keepImage(result, old?.result),
      addedAt: at,
      // E5: a product entered for an unknown barcode is remembered, so the
      // next scan finds it; the recents cap would drop it. An unpin by the
      // user stands.
      pinned: old?.pinned ?? result.isOwnProduct,
    );
  }

  /// [id] with its barcode in [canonicalBarcode] form; name keys unchanged.
  /// A 12-digit key written before FOOD-6 and the GTIN-13 key of the same
  /// product share it.
  static String canonicalId(String id) {
    if (!id.startsWith(_barcodePrefix)) return id;
    final code = id.substring(_barcodePrefix.length);
    return '$_barcodePrefix${canonicalBarcode(code)}';
  }

  /// The entry of [favorites] that stands for [result].
  ///
  /// A product: the one under its own key, else the same product stored
  /// under the other UPC-A spelling. Stored keys are not migrated (FOOD-6),
  /// so a favorite pinned from a 12-digit Android scan must still answer a
  /// 13-digit one. Anything else: the [sameFood] entry with the closest
  /// energy, its natural key first on a tie; a food that only shares the
  /// name is not it. Writers keep the found entry's [id].
  static FavoriteMeal? findFor(
    Iterable<FavoriteMeal> favorites,
    MealAnalysisResult result,
  ) {
    final id = idFor(result);
    if (_code(result) == null) return _closestByName(favorites, result, id);
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

  static FavoriteMeal? _closestByName(
    Iterable<FavoriteMeal> favorites,
    MealAnalysisResult result,
    String id,
  ) {
    FavoriteMeal? best;
    var bestGap = double.infinity;
    for (final favorite in favorites) {
      if (!sameFood(favorite.result, result)) continue;
      final gap = _energyGap(favorite.result, result) ?? 0;
      if (gap < bestGap || (gap == bestGap && favorite.id == id)) {
        best = favorite;
        bestGap = gap;
      }
    }
    return best;
  }
}
