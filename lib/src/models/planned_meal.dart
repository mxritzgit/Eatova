import 'dart:convert';

import '../services/local_day.dart';
import '../services/uuid.dart';
import 'fitness_recipe.dart';
import 'logged_meal.dart';

/// A recipe snapshot, separate from the consumed diary. Its ID also identifies
/// the eventual diary row; an eaten entry remains a conversion receipt.
class PlannedMeal {
  PlannedMeal._({
    required this.id,
    required this.day,
    required this.slot,
    required this.servings,
    required String snapshot,
    this.eatenAt,
    this.removed = false,
  }) : _snapshot = snapshot;

  factory PlannedMeal.create({
    required FitnessRecipe recipe,
    required DateTime day,
    required MealSlot slot,
    double servings = 1,
    String? id,
  }) => PlannedMeal.fromJson({
    'id': id ?? uuidV4(),
    'day': localDayKey(day),
    'slot': slot.name,
    'servings': servings,
    'recipe': recipe.toRow(),
    'removed': false,
    'eaten_at': null,
  });

  final String id;
  final String day;
  final MealSlot slot;
  final double servings;
  final String _snapshot;
  final DateTime? eatenAt;
  final bool removed;
  bool get isEaten => eatenAt != null;
  FitnessRecipe get recipe => FitnessRecipe.fromRow(
    (jsonDecode(_snapshot) as Map).cast<String, dynamic>(),
  );

  PlannedMeal copyWith({
    DateTime? day,
    MealSlot? slot,
    double? servings,
    DateTime? eatenAt,
    bool? removed,
  }) => PlannedMeal.fromJson({
    ...toJson(),
    if (day != null) 'day': localDayKey(day),
    if (slot != null) 'slot': slot.name,
    if (servings != null) 'servings': servings,
    if (eatenAt != null) 'eaten_at': eatenAt.toUtc().toIso8601String(),
    if (removed != null) 'removed': removed,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'day': day,
    'slot': slot.name,
    'servings': servings,
    'recipe': jsonDecode(_snapshot),
    'removed': removed,
    'eaten_at': eatenAt?.toUtc().toIso8601String(),
  };

  factory PlannedMeal.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final day = json['day'];
    final slot = MealSlot.values
        .where((s) => s.name == json['slot'])
        .firstOrNull;
    final servings = json['servings'];
    final raw = json['recipe'];
    final removed = json['removed'];
    final eaten = json['eaten_at'];
    final eatenAt = eaten is String ? DateTime.tryParse(eaten) : null;
    if (id is! String ||
        !isUuidShape(id) ||
        day is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        DateTime.tryParse(day) == null ||
        localDayKey(DateTime.parse(day)) != day ||
        DateTime.parse(day).year < 2000 ||
        DateTime.parse(day).year > 2100 ||
        slot == null ||
        servings is! num ||
        !servings.isFinite ||
        servings < .1 ||
        servings > 100 ||
        raw is! Map ||
        removed is! bool ||
        (eaten != null && eatenAt == null) ||
        (removed && eatenAt != null)) {
      throw const FormatException('Invalid planned meal');
    }
    final snapshot = raw.cast<String, dynamic>();
    for (final entry in <String, int>{
      'slug': 300,
      'title': 300,
      'description': 2000,
      'portion': 500,
      'ingredients': 10000,
      'preparation': 10000,
      'image_asset': 1000,
    }.entries) {
      final value = snapshot[entry.key];
      if (value is! String ||
          value.runes.length > entry.value ||
          ((entry.key == 'title' || entry.key == 'slug') &&
              value.trim().isEmpty)) {
        throw const FormatException('Invalid recipe snapshot');
      }
    }
    for (final key in [
      'calories_kcal',
      'protein_g',
      'carbs_g',
      'fat_g',
      'estimated_g',
    ]) {
      final value = snapshot[key];
      if (value is! num || !value.isFinite || value < 0 || value > 1000000) {
        throw const FormatException('Invalid recipe nutrition');
      }
    }
    final encoded = jsonEncode(snapshot);
    if (utf8.encode(encoded).length > 65536) {
      throw const FormatException('Recipe snapshot too large');
    }
    FitnessRecipe.fromRow(snapshot);
    return PlannedMeal._(
      id: id,
      day: day,
      slot: slot,
      servings: servings.toDouble(),
      snapshot: encoded,
      eatenAt: eatenAt,
      removed: removed,
    );
  }
}

/// Check identity includes the week and shopping requirement fingerprint.
/// Quantity/source changes create a fresh unchecked requirement.
class ShoppingCheck {
  const ShoppingCheck({required this.id, required this.checked});
  final String id;
  final bool checked;
  Map<String, dynamic> toJson() => {'id': id, 'checked': checked};
  factory ShoppingCheck.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}:[a-f0-9]{64}$').hasMatch(json['id']) ||
        json['checked'] is! bool) {
      throw const FormatException('Invalid shopping check');
    }
    return ShoppingCheck(id: json['id'], checked: json['checked']);
  }
}
