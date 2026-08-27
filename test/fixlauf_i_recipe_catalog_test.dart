// Fix-Lauf 2026-08-27, Paket I (F6-01/F6-04/F6-07): pure model tests.
//
//   * Makro-Probe: kcal ≈ 4P + 4C + 9F (±15 %) für alle 30 Rezepte in beiden
//     Katalogen.
//   * estimatedGrams ist das GARGEWICHT nach EINER Methodik für alle 30
//     (Reis/Quinoa/Couscous/Linsen trocken ×2,5, Pasta ×2,2, Fleisch/Fisch
//     ×0,75, Gemüse/Obst ×0,9, Flüssig/Eier/Milchprodukte/abgetropfte
//     Konserven/Haferflocken 1:1; Ei = 55 g, ½ Banane 50 g, ½ Tomate 60 g,
//     ¼ Gurke 75 g, 1 Paprika 150 g, ½ Paprika 75 g; Aromaten und
//     Löffelmengen ungezählt; auf 5 g gerundet). Jede Zeile der Tabelle trägt
//     ihre Rechnung.
//   * Schranken: bei roher Stärkebeilage nie unter der Roh-Summe; alle 30 im
//     Korridor 0,7…1,8 × Roh-Summe und 60–150 kcal/100 g (Shakshuka ist mit
//     Tomatenbasis wirklich leicht, Rührei mit Brot/Avocado wirklich dicht).
//   * Suchfaltung und Tagesrotation als reine Funktionen.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';

/// Summe aller `<n> g` / `<n> ml`-Mengen einer Zutatenliste — die Roh-Summe,
/// die vorher als `estimatedGrams` stand.
int _rohSumme(String ingredients) {
  final treffer = RegExp(r'(\d+(?:[.,]\d+)?)\s*(g|ml)\b');
  var summe = 0.0;
  for (final m in treffer.allMatches(ingredients)) {
    summe += double.parse(m.group(1)!.replaceAll(',', '.'));
  }
  return summe.round();
}

/// Rezept mit einer rohen Stärkebeilage, die beim Garen deutlich zulegt.
final _roheStaerke = RegExp(
  r'(reis|quinoa|couscous|nudeln|pasta|penne|rice|noodles)[^\n]*,\s*(roh|raw)\b',
  caseSensitive: false,
);

