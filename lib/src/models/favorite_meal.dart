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

  FavoriteMeal copyWith({bool? pinned, DateTime? addedAt}) {
    return FavoriteMeal(
      id: id,
      result: result,
      addedAt: addedAt ?? this.addedAt,
      pinned: pinned ?? this.pinned,
    );
  }

  static String idFor(MealAnalysisResult result) {
    final barcode = result.barcode;
    if (barcode != null && barcode.isNotEmpty) {
      return 'barcode:$barcode';
    }
    return 'name:${result.mealName.toLowerCase().trim()}';
  }
}
