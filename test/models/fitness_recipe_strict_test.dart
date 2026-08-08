import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';

// Sentinel-Rest S4 (Sweep 2026-08-08): `fromRow` erfand fuer einen fehlenden
// Slug einen FRISCHEN (`userRecipeSlug()` = user_<millis>). Der Slug ist aber
// der Konflikt-Schluessel des Upserts (user_id,slug) — ueber den
// Outbox-Replay (SyncOp.recipe -> fromRow(payload) -> upsert) legte jeder
// Retry mit korruptem Payload damit eine NEUE Serverzeile an statt zu
// aktualisieren: Duplikate im Rezeptbestand.
//
// Neuer Vertrag: ohne Slug ist die Zeile/der Payload korrupt -> Wurf. Der
// Replay faengt ihn (SyncOp.recipe -> null -> _CorruptOpPayload -> Drop mit
// Meldung), und in public.user_recipes ist slug als Konflikt-Schluessel
// ohnehin NOT NULL — Server-Zeilen trifft der Wurf nie.

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
