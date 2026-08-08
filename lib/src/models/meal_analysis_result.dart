import '../services/food_kcal_db.dart';
import 'meal_component.dart';
import 'model_limits.dart';

/// Textmarke fuer "Makro unbekannt". Bewusst derselbe String, den die Parser
/// fuer fehlende Makros liefern — `MacroProgress._parseMacroG` liest daraus 0
/// und traegt damit nichts Erfundenes in die Tagesringe ein.
const String _makroUnbekannt = '-';

class MealAnalysisResult {
  const MealAnalysisResult({
    required this.mealName,
    required this.caloriesKcal,
    required this.estimatedGrams,
    required this.kcalPer100G,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.confidence,
    required this.portionNotes,
    this.items = const [],
    this.isAdjusted = false,
    this.sourceLabel = 'KI-Schätzung',
    this.barcode,
    this.brand,
  });

  final String mealName;
  final int caloriesKcal;
  final int estimatedGrams;
  final double kcalPer100G;
  final String protein;
  final String carbs;
  final String fat;
  final String confidence;
  final String portionNotes;
  final List<MealComponent> items;
  final bool isAdjusted;
  final String sourceLabel;
  final String? barcode;
  final String? brand;

  String get kcalRange => '$caloriesKcal kcal';
  String get portionLabel => '$estimatedGrams g geschätzt';

  /// Bewusst **nicht** ueber [effectiveKcalPer100G]: `0 kcal / 100 g` ist bei
  /// Open Food Facts eine gueltige Angabe (Wasser, Tee), waehrend dieselbe 0
  /// aus der Scan-Function "unbekannt" hiess. Beides ist im nicht-nullbaren
  /// `kcalPer100G` nicht unterscheidbar. Das Label bleibt deshalb rein
  /// formatierend; die Unterscheidung braucht ein nullbares Feld quer durch
  /// Sync, Favoriten und Widgets (Welle 3).
  String get kcalPer100Label => '${kcalPer100G.round()} kcal / 100 g';

  bool get hasItemizedBreakdown => items.isNotEmpty;

  /// kcal/100 g, sofern der Wert brauchbar ist — sonst `null`.
  ///
  /// Siehe [MealComponent.effectiveKcalPer100G]: `0` ist der Sentinel, den der
  /// Server fuer nicht parsebare (und fuer negative) Modellwerte lieferte,
  /// Werte ueber 900 sind physikalisch unmoeglich. Beides heisst "fehlt".
  double? get effectiveKcalPer100G {
    if (!kcalPer100G.isFinite || kcalPer100G <= 0) {
      return null;
    }
    return isPlausibleKcalPer100G(kcalPer100G) ? kcalPer100G : null;
  }

  /// Die Mahlzeit als genau ein Bestandteil — dieselbe Synthese, die das
  /// Bestandteil-Sheet vornimmt, wenn das Modell keine Einzelposten lieferte.
  /// Sie ist die Vergleichsbasis fuer [adjustedToItems].
  MealComponent get asSingleComponent => MealComponent(
    name: mealName,
    grams: estimatedGrams,
    caloriesKcal: caloriesKcal,
    kcalPer100G: kcalPer100G,
  );

