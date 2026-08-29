import 'dart:convert';

import '../l10n/l10n.dart';
import '../services/food_kcal_db.dart';
import 'meal_component.dart';
import 'model_limits.dart';

/// Text marker for "macro unknown". Same string the parsers emit for missing
/// macros; `MacroProgress._parseMacroG` reads 0 from it, so nothing invented
/// reaches the daily rings.
const String _makroUnbekannt = '-';

/// The [MealResultSource.code] values as separate `static const`s, because an
/// instance-field access is not a valid constant expression and cannot be a
/// default parameter. [MealResultSource.code] reads from here — one value,
/// defined once.
abstract final class _MealResultSourceCodes {
  static const String aiEstimate = 'aiEstimate';
  static const String photoAi = 'photoAi';
  static const String openFoodFacts = 'OpenFoodFacts';
  static const String recipe = 'recipe';
  static const String manual = 'manual';
}

/// Same constant workaround as [_MealResultSourceCodes], for
/// [MealResultConfidence]. `high`/`medium`/`low` are the raw codes the model
/// itself returns, not a translation; the model value is the persisted code
/// and translation happens only at display time.
abstract final class _MealResultConfidenceCodes {
  static const String high = 'high';
  static const String medium = 'medium';
  static const String low = 'low';
  static const String unknown = 'unknown';
  static const String database = 'database';
  static const String recipe = 'recipe';
  static const String manual = 'manual';
}

/// Language-neutral origin classification of a scan result.
///
/// [MealAnalysisResult.sourceLabel] stays a raw `String` for backwards
/// compatibility (persistence and existing tests use string literals).
/// [resolve] maps that raw value to a known origin: the neutral [code], the
/// legacy German value ([legacyDe]), or — as a defensive line — the English
/// display text. No match -> `null`, and the caller shows the raw value
/// unchanged (pass-through, i18n-design.md §5).
enum MealResultSource {
  aiEstimate(_MealResultSourceCodes.aiEstimate, legacyDe: 'KI-Schätzung'),
  photoAi(_MealResultSourceCodes.photoAi, legacyDe: 'Foto-KI'),
  // Brand name — already neutral, code == legacyDe on purpose.
  openFoodFacts(
    _MealResultSourceCodes.openFoodFacts,
    legacyDe: 'OpenFoodFacts',
  ),
  recipe(_MealResultSourceCodes.recipe, legacyDe: 'Eatova Rezept'),
  // Manual entry. legacyDe is only a resolve alias — no legacy rows carry it.
  manual(_MealResultSourceCodes.manual, legacyDe: 'Manuell');

  const MealResultSource(this.code, {required this.legacyDe});

  /// The language-neutral persisted value (new rows and the
  /// `MealAnalysisResult` default). Fits the 80-char `sourceLabelMaxChars`
  /// limits, so no DB migration is needed.
  final String code;

  /// The legacy German value in older `logged_meals`/`favorite_meals` rows.
  final String legacyDe;

  /// Display text in the language of [l10n].
  String label(AppLocalizations l10n) => switch (this) {
    MealResultSource.aiEstimate => l10n.foodSourceAiEstimate,
    MealResultSource.photoAi => l10n.foodSourcePhotoAi,
    // Brand name, deliberately untranslated.
    MealResultSource.openFoodFacts => 'OpenFoodFacts',
    MealResultSource.recipe => l10n.foodSourceRecipe,
    MealResultSource.manual => l10n.foodSourceManual,
  };

  /// Maps a raw persisted `sourceLabel` to a known origin, or `null` for
  /// anything unknown (pass-through case, see class doc).
  static MealResultSource? resolve(String raw) {
    for (final value in values) {
      if (value.code == raw || value.legacyDe == raw) return value;
    }
    // Defensive: an English display label, in case one was ever persisted.
    for (final value in values) {
      if (value.label(enL10n) == raw) return value;
    }
    return null;
  }
}

/// Language-neutral confidence classification of a scan result — same pattern
/// as [MealResultSource], here for [MealAnalysisResult.confidence].
///
/// The field stays a raw `String` for the same compatibility reason as
/// `sourceLabel`. [resolve] maps it to the [code] (identical to what the model
/// already returns for `high`/`medium`/`low`), the legacy German value, or the
/// English display text.
enum MealResultConfidence {
  high(_MealResultConfidenceCodes.high, legacyDe: 'Hoch'),
  medium(_MealResultConfidenceCodes.medium, legacyDe: 'Mittel'),
  low(_MealResultConfidenceCodes.low, legacyDe: 'Niedrig'),
  unknown(_MealResultConfidenceCodes.unknown, legacyDe: 'Unbekannt'),
  database(_MealResultConfidenceCodes.database, legacyDe: 'Datenbank'),
  recipe(_MealResultConfidenceCodes.recipe, legacyDe: 'Rezept'),
  manual(_MealResultConfidenceCodes.manual, legacyDe: 'Eigene Angabe');

  const MealResultConfidence(this.code, {required this.legacyDe});

