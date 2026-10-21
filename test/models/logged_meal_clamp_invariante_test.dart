// P2-01 (Review 2026-08-29): `FitnessRecipe.toMealResult` war der EINZIGE
// Erzeuger eines MealAnalysisResult ohne Klemmung — `fromEdgeFunction`,
// `fromOpenFoodFacts` und `manualEntry` rufen alle `clampMealName` & Co.
// Ausgerechnet diese Funktion benennt `model_limits.dart` als
// Durchsetzungspunkt der `logged_meals`-Grenzen.
//
// Auslöser: `user_recipes` deckelt Text bei 300 CODEPUNKTEN, das Anlege-Sheet
// bei 160 GRAPHEMEN. 30 ZWJ-Familien-Emoji sind 30 Grapheme und 210
// Codepunkte — legal anlegbar, aber `char_length(meal_name) between 1 and 160`
// reißt beim Loggen mit 23514. Die Outbox liest das als aktive Server-Ablehnung,
// wiederholt achtmal und verwirft: die Mahlzeit steht lokal im Tagebuch,
// erreicht den Server nie und ist nach dem nächsten Kaltstart weg.
//
// Der Test hat drei Ebenen — die letzten beiden sind der eigentliche Wert:
//
//   1. Der konkrete Nachweis für P2-01 (210-Codepunkte-Titel).
//   2. Eine Invariante über ALLE Erzeuger: die ECHTE `logged_meals`-Zeile, die
//      `encodeSyncOperationPayload` aus dem Ergebnis baut, muss durch jede
//      Spalte passen — inklusive `FavoriteMeal.idFor` (P2-02, die zweite
//      Hälfte desselben Constraints).
//   3. Zwei Registraturen, die den NÄCHSTEN fehlenden Clamp fangen: eine neue
//      Datei mit `MealAnalysisResult(` und eine neue Spalte in dieser Zeile
//      müssen hier eingetragen werden, sonst rot.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/services/meal_description_matcher.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_outbox.dart';

/// 👨‍👩‍👧‍👦 — 4 Personen + 3 ZWJ = 7 Codepunkte, 1 Graphem.
final String _familie = String.fromCharCodes(const <int>[
  0x1F468,
  0x200D,
  0x1F469,
  0x200D,
  0x1F467,
  0x200D,
  0x1F466,
]);

/// Genau der Titel aus dem Befund: 30 Grapheme (kommt durch `maxLength: 160`),
/// 210 Codepunkte (kommt durch den 300er-Codepunkt-Check von
/// `user_recipes.title`), aber 210 > 160 für `logged_meals.meal_name`.
final String _titel210 = _familie * 30;

// ---------------------------------------------------------------------------
// Die Invariante
// ---------------------------------------------------------------------------

/// The `logged_meals` row the outbox replay writes for [r] — the production
/// encoder, not a re-implementation of its macro parser.
Map<String, dynamic> _zeile(MealAnalysisResult r) =>
    encodeSyncOperationPayload(
          SyncOp.mealUpsert(
            LoggedMeal(
              id: 'm-p2-01',
              result: r,
              loggedAt: DateTime.utc(2026, 8, 29, 12),
            ),
          ),
        )['row']
        as Map<String, dynamic>;