  /// Rechnet die Mahlzeit auf [grams] um.
  ///
  /// **`caloriesKcal` ist autoritativ, nicht `kcalPer100G`.** Begruendung:
  /// die Kalorienzahl ist das Feld, das gross auf der Karte steht und das der
  /// Nutzer beim Tippen auf "Anpassen" bestaetigt; die Dichte ist ein
  /// Nebenfeld, das der Server unabhaengig klemmt und nie mit den anderen
  /// beiden abgleicht. Daraus folgt die Invariante
  /// `adjustedToGrams(estimatedGrams).caloriesKcal == caloriesKcal` —
  /// blosses Bestaetigen darf die Zahl nicht veraendern.
  ///
  /// Die Dichte wird nur dann zur Bezugsgroesse, wenn sich aus Kalorien und
  /// Gramm nichts herleiten laesst (Ursprungsportion 0 g oder 0 kcal).
  MealAnalysisResult adjustedToGrams(int grams) {
    final zielGramm = clampPortionGrams(grams);
    final dichte = effectiveKcalPer100G;
    final int neueKcal;
    if (estimatedGrams > 0 && caloriesKcal > 0) {
      neueKcal = clampMealCaloriesKcal(caloriesKcal * zielGramm / estimatedGrams);
    } else if (dichte != null) {
      neueKcal = clampMealCaloriesKcal(dichte * zielGramm / 100);
    } else {
      neueKcal = 0;
    }
    final neueDichte = neueKcal > 0
        ? clampKcalPer100G(neueKcal * 100 / zielGramm)
        : (dichte ?? 0);
    final factor = estimatedGrams <= 0 ? 1.0 : zielGramm / estimatedGrams;
    final adjustedItems = hasItemizedBreakdown
        ? items
              .map((item) => item.adjustedToGrams((item.grams * factor).round()))
              .toList(growable: false)
        : items;

    return MealAnalysisResult(
      mealName: mealName,
      caloriesKcal: neueKcal,
      estimatedGrams: zielGramm,
      kcalPer100G: neueDichte,
      protein: _scaleMacroText(protein, factor),
      carbs: _scaleMacroText(carbs, factor),
      fat: _scaleMacroText(fat, factor),
      confidence: confidence,
      portionNotes: neueDichte > 0
          ? 'Manuell angepasst: $zielGramm g statt der ursprünglichen Portion. Kalorien neu berechnet mit ${neueDichte.round()} kcal pro 100 g.'
          : 'Manuell angepasst: $zielGramm g statt der ursprünglichen Portion.',
      items: adjustedItems,
      isAdjusted: true,
      sourceLabel: sourceLabel,
      barcode: barcode,
      brand: brand,
    );
  }

  /// Uebernimmt die vom Nutzer bestaetigten Bestandteile.
  ///
  /// Kalorien und Gramm kommen aus der Summe der Posten. Die **Makros** aber
  /// duerfen nicht laenger per Massenverhaeltnis mitskaliert werden
  /// (docs/REVIEW-2026-08-08.md, B8): wer 20 g Olivenoel ergaenzt, aendert die
  /// Masse um 5 %, das Fett aber um 160 %. Drei Faelle, in dieser Reihenfolge:
  ///
  /// 1. **Alle Posten tragen eigene Makros** — dann wird exakt aufsummiert.
  /// 2. **Die Zusammensetzung hat sich nur einheitlich umskaliert** (dieselben
  ///    Posten in derselben Reihenfolge, alle mit demselben Gramm-Faktor;
  ///    Faktor 1,0 = unveraendert bestaetigt). Das ist eine reine
  ///    Portionsaenderung, hier ist Massenskalierung korrekt.
  /// 3. **Sonst** (Posten ergaenzt, entfernt oder ungleichmaessig geaendert)
  ///    sind die Makros **unbekannt**. Eine falsche Zahl, die praezise
  ///    aussieht, ist schaedlicher als eine fehlende.
  MealAnalysisResult adjustedToItems(List<MealComponent> adjustedItems) {
    final totalGrams = clampMealEstimatedG(
      adjustedItems.fold<int>(0, (sum, item) => sum + item.grams),
    );
    final totalKcal = clampMealCaloriesKcal(
      adjustedItems.fold<int>(0, (sum, item) => sum + item.caloriesKcal),
    );

    final summe = _macrosFromItems(adjustedItems);
    final basis = items.isNotEmpty
        ? items
        : <MealComponent>[asSingleComponent];
    final gleichmaessigerFaktor = summe == null
        ? _uniformFactor(adjustedItems, basis)
        : null;
    final bool makrosUnbekannt = summe == null && gleichmaessigerFaktor == null;

    String makro(String bisher, double? ausSumme) {
      if (ausSumme != null) return _formatMacroG(ausSumme);
      if (gleichmaessigerFaktor != null) {
        return _scaleMacroText(bisher, gleichmaessigerFaktor);
      }
      return _makroUnbekannt;
    }

    return MealAnalysisResult(
      mealName: mealName,
      caloriesKcal: totalKcal,
      estimatedGrams: totalGrams,
      kcalPer100G: totalGrams > 0
          ? clampKcalPer100G(totalKcal * 100 / totalGrams)
          : kcalPer100G,
      protein: makro(protein, summe?.protein),
      carbs: makro(carbs, summe?.carbs),
      fat: makro(fat, summe?.fat),
      confidence: confidence,
      portionNotes: makrosUnbekannt
          ? 'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. '
                'Kalorien und Gramm wurden aus der Summe der Positionen neu berechnet. '
                'Die Makro-Nährwerte lassen sich aus der geänderten Zusammensetzung '
                'nicht mehr ableiten und werden deshalb nicht ausgewiesen.'
          : 'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. Gesamtwerte wurden aus der Summe der Positionen neu berechnet.',
      items: adjustedItems,
      isAdjusted: true,
      sourceLabel: sourceLabel,
      barcode: barcode,
      brand: brand,
    );
  }

