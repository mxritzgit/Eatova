import 'dart:convert';

import '../l10n/l10n.dart';
import '../services/food_kcal_db.dart';
import 'meal_component.dart';
import 'model_limits.dart';

/// Textmarke fuer "Makro unbekannt". Bewusst derselbe String, den die Parser
/// fuer fehlende Makros liefern — `MacroProgress._parseMacroG` liest daraus 0
/// und traegt damit nichts Erfundenes in die Tagesringe ein.
const String _makroUnbekannt = '-';

/// Die [MealResultSource.code]-Werte als eigene `static const`-Konstanten:
/// ein Instanzfeld-Zugriff wie `MealResultSource.aiEstimate.code` ist KEIN
/// gueltiger konstanter Ausdruck (Dart lehnt das beim Default-Parameter von
/// `MealAnalysisResult.sourceLabel` ab), deshalb die Codes hier separat.
/// [MealResultSource.code] liest aus derselben Quelle — ein Wert existiert
/// nur einmal.
abstract final class _MealResultSourceCodes {
  static const String aiEstimate = 'aiEstimate';
  static const String photoAi = 'photoAi';
  static const String openFoodFacts = 'OpenFoodFacts';
  static const String recipe = 'recipe';
  static const String manual = 'manual';
}

/// Dieselbe Konstanten-Ausweichlösung wie [_MealResultSourceCodes], fuer
/// [MealResultConfidence]. `high`/`medium`/`low` sind KEINE Uebersetzung —
/// es sind die Roh-Codes, die das Modell selbst schon liefert
/// (`analyze-meal`s Prompt-Schema: `"confidence": "high"|"medium"|"low"`);
/// die bisherige `_formatConfidence` uebersetzte sie SOFORT beim Parsen nach
/// Deutsch. Ab diesem PR bleibt der Modell-Wert unveraendert der
/// Persistenz-Code, die Uebersetzung passiert nur noch bei der Anzeige.
abstract final class _MealResultConfidenceCodes {
  static const String high = 'high';
  static const String medium = 'medium';
  static const String low = 'low';
  static const String unknown = 'unknown';
  static const String database = 'database';
  static const String recipe = 'recipe';
  static const String manual = 'manual';
}

/// Sprachneutrale Herkunfts-Klassifizierung eines Scan-Ergebnisses
/// (Scan/Coach-PR, 2026-08-11).
///
/// [MealAnalysisResult.sourceLabel] bleibt bewusst ein roher `String` —
/// Rueckwaertskompatibilitaet: Persistenz (meals_sync.dart) UND ~25
/// Bestandstests konstruieren `MealAnalysisResult` direkt mit einem
/// String-Literal (`sourceLabel: 'Foto-KI'` etc.), das aendert dieser PR
/// nicht. NEU ist die AUFLOESUNG dieses Rohwerts fuer die ANZEIGE: [resolve]
/// ordnet ihn einem der vier bekannten Ursprnge zu — dem ab jetzt
/// geschriebenen neutralen [code], dem deutschen Bestandswert ([legacyDe],
/// vor diesem PR schrieb jeder Client woertlich diesen String) oder —
/// Verteidigungslinie, analog `FitnessRecipe._resolvePlaceholder` — dem
/// englischen Anzeigetext, falls ihn je ein Client persistiert haette. Kein
/// Treffer -> `null`, der Aufrufer zeigt den Rohwert dann UNVERAENDERT
/// (Pass-through fuer unbekannte Werte, i18n-design.md §5).
enum MealResultSource {
  aiEstimate(_MealResultSourceCodes.aiEstimate, legacyDe: 'KI-Schätzung'),
  photoAi(_MealResultSourceCodes.photoAi, legacyDe: 'Foto-KI'),
  // Markenname — bereits sprachneutral, code == legacyDe absichtlich gleich.
  openFoodFacts(
    _MealResultSourceCodes.openFoodFacts,
    legacyDe: 'OpenFoodFacts',
  ),
  recipe(_MealResultSourceCodes.recipe, legacyDe: 'Eatova Rezept'),
  // Manueller Eintrag (Spec 2026-08-13). legacyDe ist hier nur ein
  // Resolve-Alias — Alt-Zeilen mit diesem Wert gibt es nicht.
  manual(_MealResultSourceCodes.manual, legacyDe: 'Manuell');