/// Gargewichte aller 30 Rezepte mit Rechnung (Zutat → gegart, Summe → 5 g).
const Map<String, int> _gargewichte = <String, int>{
  // Hähnchen 180×0,75=135 · Reis 75×2,5=187,5 · Brokkoli 220×0,9=198 · Öl 8 = 528,5
  'hahnchen_mit_reis_and_brokkoli': 530,
  // Lachs 180×0,75=135 · Süßkartoffel 300×0,9=270 · Spargel 200×0,9=180 · Öl 10 = 595
  'lachs_mit_sukartoffel_and_spargel': 595,
  // Pute 200×0,75=150 · Quinoa 70×2,5=175 · Gemüse 250×0,9=225 · Öl 10 = 560
  'putensteak_mit_quinoa_and_ofengemuse': 560,
  // Steak 200×0,75=150 · Kartoffeln 280×0,9=252 · Bohnen 220×0,9=198 · Öl 10 = 610
  'rindersteak_mit_kartoffeln_and_bohnen': 610,
  // Garnelen 200×0,75=150 · Penne 85×2,2=187 · Zucchini 250×0,9=225 · Öl 8 = 570
  'garnelen_mit_vollkornnudeln_and_zucchini': 570,
  // 3 Eier 165 · Eiklar 150 · Spinat 80×0,9=72 · Avocado 80×0,9=72 · Tomaten
  // 120×0,9=108 · Öl 5 · Frischkäse 30 = 602
  'omelett_mit_spinat_and_avocado': 600,
  // Thunfisch 200×0,75=150 · Couscous 80×2,5=200 · Gemüse 250×0,9=225 · Öl 8 = 583
  'thunfisch_mit_couscous_and_gemuse': 585,
  // Tofu (abgetropft) 200 · Reis 75×2,5=187,5 · Edamame 150×0,9=135 · Öl 8 = 530,5
  'tofu_mit_reis_and_edamame': 530,
  // Hähnchen 190×0,75=142,5 · Süßkartoffel 300×0,9=270 · Bohnen 220×0,9=198 · Öl 10 = 620,5
  'hahnchen_mit_sukartoffel_and_bohnen': 620,
  // Hack 220×0,75=165 · Ei 55 · Haferflocken 20 · Reis 75×2,5=187,5 · Gemüse
  // 250×0,9=225 · Öl 8 = 660,5
  'putenballchen_mit_reis_and_gemuse': 660,
  // Haferflocken 40 · 2 Eier 110 · Quark 150 · Banane 90×0,9=81 · Beeren 100×0,9=90 = 471
  'protein_pancakes_mit_beeren': 470,
  // Haferflocken 60 · Skyr 150 · Milch 120 · Beeren 80×0,9=72 · ½ Banane 50×0,9=45 = 447
  'overnight_oats_mit_skyr_and_banane': 445,
  // Skyr 250 · Granola 40 · Beeren 120×0,9=108 · Nüsse 10 = 408
  'skyr_bowl_mit_beeren_and_granola': 410,
  // 3 Eier 165 · passierte Tomaten 400 · Paprika 150×0,9=135 · Feta 40 · Öl 8 = 748
  'shakshuka_mit_eiern_and_feta': 750,
  // 3 Eier 165 · Brot 50 · Avocado 70×0,9=63 · Tomaten 100×0,9=90 · Butter 5 = 373
  'ruhrei_mit_vollkornbrot_and_avocado': 375,
  // Hähnchen 160×0,75=120 · Tortilla 65 · Salat 60×0,9=54 · ½ Tomate 60×0,9=54
  // · ¼ Gurke 75×0,9=67,5 · Joghurt 60 · Öl 6 = 426,5
  'chicken_wrap_mit_joghurt_dressing': 425,
  // Hähnchen 180×0,75=135 · Reis 80×2,5=200 · Kokosmilch 100 · Tomaten 100
  // · Paprika 100×0,9=90 · Öl 8 = 633
  'hahnchen_curry_mit_reis': 635,
  // Hack 180×0,75=135 · Kidneybohnen 120 · Mais 80 · Tomaten 200
  // · ½ Paprika 75×0,9=67,5 · Öl 8 = 610,5
  'rinderhack_chili_mit_bohnen': 610,
  // Rind 180×0,75=135 · Reis 80×2,5=200 · Gemüse 200×0,9=180 · Öl 8 = 523
  'rinderstreifen_stir_fry_mit_reis': 525,
  // Filet 200×0,75=150 · Kartoffeln 280×0,9=252 · Brokkoli 220×0,9=198 · Öl 10 = 610
  'schweinefilet_mit_kartoffeln_and_brokkoli': 610,
  // Hähnchen 170×0,75=127,5 · Pasta 90×2,2=198 · Pesto 30 · Tomaten 100×0,9=90
  // · Spinat 50×0,9=45 · Parmesan 20 · Öl 6 = 516,5
  'hahnchen_pesto_pasta': 515,
  // Hähnchen 180×0,75=135 · Römersalat 120×0,9=108 · Joghurt 60 · Parmesan 15
  // · Croutons 20 · Öl 6 = 344
  'hahnchen_caesar_salat': 345,
  // Thunfisch (Dose) 150 · Pasta 90×2,2=198 · Tomaten 200 · Erbsen 50×0,9=45 · Öl 6 = 599
  'thunfisch_vollkornpasta': 600,
  // Kabeljau 200×0,75=150 · Kartoffeln 280×0,9=252 · Erbsen 100×0,9=90 · Milch 60
  // · Butter 10 · Öl 6 = 568
  'kabeljau_mit_kartoffelpuree_and_erbsen': 570,
  // Lachs roh serviert 150 · Reis 90×2,5=225 · Edamame/Avocado/Gurke/Karotte
  // je 60×0,9=54 = 591
  'lachs_poke_bowl': 590,
  // Linsen 100×2,5=250 · Reis 80×2,5=200 · Tomaten 100 · Kokosmilch 100 · Öl 8 = 658
  'linsen_dal_mit_reis': 660,
  // Kichererbsen (gegart) 200 · Reis 80×2,5=200 · Tomaten 200 · Spinat 80×0,9=72 · Öl 8 = 680
  'kichererbsen_curry_mit_reis': 680,
  // Falafel 120 · Quinoa 60×2,5=150 · Hummus 50 · Gurke 80×0,9=72 · Tomaten
  // 100×0,9=90 · Rotkohl 40×0,9=36 = 518
  'falafel_bowl_mit_hummus': 520,
  // Tempeh 160 · Reis 80×2,5=200 · Gemüse 200×0,9=180 · Öl 8 = 548
  'tempeh_stir_fry_mit_reis': 550,
  // Halloumi 100 · Avocado 80×0,9=72 · Salat 120×0,9=108 · Tomaten 100×0,9=90
  // · Gurke 60×0,9=54 · Kichererbsen 30 = 454
  'halloumi_avocado_bowl': 455,
};