  /// The language-neutral persisted value.
  final String code;

  /// The legacy German value in older rows.
  final String legacyDe;

  /// Display text in the language of [l10n].
  String label(AppLocalizations l10n) => switch (this) {
    MealResultConfidence.high => l10n.foodConfidenceHigh,
    MealResultConfidence.medium => l10n.foodConfidenceMedium,
    MealResultConfidence.low => l10n.foodConfidenceLow,
    MealResultConfidence.unknown => l10n.foodConfidenceUnknown,
    MealResultConfidence.database => l10n.foodConfidenceDatabase,
    MealResultConfidence.recipe => l10n.foodConfidenceRecipe,
    MealResultConfidence.manual => l10n.foodConfidenceManual,
  };

  /// Maps a raw persisted `confidence` to a known level, or `null` for
  /// anything unknown (e.g. a model answer outside the agreed
  /// `high`/`medium`/`low` schema).
  static MealResultConfidence? resolve(String raw) {
    for (final value in values) {
      if (value.code == raw || value.legacyDe == raw) return value;
    }
    for (final value in values) {
      if (value.label(enL10n) == raw) return value;
    }
    return null;
  }
}

/// Language-neutral markers for the four hardcoded fallback texts written to
/// `portionNotes` — three from [MealAnalysisResult.fromEdgeFunction] when the
/// model returns no `explanation`, plus [manual] for
/// [MealAnalysisResult.manualEntry].
///
/// Only these four, not `portionNotes` in general: the field otherwise carries
/// real model free text or the adjustment sentences built by
/// `adjustedToGrams`/`adjustedToItems`, both of which stay hardcoded German
/// (free text is effectively user data; the adjustment sentences are a
/// documented remaining gap, see the hardcoding rule in
/// `test/repo_rules_test.dart`).
enum MealResultPortionNote {
  autoSplit(
    'aiScanAutoSplitNote',
    legacyDe:
        'KI hat als Gesamtgericht erkannt — Bestandteile lokal '
        'aufgesplittet. Gramm und Kalorien pro Posten prüfen.',
  ),
  itemized(
    'aiScanItemizedNote',
    legacyDe:
        'KI-Schätzung aus dem Foto mit Einzelposten. Bitte '
        'Bestandteile und Gramm prüfen.',
  ),
  plain(
    'aiScanPlainNote',
    legacyDe:
        'KI-Schätzung aus dem Foto. Die Größe wurde nicht exakt '
        'vermessen; bitte Portion bestätigen oder Gewicht anpassen.',
  ),
  manual(
    'manualEntryNote',
    legacyDe: 'Nährwerte manuell nach Etikett eingetragen (pro 100 g).',
  );

  const MealResultPortionNote(this.code, {required this.legacyDe});

  /// The language-neutral persisted value.
  final String code;

  /// The legacy German value in older rows.
  final String legacyDe;

  /// Display text in the language of [l10n].
  String text(AppLocalizations l10n) => switch (this) {
    MealResultPortionNote.autoSplit => l10n.foodScanNoteAutoSplit,
    MealResultPortionNote.itemized => l10n.foodScanNoteItemized,
    MealResultPortionNote.plain => l10n.foodScanNotePlain,
    MealResultPortionNote.manual => l10n.foodManualEntryNote,
  };

  /// Maps a raw persisted `portionNotes` to a known fallback text, or `null`
  /// for anything unknown (model free text, adjustment sentences, user data).
  static MealResultPortionNote? resolve(String raw) {
    for (final value in values) {
      if (value.code == raw || value.legacyDe == raw) return value;
    }
    for (final value in values) {
      if (value.text(enL10n) == raw) return value;
    }
    return null;
  }
}

/// Language-neutral encoding of the product note that
/// [MealAnalysisResult.fromOpenFoodFacts] writes into `portionNotes`
/// (Komplettreview 2026-08-19, finding 4).
///
/// A fixed marker is not enough here: the note carries variables (barcode,
/// brand, package size, database serving). Persisted is [_prefix] plus those
/// four values as JSON; it is resolved only at display time ([text]). Under
/// [deL10n] the result is word-for-word the previous German paragraph.
///
/// [resolve] also recognises that legacy German paragraph and reads its four
/// values back via [_legacyDe]. No match leaves the raw text untouched
/// (pass-through, i18n-design.md §5).
class MealResultOffNote {
  const MealResultOffNote({
    required this.barcode,
    this.brand,
    this.package,
    this.serving,
  });

  /// Prefix of the persisted value — short and neutral so it lives in the same
  /// column as the [MealResultPortionNote] markers.
  static const String _prefix = 'offProductNote:';

  final String barcode;
  final String? brand;

  /// Package size per OFF (`quantity`), e.g. `'390 g'`.
  final String? package;

  /// Serving size per OFF (`serving_size`), e.g. `'100 g'`.
  final String? serving;