  const MealResultSource(this.code, {required this.legacyDe});

  /// Der ab diesem PR geschriebene, sprachneutrale Persistenz-Wert (neue
  /// Zeilen UND `MealAnalysisResult`-Default). Kurz genug fuer
  /// `LoggedMealLimits.sourceLabelMaxChars`/`FavoriteMealLimits.sourceLabelMaxChars`
  /// (80 Zeichen) — keine DB-Migration noetig.
  final String code;

  /// Der deutsche Bestandswert, den JEDER Client vor diesem PR geschrieben
  /// hat (Alt-Zeilen in `logged_meals`/`favorite_meals`).
  final String legacyDe;

  /// Anzeigetext in der Sprache von [l10n].
  String label(AppLocalizations l10n) => switch (this) {
    MealResultSource.aiEstimate => l10n.foodSourceAiEstimate,
    MealResultSource.photoAi => l10n.foodSourcePhotoAi,
    // Markenname, keine Uebersetzung noetig/erwuenscht.
    MealResultSource.openFoodFacts => 'OpenFoodFacts',
    MealResultSource.recipe => l10n.foodSourceRecipe,
    MealResultSource.manual => l10n.foodSourceManual,
  };

  /// Ordnet einen ROHEN, persistierten Wert (`MealAnalysisResult.sourceLabel`)
  /// einem bekannten Ursprung zu, oder liefert `null` fuer alles Unbekannte
  /// (Pass-through-Fall, s. Klassendoku).
  static MealResultSource? resolve(String raw) {
    for (final value in values) {
      if (value.code == raw || value.legacyDe == raw) return value;
    }
    // Verteidigungslinie: ein englisches Anzeige-Label, falls je persistiert.
    for (final value in values) {
      if (value.label(enL10n) == raw) return value;
    }
    return null;
  }
}

/// Sprachneutrale Sicherheits-Klassifizierung eines Scan-Ergebnisses
/// (Review-Fixwelle Scan/Coach-PR, 2026-08-11) — dasselbe Muster wie
/// [MealResultSource], hier fuer [MealAnalysisResult.confidence].
///
/// [MealAnalysisResult.confidence] bleibt aus demselben Grund wie
/// `sourceLabel` ein roher `String` (Bestandstests konstruieren Fixtures mit
/// String-Literalen wie `confidence: 'Hoch'`). [resolve] ordnet den Rohwert
/// zu: dem seit diesem PR geschriebenen [code] (fuer `high`/`medium`/`low`
/// identisch mit dem, was das Modell selbst schon liefert — keine weitere
/// Übersetzungsebene noetig), dem deutschen Bestandswert ([legacyDe]) oder —
/// Verteidigungslinie — dem englischen Anzeigetext.
enum MealResultConfidence {
  high(_MealResultConfidenceCodes.high, legacyDe: 'Hoch'),
  medium(_MealResultConfidenceCodes.medium, legacyDe: 'Mittel'),
  low(_MealResultConfidenceCodes.low, legacyDe: 'Niedrig'),
  unknown(_MealResultConfidenceCodes.unknown, legacyDe: 'Unbekannt'),
  database(_MealResultConfidenceCodes.database, legacyDe: 'Datenbank'),
  recipe(_MealResultConfidenceCodes.recipe, legacyDe: 'Rezept'),
  manual(_MealResultConfidenceCodes.manual, legacyDe: 'Eigene Angabe');

  const MealResultConfidence(this.code, {required this.legacyDe});

  /// Der ab diesem PR geschriebene, sprachneutrale Persistenz-Wert.
  final String code;

  /// Der deutsche Bestandswert, den JEDER Client vor diesem PR geschrieben
  /// hat.
  final String legacyDe;

  /// Anzeigetext in der Sprache von [l10n].
  String label(AppLocalizations l10n) => switch (this) {
    MealResultConfidence.high => l10n.foodConfidenceHigh,
    MealResultConfidence.medium => l10n.foodConfidenceMedium,
    MealResultConfidence.low => l10n.foodConfidenceLow,
    MealResultConfidence.unknown => l10n.foodConfidenceUnknown,
    MealResultConfidence.database => l10n.foodConfidenceDatabase,
    MealResultConfidence.recipe => l10n.foodConfidenceRecipe,
    MealResultConfidence.manual => l10n.foodConfidenceManual,
  };