  /// Parst die Antwort der `analyze-meal`-Function.
  ///
  /// Die Function liefert jeden Schluessel **immer**, den Wert aber wahlweise
  /// als Zahl, als `0` (der alte Clamp-Sentinel fuer nicht parsebare Werte,
  /// und weiterhin das Ergebnis fuer negative Eingaben) oder als `null` (die
  /// Form nach dem Server-Fix). Alle drei Formen muessen hier zum selben
  /// Ergebnis fuehren, deshalb gilt ueberall `<= 0` als "fehlt", nicht nur
  /// `== null`.
  factory MealAnalysisResult.fromEdgeFunction(Map<String, dynamic> json) {
    final mealName = clampMealName(
      json['mealName']?.toString() ?? 'Unbekannte Mahlzeit',
    );
    final items = _readItems(json);
    final itemCalories = items.fold<int>(0, (sum, item) => sum + item.caloriesKcal);
    final itemGrams = items.fold<int>(0, (sum, item) => sum + item.grams);
    final calories = _readPositiveInt(json, const [
          'caloriesKcal',
          'kcal',
          'calories',
          'estimatedCaloriesKcal',
        ]) ??
        _positive(_extractFirstInt(json['caloriesKcal']?.toString())) ??
        _positive(_extractFirstInt(json['calories']?.toString())) ??
        (itemCalories > 0 ? itemCalories : 0);
    // Nur eine echte Modellangabe zaehlt als bekannte Portion. Die 150 g
    // weiter unten sind ein Default und duerfen nicht als Bezugsgroesse fuer
    // eine hergeleitete Dichte durchgehen.
    final gemesseneGramm = _readPositiveInt(json, const [
          'estimatedGrams',
          'portionGrams',
          'grams',
          'weightG',
          'estimatedWeightG',
        ]) ??
        _positive(_estimateGramsFromText(json['explanation']?.toString())) ??
        (itemGrams > 0 ? itemGrams : null);
    final estimatedGrams = gemesseneGramm ?? 150;
    // Reihenfolge der Fallback-Kette, bewusst so:
    //   1. die explizite, plausible Modelldichte
    //   2. die Herleitung aus den beiden autoritativen Zahlen DIESES Fotos
    //   3. erst dann die namensbasierte Referenztabelle — sie matcht auf
    //      Teilstrings ('Apfelkuchen' enthaelt 'apfel') und weiss nichts von
    //      der Zubereitung, ist also die schwaechste Quelle
    //   4. zuletzt die Herleitung mit der Default-Portion
    final kcalPer100G = _readPlausibleDouble(json, const [
          'kcalPer100G',
          'caloriesPer100G',
          'caloriesPer100g',
          'kcalPer100g',
        ]) ??
        ((gemesseneGramm != null && gemesseneGramm > 0 && calories > 0)
            ? calories * 100 / gemesseneGramm
            : null) ??
        _knownKcalPer100G(mealName) ??
        ((estimatedGrams > 0 && calories > 0)
            ? calories * 100 / estimatedGrams
            : 52.0);
    final protein = json['proteinG'];
    final carbs = json['carbsG'];
    final fat = json['fatG'];
    final confidence = json['confidence']?.toString() ?? 'medium';
    final dichte = clampKcalPer100G(kcalPer100G);
    final resolvedCalories = clampMealCaloriesKcal(
      calories > 0 ? calories : (dichte * estimatedGrams / 100).round(),
    );
    final resolvedGrams = clampMealEstimatedG(
      estimatedGrams > 0 ? estimatedGrams : itemGrams,
    );
    var normalizedItems =
        itemGrams > 0 || itemCalories > 0 ? items : const <MealComponent>[];

    // If the upstream model returned the meal as a single (or empty) entry
    // but the meal name describes multiple foods, expand it client-side
    // using the local kcal database.
    var autoSplit = false;
    if (normalizedItems.length < 2) {
      final split = autoSplitItems(
        mealName: mealName,
        totalGrams: resolvedGrams,
        totalKcal: resolvedCalories,
      );
      if (split.length >= 2) {
        normalizedItems = split;
        autoSplit = true;
      }
    }

    return MealAnalysisResult(
      mealName: mealName,
      caloriesKcal: resolvedCalories,
      estimatedGrams: resolvedGrams,
      kcalPer100G: dichte,
      protein: _macroTextFromRaw(protein),
      carbs: _macroTextFromRaw(carbs),
      fat: _macroTextFromRaw(fat),
      confidence: _formatConfidence(confidence),
      portionNotes: json['explanation']?.toString() ??
          (autoSplit
              ? 'KI hat als Gesamtgericht erkannt — Bestandteile lokal aufgesplittet. Gramm und Kalorien pro Posten prüfen.'
              : normalizedItems.isNotEmpty
                  ? 'KI-Schätzung aus dem Foto mit Einzelposten. Bitte Bestandteile und Gramm prüfen.'
                  : 'KI-Schätzung aus dem Foto. Die Größe wurde nicht exakt vermessen; bitte Portion bestätigen oder Gewicht anpassen.'),
      items: normalizedItems,
      sourceLabel: 'Foto-KI',
    );
  }

