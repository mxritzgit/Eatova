import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../theme/app_tokens.dart';

/// Formular für eigene Nährwerte (Spec 2026-08-13): Werte vom Etikett PRO
/// 100 g plus die gegessene Portion — `MealAnalysisResult.manualEntry`
/// rechnet die Portionswerte aus. Für Lebensmittel ohne Datenbank-Eintrag
/// (Hofladen, Wochenmarkt, lose Ware).
///
/// Liefert das fertige Ergebnis zurück oder null (abgebrochen); GELOGGT wird
/// im Aufrufer (Add-Meal-Sheet) — dieselbe Trennung wie beim Analyse-Sheet.
///
/// **Bewusst OHNE Verwerfen-Schutz (D5-Kriterium, s. add_meal_sheet.dart):**
/// hier stehen ein Name und vier Zahlen vom Etikett — in Sekunden erneut
/// eingetippt, anders als die acht Rezeptfelder.
Future<MealAnalysisResult?> showManualMealSheet(
  BuildContext context, {
  String? initialName,
}) {
  return showModalBottomSheet<MealAnalysisResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Wie im Add-Meal-Sheet: der Scrim dunkelt in beiden Anzeige-Modi ab.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) => ManualMealSheet(initialName: initialName),
  );
}

class ManualMealSheet extends StatefulWidget {
  const ManualMealSheet({super.key, this.initialName});

  /// Vorbelegung aus der Produktsuche („nichts gefunden" → Suchbegriff).
  final String? initialName;

  @override
  State<ManualMealSheet> createState() => _ManualMealSheetState();
}

class _ManualMealSheetState extends State<ManualMealSheet> {
  late final TextEditingController _name;
  late final TextEditingController _kcal100;
  late final TextEditingController _grams;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  // kcal/100 g läuft gegen die PLAUSIBILITÄTS-Grenze (reines Fett ~900),
  // nicht gegen die DB-Grenze — mehr ist physikalisch unmöglich. Die 0 ist
  // erlaubt: eine ausdrückliche 0 (Wasser, Zero) ist eine Messung
  // (MealAnalysisResult.explicitZeroKcal), kein fehlender Wert.
  static const int _kcal100Min = 0; // PlausibilityLimits.kcalPer100GMin
  static const int _kcal100Max = 900; // PlausibilityLimits.kcalPer100GMax
  static const int _gramsMin = 1; // PlausibilityLimits.portionGramsMin
  static const int _gramsMax = 10000; // PlausibilityLimits.portionGramsMax
  static const int _macroMin = 0; // LoggedMealLimits.macroGMin
  static const int _macroMax = 1000; // LoggedMealLimits.macroGMax

  @override
  void initState() {
    super.initState();
    _name = _feld(widget.initialName?.trim() ?? '');
    _kcal100 = _feld();
    // 100 g als Startwert: die Etikett-Basis selbst — wer die ganze
    // Referenzmenge isst, muss nichts anfassen.
    _grams = _feld('100');
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
  }

  /// Controller mit Rebuild-Listener — Save-Sperre, Fehlertexte und die
  /// Vorschauzeile hängen live am Feldinhalt (Muster recipe_create_sheet).
  TextEditingController _feld([String start = '']) {
    final controller = TextEditingController(text: start);
    controller.addListener(() => setState(() {}));
    return controller;
  }