FitnessRecipe _rezept(String slug, {bool userCreated = false}) =>
    FitnessRecipe(
      slug: slug,
      title: slug,
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: 500,
      proteinG: 40,
      carbsG: 50,
      fatG: 12,
      estimatedGrams: 400,
      categories: const <String>['Hauptgericht'],
      userCreated: userCreated,
    );

void main() {
  for (final (name, katalog) in <(String, List<FitnessRecipe>)>[
    ('de', recipeCatalogDe),
    ('en', recipeCatalogEn),
  ]) {
    group('Katalog $name', () {
      test('Makro-Probe: kcal liegt innerhalb ±15 % von 4P + 4C + 9F', () {
        for (final r in katalog) {
          final rechnerisch = 4 * r.proteinG + 4 * r.carbsG + 9 * r.fatG;
          final abweichung = (r.caloriesKcal - rechnerisch) / rechnerisch;
          expect(
            abweichung.abs(),
            lessThanOrEqualTo(0.15),
            reason: '${r.slug}: ${r.caloriesKcal} kcal vs. $rechnerisch '
                'rechnerisch (${(abweichung * 100).toStringAsFixed(1)} %)',
          );
        }
      });

      test('alle 30 Gargewichte sind gepinnt (Rechnung in der Tabelle)', () {
        expect(katalog.map((r) => r.slug).toSet(), _gargewichte.keys.toSet());
        for (final r in katalog) {
          expect(r.estimatedGrams, _gargewichte[r.slug], reason: r.slug);
        }
      });

      test(
          'rohe Stärkebeilage: estimatedGrams liegt nie unter der '
          'Roh-Zutatensumme', () {
        final betroffen = katalog
            .where((r) => _roheStaerke.hasMatch(r.ingredients))
            .toList(growable: false);
        expect(betroffen.length, greaterThanOrEqualTo(12),
            reason: 'Vorbedingung: der Zutaten-Parser muss die rohen '
                'Beilagen finden, sonst prüft der Test nichts.');
        for (final r in betroffen) {
          final roh = _rohSumme(r.ingredients);
          expect(roh, greaterThan(0), reason: '${r.slug}: keine Mengen gelesen');
          expect(
            r.estimatedGrams,
            greaterThanOrEqualTo(roh),
            reason: '${r.slug}: estimatedGrams ${r.estimatedGrams} g unter der '
                'Roh-Summe $roh g — Reis/Pasta legen beim Garen ×2,2–2,5 zu.',
          );
        }
      });

      test('alle 30 liegen im Korridor 0,7…1,8 × Roh-Summe', () {
        for (final r in katalog) {
          final roh = _rohSumme(r.ingredients);
          expect(roh, greaterThan(0), reason: r.slug);
          expect(r.estimatedGrams, greaterThanOrEqualTo(0.7 * roh),
              reason: '${r.slug}: unter 70 % der gewogenen Zutaten — mehr als '
                  'der Fleisch-Garverlust kann nicht verschwinden.');
          expect(r.estimatedGrams, lessThanOrEqualTo(1.8 * roh),
              reason: '${r.slug}: über 180 % der gewogenen Zutaten.');
        }
      });

      test('kcal/100 g aller 30 Teller bleibt im Band 60–150', () {
        for (final r in katalog) {
          expect(r.kcalPer100G, inInclusiveRange(60, 150), reason: r.slug);
        }
      });
    });
  }

  test('de/en-Parität der Gramm bleibt (Zwilling zum Paritätstest)', () {
    for (var i = 0; i < recipeCatalogDe.length; i++) {
      expect(recipeCatalogEn[i].estimatedGrams,
          recipeCatalogDe[i].estimatedGrams,
          reason: recipeCatalogDe[i].slug);
    }
  });

  group('foldRecipeSearchText', () {
    test('faltet Umlaute und ß und senkt die Schreibung', () {
      expect(foldRecipeSearchText('Hähnchen'), 'haehnchen');
      expect(foldRecipeSearchText('Süßkartoffel'), 'suesskartoffel');
      expect(foldRecipeSearchText('ÖL'), 'oel');
      expect(foldRecipeSearchText('Haehnchen'), 'haehnchen');
    });

    test('Query und Feld treffen sich unabhängig von der Schreibweise', () {
      const feld = 'Hähnchen mit Reis & Brokkoli';
      for (final query in const ['haehnchen', 'Hähnchen', 'HAEHNCHEN']) {
        expect(
          foldRecipeSearchText(feld).contains(foldRecipeSearchText(query)),
          isTrue,
          reason: query,
        );
      }
    });
  });

  group('rotatedRecommendations', () {
    final pool = List<FitnessRecipe>.generate(30, (i) => _rezept('r$i'));

    test('liefert vier Rezepte und verschiebt sich pro Kalendertag um eins',
        () {
      final heute = rotatedRecommendations(pool, DateTime(2026, 8, 27));
      final morgen = rotatedRecommendations(pool, DateTime(2026, 8, 28));
      expect(heute, hasLength(4));
      expect(morgen, hasLength(4));
      expect(morgen.first, same(heute[1]));
      expect(heute.map((r) => r.slug).toSet(), hasLength(4),
          reason: 'keine Dopplung innerhalb eines Tages');
    });

    test('läuft über das Katalogende hinweg (wrap-around)', () {
      DateTime tagMitStart(int start) {
        var d = DateTime(2026, 1, 1);
        while (rotatedRecommendations(pool, d).first.slug != 'r$start') {
          d = d.add(const Duration(days: 1));
        }
        return d;
      }

      final auswahl = rotatedRecommendations(pool, tagMitStart(28));
      expect(auswahl.map((r) => r.slug).toList(), ['r28', 'r29', 'r0', 'r1']);
    });

    test('Tageszeit ändert die Auswahl nicht, nur das Datum', () {
      final frueh = rotatedRecommendations(pool, DateTime(2026, 8, 27, 0, 5));
      final spaet = rotatedRecommendations(pool, DateTime(2026, 8, 27, 23, 55));
      expect(frueh.map((r) => r.slug), spaet.map((r) => r.slug));
    });

    test('ein kleiner Pool kommt ganz zurück, ein leerer leer', () {
      final klein = pool.take(2).toList();
      expect(rotatedRecommendations(klein, DateTime(2026, 8, 27)), hasLength(2));
      expect(rotatedRecommendations(const [], DateTime(2026, 8, 27)), isEmpty);
    });

    test('alle 30 Katalogrezepte kommen im Laufe eines Monats dran', () {
      final gesehen = <String>{};
      for (var i = 0; i < 30; i++) {
        gesehen.addAll(
          rotatedRecommendations(recipeCatalogDe, DateTime(2026, 8, 1 + i))
              .map((r) => r.slug),
        );
      }
      expect(gesehen, hasLength(30));
    });
  });
}
