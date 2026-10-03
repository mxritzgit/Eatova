import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/logged_meal.dart';
import '../../models/model_limits.dart';
import '../../models/number_input.dart';
import '../../theme/app_tokens.dart';
import '../common/decimal_text.dart';
import '../common/persistence_action.dart';
import '../design/design.dart';
import 'meal_slot_picker.dart';

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
  MealSlot? initialSlot,
  ValueChanged<MealSlot>? onSlotChanged,
  String? contextLabel,
  PersistValueChanged<MealAnalysisResult>? onSave,
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
  });

  /// Prefill from the product search (nothing found -> search term).
  final String? initialName;
  final MealSlot? initialSlot;
  final ValueChanged<MealSlot>? onSlotChanged;
  final String? contextLabel;
  final PersistValueChanged<MealAnalysisResult>? onSave;

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
    final result = _ergebnis();
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
            24,
            0,
            24,
            24 + mediaQuery.viewPadding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.foodManualEntryTitle,
                      key: const ValueKey('manual-meal-title'),
                      style: AppType.display(
                        mediaQuery.textScaler.scale(24) > 36 ? 20 : 24,
                        color: t.ink,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('manual-meal-close'),
                    tooltip: l10n.commonClose,
                    onPressed: () => Navigator.of(context).pop(),
                    style: IconButton.styleFrom(backgroundColor: t.surf2),
                    icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l10n.foodManualEntrySubtitle,
                style: AppType.ui(12.5, color: t.ink2, height: 1.4),
              ),
              const SizedBox(height: 12),
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
                child: _ManualField(
                  fieldKey: const ValueKey('manual-meal-name'),
                  controller: _name,
                  label: l10n.foodAddItemNameLabel,
                  hint: l10n.foodManualNameHint,
                  maxChars: LoggedMealLimits.mealNameMaxChars,
                ),
              ),
              const SizedBox(height: 24),
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
