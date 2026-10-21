import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/logged_meal.dart';
import '../../models/model_limits.dart';
import '../../models/number_input.dart';
import '../../models/persisted_labels.dart';
import '../../theme/app_tokens.dart';
import '../common/decimal_text.dart';
import '../common/persistence_action.dart';
import '../design/design.dart';
import 'food_glyphs.dart';
import 'meal_slot_picker.dart';

/// Form for custom nutrition values in two modes:
///
/// * **Per 100 g** (default): label values plus the portion eaten;
///   `MealAnalysisResult.manualEntry` computes the portion values. For foods
///   with no database entry.
/// * **Quick entry** (E4): totals without a weight, e.g. a restaurant meal;
///   `MealAnalysisResult.quickEntry`. A mode in this sheet rather than a
///   separate entry, so every way into manual entry (the method card, the
///   dock, "nothing found", a failed scan) reaches it and the method card
///   keeps its rows.
///
/// [barcode] (E5) comes from a scan the database did not know: the result
/// carries it, and the store remembers the product for the next scan.
/// [initial] prefills the form from a stored entry (an own product's or a
/// quick entry's values) to change them.
///
/// Returns the finished result or null (cancelled); the caller logs it.
///
/// **Deliberately without a discard guard (D5 criterion):** a name and four
/// numbers are retyped in seconds, unlike the eight recipe fields.
Future<MealAnalysisResult?> showManualMealSheet(
  BuildContext context, {
  String? initialName,
  MealSlot? initialSlot,
  ValueChanged<MealSlot>? onSlotChanged,
  String? contextLabel,
  PersistValueChanged<MealAnalysisResult>? onSave,
  String? barcode,
  MealAnalysisResult? initial,
}) {
  // No route handle: a pull on it would bypass the commit guard. The sheet
  // draws a [SheetHandle] inside it.
  return showEatovaSheet<MealAnalysisResult>(
    context,
    ManualMealSheet(
      initialName: initialName,
      initialSlot: initialSlot,
      onSlotChanged: onSlotChanged,
      contextLabel: contextLabel,
      onSave: onSave,
      barcode: barcode,
      initial: initial,
    ),
    dragHandle: false,
  );
}

class ManualMealSheet extends StatefulWidget {
  const ManualMealSheet({
    super.key,
    this.initialName,
    this.initialSlot,
    this.onSlotChanged,
    this.contextLabel,
    this.onSave,
    this.barcode,
    this.initial,
  });

  /// Prefill from the product search (nothing found -> search term).
  final String? initialName;
  final MealSlot? initialSlot;
  final ValueChanged<MealSlot>? onSlotChanged;
  final String? contextLabel;
  final PersistValueChanged<MealAnalysisResult>? onSave;

  /// The scanned code the entry is saved under (own product, E5).
  final String? barcode;

  /// Stored values to change; a quick entry opens in quick mode.
  final MealAnalysisResult? initial;

  @override
  State<ManualMealSheet> createState() => _ManualMealSheetState();
}

class _ManualMealSheetState extends State<ManualMealSheet> {
  late MealSlot? _slot = widget.initialSlot;
  late final TextEditingController _name;
  late final TextEditingController _kcal100;
  late final TextEditingController _grams;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  /// Quick mode (E4): totals without grams. Own controllers, so switching
  /// never reads a per-100 g figure as a total or the other way round. An
  /// entry without a weight (also a recipe logged by servings) opens here.
  late bool _quick = widget.initial?.hasNoPortionWeight ?? false;
  late final TextEditingController _kcalTotal;
  late final TextEditingController _proteinTotal;
  late final TextEditingController _carbsTotal;
  late final TextEditingController _fatTotal;

