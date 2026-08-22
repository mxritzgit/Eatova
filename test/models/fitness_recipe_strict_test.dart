import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';

// S4 (Sweep 2026-08-08): `fromRow` used to invent a FRESH slug when one was
// missing. The slug is the upsert conflict key (user_id,slug), so every outbox
// replay of a corrupt payload created a NEW server row instead of updating —
// duplicate recipes.
//
// Contract now: no slug means the row/payload is corrupt -> throw. The replay
// catches it (-> _CorruptOpPayload -> drop with a message), and slug is NOT
// NULL in public.user_recipes, so server rows never hit the throw.

Map<String, dynamic> _zeile() => <String, dynamic>{
      'slug': 'user_123',
      'title': 'Protein-Bowl',
      'calories_kcal': 520,
      'protein_g': 40,
      'carbs_g': 50,
      'fat_g': 15,
      'estimated_g': 420,
    };

void main() {
  test('fromRow ohne slug wirft statt einen frischen Slug zu erfinden', () {
    final zeile = _zeile()..remove('slug');
    expect(() => FitnessRecipe.fromRow(zeile), throwsFormatException);
  });

  test('Kontrolle: mit slug parst die Zeile normal', () {
    final rezept = FitnessRecipe.fromRow(_zeile());
    expect(rezept.slug, 'user_123');
    expect(rezept.caloriesKcal, 520);
    expect(rezept.userCreated, isTrue);
  });
}