/// Prüft die Zeile eines Ergebnisses gegen JEDE Grenze, die
/// `logged_meals_safe_ranges_check` auf die befüllten Spalten legt — plus den
/// `favorite_key`, der aus demselben Namen gebaut wird (P2-02).
void erwarteSchreibbarAlsLoggedMeal(
  MealAnalysisResult r, {
  required String quelle,
}) {
  final zeile = _zeile(r);
  final name = zeile['meal_name'] as String;
  expect(
    isValidMealName(name),
    isTrue,
    reason: '$quelle: meal_name hat ${charLength(name)} Codepunkte, '
        'erlaubt sind 1..${LoggedMealLimits.mealNameMaxChars}.',
  );
  expect(
    isValidMealCaloriesKcal(zeile['calories_kcal'] as num),
    isTrue,
    reason: '$quelle: calories_kcal ${zeile['calories_kcal']}',
  );
  expect(
    isValidMealEstimatedG(zeile['estimated_g'] as num),
    isTrue,
    reason: '$quelle: estimated_g ${zeile['estimated_g']}',
  );

  for (final spalte in const <String>['protein_g', 'carbs_g', 'fat_g']) {
    // `null` ist erlaubt: die Spalten sind nullable, "-" heißt unbekannt.
    final wert = zeile[spalte] as num?;
    if (wert == null) continue;
    expect(
      isValidMealMacroG(wert),
      isTrue,
      reason: '$quelle: $spalte wird als $wert geschrieben, erlaubt sind '
          '0..${LoggedMealLimits.macroGMax.toInt()}.',
    );
  }

  for (final (spalte, grenze) in <(String, int)>[
    ('barcode', LoggedMealLimits.barcodeMaxChars),
    ('brand', LoggedMealLimits.brandMaxChars),
    ('source_label', LoggedMealLimits.sourceLabelMaxChars),
  ]) {
    final text = zeile[spalte] as String?;
    if (text == null) continue;
    expect(charLength(text), lessThanOrEqualTo(grenze),
        reason: '$quelle: $spalte');
  }

  // P2-02: `FavoriteMeal.idFor` kürzt selbst nichts. Der Schlüssel ist
  // `name:<mealName kleingeschrieben>` bzw. `barcode:<code>` — er bleibt genau
  // dann innerhalb von 180 Zeichen, wenn Name und Barcode oben passen.
  expect(
    isValidFavoriteKey(FavoriteMeal.idFor(r)),
    isTrue,
    reason: '$quelle: favorite_key hat '
        '${charLength(FavoriteMeal.idFor(r))} Codepunkte, erlaubt sind '
        '1..${FavoriteMealLimits.favoriteKeyMaxChars}.',
  );
}

// ---------------------------------------------------------------------------
// Bösartige Eingaben je Erzeuger
// ---------------------------------------------------------------------------

FitnessRecipe _boesesRezept() => FitnessRecipe(
      slug: 'user_p2_01',
      title: _titel210,
      description: 'd' * 500,
      portion: 'p' * 500,
      ingredients: 'z' * 500,
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      // `user_recipes` kennt nur `>= 0`, keine Obergrenzen.
      caloriesKcal: 999999,
      proteinG: 5000,
      carbsG: 5000,
      fatG: 5000,
      estimatedGrams: 999999,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

/// Eine Beschreibung mit 20 Zeilen, deren Werte niemand geklemmt hat: das
/// Modell-Ergebnis, ein Index-Treffer mit Riesentitel, Riesenmarke und
/// Riesencode, und eine direkt gebaute Zeile mit unmoeglicher Grammzahl.
MealDescriptionDraft _boeserEntwurf() {
  final beschrieben = DescribedFoodItem(
    name: _titel210,
    searchQuery: 'q',
    grams: 999999,
    gramsSource: DescribedGramsSource.stated,
    caloriesKcal: 999999,
  );
  final kandidat = DraftCandidate(
    origin: DraftItemOrigin.product,
    title: _titel210,
    brand: 'b' * 400,
    kcalPer100G: 99999,
    proteinPer100G: 5000,
    carbsPer100G: 5000,
    fatPer100G: 5000,
    barcode: '9' * 400,
  );
  final zeile = DraftFoodItem(
    described: beschrieben,
    selected: kandidat,
    candidates: <DraftCandidate>[kandidat],
    grams: 999999,
  );
  return MealDescriptionDraft(
    meal: DescribedMeal(
      base: MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': _titel210,
        'caloriesKcal': 999999,
        'estimatedGrams': 999999,
        'confidence': 'high',
      }),
      items: <DescribedFoodItem>[beschrieben],
    ),
    items: List<DraftFoodItem>.filled(DescribedMeal.maxItems, zeile),
  );
}