  factory MealAnalysisResult.fromOpenFoodFacts(
    Map<String, dynamic> product,
    String barcode,
  ) {
    final nutriments = product['nutriments'] is Map<String, dynamic>
        ? product['nutriments'] as Map<String, dynamic>
        : <String, dynamic>{};
    final productName = _firstNonEmptyString(product, const [
          'product_name',
          'generic_name',
        ]) ??
        'Produkt $barcode';
    final brand = clampBrand(_firstNonEmptyString(product, const ['brands']));
    final kcalPer100G = _offKcalPer100G(product, nutriments) ?? 0;
    final servingGrams = _offServingGrams(product);
    final calories = clampMealCaloriesKcal(kcalPer100G * servingGrams / 100);
    final protein100 = _readDouble(nutriments, const ['proteins_100g']);
    final carbs100 = _readDouble(nutriments, const ['carbohydrates_100g']);
    final fat100 = _readDouble(nutriments, const ['fat_100g']);
    final quantity = _firstNonEmptyString(product, const ['quantity']);
    final servingSize = _firstNonEmptyString(product, const ['serving_size']);
    final details = <String>[
      'OpenFoodFacts Barcode $barcode.',
      if (brand != null) 'Marke: $brand.',
      if (quantity != null) 'Packung: $quantity.',
      if (servingSize != null) 'Portion laut Datenbank: $servingSize.',
      'Nährwerte kommen aus der Produktdatenbank, nicht aus einer Foto-Schätzung.',
      'Du kannst das gegessene Gewicht weiter anpassen.',
    ].join(' ');

    return MealAnalysisResult(
      mealName: clampMealName(
        brand == null ? productName : '$productName · $brand',
      ),
      caloriesKcal: calories,
      estimatedGrams: servingGrams,
      kcalPer100G: kcalPer100G,
      protein: _macroForGrams(protein100, servingGrams),
      carbs: _macroForGrams(carbs100, servingGrams),
      fat: _macroForGrams(fat100, servingGrams),
      confidence: 'Datenbank',
      portionNotes: details,
      sourceLabel: 'OpenFoodFacts',
      barcode: barcode,
      brand: brand,
    );
  }