  /// Ordnet einen ROHEN, persistierten Wert (`MealAnalysisResult.confidence`)
  /// einer bekannten Stufe zu, oder liefert `null` fuer alles Unbekannte
  /// (Pass-through-Fall — z. B. eine Modell-Antwort ausserhalb des
  /// vereinbarten `high`/`medium`/`low`-Schemas).
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

/// Sprachneutrale Marker fuer die drei hartkodierten Fallback-Texte, die
/// [MealAnalysisResult.fromEdgeFunction] in `portionNotes` schreibt, wenn das
/// Modell kein eigenes `explanation` liefert (Review-Fixwelle Scan/Coach-PR,
/// 2026-08-11), sowie den vierten Marker [manual] fuer
/// [MealAnalysisResult.manualEntry] (Spec 2026-08-13) — derselbe Fall wie ein
/// fehlendes `explanation`, nur ohne Modellantwort ueberhaupt.
///
/// **Bewusst NUR diese vier Formulierungen**, nicht `portionNotes` generell:
/// das Feld traegt sonst entweder echten KI-Freitext (`json['explanation']`)
/// oder von `adjustedToGrams`/`adjustedToItems` rechnerisch gebaute
/// Anpassungs-Saetze (`'Manuell angepasst: …'` etc.) — beides bleibt bewusst
/// hartkodiertes Deutsch (s. `MealAnalysisResult`-Klassendoku): KI-Freitext
/// ist quasi Nutzerdaten (wie ein geloggter Mahlzeitname), keine
/// UI-Vokabel, und die Anpassungs-Saetze sind eine dokumentierte, separate
/// Restlücke (s. Waechter-Kommentar in `hartkodierung_waechter_test.dart`).
/// Muster: `FitnessRecipe._resolvePlaceholder` (Inhalte-PR) — ein bekannter
/// Alt-Text (deutsch) ODER der neue neutrale [code] wird durch die AKTIVE
/// Locale ersetzt, alles andere bleibt unangetastet.
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

  /// Der ab diesem PR geschriebene, sprachneutrale Persistenz-Wert.
  final String code;

  /// Der deutsche Bestandswert, den JEDER Client vor diesem PR geschrieben
  /// hat.
  final String legacyDe;

  /// Anzeigetext in der Sprache von [l10n].
  String text(AppLocalizations l10n) => switch (this) {
    MealResultPortionNote.autoSplit => l10n.foodScanNoteAutoSplit,
    MealResultPortionNote.itemized => l10n.foodScanNoteItemized,
    MealResultPortionNote.plain => l10n.foodScanNotePlain,
    MealResultPortionNote.manual => l10n.foodManualEntryNote,
  };

  /// Ordnet einen ROHEN, persistierten Wert
  /// (`MealAnalysisResult.portionNotes`) einem der drei bekannten Fallback-
  /// Texte zu, oder liefert `null` fuer alles Unbekannte (KI-Freitext,
  /// Anpassungs-Saetze, Nutzerdaten — Pass-through-Fall).
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

/// Sprachneutrale Kodierung des Produkt-Hinweises, den
/// [MealAnalysisResult.fromOpenFoodFacts] in `portionNotes` schreibt
/// (Komplettreview 2026-08-19, Fund 4).
///
/// Bis dahin baute die Fabrik dort einen fertigen DEUTSCHEN Absatz
/// (`'OpenFoodFacts Barcode 4001724012345. Marke: … Du kannst das gegessene
/// Gewicht weiter anpassen.'`) und persistierte ihn. Ein englischer Nutzer las
/// diesen Text unter korrekt uebersetzten Labels auf Deutsch, und kein
/// Sprachwechsel wurde ihn je wieder los — das Feld liegt im Payload.
///
/// Anders als bei [MealResultPortionNote] reicht ein fester Marker hier
/// nicht: der Absatz traegt VARIABLEN (Barcode, Marke, Packungsgroesse,
/// Portionsangabe der Datenbank). Persistiert wird deshalb ein Marker MIT
/// Nutzlast — [_prefix] plus die vier Werte als JSON —, aufgeloest wird er
/// erst zur Anzeigezeit ([text]). Unter [deL10n] ist das Ergebnis wortgleich
/// mit dem bisherigen Absatz (i18n-Regel 1: de bleibt byte-identisch).
///
/// **Alt-Zeilen bleiben lesbar UND werden uebersetzt.** [resolve] erkennt
/// neben der neuen Kodierung auch den deutschen Bestandsabsatz und liest
/// dessen vier Werte ueber [_legacyDe] zurueck — dieselbe Idee wie
/// [MealResultSource.legacyDe], nur dass ein Absatz mit Variablen ein Muster
/// statt eines Literals braucht. Passt das Muster nicht (von Hand veraenderter
/// oder noch aelterer Text), bleibt der Rohtext unveraendert stehen
/// (Pass-through, i18n-design.md §5) — lesbar ist er in jedem Fall.
class MealResultOffNote {
  const MealResultOffNote({
    required this.barcode,
    this.brand,
    this.package,
    this.serving,
  });