  /// The language-neutral value for `portionNotes`.
  String encode() {
    final werte = <String, String>{
      'barcode': barcode,
      if (brand != null) 'brand': brand!,
      if (package != null) 'package': package!,
      if (serving != null) 'serving': serving!,
    };
    return '$_prefix${jsonEncode(werte)}';
  }

  /// Display text in the language of [l10n].
  String text(AppLocalizations l10n) => <String>[
    l10n.mealNotesOffSource(barcode),
    if (brand != null) l10n.mealNotesOffBrand(brand!),
    if (package != null) l10n.mealNotesOffPackage(package!),
    if (serving != null) l10n.mealNotesOffServing(serving!),
    l10n.mealNotesOffDatabase,
    l10n.mealNotesAdjustWeight,
  ].join(' ');

  /// Maps a raw persisted value: new encoding or legacy German paragraph.
  /// Anything else -> `null` (pass-through).
  static MealResultOffNote? resolve(String raw) => raw.startsWith(_prefix)
      ? _fromJson(raw.substring(_prefix.length))
      : _fromLegacyDe(raw);

  /// A corrupted marker must not lose the row: the caller then shows the raw
  /// value, as with any unknown text.
  static Object? _jsonOderNull(String rohesJson) {
    try {
      return jsonDecode(rohesJson);
    } on FormatException {
      return null;
    }
  }

  static MealResultOffNote? _fromJson(String rohesJson) {
    final gelesen = _jsonOderNull(rohesJson);
    if (gelesen is! Map) return null;
    final barcode = gelesen['barcode'];
    // A missing key disqualifies the marker; an EMPTY barcode does not — the
    // product search returns hits without `code`.
    if (barcode == null) return null;
    return MealResultOffNote(
      barcode: barcode.toString().trim(),
      brand: _nichtLeer(gelesen['brand']),
      package: _nichtLeer(gelesen['package']),
      serving: _nichtLeer(gelesen['serving']),
    );
  }

  /// Pattern of the legacy German paragraph. Compatibility DATA, not UI text:
  /// the wording must never change again, or legacy rows lose their
  /// translation. The three middle groups are optional because
  /// `fromOpenFoodFacts` only ever wrote them when the field was present.
  static final RegExp _legacyDe = RegExp(
    r'^OpenFoodFacts Barcode (.+?)\.'
    r'(?: Marke: (.+?)\.)?'
    r'(?: Packung: (.+?)\.)?'
    r'(?: Portion laut Datenbank: (.+?)\.)?'
    r' Nährwerte kommen aus der Produktdatenbank, nicht aus einer Foto-Schätzung\.'
    r' Du kannst das gegessene Gewicht weiter anpassen\.$',
  );

  static MealResultOffNote? _fromLegacyDe(String raw) {
    final treffer = _legacyDe.firstMatch(raw);
    if (treffer == null) return null;
    final barcode = _nichtLeer(treffer.group(1));
    if (barcode == null) return null;
    return MealResultOffNote(
      barcode: barcode,
      brand: _nichtLeer(treffer.group(2)),
      package: _nichtLeer(treffer.group(3)),
      serving: _nichtLeer(treffer.group(4)),
    );
  }