  static List<MealComponent> _readItems(Map<String, dynamic> json) {
    for (final key in const ['items', 'components', 'foods', 'foodItems']) {
      final value = json[key];
      if (value is List) {
        return value
            .whereType<Map>()
            .map(
              (item) => MealComponent.fromJson(
                item.map(
                  (itemKey, itemValue) => MapEntry(itemKey.toString(), itemValue),
                ),
              ),
            )
            .where((item) => item.name.trim().isNotEmpty)
            .toList(growable: false);
      }
    }
    return const <MealComponent>[];
  }

  // -------------------------------------------------------------------------
  // Open Food Facts: Bezugsgroesse, kJ-Umrechnung, Plausibilitaet (B7)
  // -------------------------------------------------------------------------

  /// Liest kcal **pro 100 g** aus den OFF-Naehrwerten, oder `null`.
  ///
  /// Reihenfolge und Begruendung:
  ///
  /// 1. `energy-kcal_100g` / `energy_kcal_100g` — ausdruecklich auf 100 g
  ///    bezogen, also direkt verwendbar.
  /// 2. `energy-kcal_value` **nur** bei `nutrition_data_per == '100g'`. Das
  ///    Feld ist in OFF basisabhaengig: bei portionsweise erfassten Produkten
  ///    steht dort der Portionswert. Ohne die Basis ist es unbrauchbar: lieber
  ///    keine Zahl als eine mit unbekannter Bezugsgroesse (die Tiefkuehlpizza
  ///    mit 900 "kcal/100 g" wurde bei 350 g zu 3150 statt 900 kcal).
  ///    `nutrition_data_per` wird seit Welle 2 in `_fields` angefragt
  ///    (`open_food_facts_product_service.dart`) und kommt auf beiden Pfaden
  ///    an — Barcode v3 und `cgi/search.pl`. Fehlt es trotzdem, faellt der
  ///    Kandidat durch, was die sichere Richtung ist.
  /// 3. kJ. `energy-kj_100g` ist eindeutig; `energy_100g` kommt ohne Einheit
  ///    und ist per OFF-Konvention kJ — es sei denn, `energy_unit` sagt
  ///    ausdruecklich `kcal`.
  ///
  /// Jeder Kandidat muss [isPlausibleKcalPer100G] bestehen. Ein unplausibler
  /// Wert wird **verworfen, nicht umgerechnet**: dass 2180 die kJ-Zahl fuer
  /// 521 kcal ist, ist eine Vermutung; es koennte genauso ein Komma- oder ein
  /// Packungswert sein. Eine falsche, aber plausibel aussehende Zahl landet
  /// unbemerkt im Tagebuch — eine fehlende faellt auf.
  static double? _offKcalPer100G(
    Map<String, dynamic> product,
    Map<String, dynamic> nutriments,
  ) {
    final proHundert = _readDouble(nutriments, const [
      'energy-kcal_100g',
      'energy_kcal_100g',
    ]);
    if (proHundert != null && isPlausibleKcalPer100G(proHundert)) {
      return proHundert;
    }

    if (_offBasisIst100G(product)) {
      final basisWert = _readDouble(nutriments, const ['energy-kcal_value']);
      if (basisWert != null && isPlausibleKcalPer100G(basisWert)) {
        return basisWert;
      }
    }

    final kj = _readDouble(nutriments, const ['energy-kj_100g']);
    if (kj != null) {
      final umgerechnet = kj / PlausibilityLimits.kjPerKcal;
      if (isPlausibleKcalPer100G(umgerechnet)) {
        return umgerechnet;
      }
    }

    final generisch = _readDouble(nutriments, const ['energy_100g']);
    if (generisch != null) {
      final einheit = _firstNonEmptyString(
        nutriments,
        const ['energy_unit'],
      )?.toLowerCase();
      final wert = einheit == 'kcal'
          ? generisch
          : generisch / PlausibilityLimits.kjPerKcal;
      if (isPlausibleKcalPer100G(wert)) {
        return wert;
      }
    }

    return null;
  }

  static bool _offBasisIst100G(Map<String, dynamic> product) {
    final basis = product['nutrition_data_per']?.toString().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    return basis == '100g';
  }