  // kcal/100 g is bounded by plausibility (pure fat ~900), not by the DB
  // limit. 0 is allowed: an explicit 0 (water, zero drinks) is a measurement
  // (MealAnalysisResult.explicitZeroKcal), not a missing value.
  static const int _kcal100Min = 0; // PlausibilityLimits.kcalPer100GMin
  static const int _kcal100Max = 900; // PlausibilityLimits.kcalPer100GMax
  static const int _gramsMin = 1; // PlausibilityLimits.portionGramsMin
  static const int _gramsMax = 10000; // PlausibilityLimits.portionGramsMax
  static const int _macroMin = 0; // LoggedMealLimits.macroGMin
  // Per 100 g, so the per-meal DB bound (1000) does not apply.
  static const int _macroMax = PlausibilityLimits.macroPer100GMax;

  // Quick mode: whole-meal totals, bounded by the logged_meals columns.
  static const int _kcalTotalMax = LoggedMealLimits.caloriesKcalMax;
  static const int _macroTotalMax = 1000; // LoggedMealLimits.macroGMax

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = _feld(
      initial != null && !_isFallbackName(initial)
          ? initial.mealName
          : widget.initialName?.trim() ?? '',
    );
    _kcal100 = _feld();
    // 100 g as the start value: the label base itself.
    _grams = _feld(
      initial != null && initial.estimatedGrams > 0
          ? '${initial.estimatedGrams}'
          : '100',
    );
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
    _kcalTotal = _feld();
    _proteinTotal = _feld();
    _carbsTotal = _feld();
    _fatTotal = _feld();
  }

  /// A stored fallback name ("Schnell-Eintrag") is not the user's text; the
  /// field stays empty and the save writes the fallback again.
  static bool _isFallbackName(MealAnalysisResult result) =>
      result.mealName == PersistedLabels.quickEntryName && result.isQuickEntry;

  bool _prefilled = false;

  /// Numbers of [ManualMealSheet.initial] in the user's decimal style; needs
  /// the locale, hence here and not in [initState].
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final initial = widget.initial;
    if (initial == null) return;
    final locale = context.l10n.localeName;
    // A stored fallback ("Unbekannte Mahlzeit") in the user's language.
    if (!_isFallbackName(initial)) {
      _name.text = initial.resolvedMealName(context.l10n);
    }
    if (initial.hasNoPortionWeight) {
      _kcalTotal.text = '${initial.caloriesKcal}';
      _proteinTotal.text = _zahlText(_gramm(initial.protein), locale);
      _carbsTotal.text = _zahlText(_gramm(initial.carbs), locale);
      _fatTotal.text = _zahlText(_gramm(initial.fat), locale);
      return;
    }
    final dichte =
        initial.effectiveKcalPer100G ??
        (initial.explicitZeroKcal && initial.kcalPer100G == 0 ? 0 : null);
    if (dichte != null) _kcal100.text = '${dichte.round()}';
    // A scan or product favorite carries no label values per 100 g; its
    // portion's macros stand in, so changing only the name keeps them.
    String pro100(double? stored, String text) => _zahlText(
      stored ?? _proPortion(_gramm(text), initial.estimatedGrams),
      locale,
    );
    _protein.text = pro100(initial.proteinPer100G, initial.protein);
    _carbs.text = pro100(initial.carbsPer100G, initial.carbs);
    _fat.text = pro100(initial.fatPer100G, initial.fat);
  }

  /// A stored macro text ("12,5 g", "-" for unknown) as a number.
  static double? _gramm(String text) =>
      NumberInput.parse(text.replaceAll(' g', '')).value;

  /// [gramm] of a [portion] in grams as an amount per 100 g.
  static double? _proPortion(double? gramm, int portion) =>
      gramm == null || portion <= 0 ? null : gramm * 100 / portion;

  /// [wert] with at most one decimal in the separator of [locale]; '' for
  /// none.
  static String _zahlText(double? wert, String locale) {
    if (wert == null || !wert.isFinite) return '';
    final gerundet = (wert * 10).round() / 10;
    final text = gerundet == gerundet.roundToDouble()
        ? '${gerundet.round()}'
        : gerundet.toStringAsFixed(1);
    return locale == 'de' ? text.replaceAll('.', ',') : text;
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
    _kcalTotal.dispose();
    _proteinTotal.dispose();
    _carbsTotal.dispose();
    _fatTotal.dispose();
    super.dispose();
  }

  /// Error text for an integer field, or null. An EMPTY field gets no error
  /// on purpose; missing required values block via [_isValid] alone. "3,5"
  /// is refused with a hint: `MealAnalysisResult.manualEntry` takes ints.
  String? _bereichsFehler(
    TextEditingController controller, {
    required int min,
    required int max,
    required String Function(int min, int max) bereichstext,
  }) {
    final eingabe = NumberInput.parse(controller.text);
    if (eingabe is EmptyNumberInput) return null;
    final hinweis = numberInputHint(eingabe, context.l10n, wholeNumber: true);
    if (hinweis != null) return hinweis;
    final wert = eingabe.wholeValue;
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
  /// whole numbers. Bounds stay integers because the error text takes `int`.
  String? _makroFehler(TextEditingController controller) {
    final eingabe = NumberInput.parse(controller.text);
    if (eingabe is EmptyNumberInput) return null;
    final hinweis = numberInputHint(eingabe, context.l10n);
    if (hinweis != null) return hinweis;
    final wert = eingabe.value;
    if (wert == null || wert < _macroMin || wert > _macroMax) {
      return context.l10n.recipesRangeErrorGrams(_macroMin, _macroMax);
    }
    return null;
  }

  String? get _kcalTotalFehler => _bereichsFehler(
    _kcalTotal,
    min: 0,
    max: _kcalTotalMax,
    bereichstext: context.l10n.foodQuickRangeKcal,
  );

  /// [_makroFehler] for a whole-meal total (quick mode).
  String? _makroGesamtFehler(TextEditingController controller) {
    final eingabe = NumberInput.parse(controller.text);
    if (eingabe is EmptyNumberInput) return null;
    final hinweis = numberInputHint(eingabe, context.l10n);
    if (hinweis != null) return hinweis;
    final wert = eingabe.value;
    if (wert == null || wert < _macroMin || wert > _macroTotalMax) {
      return context.l10n.foodQuickRangeGrams(_macroMin, _macroTotalMax);
    }
    return null;
  }

  /// Quick mode: the total kcal are required, the name and macros are not.
  bool get _isQuickValid =>
      _kcalTotal.text.trim().isNotEmpty &&
      _kcalTotalFehler == null &&
      _makroGesamtFehler(_proteinTotal) == null &&
      _makroGesamtFehler(_carbsTotal) == null &&
      _makroGesamtFehler(_fatTotal) == null;

  bool get _isValid {
    if (_quick) return _isQuickValid;
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

  int? _zahlOderNull(TextEditingController controller) =>
      NumberInput.parse(controller.text).wholeValue;

  /// Macro value per 100 g as a decimal, comma OR dot as separator — 0.5 g of
  /// fat must be enterable (same parser as `_MacroField`).
  double? _makroOderNull(TextEditingController controller) =>
      NumberInput.parse(controller.text).value;

  /// Computed portion for the preview line — only when both required numbers
  /// are valid, otherwise null.
  int? get _vorschauKcal {
    if (_kcal100Fehler != null || _gramsFehler != null) return null;
    final kcal100 = _zahlOderNull(_kcal100);
    final gramm = _zahlOderNull(_grams);
    if (kcal100 == null || gramm == null) return null;
    return clampMealCaloriesKcal(kcal100 * gramm / 100);
  }

  bool _saving = false;

  Future<void> _save() async {
    if (!_isValid || _saving) return;
    final result = _quick ? _schnellErgebnis() : _ergebnis();
    setState(() => _saving = true);
    final saved = await tryPersistChange(context, () async {
      await widget.onSave?.call(result);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(result);
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
      barcode: widget.barcode,
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
      // Every 0 here is computed from typed label values, a measurement: a
      // small portion of a low-density food rounds to 0 kcal too. Without the
      // marker it read as the legacy "unknown" sentinel and was refused.
      explicitZeroKcal: basis.caloriesKcal == 0,
      // Kept, so a reused portion rescales from the label, not the rounding.
      proteinPer100G: _makroOderNull(_protein),
      carbsPer100G: _makroOderNull(_carbs),
      fatPer100G: _makroOderNull(_fat),
    );
  }

  /// Quick mode: the totals as typed, no grams ([MealAnalysisResult.quickEntry]).
  MealAnalysisResult _schnellErgebnis() => MealAnalysisResult.quickEntry(
    name: _name.text,
    caloriesKcal: _zahlOderNull(_kcalTotal)!,
    proteinG: _makroOderNull(_proteinTotal),
    carbsG: _makroOderNull(_carbsTotal),
    fatG: _makroOderNull(_fatTotal),
    barcode: widget.barcode,
  );

  void _setQuick(bool quick) {
    if (quick == _quick) return;
    HapticFeedback.selectionClick();
    setState(() => _quick = quick);
  }

  @override
  Widget build(BuildContext context) => CommitDismissGuard(
    pending: _saving,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final mediaQuery = MediaQuery.of(context);
    final vorschau = _vorschauKcal;
    // showEatovaSheet supplies ground, edge, keyboard inset and the safe-area
    // height cap (five input fields: the keyboard is practically always open).
    return Column(
      key: const ValueKey('manual-meal-sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Outside the scroll area, so a pull on it moves the sheet.
        const SheetHandle(padding: EdgeInsets.only(top: 10, bottom: 12)),
        Flexible(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            24 + mediaQuery.viewPadding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SheetTitle(
                      l10n.foodManualEntryTitle,
                      textKey: const ValueKey('manual-meal-title'),
                      compact: mediaQuery.textScaler.scale(24) > 36,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SheetCloseButton(
                    buttonKey: const ValueKey('manual-meal-close'),
                    tooltip: l10n.commonClose,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _quick ? l10n.foodQuickSubtitle : l10n.foodManualEntrySubtitle,
                key: const ValueKey('manual-meal-subtitle'),
                style: AppType.ui(12.5, color: t.ink2, height: 1.4),
              ),
              const SizedBox(height: 12),
              _ModeChips(
                quick: _quick,
                onChanged: _saving ? null : _setQuick,
              ),
              const SizedBox(height: 16),
              if (_slot != null) ...[
                if (widget.contextLabel != null) ...[
                  Text(
                    widget.contextLabel!,
                    style: AppType.ui(12, color: t.ink2),
                  ),
                  const SizedBox(height: 8),
                ],
                MealSlotPicker(
                  selected: _slot!,
                  keyPrefix: 'manual-slot-',
                  onSelected: (slot) {
                    setState(() => _slot = slot);
                    widget.onSlotChanged?.call(slot);
                  },
                ),
                const SizedBox(height: 16),
              ],
              _ManualGroup(
                label: l10n.recipesGroupWhatIsIt,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ManualField(
                      fieldKey: const ValueKey('manual-meal-name'),
                      controller: _name,
                      label: l10n.foodAddItemNameLabel,
                      hint: _quick
                          ? l10n.foodQuickNameHint
                          : l10n.foodManualNameHint,
                      maxChars: LoggedMealLimits.mealNameMaxChars,
                    ),
                    if (widget.barcode case final code?) ...[
                      const SizedBox(height: 10),
                      _BarcodeNote(code: code),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (_quick)
                _quickNutrition(context)
              else ...[
              _ManualGroup(
                label: l10n.foodManualGroupNutrition,
                trailing: l10n.foodManualPer100GSuffix,
                child: Column(
                  children: [
                    _ManualPair(
                      children: [
                        _ManualField(
                          fieldKey: const ValueKey('manual-meal-kcal100'),
                          controller: _kcal100,
                          label: l10n.foodAddItemCaloriesLabel,
                          unit: 'kcal',
                          numeric: true,
                          dot: t.accent,
                          errorText: _kcal100Fehler,
                        ),
                        _ManualField(
                          fieldKey: const ValueKey('manual-meal-protein'),
                          controller: _protein,
                          label: l10n.todayMacroProtein,
                          unit: 'g',
                          numeric: true,
                          decimal: true,
                          dot: t.protein,
                          errorText: _makroFehler(_protein),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ManualPair(
                      children: [
                        _ManualField(
                          fieldKey: const ValueKey('manual-meal-carbs'),
                          controller: _carbs,
                          label: l10n.todayMacroCarbs,
                          unit: 'g',
                          numeric: true,
                          decimal: true,
                          dot: t.carbs,
                          errorText: _makroFehler(_carbs),
                        ),
                        _ManualField(
                          fieldKey: const ValueKey('manual-meal-fat'),
                          controller: _fat,
                          label: l10n.todayMacroFat,
                          unit: 'g',
                          numeric: true,
                          decimal: true,
                          dot: t.fat,
                          errorText: _makroFehler(_fat),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Container(
                key: const ValueKey('manual-portion-panel'),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: t.brandSurface,
                  borderRadius: BorderRadius.circular(rCard),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.foodManualGroupPortion,
                      style: AppType.display(18, color: t.onBrandSurface),
                    ),
                    const SizedBox(height: 14),
                    _ManualField(
                      fieldKey: const ValueKey('manual-meal-grams'),
                      controller: _grams,
                      label: l10n.foodAddItemWeightLabel,
                      unit: 'g',
                      numeric: true,
                      errorText: _gramsFehler,
                      onBrand: true,
                    ),
                    if (vorschau != null) ...[
                      const SizedBox(height: 16),
                      Text.rich(
                        TextSpan(
                          text: '$vorschau',
                          style: AppType.display(40, color: t.onBrandSurface),
                          children: [
                            TextSpan(
                              text: ' kcal',
                              style: AppType.ui(16, color: t.onBrandSurface),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        key: const ValueKey('manual-meal-computed'),
                        l10n.foodManualComputedKcal(
                          vorschau,
                          _zahlOderNull(_grams)!,
                        ),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w600,
                          color: t.onBrandSurface,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 20,
                        runSpacing: 12,
                        children: [
                          for (final nutrient in [
                            (l10n.todayMacroProtein, _protein),
                            (l10n.todayMacroCarbs, _carbs),
                            (l10n.todayMacroFat, _fat),
                          ])
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nutrient.$1,
                                  style: AppType.ui(11, color: t.ink2),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _makroFehler(nutrient.$2) == null
                                      ? MealAnalysisResult.macroForGrams(
                                          _makroOderNull(nutrient.$2),
                                          _zahlOderNull(_grams)!,
                                        )
                                      : '—',
                                  style: AppType.ui(
                                    15,
                                    weight: FontWeight.w700,
                                    color: t.onBrandSurface,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              ],
              const SizedBox(height: 14),
              // onTap == null is the lock signal and the visible disabled
              // state.
              PrimaryActionButton(
                key: const ValueKey('manual-meal-save'),
                onTap: _isValid && !_saving ? _save : null,
                icon: Icons.check_rounded,
                label: l10n.commonSave,
              ),
            ],
          ),
        ),
        ),
      ],
    );
  }

  /// Quick mode's fields: total kcal (required) and the three macros as
  /// totals, without a portion panel; there is nothing to compute.
  Widget _quickNutrition(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return _ManualGroup(
      label: l10n.foodManualGroupNutrition,
      trailing: l10n.foodQuickTotalSuffix,
      child: Column(
        children: [
          _ManualPair(
            children: [
              _ManualField(
                fieldKey: const ValueKey('manual-meal-kcal-total'),
                controller: _kcalTotal,
                label: l10n.foodAddItemCaloriesLabel,
                unit: 'kcal',
                numeric: true,
                dot: t.accent,
                errorText: _kcalTotalFehler,
              ),
              _ManualField(
                fieldKey: const ValueKey('manual-meal-protein-total'),
                controller: _proteinTotal,
                label: l10n.todayMacroProtein,
                unit: 'g',
                numeric: true,
                decimal: true,
                dot: t.protein,
                errorText: _makroGesamtFehler(_proteinTotal),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ManualPair(
            children: [
              _ManualField(
                fieldKey: const ValueKey('manual-meal-carbs-total'),
                controller: _carbsTotal,
                label: l10n.todayMacroCarbs,
                unit: 'g',
                numeric: true,
                decimal: true,
                dot: t.carbs,
                errorText: _makroGesamtFehler(_carbsTotal),
              ),
              _ManualField(
                fieldKey: const ValueKey('manual-meal-fat-total'),
                controller: _fatTotal,
                label: l10n.todayMacroFat,
                unit: 'g',
                numeric: true,
                decimal: true,
                dot: t.fat,
                errorText: _makroGesamtFehler(_fatTotal),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The two modes as one choice: label values per 100 g, or a quick entry
/// with totals. Side by side, stacked once large text would squeeze them.
class _ModeChips extends StatelessWidget {
  const _ModeChips({required this.quick, required this.onChanged});

  final bool quick;

  /// Null while a save is in flight: both chips show disabled.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final change = onChanged;
    final chips = [
      FilterChipPill(
        key: const ValueKey('manual-mode-per100'),
        label: l10n.foodQuickModePer100,
        selected: !quick,
        expand: true,
        onTap: change == null ? null : () => change(false),
      ),
      FilterChipPill(
        key: const ValueKey('manual-mode-quick'),
        label: l10n.foodQuickModeTotal,
        selected: quick,
        expand: true,
        onTap: change == null ? null : () => change(true),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [chips.first, const SizedBox(height: 8), chips.last],
          );
        }
        return Row(
          children: [
            Expanded(child: chips.first),
            const SizedBox(width: 10),
            Expanded(child: chips.last),
          ],
        );
      },
    );
  }
}

/// The scanned code under the name: the entry is saved as the user's own
/// product and found first on the next scan (E5).
class _BarcodeNote extends StatelessWidget {
  const _BarcodeNote({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      key: const ValueKey('manual-meal-barcode-note'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: FoodGlyphIcon(FoodGlyph.barcode, size: 16, color: t.ink2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.l10n.foodOwnProductBarcodeNote(code),
            style: AppType.ui(12.5, color: t.ink2, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _ManualPair extends StatelessWidget {
  const _ManualPair({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 280 ||
          MediaQuery.textScalerOf(context).scale(14) > 21) {
        return Column(
          children: [children.first, const SizedBox(height: 14), children.last],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: children.first),
          const SizedBox(width: 14),
          Expanded(child: children.last),
        ],
      );
    },
  );
}

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
        if (MediaQuery.textScalerOf(context).scale(17) > 25.5)
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(label, style: AppType.display(17, color: t.ink)),
              if (trailing != null)
                Text(trailing!, style: AppType.ui(11, color: t.ink2)),
            ],
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(label, style: AppType.display(17, color: t.ink)),
              ),
              if (trailing != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    // Flush with the field edge, not at the row's half mark.
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      heightFactor: 1,
                      child: Text(
                        trailing!,
                        textAlign: TextAlign.end,
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w500,
                          color: t.ink2,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

/// Labelled input field: readable header with unit and macro dot on a
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
    this.onBrand = false,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? unit;
  final bool numeric;

  /// Only meaningful with [numeric]: offers the decimal keyboard. Set only on
  /// fields whose value may be fractional; kcal/100 g and portion grams stay
  /// integers.
  final bool decimal;
  final int? maxChars;
  final String? errorText;
  final Color? dot;

  /// Sits on the brandSurface portion panel: [FieldCapsule.onBrand].
  final bool onBrand;

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
    // No character filter: `digitsOnly` swallowed the separator SILENTLY
    // ("3,5" became 35 — a factor of 10 in the rings, the database and the
    // 90-day average). The validators refuse such text visibly instead.
    final kopfzeile = unit == null ? label : '$label · $unit';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
              child: Text(kopfzeile, style: AppType.ui(12, color: t.ink2)),
            ),
          ],
        ),
        const SizedBox(height: 5),
        FieldCapsule(
          focusNode: _focus,
          error: hasError,
          onBrand: widget.onBrand,
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
                    textCapitalization: widget.numeric
                        ? TextCapitalization.none
                        : TextCapitalization.sentences,
                    style: AppType.ui(
                      widget.numeric ? 20 : 16,
                      weight: FontWeight.w600,
                      color: t.ink,
                    ),
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