  static String? _nichtLeer(Object? wert) {
    final wertText = wert?.toString().trim();
    return wertText == null || wertText.isEmpty ? null : wertText;
  }
}

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
    this.sourceLabel = _MealResultSourceCodes.aiEstimate,
    this.barcode,
    this.brand,
    this.explicitZeroKcal = false,
  });

  final String mealName;
  final int caloriesKcal;
  final int estimatedGrams;
  final double kcalPer100G;
  final String protein;
  final String carbs;
  final String fat;

  /// RAW confidence value as persisted — see [MealResultConfidence]. Always
  /// render via [resolvedConfidence].
  final String confidence;

  /// RAW note text as persisted: a fallback marker from `fromEdgeFunction`
  /// ([MealResultPortionNote]), the encoded OFF product note
  /// ([MealResultOffNote]), real model free text (`explanation`), or an
  /// adjustment sentence from `adjustedToGrams`/`adjustedToItems`. The last
  /// two stay hardcoded German by design. Render via [resolvedPortionNotes].
  final String portionNotes;
  final List<MealComponent> items;
  final bool isAdjusted;

  /// RAW origin value as persisted — a neutral [MealResultSource.code] for new
  /// rows, the legacy German value for old ones, and any other string stays
  /// untouched. Always render via [resolvedSourceLabel], never this field.
  final String sourceLabel;
  final String? barcode;
  final String? brand;

  /// `true` when the 0 in [caloriesKcal]/[kcalPer100G] is a MEASUREMENT (water,
  /// zero drink — see [offMeldetExplizitNullKcal]) and not the "unknown"
  /// sentinel. Only with this marker do the UI log guards let a 0 through.
  /// Persisted in the payload; legacy rows read `false` and stay blocked.
  final bool explicitZeroKcal;

  /// Origin value in the language of [l10n]. Known raw values resolve via
  /// [MealResultSource]; unknown ones are shown unchanged (pass-through).
  String resolvedSourceLabel(AppLocalizations l10n) {
    final source = MealResultSource.resolve(sourceLabel);
    return source == null ? sourceLabel : source.label(l10n);
  }

  /// Portion label in the language of [l10n]. Unlike [sourceLabel] this text is
  /// never persisted (only [estimatedGrams] is), so there is no legacy-row
  /// compatibility question.
  String resolvedPortionLabel(AppLocalizations l10n) =>
      l10n.foodPortionEstimated(estimatedGrams);

  /// Confidence level in the language of [l10n]. Known raw values resolve via
  /// [MealResultConfidence]; unknown ones are shown unchanged.
  String resolvedConfidence(AppLocalizations l10n) {
    final level = MealResultConfidence.resolve(confidence);
    return level == null ? confidence : level.label(l10n);
  }

  /// Scan/adjustment note in the language of [l10n]. Resolves the fallback
  /// markers ([MealResultPortionNote]) and the OFF product note
  /// ([MealResultOffNote], legacy German rows included); model free text and
  /// the computed adjustment sentences stay unchanged (pass-through).
  String resolvedPortionNotes(AppLocalizations l10n) {
    final note = MealResultPortionNote.resolve(portionNotes);
    if (note != null) return note.text(l10n);
    final offNote = MealResultOffNote.resolve(portionNotes);
    return offNote == null ? portionNotes : offNote.text(l10n);
  }

  /// Deliberately **not** via [effectiveKcalPer100G]: `0 kcal / 100 g` is valid
  /// in Open Food Facts (water, tea) but means "unknown" from the scan
  /// function, and the non-nullable `kcalPer100G` cannot tell them apart. This
  /// label stays purely formatting.
  String get kcalPer100Label => '${kcalPer100G.round()} kcal / 100 g';

  bool get hasItemizedBreakdown => items.isNotEmpty;

  /// kcal/100 g if the value is usable, else `null`.
  ///
  /// See [MealComponent.effectiveKcalPer100G]: `0` is the server's sentinel for
  /// unparseable or negative model values, and anything above 900 is physically
  /// impossible. Both mean "missing".
  double? get effectiveKcalPer100G {
    if (!kcalPer100G.isFinite || kcalPer100G <= 0) {
      return null;
    }
    return isPlausibleKcalPer100G(kcalPer100G) ? kcalPer100G : null;
  }

  /// The meal as a single component — the same synthesis the components sheet
  /// does when the model returned no items. Baseline for [adjustedToItems].
  MealComponent get asSingleComponent => MealComponent(
    name: mealName,
    grams: estimatedGrams,
    caloriesKcal: caloriesKcal,
    kcalPer100G: kcalPer100G,
  );

  /// Rescales the meal to [grams].
  ///
  /// **`caloriesKcal` is authoritative, not `kcalPer100G`** — the calorie count
  /// is what the user sees and confirms; the density is a side field the server
  /// clamps independently. Invariant:
  /// `adjustedToGrams(estimatedGrams).caloriesKcal == caloriesKcal`.
  ///
  /// The density becomes the reference only when calories and grams yield
  /// nothing (source portion 0 g or 0 kcal).
  MealAnalysisResult adjustedToGrams(int grams) {
    final zielGramm = clampPortionGrams(grams);
    final dichte = effectiveKcalPer100G;
    final int neueKcal;
    if (estimatedGrams > 0 && caloriesKcal > 0) {
      neueKcal = clampMealCaloriesKcal(
        caloriesKcal * zielGramm / estimatedGrams,
      );
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
              .map(
                (item) => item.adjustedToGrams((item.grams * factor).round()),
              )
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
      explicitZeroKcal: explicitZeroKcal,
    );
  }

  /// Takes over the components the user confirmed.
  ///
  /// Calories and grams come from the item sum. Macros must NOT be scaled by
  /// mass ratio (docs/REVIEW-2026-08-08.md, B8): adding 20 g of olive oil moves
  /// mass by 5 % but fat by 160 %. Three cases, in order:
  ///
  /// 1. **All items carry macros** — sum exactly.
  /// 2. **Uniform rescale only** (same items, same order, same gram factor;
  ///    factor 1.0 = confirmed unchanged) — mass scaling is correct here.
  /// 3. **Otherwise** the macros are **unknown**. A wrong number that looks
  ///    precise is worse than a missing one.
  MealAnalysisResult adjustedToItems(List<MealComponent> adjustedItems) {
    final totalGrams = clampMealEstimatedG(
      adjustedItems.fold<int>(0, (sum, item) => sum + item.grams),
    );
    final totalKcal = clampMealCaloriesKcal(
      adjustedItems.fold<int>(0, (sum, item) => sum + item.caloriesKcal),
    );

    final summe = _macrosFromItems(adjustedItems);
    final basis = items.isNotEmpty ? items : <MealComponent>[asSingleComponent];
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
      explicitZeroKcal: explicitZeroKcal,
    );
  }

  /// Parses the `analyze-meal` function response.
  ///
  /// The function always returns every key, but the value may be a number, `0`
  /// (the clamp sentinel for unparseable and negative inputs) or `null`. All
  /// three must lead to the same result, so `<= 0` means "missing" everywhere,
  /// not just `== null`.
  factory MealAnalysisResult.fromEdgeFunction(Map<String, dynamic> json) {
    final mealName = clampMealName(
      json['mealName']?.toString() ?? 'Unbekannte Mahlzeit',
    );
    final items = _readItems(json);
    final itemCalories = items.fold<int>(
      0,
      (sum, item) => sum + item.caloriesKcal,
    );
    final itemGrams = items.fold<int>(0, (sum, item) => sum + item.grams);
    final calories =
        _readPositiveInt(json, const [
          'caloriesKcal',
          'kcal',
          'calories',
          'estimatedCaloriesKcal',
        ]) ??
        _positive(_extractFirstInt(json['caloriesKcal']?.toString())) ??
        _positive(_extractFirstInt(json['calories']?.toString())) ??
        (itemCalories > 0 ? itemCalories : 0);
    // Only a real model value counts as a known portion; the 150 g below is a
    // default and must never serve as the reference for a derived density.
    //
    // Order: explicit model value, then the ITEM SUM (structured numbers),
    // and only last the explanation text — and that only when it carries
    // EXACTLY ONE gram figure. The prompt asks for a size rationale that
    // typically names several ('120 g pasta with 80 g sauce'), where the first
    // one is not the total weight.
    final gemesseneGramm =
        _readPositiveInt(json, const [
          'estimatedGrams',
          'portionGrams',
          'grams',
          'weightG',
          'estimatedWeightG',
        ]) ??
        (itemGrams > 0 ? itemGrams : null) ??
        _positive(_unambiguousGramsFromText(json['explanation']?.toString()));
    final estimatedGrams = gemesseneGramm ?? 150;
    // Fallback chain, in this order on purpose:
    //   1. the explicit, plausible model density
    //   2. derivation from the two authoritative numbers of THIS photo
    //   3. the name-based reference table — knows only a handful of raw foods
    //      and nothing about preparation, so it is the weakest source
    //   4. derivation using the default portion
    final kcalPer100G =
        _readPlausibleDouble(json, const [
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
            : 0.0);
    // The chain ends in 0, not an invented density: 0 without explicitZeroKcal
    // is this model's "unknown" form, and the log guards block it with a hint
    // instead of storing a made-up number.
    final protein = json['proteinG'];
    final carbs = json['carbsG'];
    final fat = json['fatG'];
    // Missing/empty confidence is not "medium" — it is no statement at all.
    final confidence = json['confidence']?.toString();
    final dichte = clampKcalPer100G(kcalPer100G);
    // Total calories may only be derived from a REALLY MEASURED portion, never
    // from the 150 g default: combined with a name-based reference density that
    // turned a number-free model answer into a loggable figure that looks like
    // a measurement. Without solid numbers it stays 0 (unknown form).
    final resolvedCalories = clampMealCaloriesKcal(
      calories > 0
          ? calories
          : (gemesseneGramm != null
                ? (dichte * gemesseneGramm / 100).round()
                : 0),
    );
    final resolvedGrams = clampMealEstimatedG(
      estimatedGrams > 0 ? estimatedGrams : itemGrams,
    );
    var normalizedItems = itemGrams > 0 || itemCalories > 0
        ? items
        : const <MealComponent>[];

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
    // `items[]` and `caloriesKcal` arrive unreconciled in the same answer.
    // Without this, merely confirming in the components sheet would replace the
    // total with the item sum — a different meal than the card showed.
    normalizedItems = _itemsMitGesamtKcal(normalizedItems, resolvedCalories);

    return MealAnalysisResult(
      mealName: mealName,
      caloriesKcal: resolvedCalories,
      estimatedGrams: resolvedGrams,
      kcalPer100G: dichte,
      protein: _macroTextFromRaw(protein),
      carbs: _macroTextFromRaw(carbs),
      fat: _macroTextFromRaw(fat),
      confidence: confidence == null || confidence.isEmpty
          ? _MealResultConfidenceCodes.unknown
          : _confidenceCodeFromModel(confidence),
      // The server normalizes a missing explanation to '' (normalize.ts), so
      // empty counts as absent — otherwise the i18n marker never fires and
      // the info sheet shows a blank line (F4-06).
      portionNotes: _nonEmpty(json['explanation']?.toString()) ??
          (autoSplit
              ? MealResultPortionNote.autoSplit.code
              : normalizedItems.isNotEmpty
              ? MealResultPortionNote.itemized.code
              : MealResultPortionNote.plain.code),
      items: normalizedItems,
      sourceLabel: MealResultSource.photoAi.code,
    );
  }

  factory MealAnalysisResult.fromOpenFoodFacts(
    Map<String, dynamic> product,
    String barcode,
  ) {
    final nutriments = product['nutriments'] is Map<String, dynamic>
        ? product['nutriments'] as Map<String, dynamic>
        : <String, dynamic>{};
    // P2-01b: the code is NOT only what the scanner read — it is pinned to
    // EAN-8/EAN-13/UPC-A, but `ProductSearchResult.fromOpenFoodFacts` takes
    // `product['code']` verbatim out of the Meilisearch/OFF index. Past 64
    // chars that breaks `logged_meals.barcode`, past 172 the `favorite_key`
    // built from it. Foreign source, nobody to ask -> clamp (model_limits.dart).
    final code = clampBarcode(barcode) ?? '';
    final productName =
        _firstNonEmptyString(product, const ['product_name', 'generic_name']) ??
        'Produkt $code';
    final brand = clampBrand(_firstNonEmptyString(product, const ['brands']));
    final kcalPer100G = _offKcalPer100G(product, nutriments) ?? 0;
    final servingGrams = _offServingGrams(product);
    final calories = clampMealCaloriesKcal(kcalPer100G * servingGrams / 100);
    final protein100 = _readDouble(nutriments, const ['proteins_100g']);
    final carbs100 = _readDouble(nutriments, const ['carbohydrates_100g']);
    final fat100 = _readDouble(nutriments, const ['fat_100g']);
    final quantity = _firstNonEmptyString(product, const ['quantity']);
    final servingSize = _firstNonEmptyString(product, const ['serving_size']);
    // Persisted language-neutral, resolved only at display time: a finished
    // German paragraph in the payload survived every language switch. Under
    // deL10n `MealResultOffNote.text()` yields the same wording as before.
    final hinweis = MealResultOffNote(
      barcode: code,
      brand: brand,
      package: quantity,
      serving: servingSize,
    );

    return MealAnalysisResult(
      mealName: clampMealName(
        brand == null ? productName : '$productName · $brand',
      ),
      caloriesKcal: calories,
      estimatedGrams: servingGrams,
      kcalPer100G: kcalPer100G,
      protein: macroForGrams(protein100, servingGrams),
      carbs: macroForGrams(carbs100, servingGrams),
      fat: macroForGrams(fat100, servingGrams),
      confidence: _MealResultConfidenceCodes.database,
      portionNotes: hinweis.encode(),
      sourceLabel: MealResultSource.openFoodFacts.code,
      barcode: code,
      brand: brand,
      // Only an EXPLICITLY reported 0 (water, zero drink) is a measurement; the
      // `?? 0` parser fallback above never satisfies this, because the detector
      // reads the raw fields.
      explicitZeroKcal: kcalPer100G == 0 && offMeldetExplizitNullKcal(product),
    );
  }

  /// Builds the result of a MANUALLY entered food (manual_meal_sheet): label
  /// values per 100 g plus the eaten portion. Inputs are form-validated, so the
  /// clamps here are defensive only, not repair.
  factory MealAnalysisResult.manualEntry({
    required String name,
    required int kcalPer100G,
    required int grams,
    int? proteinPer100G,
    int? carbsPer100G,
    int? fatPer100G,
  }) {
    final zielGramm = clampPortionGrams(grams);
    final dichte = clampKcalPer100G(kcalPer100G);
    final kalorien = clampMealCaloriesKcal(dichte * zielGramm / 100);
    return MealAnalysisResult(
      mealName: clampMealName(name),
      caloriesKcal: kalorien,
      estimatedGrams: zielGramm,
      kcalPer100G: dichte,
      protein: macroForGrams(proteinPer100G?.toDouble(), zielGramm),
      carbs: macroForGrams(carbsPer100G?.toDouble(), zielGramm),
      fat: macroForGrams(fatPer100G?.toDouble(), zielGramm),
      confidence: _MealResultConfidenceCodes.manual,
      portionNotes: MealResultPortionNote.manual.code,
      sourceLabel: _MealResultSourceCodes.manual,
      // An EXPLICITLY entered 0 (water, zero drink) is a measurement, not the
      // unknown sentinel — only it may pass the log guard.
      explicitZeroKcal: kcalPer100G == 0,
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
                  (itemKey, itemValue) =>
                      MapEntry(itemKey.toString(), itemValue),
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
  // Open Food Facts: reference base, kJ conversion, plausibility (B7)
  // -------------------------------------------------------------------------

  /// Reads kcal **per 100 g** from the OFF nutriments, or `null`.
  ///
  /// Order and reasoning:
  ///
  /// 1. `energy-kcal_100g` / `energy_kcal_100g` — explicitly per 100 g.
  /// 2. `energy-kcal_value` **only** when `nutrition_data_per == '100g'`: the
  ///    field is base-dependent in OFF and holds the serving value for
  ///    per-serving products. Without the base it is unusable — better no
  ///    number than one with an unknown reference.
  /// 3. kJ. `energy-kj_100g` is unambiguous; `energy_100g` has no unit and is
  ///    kJ by OFF convention unless `energy_unit` says `kcal`.
  ///
  /// Every candidate must pass [isPlausibleKcalPer100G]. An implausible value
  /// is **dropped, not converted**: assuming 2180 is the kJ figure for 521 kcal
  /// is a guess, and a wrong-but-plausible number goes unnoticed in the diary
  /// while a missing one does not.
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
      final einheit = _firstNonEmptyString(nutriments, const [
        'energy_unit',
      ])?.toLowerCase();
      final wert = einheit == 'kcal'
          ? generisch
          : generisch / PlausibilityLimits.kjPerKcal;
      if (isPlausibleKcalPer100G(wert)) {
        return wert;
      }
    }

    return null;
  }

  /// Whether the OFF nutriments state energy EXPLICITLY as 0 (water, tea, zero
  /// drinks). Only then is a parsed 0 a measurement, and the energy filter may
  /// let it be logged instead of claiming "no nutrition data".
  ///
  /// Candidates and precedence mirror [_offKcalPer100G]: the preferred field
  /// decides if present (a 0 in a lower-ranked field next to a filled kcal
  /// field is not a 0-kcal statement); `energy-kcal_value` counts only on a
  /// 100 g base; kJ needs no conversion, 0 kJ is 0 kcal.
  static bool offMeldetExplizitNullKcal(Map<String, dynamic> product) {
    final nutriments = product['nutriments'] is Map<String, dynamic>
        ? product['nutriments'] as Map<String, dynamic>
        : <String, dynamic>{};
    final proHundert = _readDouble(nutriments, const [
      'energy-kcal_100g',
      'energy_kcal_100g',
    ]);
    if (proHundert != null) {
      return proHundert == 0;
    }
    if (_offBasisIst100G(product)) {
      final basisWert = _readDouble(nutriments, const ['energy-kcal_value']);
      if (basisWert != null) {
        return basisWert == 0;
      }
    }
    final kj = _readDouble(nutriments, const ['energy-kj_100g', 'energy_100g']);
    return kj != null && kj == 0;
  }

  static bool _offBasisIst100G(Map<String, dynamic> product) {
    final basis = product['nutrition_data_per']
        ?.toString()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '');
    return basis == '100g';
  }

  /// Serving size from OFF, always 1..10000 g.
  ///
  /// A `serving_quantity` outside that range is a mis-filled column, not a
  /// portion. Rather than clamping it to 10000 g (inventing a 10 kg plate),
  /// fall back to the 100 g base the nutriments are normalised to anyway.
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
  // Macros per component (B8)
  // -------------------------------------------------------------------------

  /// Sums the macros of all items — only if **every** item carries them. A
  /// partial sum would be systematically too low, i.e. another invented number.
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

  /// Shared gram factor when [neu] holds the same items in the same order as
  /// [alt], all rescaled by that factor — otherwise `null`.
  ///
  /// Factor 1.0 is the common case: the user opens the components and confirms
  /// without changing anything, so the macros stay as they were.
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
        // No reference, no factor. As long as nothing changed either, the item
        // is neutral for this question.
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
  // Reading with "<= 0 means missing" semantics
  // -------------------------------------------------------------------------

  static int? _positive(int? value) =>
      value == null || value <= 0 ? null : value;

  /// Like [_readInt], but `0` and negative values count as "missing".
  static int? _readPositiveInt(Map<String, dynamic> json, List<String> keys) =>
      _positive(_readInt(json, keys));

  /// Like [_readDouble], but `<= 0`, non-finite and physically impossible
  /// densities (> 900 kcal/100 g) count as "missing".
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

  /// Null for null AND whitespace-only — the server's "no explanation" is ''.
  static String? _nonEmpty(String? raw) {
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? null : raw;
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

  /// Scales a per-100 g macro value to [grams] and formats it. Public because
  /// both [fromOpenFoodFacts] and [manualEntry] need the same formatter.
  static String macroForGrams(double? per100G, int grams) {
    if (per100G == null || !per100G.isFinite) {
      return _makroUnbekannt;
    }
    return _formatMacroG(per100G * grams / 100);
  }

  /// Formats a macro value in grams, clamped to the DB limit (0..1000 g).
  /// Whole values without a decimal, otherwise one digit with a German comma.
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

  /// Turns a raw macro value from the function response into text.
  ///
  /// `null` (the key is always present, the value may be null) and anything
  /// unparseable becomes "unknown" rather than an invented number.
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

  /// First gram figure in a text. Only for OFF's `serving_size`, a field that
  /// carries exactly ONE serving. For model explanation text see
  /// [_unambiguousGramsFromText].
  static int? _estimateGramsFromText(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'(\d{2,4})\s*g').firstMatch(value.toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Grams from model explanation text, but only when it carries EXACTLY ONE
  /// gram figure (Komplettreview 2026-08-19, finding 3).
  ///
  /// `explanation` is a size rationale and typically names several weights
  /// ('about 120 g pasta with 80 g sauce'); reading the first as the TOTAL is
  /// guessing. The word boundary also keeps '120 gebraten' out.
  static int? _unambiguousGramsFromText(String? value) {
    if (value == null) {
      return null;
    }
    final treffer = RegExp(
      r'(\d{2,4})\s*g(?:ramm|rams)?\b',
    ).allMatches(value.toLowerCase()).toList(growable: false);
    if (treffer.length != 1) {
      return null;
    }
    return int.tryParse(treffer.single.group(1)!);
  }

  /// Reference densities for a handful of raw foods the model often returns
  /// without numbers. Weakest source of the density chain in
  /// [fromEdgeFunction]; composite dishes go through `autoSplitItems`.
  static const Map<String, double> _referenzKcalPer100G = <String, double>{
    'apfel': 52,
    'äpfel': 52,
    'apple': 52,
    'apples': 52,
    'banane': 89,
    'bananen': 89,
    'banana': 89,
    'bananas': 89,
    'orange': 47,
    'orangen': 47,
    'oranges': 47,
    'erdbeere': 32,
    'erdbeeren': 32,
    'strawberry': 32,
    'strawberries': 32,
  };

  /// Reference density for a meal name — only on an EXACT match of the
  /// normalised name. A substring search gave 'Erdbeerkuchen' the 32 kcal/100 g
  /// of a strawberry. The table knows only whole, raw foods; anything more
  /// specific gets no answer.
  static double? _knownKcalPer100G(String mealName) {
    final name = mealName.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    return _referenzKcalPer100G[name];
  }

  /// Rescales item calories proportionally and sum-exactly onto [gesamtKcal].
  ///
  /// **The model total wins over the item sum**, for the same reason it wins
  /// over the density in [adjustedToGrams]: it is the number the user sees and
  /// confirms, the items are its breakdown. Hence
  /// `adjustedToItems(items).caloriesKcal == caloriesKcal`.
  ///
  /// Items keep their ratios and grams (density follows); macros stay
  /// untouched, being a separate model statement. Without a reference nothing
  /// is computed — an item list with no calories at all stays unchanged rather
  /// than getting an invented distribution. The GRAM sum is left alone on
  /// purpose: shifting it would reweight every item and its macros.
  static List<MealComponent> _itemsMitGesamtKcal(
    List<MealComponent> posten,
    int gesamtKcal,
  ) {
    if (posten.isEmpty || gesamtKcal <= 0) {
      return posten;
    }
    final summe = posten.fold<int>(0, (sum, item) => sum + item.caloriesKcal);
    if (summe <= 0 || summe == gesamtKcal) {
      return posten;
    }
    final faktor = gesamtKcal / summe;
    final neu = posten
        .map(
          (item) => _mitKcal(
            item,
            clampMealCaloriesKcal(item.caloriesKcal * faktor),
          ),
        )
        .toList();
    // Rounding remainder onto the largest item, or the sum misses its target
    // and the invariant above would only hold approximately.
    final rest =
        gesamtKcal - neu.fold<int>(0, (sum, item) => sum + item.caloriesKcal);
    if (rest != 0) {
      var groesster = 0;
      for (var i = 1; i < neu.length; i++) {
        if (neu[i].caloriesKcal > neu[groesster].caloriesKcal) {
          groesster = i;
        }
      }
      neu[groesster] = _mitKcal(
        neu[groesster],
        clampMealCaloriesKcal(neu[groesster].caloriesKcal + rest),
      );
    }
    return List<MealComponent>.of(neu, growable: false);
  }

  /// [MealComponent] has no `copyWith`, so the item is rebuilt. Density follows
  /// the new calorie count; grams and macros stay as the model reported them.
  static MealComponent _mitKcal(MealComponent item, int kcal) => MealComponent(
    name: item.name,
    grams: item.grams,
    caloriesKcal: kcal,
    kcalPer100G: item.grams > 0 && kcal > 0
        ? clampKcalPer100G(kcal * 100 / item.grams)
        : item.kcalPer100G,
    proteinG: item.proteinG,
    carbsG: item.carbsG,
    fatG: item.fatG,
  );

  /// Scales the number inside a macro text by [factor].
  ///
  /// Only valid for **uniform** portion changes: same dish, more or less of it.
  /// Once the composition changes, the mass ratio is the wrong measure — see
  /// [adjustedToItems].
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

  /// Normalises a raw model value (`'high'`/`'HIGH'`/`'High'` — the model is
  /// not strict here) to the neutral persistence code. Unknown values pass
  /// through unchanged.
  static String _confidenceCodeFromModel(String value) {
    switch (value.toLowerCase()) {
      case 'high':
        return _MealResultConfidenceCodes.high;
      case 'medium':
        return _MealResultConfidenceCodes.medium;
      case 'low':
        return _MealResultConfidenceCodes.low;
      default:
        return value;
    }
  }
}

/// Macro sum in grams. Internal only; exists so
/// [MealAnalysisResult.adjustedToItems] can return three values.
class _MacroTriple {
  const _MacroTriple(this.protein, this.carbs, this.fat);

  final double protein;
  final double carbs;
  final double fat;
}