Map<String, MealAnalysisResult> _alleErzeuger() {
  final ausRezept = _boesesRezept().toMealResult();
  return <String, MealAnalysisResult>{
    'FitnessRecipe.toMealResult': ausRezept,
    'MealDescriptionDraft.toResult': _boeserEntwurf().toResult(),
    // 'İ' (U+0130): would a full Unicode lowercase in `idFor` turn one
    // codepoint into two, the clamped name would outgrow the favorite_key.
    'MealAnalysisResult.fromEdgeFunction': MealAnalysisResult.fromEdgeFunction(
      <String, dynamic>{
        'mealName': 'İ' * 300,
        'caloriesKcal': 999999,
        'estimatedGrams': 999999,
        'kcalPer100G': 99999,
        'proteinG': 5000,
        'carbsG': 5000,
        'fatG': 5000,
        'confidence': 'high',
      },
    ),
    // Realistischer Barcode: der Scanner ist auf EAN-8/EAN-13/UPC-A begrenzt.
    'MealAnalysisResult.fromOpenFoodFacts': MealAnalysisResult.fromOpenFoodFacts(
      <String, dynamic>{
        'product_name': _titel210,
        'brands': 'b' * 400,
        'serving_quantity': 999999,
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 800,
          'proteins_100g': 900,
          'carbohydrates_100g': 900,
          'fat_100g': 900,
        },
      },
      '4001234567890',
    ),
    // P2-01b: der Code kommt NICHT nur von der Kamera. `ProductSearchResult
    // .fromOpenFoodFacts` nimmt `product['code']` wortwoertlich aus dem
    // Meilisearch-/OFF-Index — ueber 64 Zeichen reisst `logged_meals.barcode`,
    // ueber 172 zusaetzlich der `favorite_key`, der aus `barcode:<code>` gebaut
    // wird.
    'MealAnalysisResult.fromOpenFoodFacts (Index-Code aus der Suche)':
        MealAnalysisResult.fromOpenFoodFacts(
      <String, dynamic>{
        'product_name': _titel210,
        'brands': 'b' * 400,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 500},
      },
      '9' * 400,
    ),
    'MealAnalysisResult.manualEntry': MealAnalysisResult.manualEntry(
      name: _titel210,
      kcalPer100G: 99999,
      grams: 999999,
      proteinPer100G: 5000,
      carbsPer100G: 5000,
      fatPer100G: 5000,
    ),
    'MealAnalysisResult.adjustedToGrams': ausRezept.adjustedToGrams(999999),
    'MealAnalysisResult.adjustedToItems': ausRezept.adjustedToItems(
      <MealComponent>[
        const MealComponent(
          name: 'Posten',
          grams: 999999,
          caloriesKcal: 999999,
          kcalPer100G: 99999,
          proteinG: 5000,
          carbsG: 5000,
          fatG: 5000,
        ),
      ],
    ),
  };
}

// ---------------------------------------------------------------------------
// Registratur 1: Dateien unter lib/, die ein MealAnalysisResult bauen
// ---------------------------------------------------------------------------