  /// Portionsgroesse aus OFF, immer 1..10000 g.
  ///
  /// Ein `serving_quantity` ausserhalb dieses Bereichs (0, oder 250000 fuer
  /// einen Mehlsack) ist keine Portion, sondern eine falsch befuellte Spalte.
  /// Statt sie auf 10000 g zu klemmen — und damit einen 10-kg-Teller zu
  /// erfinden — faellt die Funktion auf den 100-g-Bezug zurueck, auf den die
  /// Naehrwerte ohnehin normiert sind.
  static int _offServingGrams(Map<String, dynamic> product) {
    final menge = _readDouble(product, const ['serving_quantity']);
    if (menge != null && isPlausiblePortionGrams(menge)) {
      return clampPortionGrams(menge);
    }
    final ausText = _estimateGramsFromText(product['serving_size']?.toString());
    if (ausText != null && isPlausiblePortionGrams(ausText)) {
      return ausText;
    }
    return 100;
  }

  // -------------------------------------------------------------------------
  // Makros pro Bestandteil (B8)
  // -------------------------------------------------------------------------

  /// Summiert die Makros aller Posten — aber nur, wenn **jeder** Posten
  /// welche traegt. Eine Teilsumme waere systematisch zu niedrig und damit
  /// wieder eine erfundene Zahl.
  static _MacroTriple? _macrosFromItems(List<MealComponent> posten) {
    if (posten.isEmpty || !posten.every((item) => item.hasMacros)) {
      return null;
    }
    var protein = 0.0;
    var carbs = 0.0;
    var fat = 0.0;
    for (final item in posten) {
      protein += item.proteinG!;
      carbs += item.carbsG!;
      fat += item.fatG!;
    }
    return _MacroTriple(protein, carbs, fat);
  }

  /// Gemeinsamer Gramm-Faktor, wenn [neu] dieselben Posten in derselben
  /// Reihenfolge wie [alt] enthaelt und alle um denselben Faktor umskaliert
  /// wurden — sonst `null`.
  ///
  /// Faktor 1,0 ist der haeufigste Fall: der Nutzer oeffnet die Bestandteile
  /// und bestaetigt, ohne etwas zu aendern. Dann duerfen die Makros
  /// selbstverstaendlich unveraendert bleiben.
  static double? _uniformFactor(
    List<MealComponent> neu,
    List<MealComponent> alt,
  ) {
    if (neu.isEmpty || neu.length != alt.length) {
      return null;
    }
    double? faktor;
    for (var i = 0; i < neu.length; i++) {
      if (neu[i].name != alt[i].name) {
        return null;
      }
      final altG = alt[i].grams;
      final neuG = neu[i].grams;
      if (altG <= 0) {
        // Ohne Bezugsgroesse laesst sich kein Faktor bilden. Solange sich
        // auch nichts geaendert hat, ist der Posten fuer die Frage neutral.
        if (neuG != altG) {
          return null;
        }
        continue;
      }
      final aktuell = neuG / altG;
      if (faktor == null) {
        faktor = aktuell;
      } else if ((aktuell - faktor).abs() > faktor * 0.02) {
        return null;
      }
    }
    return faktor;
  }

  // -------------------------------------------------------------------------
  // Lesen mit "<= 0 heisst fehlt"-Semantik
  // -------------------------------------------------------------------------

  static int? _positive(int? value) =>
      value == null || value <= 0 ? null : value;

  /// Wie [_readInt], aber `0` und negative Werte gelten als "fehlt".
  static int? _readPositiveInt(Map<String, dynamic> json, List<String> keys) =>
      _positive(_readInt(json, keys));

  /// Wie [_readDouble], aber `<= 0`, nicht-endliche und physikalisch
  /// unmoegliche Dichten (> 900 kcal/100 g) gelten als "fehlt".
  static double? _readPlausibleDouble(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    final wert = _readDouble(json, keys);
    if (wert == null || !wert.isFinite || wert <= 0) {
      return null;
    }
    return isPlausibleKcalPer100G(wert) ? wert : null;
  }

