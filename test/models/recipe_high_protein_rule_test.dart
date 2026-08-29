// P2-04 (Review 2026-08-29): `High Protein` war nach Gefühl vergeben.
// Über alle 30 Rezepte gerechnet trennte KEINE Schwelle die beiden Gruppen:
//
//   * absolut:  Minimum mit Tag 26 g  vs. Maximum ohne Tag 36 g
//   * relativ:  18,6 % der Energie    vs. 23,3 %
//   * je 100 g: 3,9                   vs. 6,2
//
// Die schärfste Inversion: Omelett 36 g / 23,2 % OHNE Tag gegen Linsen-Dal
// 26 g / 18,6 % MIT Tag.
//
// Regel jetzt: [HighProteinRule] — >= 20 % der Energie aus Protein (EU
// 1924/2006, Anhang, "HIGH PROTEIN") UND >= 30 g je Portion (Mahlzeiten-Boden,
// weil der Katalog ganze Teller führt und nicht Produkte). Dieser Test hält
// Regel und Katalog aneinander fest, in BEIDEN Sprachen.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';

/// Energieanteil des Proteins, wie [HighProteinRule] ihn meint.
double _proteinAnteil(FitnessRecipe r) =>
    r.proteinG * HighProteinRule.kcalPerProteinG / r.caloriesKcal;

/// Ein Prüfrezept mit frei wählbaren Zahlen; alles andere ist für die Regel
/// ohne Belang.
FitnessRecipe _probe({required int proteinG, required int caloriesKcal}) =>
    FitnessRecipe(
      slug: 'probe',
      title: 'Probe',
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: caloriesKcal,
      proteinG: proteinG,
      carbsG: 0,
      fatG: 0,
      estimatedGrams: 400,
      categories: const <String>[],
    );

void main() {
  group('HighProteinRule als reine Funktion', () {
    test('die Schwellen stehen fest und sind begruendet', () {
      // Ein stilles Absenken der Regel faellt hier auf, nicht erst im Katalog.
      expect(HighProteinRule.minEnergyShare, 0.20);
      expect(HighProteinRule.minProteinG, 30);
      expect(HighProteinRule.kcalPerProteinG, 4);
    });

    test('beide Bedingungen muessen erfuellt sein', () {
      // Genau auf beiden Schwellen: 30 g bei 600 kcal = 20,0 %.
      expect(_probe(proteinG: 30, caloriesKcal: 600).meetsHighProteinRule,
          isTrue);
      // Anteil reicht, Menge nicht (28 g / 400 kcal = 28 %).
      expect(_probe(proteinG: 28, caloriesKcal: 400).meetsHighProteinRule,
          isFalse);
      // Menge reicht, Anteil nicht (32 g / 1200 kcal = 10,7 %) — die Form, die
      // der reine Gramm-Boden durchlassen wuerde.
      expect(_probe(proteinG: 32, caloriesKcal: 1200).meetsHighProteinRule,
          isFalse);
      // Knapp unter beiden Schwellen.
      expect(_probe(proteinG: 29, caloriesKcal: 500).meetsHighProteinRule,
          isFalse);
    });

    test('ohne Kalorien gibt es keinen Energieanteil und keinen Tag', () {
      expect(
          _probe(proteinG: 100, caloriesKcal: 0).meetsHighProteinRule, isFalse);
    });
  });

  for (final (sprache, katalog) in <(String, List<FitnessRecipe>)>[
    ('de', recipeCatalogDe),
    ('en', recipeCatalogEn),
  ]) {
    group('Katalog $sprache: der Tag folgt der Regel', () {
      test('alle 30 Rezepte tragen genau dann High Protein, wenn sie duerfen',
          () {
        expect(katalog, hasLength(30));
        for (final r in katalog) {
          expect(
            r.categories.contains(highProteinCategory),
            r.meetsHighProteinRule,
            reason: '${r.slug}: ${r.proteinG} g / ${r.caloriesKcal} kcal = '
                '${(_proteinAnteil(r) * 100).toStringAsFixed(1)} % — Tag '
                '${r.categories.contains(highProteinCategory) ? "gesetzt" : "fehlt"}, '
                'Regel sagt ${r.meetsHighProteinRule}.',
          );
        }
      });

      test('der Tag trennt wirklich: weder alle noch keiner', () {
        // Eine Regel, die alle 30 durchlaesst, waere als Filter wertlos.
        final mitTag =
            katalog.where((r) => r.categories.contains(highProteinCategory));
        expect(mitTag, hasLength(24));
        expect(katalog.length - mitTag.length, 6);
      });

      test('zwischen der schwaechsten Ja- und der staerksten Nein-Portion '
          'liegt eine Luecke', () {
        // Genau das fehlte vorher: die Gruppen ueberlappten sich.
        final ja = katalog
            .where((r) => r.meetsHighProteinRule)
            .map((r) => r.proteinG)
            .reduce((a, b) => a < b ? a : b);
        final nein = katalog
            .where((r) => !r.meetsHighProteinRule)
            .map((r) => r.proteinG)
            .reduce((a, b) => a > b ? a : b);
        expect(ja, greaterThan(nein),
            reason: 'schwaechstes Ja $ja g, staerkstes Nein $nein g');
        expect(ja, HighProteinRule.minProteinG);
      });

      test('die drei korrigierten Rezepte sind gepinnt', () {
        FitnessRecipe bySlug(String slug) =>
            katalog.firstWhere((r) => r.slug == slug);

        // Omelett: 36 g / 23,2 % — bekam den Tag.
        expect(
          bySlug('omelett_mit_spinat_and_avocado')
              .categories
              .contains(highProteinCategory),
          isTrue,
        );
        // Ruehrei: 28 g / 20,7 % — Anteil ja, Menge nein.
        expect(
          bySlug('ruhrei_mit_vollkornbrot_and_avocado')
              .categories
              .contains(highProteinCategory),
          isFalse,
        );
        // Linsen-Dal: 26 g / 18,6 % — beides nein.
        expect(
          bySlug('linsen_dal_mit_reis')
              .categories
              .contains(highProteinCategory),
          isFalse,
        );
      });
    });
  }

  test('de und en tragen dieselbe High-Protein-Menge', () {
    Set<String> mitTag(List<FitnessRecipe> katalog) => katalog
        .where((r) => r.categories.contains(highProteinCategory))
        .map((r) => r.slug)
        .toSet();
    expect(mitTag(recipeCatalogEn), mitTag(recipeCatalogDe));
  });

  test('High Protein steht als Filter-Chip zur Verfuegung', () {
    // Die Konstante und der Chip muessen dasselbe Wort sein, sonst filtert der
    // Chip ins Leere.
    expect(recipeFilters, contains(highProteinCategory));
  });
}