  /// Praefix des persistierten Werts. Kurz und sprachneutral, damit er in
  /// derselben Spalte lebt wie die Marker aus [MealResultPortionNote].
  static const String _prefix = 'offProductNote:';

  final String barcode;
  final String? brand;

  /// Packungsgroesse laut OFF (`quantity`), z. B. `'390 g'`.
  final String? package;

  /// Portionsangabe laut OFF (`serving_size`), z. B. `'100 g'`.
  final String? serving;

  /// Der sprachneutrale Wert fuer `portionNotes`.
  String encode() {
    final werte = <String, String>{
      'barcode': barcode,
      if (brand != null) 'brand': brand!,
      if (package != null) 'package': package!,
      if (serving != null) 'serving': serving!,
    };
    return '$_prefix${jsonEncode(werte)}';
  }

  /// Anzeigetext in der Sprache von [l10n].
  String text(AppLocalizations l10n) => <String>[
    l10n.mealNotesOffSource(barcode),
    if (brand != null) l10n.mealNotesOffBrand(brand!),
    if (package != null) l10n.mealNotesOffPackage(package!),
    if (serving != null) l10n.mealNotesOffServing(serving!),
    l10n.mealNotesOffDatabase,
    l10n.mealNotesAdjustWeight,
  ].join(' ');

  /// Ordnet einen ROHEN, persistierten Wert zu: neue Kodierung oder deutscher
  /// Bestandsabsatz. Alles andere -> `null` (Pass-through-Fall).
  static MealResultOffNote? resolve(String raw) => raw.startsWith(_prefix)
      ? _fromJson(raw.substring(_prefix.length))
      : _fromLegacyDe(raw);

  /// Ein beschaedigter Marker ist kein Grund, die Zeile zu verlieren: der
  /// Aufrufer zeigt dann den Rohwert, wie bei jedem unbekannten Text.
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
    // Der fehlende Schluessel disqualifiziert den Marker; ein LEERER Barcode
    // nicht — die Produktsuche liefert Treffer ohne `code` (s.
    // `ProductSearchResult.fromOpenFoodFacts`), und der Bestandsabsatz schrieb
    // dafuer schon immer 'OpenFoodFacts Barcode .'.
    if (barcode == null) return null;
    return MealResultOffNote(
      barcode: barcode.toString().trim(),
      brand: _nichtLeer(gelesen['brand']),
      package: _nichtLeer(gelesen['package']),
      serving: _nichtLeer(gelesen['serving']),
    );
  }

  /// Muster des deutschen Bestandsabsatzes. Bewusst Kompatibilitaets-DATEN,
  /// kein UI-Text (dieselbe Rolle wie [MealResultSource.legacyDe]): die
  /// Wortlaute sind die Fassung VOR dem Komplettreview 2026-08-19 und duerfen
  /// sich nie wieder aendern — sonst verlieren Alt-Zeilen ihre Uebersetzung.
  /// Die drei mittleren Gruppen sind optional, weil `fromOpenFoodFacts` sie
  /// schon damals nur bei vorhandenem Feld schrieb.
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

  /// ROHER Sicherheits-Wert, wie er persistiert wird — s.
  /// [MealResultConfidence] fuer die Kompatibilitaets- und Anzeigelogik.
  /// Fuer die Anzeige immer [resolvedConfidence] verwenden.
  final String confidence;