  static int? _readInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is int) {
        return value;
      }
      if (value is double) {
        return value.round();
      }
      if (value is String) {
        final parsed = _extractFirstInt(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  static double? _readDouble(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) {
        return value.toDouble();
      }
      if (value is String) {
        final normalized = value.replaceAll(',', '.');
        final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(normalized);
        if (match != null) {
          return double.tryParse(match.group(0)!);
        }
      }
    }
    return null;
  }

  static String? _firstNonEmptyString(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  static String _macroForGrams(double? per100G, int grams) {
    if (per100G == null || !per100G.isFinite) {
      return _makroUnbekannt;
    }
    return _formatMacroG(per100G * grams / 100);
  }

  /// Formatiert einen Makro-Wert in Gramm, geklemmt auf die DB-Grenze
  /// (0..1000 g). Ganzzahlige Werte ohne Nachkommastelle, sonst eine Stelle
  /// mit deutschem Dezimalkomma.
  static String _formatMacroG(double wert) {
    if (!wert.isFinite) {
      return _makroUnbekannt;
    }
    final geklemmt = clampMealMacroG(wert);
    if ((geklemmt - geklemmt.roundToDouble()).abs() < 0.05) {
      return '${geklemmt.round()} g';
    }
    return '${geklemmt.toStringAsFixed(1).replaceAll('.', ',')} g';
  }

  /// Uebersetzt einen rohen Makro-Wert aus der Function-Antwort in Text.
  ///
  /// `null` (der Schluessel ist immer da, der Wert kann `null` sein) und alles
  /// Unparsebare — etwa `"viel"` — werden zu "unbekannt". Frueher wurde
  /// daraus `"viel g"` bzw. serverseitig `0`; beides erfand eine Zahl.
  static String _macroTextFromRaw(Object? raw) {
    if (raw == null) {
      return _makroUnbekannt;
    }
    final double? wert;
    if (raw is num) {
      wert = raw.toDouble();
    } else {
      final normalized = raw.toString().replaceAll(',', '.');
      final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(normalized);
      wert = match == null ? null : double.tryParse(match.group(0)!);
    }
    if (wert == null || !wert.isFinite) {
      return _makroUnbekannt;
    }
    return _formatMacroG(wert);
  }

  static int? _extractFirstInt(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'\d+').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  static int? _estimateGramsFromText(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'(\d{2,4})\s*g').firstMatch(value.toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static double? _knownKcalPer100G(String mealName) {
    final lower = mealName.toLowerCase();
    if (lower.contains('apfel') || lower.contains('apple')) {
      return 52;
    }
    if (lower.contains('banane') || lower.contains('banana')) {
      return 89;
    }
    if (lower.contains('orange')) {
      return 47;
    }
    if (lower.contains('erdbeer') || lower.contains('strawberr')) {
      return 32;
    }
    return null;
  }

  /// Skaliert die Zahl in einem Makro-Text mit [factor].
  ///
  /// Nur fuer **einheitliche** Portionsaenderungen zulaessig: dieselbe Speise,
  /// mehr oder weniger davon. Sobald sich die Zusammensetzung aendert, ist das
  /// Massenverhaeltnis die falsche Groesse — siehe [adjustedToItems].
  static String _scaleMacroText(String value, double factor) {
    final match = RegExp(r'(\d+(?:[,.]\d+)?)').firstMatch(value);
    if (match == null) {
      return value;
    }
    final number = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (number == null) {
      return value;
    }
    final scaled = clampMealMacroG(number * factor);
    final formatted = (scaled - scaled.roundToDouble()).abs() < 0.05
        ? scaled.round().toString()
        : scaled.toStringAsFixed(1);
    return value.replaceFirst(match.group(1)!, formatted.replaceAll('.', ','));
  }

  static String _formatConfidence(String value) {
    switch (value.toLowerCase()) {
      case 'high':
        return 'Hoch';
      case 'medium':
        return 'Mittel';
      case 'low':
        return 'Niedrig';
      default:
        return value;
    }
  }
}

/// Makro-Summe in Gramm. Rein intern; existiert nur, damit
/// [MealAnalysisResult.adjustedToItems] drei Werte zurueckgeben kann.
class _MacroTriple {
  const _MacroTriple(this.protein, this.carbs, this.fat);

  final double protein;
  final double carbs;
  final double fat;
}