  @override
  void dispose() {
    _name.dispose();
    _kcal100.dispose();
    _grams.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  /// Fehlertext für ein Ganzzahlfeld oder null. Ein LEERES Feld bekommt
  /// bewusst keinen Fehler („noch nichts eingegeben" ist kein Eingabefehler);
  /// fehlende Pflichtwerte sperren allein über [_isValid].
  String? _bereichsFehler(
    TextEditingController controller, {
    required int min,
    required int max,
    required String Function(int min, int max) bereichstext,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final wert = int.tryParse(text);
    if (wert == null || wert < min || wert > max) return bereichstext(min, max);
    return null;
  }

  String? get _kcal100Fehler => _bereichsFehler(
    _kcal100,
    min: _kcal100Min,
    max: _kcal100Max,
    bereichstext: context.l10n.recipesRangeErrorKcal,
  );

  String? get _gramsFehler => _bereichsFehler(
    _grams,
    min: _gramsMin,
    max: _gramsMax,
    bereichstext: context.l10n.recipesRangeErrorGrams,
  );

  /// Makro-Felder tragen DEZIMALWERTE (s. [_makroOderNull]) — die
  /// Bereichsprüfung läuft deshalb auf der geparsten Zahl und nicht über
  /// [_bereichsFehler], das eine reine Ziffernfolge erwartet. Die Grenzen
  /// bleiben ganzzahlig, weil der Fehlertext `int`-Platzhalter führt.
  String? _makroFehler(TextEditingController controller) {
    if (controller.text.trim().isEmpty) return null;
    final wert = _makroOderNull(controller);
    if (wert == null || wert < _macroMin || wert > _macroMax) {
      return context.l10n.recipesRangeErrorGrams(_macroMin, _macroMax);
    }
    return null;
  }

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    if (_kcal100.text.trim().isEmpty || _grams.text.trim().isEmpty) {
      return false;
    }
    return _kcal100Fehler == null &&
        _gramsFehler == null &&
        _makroFehler(_protein) == null &&
        _makroFehler(_carbs) == null &&
        _makroFehler(_fat) == null;
  }

  int? _zahlOderNull(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : int.tryParse(text);
  }

  /// Makro-Wert pro 100 g als Dezimalzahl, Komma ODER Punkt als Trenner —
  /// dasselbe Muster wie `_MacroField` in meal_widgets_adjust.dart: 0,5 g
  /// Fett muss eingebbar sein.
  double? _makroOderNull(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  /// Gerechnete Portion für die Vorschauzeile — nur wenn beide Pflichtzahlen
  /// gültig dastehen, sonst null (keine Vorschau aus halben Eingaben).
  int? get _vorschauKcal {
    if (_kcal100Fehler != null || _gramsFehler != null) return null;
    final kcal100 = _zahlOderNull(_kcal100);
    final gramm = _zahlOderNull(_grams);
    if (kcal100 == null || gramm == null) return null;
    return clampMealCaloriesKcal(kcal100 * gramm / 100);
  }

  void _save() {
    if (!_isValid) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(_ergebnis());
  }

  /// Baut das Ergebnis aus [MealAnalysisResult.manualEntry] und setzt NUR die
  /// drei Makro-Strings nach.
  ///
  /// **Zwang, den der Code nicht zeigt:** die Factory nimmt die Makros pro
  /// 100 g heute als `int` — ein getipptes „3,5" müsste dort auf 4 gerundet
  /// werden und wäre für 125 g um ein halbes Gramm falsch. Ihre Signatur
  /// liegt in `models/meal_analysis_result.dart` und bleibt in diesem
  /// Durchgang unangetastet; solange sie `int` führt, skaliert dieses Sheet
  /// die drei Werte mit demselben ÖFFENTLICHEN Formatierer nach, den die
  /// Factory selbst benutzt. Alles Übrige — Klemmen, Herkunfts-Codes,
  /// `explicitZeroKcal` — kommt unverändert aus der Factory.
  MealAnalysisResult _ergebnis() {
    final basis = MealAnalysisResult.manualEntry(
      name: _name.text,
      kcalPer100G: _zahlOderNull(_kcal100)!,
      grams: _zahlOderNull(_grams)!,
    );
    final gramm = basis.estimatedGrams;
    String makro(TextEditingController controller) =>
        MealAnalysisResult.macroForGrams(_makroOderNull(controller), gramm);
    return MealAnalysisResult(
      mealName: basis.mealName,
      caloriesKcal: basis.caloriesKcal,
      estimatedGrams: gramm,
      kcalPer100G: basis.kcalPer100G,
      protein: makro(_protein),
      carbs: makro(_carbs),
      fat: makro(_fat),
      confidence: basis.confidence,
      portionNotes: basis.portionNotes,
      items: basis.items,
      isAdjusted: basis.isAdjusted,
      sourceLabel: basis.sourceLabel,
      barcode: basis.barcode,
      brand: basis.brand,
      explicitZeroKcal: basis.explicitZeroKcal,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final mediaQuery = MediaQuery.of(context);
    final vorschau = _vorschauKcal;
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        key: const ValueKey('manual-meal-sheet'),
        constraints: BoxConstraints(maxHeight: mediaQuery.size.height * 0.92),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.line,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.foodManualEntryTitle,
                style: AppType.display(24, color: t.ink, height: 1.15),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.foodManualEntrySubtitle,
                style: AppType.ui(12.5, color: t.ink2, height: 1.4),
              ),
              const SizedBox(height: 12),
              _ManualGroup(
                label: l10n.recipesGroupWhatIsIt,
                child: _ManualField(
                  fieldKey: const ValueKey('manual-meal-name'),
                  controller: _name,
                  label: l10n.foodAddItemNameLabel,
                  hint: l10n.foodManualNameHint,
                  maxChars: LoggedMealLimits.mealNameMaxChars,
                ),
              ),
              const SizedBox(height: 10),
              _ManualGroup(
                label: l10n.foodManualGroupNutrition,
                trailing: l10n.foodManualPer100GSuffix,
                // 2×2 statt 4 Spalten: die Felder tragen längere Kopfzeilen
                // („KALORIEN · KCAL") und bleiben so auch bei großer Schrift
                // einzeilig.
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-kcal100'),
                            controller: _kcal100,
                            label: l10n.foodAddItemCaloriesLabel,
                            unit: 'kcal',
                            numeric: true,
                            dot: t.accent,
                            errorText: _kcal100Fehler,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-protein'),
                            controller: _protein,
                            label: l10n.todayMacroProtein,
                            unit: 'g',
                            numeric: true,
                            decimal: true,
                            dot: t.protein,
                            errorText: _makroFehler(_protein),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-carbs'),
                            controller: _carbs,
                            label: l10n.recipesNutritionCarbsLabel,
                            unit: 'g',
                            numeric: true,
                            decimal: true,
                            dot: t.carbs,
                            errorText: _makroFehler(_carbs),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ManualField(
                            fieldKey: const ValueKey('manual-meal-fat'),
                            controller: _fat,
                            label: l10n.todayMacroFat,
                            unit: 'g',
                            numeric: true,
                            decimal: true,
                            dot: t.fat,
                            errorText: _makroFehler(_fat),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _ManualGroup(
                label: l10n.foodManualGroupPortion,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ManualField(
                      fieldKey: const ValueKey('manual-meal-grams'),
                      controller: _grams,
                      label: l10n.foodAddItemWeightLabel,
                      unit: 'g',
                      numeric: true,
                      errorText: _gramsFehler,
                    ),
                    if (vorschau != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        key: const ValueKey('manual-meal-computed'),
                        l10n.foodManualComputedKcal(
                          vorschau,
                          _zahlOderNull(_grams)!,
                        ),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w600,
                          color: t.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // FilledButton mit onPressed == null als Sperrsignal — dasselbe
              // testbare Muster wie recipe-create-save.
              FilledButton.icon(
                key: const ValueKey('manual-meal-save'),
                onPressed: _isValid ? _save : null,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(
                  l10n.commonSave,
                  style: AppType.ui(14.5, weight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: t.forest,
                  foregroundColor: t.onForest,
                  disabledBackgroundColor: t.surf2,
                  disabledForegroundColor: t.ink2,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gruppen-Kopf (Versalien-Label + gedämpfter Zusatz rechts) — lokale Kopie
/// des `_SheetGroup`-Musters aus recipe_create_sheet.dart; beide Sheets
/// sprechen dieselbe Formular-Sprache.
class _ManualGroup extends StatelessWidget {
  const _ManualGroup({required this.label, required this.child, this.trailing});

  final String label;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: AppType.eyebrow(t.ink2, size: 10),
              ),
            ),
            if (trailing != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    trailing!,
                    textAlign: TextAlign.right,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Beschriftetes Eingabefeld — lokale Kopie des `_RecipeSheetField`-Musters
/// (recipe_create_sheet.dart): Versalien-Kopfzeile mit Einheit, Kapsel ohne
/// InputDecoration-Rahmen, rot nur bei Fehler, Semantics-Label für den
/// Screenreader.
class _ManualField extends StatelessWidget {
  const _ManualField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.unit,
    this.numeric = false,
    this.decimal = false,
    this.maxChars,
    this.errorText,
    this.dot,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? unit;
  final bool numeric;

  /// Nur mit [numeric] sinnvoll: lässt Komma und Punkt zusätzlich zu den
  /// Ziffern durch. Trägt allein das Feld, dessen Wert gebrochen sein darf —
  /// kcal/100 g und die Portionsgramm bleiben ganzzahlig.
  final bool decimal;
  final int? maxChars;
  final String? errorText;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    final zifferntastatur = decimal
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.number;
    // `digitsOnly` schluckt das Trennzeichen STUMM: aus „3,5" würde 35 — ein
    // Faktor 10 in den Ringen, in der Datenbank und im 90-Tage-Schnitt, den
    // die richtig bleibenden Kalorien nirgends verraten.
    final ziffernfilter = decimal
        ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
        : FilteringTextInputFormatter.digitsOnly;
    final kopfzeile = unit == null
        ? label.toUpperCase()
        : '${label.toUpperCase()} · ${unit!.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          // Feste einzeilige Kopfzeile — s. recipe_create_sheet.dart:
          // ungleich umbrechende Labels ließen die Felder sonst auf
          // verschiedenen Höhen beginnen.
          height: MediaQuery.textScalerOf(context).scale(9.5) * 1.35,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (dot != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    kopfzeile,
                    maxLines: 1,
                    softWrap: false,
                    style: AppType.eyebrow(t.ink2, size: 9.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: hasError ? t.danger : t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  label: label,
                  child: TextField(
                    key: fieldKey,
                    cursorOpacityAnimates: false,
                    controller: controller,
                    maxLength: maxChars,
                    keyboardType: numeric
                        ? zifferntastatur
                        : TextInputType.text,
                    inputFormatters: numeric ? [ziffernfilter] : null,
                    textCapitalization: numeric
                        ? TextCapitalization.none
                        : TextCapitalization.sentences,
                    style: AppType.ui(14, color: t.ink),
                    cursorColor: t.accent,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: hint,
                      hintStyle: AppType.ui(14, color: t.ink2),
                      counterText: '',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }
}