  /// ROHER Notiz-Text, wie er persistiert wird. Traegt entweder einen der
  /// drei bekannten Fallback-Marker aus `fromEdgeFunction`
  /// (s. [MealResultPortionNote], ueber [resolvedPortionNotes] aufloesbar),
  /// den kodierten OFF-Produkthinweis aus `fromOpenFoodFacts`
  /// (s. [MealResultOffNote], ebenfalls aufloesbar), echten KI-Freitext
  /// (`explanation`) oder von `adjustedToGrams`/`adjustedToItems` gebaute
  /// Anpassungs-Saetze — beide Letzteren bleiben bewusst hartkodiertes Deutsch
  /// (quasi Nutzerdaten bzw. dokumentierte Restlücke, s.
  /// [MealResultPortionNote]-Klassendoku).
  final String portionNotes;
  final List<MealComponent> items;
  final bool isAdjusted;

  /// ROHER Herkunfts-Wert, wie er persistiert wird — s. [MealResultSource]
  /// fuer die Kompatibilitaets- und Anzeigelogik. Ab diesem PR ein neutraler
  /// [MealResultSource.code] (z. B. `'photoAi'`); Alt-Zeilen tragen den
  /// deutschen Bestandswert (z. B. `'Foto-KI'`); beides — und jeder sonstige
  /// String — bleibt hier unveraendert stehen. Fuer die Anzeige immer
  /// [resolvedSourceLabel] verwenden, NIE dieses Feld direkt rendern.
  final String sourceLabel;
  final String? barcode;
  final String? brand;

  /// `true`, wenn die 0 in [caloriesKcal]/[kcalPer100G] eine MESSUNG ist
  /// (Wasser, Zero-Getraenk — die Datenquelle sagt ausdruecklich 0 kcal,
  /// siehe [offMeldetExplizitNullKcal]) und nicht der Sentinel fuer
  /// „unbekannt". Nur mit diesem Marker duerfen die Letzt-Bremsen im UI
  /// (add_meal_sheet, meal_analysis_sheet) eine 0 durchlassen. Er wird im
  /// Payload persistiert (mealResultToJson), damit auch der Auto-Recent-
  /// Favorit eines Wassers loggbar bleibt — Alt-Zeilen ohne den Schluessel
  /// lesen `false` und bleiben blockiert wie bisher.
  final bool explicitZeroKcal;

  /// Anzeige des Herkunfts-Werts in der Sprache von [l10n]. Loest bekannte
  /// Rohwerte (neutraler Code seit diesem PR ODER deutscher Bestandswert
  /// davor) ueber [MealResultSource] auf; ein unbekannter Rohwert wird
  /// UNVERAENDERT angezeigt (Pass-through, s. [MealResultSource]-Klassendoku).
  String resolvedSourceLabel(AppLocalizations l10n) {
    final source = MealResultSource.resolve(sourceLabel);
    return source == null ? sourceLabel : source.label(l10n);
  }

  /// Ersetzt den bis Scan/Coach-PR hartkodiert deutschen `portionLabel`-Getter
  /// (`'$estimatedGrams g geschätzt'`). Anders als [sourceLabel] wird dieser
  /// Text NIE persistiert (nur [estimatedGrams], eine reine Zahl, ist Teil des
  /// Payloads) — es gibt hier also keine Altzeilen-Kompatibilitaetsfrage, nur
  /// eine fehlende Anzeige-Sprache, die dieser Aufruf ergaenzt.
  String resolvedPortionLabel(AppLocalizations l10n) =>
      l10n.foodPortionEstimated(estimatedGrams);

  /// Anzeige der Sicherheits-Stufe in der Sprache von [l10n]. Loest bekannte
  /// Rohwerte (neutraler Code seit diesem PR ODER deutscher Bestandswert
  /// davor) ueber [MealResultConfidence] auf; ein unbekannter Rohwert wird
  /// UNVERAENDERT angezeigt (Pass-through).
  String resolvedConfidence(AppLocalizations l10n) {
    final level = MealResultConfidence.resolve(confidence);
    return level == null ? confidence : level.label(l10n);
  }