/// Jede Datei, die `MealAnalysisResult(` aufruft, mit der Begründung, warum
/// sie geklemmte Werte liefert. Eine NEUE Datei muss hier eingetragen und in
/// [_alleErzeuger] abgedeckt werden — genau der Schritt, der bei
/// `toMealResult` fehlte.
const Map<String, String> _erzeugerDateien = <String, String>{
  'lib/src/models/meal_analysis_result.dart':
      'die Klasse selbst plus fromEdgeFunction/fromOpenFoodFacts/manualEntry/'
          'adjustedToGrams/adjustedToItems — alle in _alleErzeuger',
  'lib/src/models/fitness_recipe.dart':
      'toMealResult, seit P2-01 geklemmt — in _alleErzeuger',
  'lib/src/services/meals_sync.dart':
      'mealResultFromJson liest zurueck, was vorher geschrieben wurde: die '
          'Zeile hat den Constraint bereits passiert, ein Clamp beim Lesen '
          'wuerde Server- und Lokalstand auseinanderlaufen lassen',
  'lib/src/widgets/kcal/manual_meal_sheet.dart':
      'baut aus MealAnalysisResult.manualEntry um und nimmt jeden Wert von '
          'dort; die Makros gehen durch macroForGrams, das selbst klemmt',
  'lib/src/services/meal_description_matcher.dart':
      'MealDescriptionDraft.toResult nimmt jeden Wert aus adjustedToItems '
          'ueber geklemmte Zeilen-Komponenten — in _alleErzeuger',
  'lib/src/widgets/kcal/meal_describe_draft.dart':
      'nur die Vorschau im Zeileneditor (Makro-Zeile); sie wird nie '
          'geloggt, geloggt wird toResult',
};

/// Spalten der `logged_meals`-Zeile, die jede Mahlzeit-Operation schreibt, mit
/// der Begründung, warum sie gedeckt sind. Eine neue Spalte muss hier
/// eingetragen werden. `user_id` fehlt, weil die RPC den Besitzer aus der
/// Anmeldung nimmt.
const Map<String, String> _upsertSpalten = <String, String>{
  'id': 'Client-UUID, kommt nicht aus dem Ergebnis',
  'logged_at': 'Zeitstempel',
  'local_day': 'abgeleiteter Tagesschluessel',
  'forced_slot': 'Enum-Name, durch forcedSlotValues gedeckt',
  'meal_name': 'geprueft: clampMealName',
  'calories_kcal': 'geprueft: clampMealCaloriesKcal',
  'estimated_g': 'geprueft: clampMealEstimatedG',
  'protein_g': 'geprueft: isValidMealMacroG auf dem geschriebenen Wert',
  'carbs_g': 'geprueft: isValidMealMacroG auf dem geschriebenen Wert',
  'fat_g': 'geprueft: isValidMealMacroG auf dem geschriebenen Wert',
  'barcode': 'geprueft: barcodeMaxChars',
  'brand': 'geprueft: brandMaxChars',
  'source_label': 'geprueft: sourceLabelMaxChars',
  'payload': 'JSON, nur als Ganzes begrenzt (payloadMaxBytes)',
};

/// Quelltext ohne `//`-Kommentare — sonst zaehlt ein erklaerender Kommentar
/// als Treffer.
String _ohneKommentare(String quelle) => quelle
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('//');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

