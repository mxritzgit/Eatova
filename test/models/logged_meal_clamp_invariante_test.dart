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
//   2. Eine Invariante über ALLE Erzeuger: was hier herauskommt, muss durch
//      jede Spalte passen, die `MealsSync` aus dem Ergebnis befüllt — inklusive
//      `FavoriteMeal.idFor` (P2-02, die zweite Hälfte desselben Constraints).
//   3. Zwei Registraturen, die den NÄCHSTEN fehlenden Clamp fangen: eine neue
//      Datei mit `MealAnalysisResult(` und eine neue Spalte im
//      `logged_meals`-Upsert müssen hier eingetragen werden, sonst rot.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/model_limits.dart';

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

/// Nachbau von `MealsSync._macroToNumeric`: die App schreibt keinen `double`,
/// sondern die erste Zahl aus dem Makro-TEXT in eine `numeric`-Spalte.
/// `_makroRegexIstNochDieselbe` hält den Nachbau am Original fest.
num? _macroZuNumeric(String macroText) {
  final match = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(macroText);
  if (match == null) return null;
  return num.tryParse(match.group(1)!.replaceAll(',', '.'));
}

/// Prüft ein Ergebnis gegen JEDE Grenze, die `logged_meals_safe_ranges_check`
/// auf die von `MealsSync` befüllten Spalten legt — plus den `favorite_key`,
/// der aus demselben Namen gebaut wird (P2-02).
void erwarteSchreibbarAlsLoggedMeal(
  MealAnalysisResult r, {
  required String quelle,
}) {
  expect(
    isValidMealName(r.mealName),
    isTrue,
    reason: '$quelle: meal_name hat ${charLength(r.mealName)} Codepunkte, '
        'erlaubt sind 1..${LoggedMealLimits.mealNameMaxChars}.',
  );
  expect(
    isValidMealCaloriesKcal(r.caloriesKcal),
    isTrue,
    reason: '$quelle: calories_kcal ${r.caloriesKcal}',
  );
  expect(
    isValidMealEstimatedG(r.estimatedGrams),
    isTrue,
    reason: '$quelle: estimated_g ${r.estimatedGrams}',
  );

  for (final (spalte, text) in <(String, String)>[
    ('protein_g', r.protein),
    ('carbs_g', r.carbs),
    ('fat_g', r.fat),
  ]) {
    final wert = _macroZuNumeric(text);
    // `null` ist erlaubt: die Spalten sind nullable, "-" heißt unbekannt.
    if (wert == null) continue;
    expect(
      isValidMealMacroG(wert),
      isTrue,
      reason: '$quelle: $spalte wird als $wert geschrieben (aus "$text"), '
          'erlaubt sind 0..${LoggedMealLimits.macroGMax.toInt()}.',
    );
  }

  final barcode = r.barcode;
  if (barcode != null) {
    expect(
      charLength(barcode),
      lessThanOrEqualTo(LoggedMealLimits.barcodeMaxChars),
      reason: '$quelle: barcode',
    );
  }
  final brand = r.brand;
  if (brand != null) {
    expect(
      charLength(brand),
      lessThanOrEqualTo(LoggedMealLimits.brandMaxChars),
      reason: '$quelle: brand',
    );
  }
  expect(
    charLength(r.sourceLabel),
    lessThanOrEqualTo(LoggedMealLimits.sourceLabelMaxChars),
    reason: '$quelle: source_label',
  );

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

Map<String, MealAnalysisResult> _alleErzeuger() {
  final ausRezept = _boesesRezept().toMealResult();
  return <String, MealAnalysisResult>{
    'FitnessRecipe.toMealResult': ausRezept,
    'MealAnalysisResult.fromEdgeFunction': MealAnalysisResult.fromEdgeFunction(
      <String, dynamic>{
        'mealName': _titel210,
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
    // `fromOpenFoodFacts` reicht `barcode` ungeklemmt durch — dokumentierter
    // Fremdbedarf an meal_analysis_result.dart, hier nicht behebbar.
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
};

/// Spalten des `logged_meals`-Upserts in `MealsSync.insertLoggedMeal` mit der
/// Begründung, warum sie gedeckt sind. Eine neue Spalte muss hier eingetragen
/// werden.
const Map<String, String> _upsertSpalten = <String, String>{
  'id': 'Client-UUID, kommt nicht aus dem Ergebnis',
  'user_id': 'aus der Session',
  'logged_at': 'Zeitstempel',
  'local_day': 'abgeleiteter Tagesschluessel',
  'forced_slot': 'Enum-Name, durch forcedSlotValues gedeckt',
  'meal_name': 'geprueft: clampMealName',
  'calories_kcal': 'geprueft: clampMealCaloriesKcal',
  'estimated_g': 'geprueft: clampMealEstimatedG',
  'protein_g': 'geprueft: Makro-Text -> _macroZuNumeric',
  'carbs_g': 'geprueft: Makro-Text -> _macroZuNumeric',
  'fat_g': 'geprueft: Makro-Text -> _macroZuNumeric',
  'barcode': 'geprueft: barcodeMaxChars',
  'brand': 'geprueft: brandMaxChars',
  'source_label': 'geprueft: sourceLabelMaxChars',
  'payload': 'JSON, nur als Ganzes begrenzt (payloadMaxBytes)',
};

String _lies(String pfad) {
  final datei = File(pfad);
  expect(datei.existsSync(), isTrue, reason: '$pfad fehlt');
  return datei.readAsStringSync();
}

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

Set<String> _spaltenDesUpserts() {
  final quelle = _ohneKommentare(_lies('lib/src/services/meals_sync.dart'));
  const kopf = "from('logged_meals').upsert({";
  final start = quelle.indexOf(kopf);
  expect(start, isNonNegative, reason: 'insertLoggedMeal-Upsert nicht gefunden');
  final ende = quelle.indexOf('}, onConflict:', start);
  expect(ende, isNonNegative, reason: 'Ende des Upsert-Maps nicht gefunden');
  final block = quelle.substring(start + kopf.length, ende);
  return RegExp(r"'([a-z_]+)':")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

// ---------------------------------------------------------------------------

void main() {
  group('P2-01: toMealResult klemmt auf die logged_meals-Grenzen', () {
    test('ein 210-Codepunkte-Titel wird beim Loggen auf 160 gekuerzt', () {
      final rezept = _boesesRezept();
      // Vorbedingung: genau der Fall aus dem Befund — 30 Grapheme zu je 7
      // Codepunkten kommen durch `maxLength: 160` UND durch den 300er-Check.
      expect(charLength(rezept.title), 30 * 7);
      expect(charLength(rezept.title), lessThanOrEqualTo(300));

      final meal = rezept.toMealResult();
      expect(
        charLength(meal.mealName),
        lessThanOrEqualTo(LoggedMealLimits.mealNameMaxChars),
      );
      expect(isValidMealName(meal.mealName), isTrue);
    });

    test('auch Zahlen und Makros kommen geklemmt heraus', () {
      final meal = _boesesRezept().toMealResult();
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

    test('ein Titel mit 161..300 Codepunkten aus fromRow trifft es genauso', () {
      // Der zweite, einfachere Ausloeser: alles, was schon gespeichert ist.
      final rezept = FitnessRecipe.fromRow(<String, dynamic>{
        'slug': 'user_alt',
        'title': 'A' * 300,
        'calories_kcal': 520,
        'protein_g': 40,
        'carbs_g': 50,
        'fat_g': 15,
        'estimated_g': 420,
      });
      expect(charLength(rezept.title), 300);
      expect(
        charLength(rezept.toMealResult().mealName),
        LoggedMealLimits.mealNameMaxChars,
      );
    });
  });

  group('Invariante: JEDER Erzeuger liefert ein schreibbares Ergebnis', () {
    _alleErzeuger().forEach((name, ergebnis) {
      test('$name haelt jede logged_meals-Spalte ein', () {
        erwarteSchreibbarAlsLoggedMeal(ergebnis, quelle: name);
      });
    });

    test('P2-02: der favorite_key bleibt aus demselben Namen im Rahmen', () {
      // `idFor` kuerzt nicht selbst — der Schluessel haengt komplett am
      // geklemmten Namen. `name:` + 160 = 165 <= 180.
      final meal = _boesesRezept().toMealResult();
      final schluessel = FavoriteMeal.idFor(meal);
      expect(schluessel.startsWith('name:'), isTrue);
      expect(
        charLength(schluessel),
        lessThanOrEqualTo(FavoriteMealLimits.favoriteKeyMaxChars),
      );
    });

    test('toLowerCase in idFor verlaengert den Namen nicht', () {
      // Waere `toLowerCase` eine VOLLE Unicode-Abbildung, koennte ein Zeichen
      // zu zweien werden (U+0130 -> i + Punkt) und 160 Codepunkte zu 320. Darts
      // Abbildung ist 1:1 — genau das haelt dieser Test fest.
      const kritisch = 'İ'; // LATIN CAPITAL LETTER I WITH DOT ABOVE
      final name = clampMealName(kritisch * 300);
      expect(charLength(name), LoggedMealLimits.mealNameMaxChars);
      expect(charLength(name.toLowerCase()), charLength(name));
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

    test('jede Spalte des logged_meals-Upserts ist hier begruendet', () {
      expect(
        _spaltenDesUpserts(),
        _upsertSpalten.keys.toSet(),
        reason: 'MealsSync schreibt eine Spalte, die diese Invariante nicht '
            'kennt — sie ist damit ungeprueft.',
      );
    });

    test('der Makro-Nachbau passt noch zur Regex in meals_sync', () {
      final quelle = _lies('lib/src/services/meals_sync.dart');
      expect(
        quelle.contains(r"RegExp(r'(\d+(?:[.,]\d+)?)')"),
        isTrue,
        reason: '_macroToNumeric parst anders als _macroZuNumeric hier — die '
            'Makro-Pruefung der Invariante misst dann das Falsche.',
      );
    });
  });
}
