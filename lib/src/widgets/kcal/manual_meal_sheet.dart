import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../theme/app_tokens.dart';
import '../design/sheets.dart';

/// Form for custom nutrition values: label values PER 100 g plus the portion
/// eaten; `MealAnalysisResult.manualEntry` computes the portion values. For
/// foods with no database entry.
///
/// Returns the finished result or null (cancelled); the caller logs it.
///
/// **Deliberately without a discard guard (D5 criterion):** a name and four
/// numbers are retyped in seconds, unlike the eight recipe fields.
Future<MealAnalysisResult?> showManualMealSheet(
  BuildContext context, {
  String? initialName,
}) {
  return showModalBottomSheet<MealAnalysisResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
    builder: (sheetContext) => ManualMealSheet(initialName: initialName),
  );
}

class ManualMealSheet extends StatefulWidget {
  const ManualMealSheet({super.key, this.initialName});

  /// Prefill from the product search (nothing found -> search term).
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

  // kcal/100 g is bounded by plausibility (pure fat ~900), not by the DB
  // limit. 0 is allowed: an explicit 0 (water, zero drinks) is a measurement
  // (MealAnalysisResult.explicitZeroKcal), not a missing value.
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
    // 100 g as the start value: the label base itself.
    _grams = _feld('100');
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
  }

  /// Controller with a rebuild listener — save lock, error texts and the
  /// preview line hang live on the field content.
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

  /// Error text for an integer field, or null. An EMPTY field gets no error
  /// on purpose; missing required values block via [_isValid] alone.
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

  /// Macro fields carry DECIMALS (see [_makroOderNull]), so the range check
  /// runs on the parsed number rather than [_bereichsFehler], which expects
  /// digits only. Bounds stay integers because the error text takes `int`.
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

  /// Macro value per 100 g as a decimal, comma OR dot as separator — 0.5 g of
  /// fat must be enterable (same pattern as `_MacroField`).
  double? _makroOderNull(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  /// Computed portion for the preview line — only when both required numbers
  /// are valid, otherwise null.
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

  /// Builds the result from [MealAnalysisResult.manualEntry] and only patches
  /// the three macro strings.
  ///
  /// Constraint not visible in the code: the factory takes macros per 100 g as
  /// `int`, so a typed "3,5" would round to 4 and be half a gram off for
  /// 125 g. While that signature stays `int`, this sheet scales the three
  /// values with the same public formatter the factory uses. Everything else —
  /// clamping, source codes, `explicitZeroKcal` — comes from the factory.
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
        // Safe-area and keyboard aware instead of a fixed 92 %: five input
        // fields, so the keyboard is practically always open.
        constraints: BoxConstraints(maxHeight: sheetMaxHeightOf(context)),
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
                // 2x2 instead of 4 columns: the headers are long and stay on
                // one line this way even at large font sizes.
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
              // FilledButton with onPressed == null as the lock signal — same
              // testable pattern as recipe-create-save.
              FilledButton.icon(
                key: const ValueKey('manual-meal-save'),
                onPressed: _isValid ? _save : null,
                icon: const Icon(Icons.check_rounded, size: 18),
                // No styleFrom: fill, ink, disabled tone and shape come from
                // the app-wide filledButtonTheme (review F8-10).
                label: Text(
                  l10n.commonSave,
                  style: AppType.ui(14.5, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Group header (uppercase label plus a muted suffix on the right) — local
/// copy of the `_SheetGroup` pattern from recipe_create_sheet.dart.
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

/// Labelled input field: uppercase header with unit and macro dot on a
/// [FieldCapsule] (rest `field`, focus `fieldFocus`, error `fieldError` plus
/// the error line below), semantics label for the screen reader.
class _ManualField extends StatefulWidget {
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

  /// Only meaningful with [numeric]: also allows comma and dot. Set only on
  /// fields whose value may be fractional; kcal/100 g and portion grams stay
  /// integers.
  final bool decimal;
  final int? maxChars;
  final String? errorText;
  final Color? dot;

  @override
  State<_ManualField> createState() => _ManualFieldState();
}

class _ManualFieldState extends State<_ManualField> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final label = widget.label;
    final unit = widget.unit;
    final dot = widget.dot;
    final errorText = widget.errorText;
    final hasError = errorText != null;
    final zifferntastatur = widget.decimal
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.number;
    // `digitsOnly` swallows the separator SILENTLY: "3,5" becomes 35 — a
    // factor of 10 in the rings, the database and the 90-day average, with
    // the still-correct calories hiding it.
    final ziffernfilter = widget.decimal
        ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
        : FilteringTextInputFormatter.digitsOnly;
    final kopfzeile = unit == null
        ? label.toUpperCase()
        : '${label.toUpperCase()} · ${unit.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          // Fixed one-line header: unevenly wrapping labels would otherwise
          // start the fields at different heights.
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
        FieldCapsule(
          focusNode: _focus,
          error: hasError,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  label: label,
                  child: TextField(
                    key: widget.fieldKey,
                    focusNode: _focus,
                    cursorOpacityAnimates: false,
                    controller: widget.controller,
                    maxLength: widget.maxChars,
                    keyboardType: widget.numeric
                        ? zifferntastatur
                        : TextInputType.text,
                    inputFormatters: widget.numeric ? [ziffernfilter] : null,
                    textCapitalization: widget.numeric
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
                      hintText: widget.hint,
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
            errorText,
            style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }
}
