import 'meal_analysis_result.dart';

class FavoriteMeal {
  const FavoriteMeal({
    required this.id,
    required this.result,
    required this.addedAt,
    this.pinned = false,
  });

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
    if (code == null || code.isEmpty || code != other?.barcode) return next;
    return next.withImageUrl(photo);
  }

  static String idFor(MealAnalysisResult result) {
    final barcode = result.barcode;
    if (barcode != null && barcode.isNotEmpty) {
      return 'barcode:$barcode';
    }
    return 'name:${result.mealName.toLowerCase().trim()}';
  }
}