Set<String> _dateienMitErzeuger() {
  final gefunden = <String>{};
  for (final eintrag in Directory('lib').listSync(recursive: true)) {
    if (eintrag is! File || !eintrag.path.endsWith('.dart')) continue;
    final pfad = eintrag.path.replaceAll(r'\', '/');
    if (_ohneKommentare(eintrag.readAsStringSync())
        .contains('MealAnalysisResult(')) {
      gefunden.add(pfad);
    }
  }
  return gefunden;
}

// ---------------------------------------------------------------------------

void main() {
  group('P2-01: toMealResult klemmt auf die logged_meals-Grenzen', () {
    test('210-Codepunkte-Titel, Zahlen und Makros kommen geklemmt heraus', () {
      final rezept = _boesesRezept();
      // Vorbedingung: genau der Fall aus dem Befund — 30 Grapheme zu je 7
      // Codepunkten kommen durch `maxLength: 160` UND durch den 300er-Check.
      expect(charLength(rezept.title), 30 * 7);

      final meal = rezept.toMealResult();
      expect(isValidMealName(meal.mealName), isTrue);
      expect(meal.caloriesKcal, LoggedMealLimits.caloriesKcalMax);
      expect(meal.estimatedGrams, LoggedMealLimits.estimatedGMax);
      // 5000 g Protein wuerde als 5000 in eine 0..1000-Spalte geschrieben.
      expect(meal.protein, '${LoggedMealLimits.macroGMax.toInt()} g');
      expect(meal.carbs, '${LoggedMealLimits.macroGMax.toInt()} g');
      expect(meal.fat, '${LoggedMealLimits.macroGMax.toInt()} g');
      expect(isPlausibleKcalPer100G(meal.kcalPer100G), isTrue);
    });

    test('ein normales Katalogrezept bleibt Zeichen fuer Zeichen gleich', () {
      // Der Clamp darf nichts an gesunden Werten aendern.
      final rezept = recipeCatalogDe.first;
      final meal = rezept.toMealResult();
      expect(meal.mealName, rezept.title);
      expect(meal.caloriesKcal, rezept.caloriesKcal);
      expect(meal.estimatedGrams, rezept.estimatedGrams);
      expect(meal.protein, '${rezept.proteinG} g');
      expect(meal.carbs, '${rezept.carbsG} g');
      expect(meal.fat, '${rezept.fatG} g');
      expect(meal.kcalPer100G, rezept.kcalPer100G);
    });
  });

  group('Invariante: JEDER Erzeuger liefert ein schreibbares Ergebnis', () {
    _alleErzeuger().forEach((name, ergebnis) {
      test('$name haelt jede logged_meals-Spalte ein', () {
        erwarteSchreibbarAlsLoggedMeal(ergebnis, quelle: name);
      });
    });
  });

  group('P2-01b: der Barcode kommt geklemmt aus der Produktsuche', () {
    /// Ein Code, wie ihn nur der Index liefern kann — nie der Scanner.
    final langerCode = '9' * 400;

    MealAnalysisResult riegel(String code) =>
        MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
          'product_name': 'Riegel',
          'nutriments': <String, dynamic>{'energy-kcal_100g': 500},
        }, code);

    test('fromOpenFoodFacts kuerzt einen Index-Code, ein echter EAN bleibt', () {
      expect(riegel(langerCode).barcode, '9' * LoggedMealLimits.barcodeMaxChars,
          reason: 'gekuerzt, nicht verworfen');
      expect(riegel('4001234567890').barcode, '4001234567890');
    });

    test('ProductSearchResult nimmt product[code] nicht mehr wortwoertlich',
        () {
      final treffer = ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
        'code': langerCode,
        'product_name': 'Riegel',
        'nutriments': <String, dynamic>{'energy-kcal_100g': 500},
      });
      expect(charLength(treffer.code), LoggedMealLimits.barcodeMaxChars);
      expect(treffer.result.barcode, treffer.code,
          reason: 'Trefferliste und Ergebnis muessen denselben Code fuehren, '
              'sonst laufen Favoriten-Schluessel auseinander');
    });
  });

  group('Registratur: der naechste fehlende Clamp faellt hier auf', () {
    test('nur bekannte Dateien bauen ein MealAnalysisResult', () {
      expect(
        _dateienMitErzeuger(),
        _erzeugerDateien.keys.toSet(),
        reason: 'Eine Datei baut ein MealAnalysisResult, ohne in '
            '_erzeugerDateien mit Begruendung zu stehen (oder eine bekannte '
            'ist weg). Neue Erzeuger gehoeren zusaetzlich in _alleErzeuger.',
      );
    });

    test('jede Spalte der logged_meals-Zeile ist hier begruendet', () {
      expect(
        _zeile(_boesesRezept().toMealResult()).keys.toSet(),
        _upsertSpalten.keys.toSet(),
        reason: 'Die Mahlzeit-Zeile schreibt eine Spalte, die diese Invariante '
            'nicht kennt — sie ist damit ungeprueft.',
      );
    });
  });
}