  /// Anzeige der Anpassungs-/Scan-Notiz in der Sprache von [l10n]. Loest die
  /// bekannten Fallback-Marker aus `fromEdgeFunction` (s.
  /// [MealResultPortionNote]) und den OFF-Produkthinweis aus
  /// `fromOpenFoodFacts` (s. [MealResultOffNote], inklusive der deutschen
  /// Alt-Zeilen) auf; echter KI-Freitext und die rechnerischen Anpassungs-Texte
  /// aus `adjustedToGrams`/`adjustedToItems` sind kein UI-Vokabular und bleiben
  /// unveraendert (Pass-through) — dieselbe Klammer wie [resolvedSourceLabel].
  String resolvedPortionNotes(AppLocalizations l10n) {
    final note = MealResultPortionNote.resolve(portionNotes);
    if (note != null) return note.text(l10n);
    final offNote = MealResultOffNote.resolve(portionNotes);
    return offNote == null ? portionNotes : offNote.text(l10n);
  }

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
    // Nur eine echte Modellangabe zaehlt als bekannte Portion. Die 150 g
    // weiter unten sind ein Default und duerfen nicht als Bezugsgroesse fuer
    // eine hergeleitete Dichte durchgehen.
    //
    // Reihenfolge seit dem Komplettreview 2026-08-19 (Fund 3): explizite
    // Modellangabe, dann die POSTENSUMME (strukturierte Zahlen), erst zuletzt
    // der Erklaertext — und der nur noch, wenn er GENAU EINE Grammangabe
    // traegt. Der Prompt verlangt in `explanation` ausdruecklich eine
    // Groessen-Begruendung, die typischerweise mehrere Grammzahlen nennt
    // ('120 g Nudeln mit 80 g Sauce'); die erste davon ist dann eben NICHT
    // das Gesamtgewicht, und sie schlug bisher trotzdem die Postensumme.
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
    // Reihenfolge der Fallback-Kette, bewusst so:
    //   1. die explizite, plausible Modelldichte
    //   2. die Herleitung aus den beiden autoritativen Zahlen DIESES Fotos
    //   3. erst dann die namensbasierte Referenztabelle — sie kennt nur eine
    //      Handvoll unverarbeiteter Lebensmittel, weiss nichts von der
    //      Zubereitung und ist damit die schwaechste Quelle
    //   4. zuletzt die Herleitung mit der Default-Portion
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
    // Sentinel-Rest C (Nachverifikation 2026-08-08): am Ende der Kette stand
    // `: 52.0` — eine gewuerfelte Dichte, die aus einem komplett zahlenlosen
    // Modell-Ergebnis eine loggbare 78-kcal-Mahlzeit machte. 0 ist die
    // etablierte Unbekannt-Form dieses Modells (ohne explicitZeroKcal), die
    // Log-Guards blockieren sie mit Hinweis statt Fantasie zu speichern.
    final protein = json['proteinG'];
    final carbs = json['carbsG'];
    final fat = json['fatG'];
    // Fehlende/leere confidence ist keine "mittlere" — sie ist keine Aussage.
    final confidence = json['confidence']?.toString();
    final dichte = clampKcalPer100G(kcalPer100G);
    // Fund 1b (Komplettreview 2026-08-19): die Gesamtkalorien duerfen nur aus
    // einer WIRKLICH GEMESSENEN Portion hergeleitet werden. Zuvor stand hier
    // `estimatedGrams`, also notfalls die Default-Portion von 150 g — zusammen
    // mit einer namensbasierten Referenzdichte entstand daraus aus einer
    // zahlenlosen Modellantwort eine loggbare Kalorienzahl ('Apfel' -> 78
    // kcal), die auf der Karte aussieht wie eine Messung. Ohne belastbare
    // Zahlen bleibt es bei der etablierten Unbekannt-Form 0 (ohne
    // explicitZeroKcal): die Log-Guards blockieren sie mit Hinweis.
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
    // Fund 2 (Komplettreview 2026-08-19): `items[]` und `caloriesKcal` kamen
    // bisher unabgeglichen aus derselben Antwort. Wer im Bestandteil-Sheet nur
    // BESTAETIGTE, bekam ueber `adjustedToItems` die Postensumme als neue
    // Gesamtzahl — also eine andere Mahlzeit, als auf der Karte stand.
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
      portionNotes:
          json['explanation']?.toString() ??
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
    final productName =
        _firstNonEmptyString(product, const ['product_name', 'generic_name']) ??
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
    // Sprachneutral persistiert, erst zur Anzeigezeit aufgeloest (Fund 4,
    // Komplettreview 2026-08-19): der fertige deutsche Absatz, der hier
    // frueher gebaut wurde, ueberlebte im Payload jeden Sprachwechsel. Unter
    // deL10n liefert `MealResultOffNote.text()` denselben Wortlaut wie bisher.
    final hinweis = MealResultOffNote(
      barcode: barcode,
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
      barcode: barcode,
      brand: brand,
      // Die 0 traegt ihre Herkunft: nur eine AUSDRUECKLICH gemeldete 0
      // (Wasser, Zero) ist eine Messung — der Parser-Fallback `?? 0` oben
      // erfuellt die Bedingung nie, weil der Detektor die Rohfelder liest.
      explicitZeroKcal: kcalPer100G == 0 && offMeldetExplizitNullKcal(product),
    );
  }

  /// Baut das Ergebnis eines MANUELL eingetragenen Lebensmittels
  /// (manual_meal_sheet, Spec 2026-08-13): Etikett-Werte pro 100 g plus die
  /// gegessene Portion. Anders als bei den Parser-Fabriken oben sind die
  /// Eingaben formularvalidiert — die Klemmen sind reine Defensiv-Schicht,
  /// keine Reparatur.
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
      // Eine AUSDRÜCKLICH eingetragene 0 (Wasser, Zero) ist eine Messung,
      // kein Unbekannt-Sentinel — nur sie darf die Log-Bremse passieren.
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

  /// Ob die OFF-Naehrwerte die Energie EXPLIZIT mit 0 angeben (Wasser, Tee,
  /// Zero-Getraenke). Nur dann ist eine geparste 0 eine Messung und keine
  /// fehlende Angabe — der Energie-Filter darf sie loggen lassen, statt
  /// faelschlich „ohne Naehrwerte" zu behaupten (Nachverifikation 2026-08-08
  /// zu B7).
  ///
  /// Kandidaten und Vorrang entsprechen [_offKcalPer100G]: steht im
  /// bevorzugten Feld ein Wert, entscheidet DER (eine 0 in einem
  /// nachrangigen Feld neben einem befuellten kcal-Feld ist keine
  /// 0-kcal-Angabe); `energy-kcal_value` zaehlt nur bei 100-g-Basis; die
  /// kJ-Felder brauchen keine Umrechnung, 0 kJ sind 0 kcal. Ein nullbares
  /// kcal-Feld quer durch Sync/Favoriten/Widgets braucht diese
  /// Unterscheidung nicht: sie faellt am Gate, bevor die 0 ihre Herkunft
  /// verliert.
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

  /// Skaliert einen 100-g-Makrowert auf [grams] und formatiert ihn. Oeffentlich
  /// (statt `_macroForGrams`), weil sowohl [fromOpenFoodFacts] als auch die
  /// manuelle Factory [manualEntry] denselben Formatierer brauchen — beide
  /// starten von Etikett-Werten pro 100 g.
  static String macroForGrams(double? per100G, int grams) {
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

  /// Erste Grammangabe eines Textes. Nur noch fuer OFFs `serving_size`
  /// gedacht — ein Feld, das genau EINE Portionsangabe traegt ('100 g',
  /// '1 Riegel (30 g)'). Fuer den KI-Erklaertext ist die Frage eine andere,
  /// s. [_unambiguousGramsFromText].
  static int? _estimateGramsFromText(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'(\d{2,4})\s*g').firstMatch(value.toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Gramm aus einem KI-Erklaertext — aber nur, wenn der Text GENAU EINE
  /// Grammangabe traegt (Fund 3, Komplettreview 2026-08-19).
  ///
  /// `explanation` ist laut Prompt eine Groessen-BEGRUENDUNG und nennt
  /// deshalb typischerweise mehrere Gewichte ('etwa 120 g Nudeln mit 80 g
  /// Sauce'). Die erste Zahl daraus als GESAMTgewicht zu lesen, ist geraten;
  /// bei genau einer Angabe ist die Lesart dagegen eindeutig. Das
  /// Wortende (`\b`, optional 'gramm'/'grams') haelt ausserdem Treffer wie
  /// '120 gebraten' draussen, die das alte Muster mitnahm.
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

  /// Referenzdichten fuer eine Handvoll unverarbeiteter Lebensmittel, die das
  /// Modell haeufig ohne Zahlen zurueckgibt. Schwaechste Quelle der
  /// Dichte-Kette in [fromEdgeFunction] und bewusst kurz gehalten — fuer
  /// zusammengesetzte Gerichte gibt es `autoSplitItems`/`food_kcal_db.dart`.
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

  /// Referenzdichte zum Mahlzeitnamen — nur bei EXAKTEM Treffer auf dem
  /// normalisierten Namen (Fund 1a, Komplettreview 2026-08-19).
  ///
  /// Vorher war das eine Teilstring-Suche: 'Erdbeerkuchen' enthaelt 'erdbeer'
  /// und bekam damit 32 kcal/100 g, 'Apfelstrudel' die 52 eines rohen Apfels.
  /// Die Tabelle kennt nur ganze, unverarbeitete Lebensmittel — sobald der
  /// Name mehr sagt als sie weiss, ist Schweigen die richtige Antwort.
  static double? _knownKcalPer100G(String mealName) {
    final name = mealName.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    return _referenzKcalPer100G[name];
  }

  /// Nordet die Kalorien der Posten proportional und summengenau auf
  /// [gesamtKcal] ein (Fund 2, Komplettreview 2026-08-19).
  ///
  /// **Der Modell-Gesamtwert gewinnt gegen die Postensumme** — aus demselben
  /// Grund, aus dem er in [adjustedToGrams] gegen die Dichte gewinnt: er ist
  /// die Zahl, die gross auf der Karte steht und die der Nutzer bestaetigt;
  /// die Posten sind seine Aufschluesselung. Damit gilt auch hier
  /// `adjustedToItems(items).caloriesKcal == caloriesKcal`, blosses
  /// Bestaetigen verschiebt die Mahlzeit also nicht mehr.
  ///
  /// Die Posten behalten ihre Verhaeltnisse zueinander und ihre Gramm (die
  /// Dichte wird mitgefuehrt); die Makros bleiben unangetastet — sie sind eine
  /// eigene Modellaussage, keine Ableitung aus den Kalorien. Ohne
  /// Bezugsgroesse wird nichts gerechnet: eine Postenliste ganz ohne
  /// Kalorienzahl (der Server liefert dort `null`) bleibt unveraendert, statt
  /// eine Verteilung zu erfinden.
  ///
  /// Die GRAMMsumme bleibt bewusst unangetastet: sie proportional zu
  /// verschieben hiesse, jeden Posten neu zu gewichten und die Makros mit ihm
  /// (s. `MealComponent.adjustedToGrams`) — das ist eine eigene Entscheidung
  /// und nicht die, um die es hier geht.
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
    // Rundungsrest (hoechstens ein halbes kcal je Posten) auf den groessten
    // Posten — sonst verfehlt die Summe ihr Ziel um ein paar kcal und die
    // Invariante oben gaelte nur ungefaehr.
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

  /// [MealComponent] hat kein `copyWith` — der Posten wird deshalb neu
  /// gebaut. Die Dichte folgt der neuen Kalorienzahl (sonst widerspraeche sie
  /// dem eigenen Posten), Gramm und Makros bleiben, wie das Modell sie
  /// gemeldet hat.
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

  /// Normalisiert eine rohe Modell-Angabe (`'high'`/`'HIGH'`/`'High'` etc.,
  /// das Modell ist hier nicht strikt) auf den neutralen Persistenz-Code —
  /// ersetzt das fruehere `_formatConfidence`, das SOFORT nach Deutsch
  /// uebersetzte. Ein unbekannter Wert bleibt unveraendert (Pass-through,
  /// identisch zum bisherigen `default: return value`-Zweig).
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

/// Makro-Summe in Gramm. Rein intern; existiert nur, damit
/// [MealAnalysisResult.adjustedToItems] drei Werte zurueckgeben kann.
class _MacroTriple {
  const _MacroTriple(this.protein, this.carbs, this.fat);

  final double protein;
  final double carbs;
  final double fat;
}
