import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/recipe_catalog_de.dart';
import 'package:eatova/src/models/recipe_catalog_en.dart';

/// Wächter der Spec §6 (Inhalte-PR): der deutsche und der englische
/// Rezeptkatalog müssen exakt dieselbe Slug-Menge tragen. Der Slug ist die
/// sprachneutrale Identität, an der Favoriten und der Ziel-Abgleich hängen
/// (s. `fitness_recipe.dart`, `recipeCatalogForLocale`) — fehlt ein Slug auf
/// einer Seite, verschwindet das Rezept beim Sprachwechsel spurlos aus der
/// Liste, oder ein Favorit findet unter der anderen Sprache keinen Treffer
/// mehr. Pendant zu `arb_parity_test.dart`.
void main() {
  test('beide Kataloge tragen 30 Rezepte mit identischer Slug-Menge', () {
    expect(recipeCatalogDe, hasLength(30));
    expect(recipeCatalogEn, hasLength(30));

    final slugsDe = recipeCatalogDe.map((r) => r.slug).toSet();
    final slugsEn = recipeCatalogEn.map((r) => r.slug).toSet();

    expect(slugsDe, hasLength(recipeCatalogDe.length),
        reason: 'doppelte Slugs im deutschen Katalog');
    expect(slugsEn, hasLength(recipeCatalogEn.length),
        reason: 'doppelte Slugs im englischen Katalog');
    expect(
      slugsEn.difference(slugsDe),
      isEmpty,
      reason: 'der englische Katalog hat Slugs, die der deutsche nicht kennt',
    );
    expect(
      slugsDe.difference(slugsEn),
      isEmpty,
      reason: 'diese Rezepte fehlen im englischen Katalog',
    );
  });

  test(
      'gleiche Reihenfolge, gleiche Kategorien/Zahlen/Bildpfade — nur die '
      'Textfelder unterscheiden sich', () {
    for (var i = 0; i < recipeCatalogDe.length; i++) {
      final de = recipeCatalogDe[i];
      final en = recipeCatalogEn[i];
      expect(en.slug, de.slug, reason: 'Index $i: Slug-Reihenfolge weicht ab');
      expect(en.imageAsset, de.imageAsset, reason: de.slug);
      expect(en.categories, de.categories, reason: de.slug);
      expect(en.caloriesKcal, de.caloriesKcal, reason: de.slug);
      expect(en.proteinG, de.proteinG, reason: de.slug);
      expect(en.carbsG, de.carbsG, reason: de.slug);
      expect(en.fatG, de.fatG, reason: de.slug);
      expect(en.estimatedGrams, de.estimatedGrams, reason: de.slug);
      // Die Textfelder muessen sich UNTERSCHEIDEN (Uebersetzung, nicht
      // versehentlich dieselbe Zeile kopiert) — ausser wo Deutsch und
      // Englisch zufaellig gleich lauten (z. B. "Vegan" in Kategorien ist
      // schon oben verglichen, hier geht es um die Prosa-Felder).
      expect(en.title, isNot(de.title), reason: de.slug);
    }
  });
}
