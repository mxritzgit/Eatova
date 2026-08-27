import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/recipe_catalog_de.dart';
import 'package:eatova/src/models/recipe_catalog_en.dart';

/// Guard for spec §6: the German and English recipe catalogs must carry the
/// exact same slug set. The slug is the language-neutral identity favorites and
/// goal matching hang on, so a missing slug makes a recipe vanish on language
/// switch. Counterpart to the ARB parity rule in `test/repo_rules_test.dart`.
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
      // Prose fields must DIFFER — a translation, not the same line copied.
      expect(en.title, isNot(de.title), reason: de.slug);
    }
  });
}
