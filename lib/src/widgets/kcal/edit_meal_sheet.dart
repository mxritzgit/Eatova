import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../common/lively.dart' show PressScale;
import '../common/persistence_action.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../models/number_input.dart';
import '../../services/day_math.dart';
import '../../services/local_day.dart';
import '../../theme/app_tokens.dart';
import '../../screens/today/today_day_strip.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';
import 'food_date_picker.dart';
import 'manual_meal_sheet.dart';
import 'meal_analysis_sheet.dart';
import 'meal_copy_sheet.dart';
import 'saved_meal_presentation.dart' show SavedMealNutrients;
import 'slot_selector.dart';

/// Store callback for the edit sheet: changes portion/components, slot and/or
/// day of a logged meal (null = unchanged) and returns the new state, or null
/// if the id no longer exists.
typedef UpdateMealDetails =
    FutureOr<LoggedMeal?> Function(
      String id, {
      MealAnalysisResult? result,
      MealSlot? slot,
      DateTime? day,
    });

/// Store callback for "Bearbeiten" in the favorites: saves [result] into
/// the favorite [id] without logging it and returns the key it is stored
/// under afterwards (a rename moves it).
typedef UpdateFavorite =
    FutureOr<String> Function(String id, MealAnalysisResult result);

/// Provides the HomeStore edit callbacks below the food tab.
///
/// The diary slot cards and the AddMealSheet live under
/// `MealAnalysisScreen`, whose signature stays untouched, so the scope routes
/// the callbacks past the screen straight to the widgets that open the edit
/// sheet. Without the scope (previews, standalone tests) those widgets fall
/// back to their previous behaviour.
class MealEditScope extends InheritedWidget {
  const MealEditScope({
    super.key,
    required this.onUpdateMeal,
    required this.onRemoveMeal,
    this.onCopyMeals,
    this.onUpdateFavorite,
    required super.child,
  });

  final UpdateMealDetails onUpdateMeal;
  final PersistValueChanged<String> onRemoveMeal;

  /// "Copy to…" in the edit sheet; null hides the action.
  final CopyMeals? onCopyMeals;

  /// "Bearbeiten" in the favorites sheet; null hides the action.
  final UpdateFavorite? onUpdateFavorite;

  /// Deliberately without dependency registration (getInherited…): the
  /// callbacks are stable store tear-offs and the lookup also happens outside
  /// build (sheet openers).
  static MealEditScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MealEditScope>();

  @override
  bool updateShouldNotify(MealEditScope oldWidget) =>
      onUpdateMeal != oldWidget.onUpdateMeal ||
      onRemoveMeal != oldWidget.onRemoveMeal ||
      onCopyMeals != oldWidget.onCopyMeals ||
      onUpdateFavorite != oldWidget.onUpdateFavorite;
}

/// Edit-sheet result for callers holding a local list copy (AddMealSheet):
/// the saved new state or a deletion. A null future result means closed
/// without changes.
class MealEditOutcome {
  const MealEditOutcome.saved(LoggedMeal this.meal) : deleted = false;
  const MealEditOutcome.deleted() : meal = null, deleted = true;

  final LoggedMeal? meal;
  final bool deleted;
}

/// Opens the edit sheet for a logged meal. A null [onRemoveMeal] means no
/// delete button, e.g. when the caller has no remove path wired up; a null
/// [onCopyMeals] means no "Copy to…".
Future<MealEditOutcome?> showEditMealSheet(
  BuildContext context, {
  required LoggedMeal meal,
  required UpdateMealDetails onUpdateMeal,
  PersistValueChanged<String>? onRemoveMeal,
  CopyMeals? onCopyMeals,
}) {
  return showModalBottomSheet<MealEditOutcome>(
    showDragHandle: false,
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
    builder: (sheetContext) {
      return EditMealSheet(
        meal: meal,
        onUpdateMeal: onUpdateMeal,
        onRemoveMeal: onRemoveMeal,
        onCopyMeals: onCopyMeals,
      );
    },
  );
}

/// Intercepts the drag-down dismissal of a modal bottom sheet.
///
/// `PopScope` only covers half of it: a barrier tap goes through
/// `Navigator.maybePop` and asks the pop disposition, but a drag goes
/// `BottomSheet._handleDragEnd` -> `onClosing` -> `Navigator.pop` and never
/// does. The only lever from inside the sheet is the gesture arena: a vertical
/// drag recognizer in the builder child sits below
/// `_BottomSheetGestureDetector` and wins, the same way a ScrollView swallows
/// the drag. Scrollable areas sit deeper still and stay unaffected.
///
/// With [active] false no recognizer is registered at all, so a clean sheet
/// drags away as usual.
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Minimum downward distance counted as close intent. Small on purpose: the
  /// guard swallows the gesture either way, this only decides whether the user
  /// gets an answer.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` from bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Without translucent, gaps between children stay uncovered.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

class EditMealSheet extends StatefulWidget {
  const EditMealSheet({
    super.key,
    required this.meal,
    required this.onUpdateMeal,
    this.onRemoveMeal,
    this.onCopyMeals,
  });

  final LoggedMeal meal;
  final UpdateMealDetails onUpdateMeal;
  final PersistValueChanged<String>? onRemoveMeal;
  final CopyMeals? onCopyMeals;

  @override
  State<EditMealSheet> createState() => _EditMealSheetState();
}

class _EditMealSheetState extends State<EditMealSheet> {
  late MealAnalysisResult _result;

  /// What the servings stepper scales from: the logged entry, or the last
  /// change made otherwise (values, name, portion), so stepping back and
  /// forth never drifts by rounding.
  late MealAnalysisResult _servingsBase;
  late MealSlot _slot;
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    _result = widget.meal.result;
    _servingsBase = _result;
    _slot = widget.meal.slot;
    // effectiveLocalDay ('YYYY-MM-DD') parses as local midnight, the same day
    // anchor the bucketing uses.
    _day = DateUtils.dateOnly(DateTime.parse(widget.meal.effectiveLocalDay));
  }

  /// Stepping back to the logged servings restores the logged instance, so
  /// the sheet is clean again.
  bool get _resultChanged => !identical(_result, widget.meal.result);

  bool get _slotChanged => _slot != widget.meal.slot;

  bool get _dayChanged => localDayKey(_day) != widget.meal.effectiveLocalDay;

  bool get _dirty => _resultChanged || _slotChanged || _dayChanged;

  /// Adjusts portion/components through the existing
  /// showWeightAdjustmentSheet editor. Same pattern as
  /// MealAnalysisSheet._adjustPortion — [mealPortionAdjustment] included, so a
  /// meal without components does not grow a fake one-item breakdown — but
  /// without an immediate save: the change only lands on "save".
  Future<void> _adjustPortion() async {
    final adjustment = await showWeightAdjustmentSheet(context, _result);
    if (!mounted) return;

    final applied = mealPortionAdjustment(_result, adjustment);
    if (applied == null) return;
    setState(() => _result = _servingsBase = applied.result);
  }

  /// A manual entry (a quick entry, an own product, label values per
  /// 100 g) changes its values and name in the manual form, prefilled; like
  /// a portion change they only land on "save".
  Future<void> _editValues() async {
    final edited = await showManualMealSheet(
      context,
      initial: _result,
      barcode: _result.barcode,
    );
    if (!mounted || edited == null) return;
    setState(() => _result = _servingsBase = edited);
  }

  /// A scan or a described meal takes the user's own name.
  Future<void> _rename() async {
    final shown = _result.resolvedMealName(context.l10n);
    final name = (await showMealRenameSheet(context, initial: shown))?.trim();
    if (!mounted || name == null || name.isEmpty || name == shown) return;
    setState(() {
      final renamed = _result.withMealName(name);
      _servingsBase = identical(_servingsBase, _result)
          ? renamed
          : _servingsBase.withMealName(name);
      _result = renamed;
    });
  }

  static const double _servingsStep = 0.5;
  static const double _servingsMax = 20;

  /// The next half serving above (+1) or below (-1) the current one, or
  /// null at the ends: half a serving, [_servingsMax], or a total one entry
  /// cannot hold.
  double? _servingsNeighbour(int direction) {
    final steps = _result.effectiveServings / _servingsStep;
    final next = direction > 0
        ? (steps.floor() + 1) * _servingsStep
        : (steps.ceil() - 1) * _servingsStep;
    if (next < _servingsStep || next > _servingsMax) return null;
    final base = _servingsBase;
    final factor = next / base.effectiveServings;
    final fits =
        base.caloriesKcal * factor <= LoggedMealLimits.caloriesKcalMax &&
        [base.protein, base.carbs, base.fat].every(
          (macro) => (_grams(macro) ?? 0) * factor <= LoggedMealLimits.macroGMax,
        );
    return fits ? next : null;
  }

  /// The grams in a stored macro text ("12,5 g"), or null for unknown ("-").
  static double? _grams(String macro) =>
      NumberInput.parse(macro.replaceAll(' g', '')).value;

  void _stepServings(int direction) {
    final next = _servingsNeighbour(direction);
    if (next == null) return;
    final base = _servingsBase;
    setState(() {
      _result = next == base.effectiveServings
          ? base
          : base.withServings(next);
    });
  }

  bool get _isManualEntry =>
      MealResultSource.resolve(_result.sourceLabel) == MealResultSource.manual;

  bool get _isAiNamed => switch (MealResultSource.resolve(
    _result.sourceLabel,
  )) {
    MealResultSource.photoAi || MealResultSource.aiEstimate => true,
    _ => false,
  };

  /// The app's calendar sheet for days beyond the strip. Same bounds as the
  /// food-tab calendar: two years back, nothing in the future. Feeds the same
  /// _day state as the strip; saving still runs only through
  /// updateLoggedMealDetails.
  Future<void> _pickOtherDay() async {
    final today = DateUtils.dateOnly(clock.now());
    final firstDate = DateTime(today.year - 2, today.month, today.day);
    var initial = _day;
    if (initial.isBefore(firstDate)) initial = firstDate;
    if (initial.isAfter(today)) initial = today;
    final picked = await showFoodDatePicker(
      context,
      initialDate: initial,
      firstDate: firstDate,
      today: today,
      confirmLabel: context.l10n.foodDatePickerHelpText,
    );
    if (!mounted || picked == null) return;
    setState(() => _day = DateUtils.dateOnly(picked));
  }

  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    LoggedMeal? updated;
    final saved = await tryPersistChange(context, () async {
      updated = await widget.onUpdateMeal(
        widget.meal.id,
        result: _resultChanged ? _result : null,
        slot: _slotChanged ? _slot : null,
        day: _dayChanged ? _day : null,
      );
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) return;
    Navigator.of(
      context,
    ).pop(updated == null ? null : MealEditOutcome.saved(updated!));
  }

  /// "Copy to…": copies the SAVED meal, so it is only offered on a clean
  /// sheet. The original stays; after the copy the sheet closes unchanged.
  Future<void> _copy() async {
    final copyMeals = widget.onCopyMeals;
    if (copyMeals == null || _saving || _dirty) return;
    final copied = await showMealCopySheet(
      context,
      meal: widget.meal,
      onCopy: (day, slot) async {
        await copyMeals([widget.meal.id], day: day, slot: slot);
      },
    );
    if (!mounted || copied != true) return;
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = await tryPersistChange(context, () async {
      await widget.onRemoveMeal?.call(widget.meal.id);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) return;
    Navigator.of(context).pop(const MealEditOutcome.deleted());
  }

  /// Runs for every intercepted dismiss attempt: barrier tap, system back and
  /// the close button arrive via [PopScope], dragging via
  /// [_DiscardDragGuard]. Repeat attempts do not stack dialogs.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_saving) return;
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await confirmDiscardChanges(
      context,
      body: context.l10n.foodDiscardChangesBody,
    );
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // The dialog is already popped, so the sheet is the top route again.
    // Deliberately without a result: discarded is not saved.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => CommitDismissGuard(
    pending: _saving,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // Safe-area aware instead of a fixed 92 %: the sheet must never reach
    // under the status bar or Dynamic Island.
    final maxHeight = sheetMaxHeightOf(context);

    return PopScope<MealEditOutcome?>(
      // Only while something is actually unsaved; a clean sheet closes at once.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: _buildSheet(mediaQuery, maxHeight),
      ),
    );
  }

  Widget _buildSheet(MediaQueryData mediaQuery, double maxHeight) {
    final t = context.t;
    final l10n = context.l10n;
    // No SheetScaffold: fixed header over a capped scroll area with two footer
    // actions. Own shell (the discard guard needs PopScope and the drag
    // guard), drawn like showEatovaSheet: bg ground with a 1 px lineStrong
    // edge that lifts it off the scrim.
    final today = startOfDay(clock.now());
    return Container(
      key: const ValueKey('edit-meal-sheet'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: ShapeDecoration(
        color: t.bg,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
          side: BorderSide(color: t.lineStrong),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHandle(onDismiss: () => Navigator.of(context).maybePop()),
          _Header(
            slot: _slot,
            mealName: _result.resolvedMealName(context.l10n),
            onClose: () => Navigator.of(context).maybePop(),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('edit-meal-sheet-scroll'),
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + mediaQuery.viewPadding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SummaryCard(result: _result, adjusted: _resultChanged),
                  const SizedBox(height: 10),
                  // Without a weight (a quick entry, a recipe logged by
                  // servings) the amount is servings, in half steps.
                  if (_result.hasNoPortionWeight) ...[
                    _ServingsStepper(
                      label: _result.servingsLabel(l10n),
                      onLess: _saving || _servingsNeighbour(-1) == null
                          ? null
                          : () => _stepServings(-1),
                      onMore: _saving || _servingsNeighbour(1) == null
                          ? null
                          : () => _stepServings(1),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.foodServingsNoWeightHint,
                      key: const ValueKey('edit-meal-servings-hint'),
                      style: AppType.ui(13.5, color: t.ink2, height: 1.4),
                    ),
                  ] else
                    SoftPillButton(
                      key: const ValueKey('edit-meal-adjust-button'),
                      onTap: _adjustPortion,
                      icon: Icons.tune_rounded,
                      label: l10n.foodAdjustPortionButton,
                      expand: true,
                    ),
                  if (_isManualEntry) ...[
                    const SizedBox(height: 10),
                    SoftPillButton(
                      key: const ValueKey('edit-meal-quick-values'),
                      onTap: _saving ? null : _editValues,
                      icon: Icons.edit_outlined,
                      label: l10n.foodQuickEditValues,
                      expand: true,
                    ),
                  ],
                  if (_isAiNamed) ...[
                    const SizedBox(height: 10),
                    SoftPillButton(
                      key: const ValueKey('edit-meal-rename'),
                      onTap: _saving ? null : _rename,
                      icon: Icons.drive_file_rename_outline_rounded,
                      label: l10n.foodRenameAction,
                      expand: true,
                    ),
                  ],
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionMeal),
                  const SizedBox(height: 8),
                  SlotSelector(
                    key: const ValueKey('edit-meal-slot-select'),
                    selected: _slot,
                    keyPrefix: 'edit-slot-select-',
                    onSelected: (slot) => setState(() => _slot = slot),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionDay),
                  const SizedBox(height: 8),
                  TodayDayStrip(
                    key: const ValueKey('edit-meal-day-picker'),
                    selectedDate: _day,
                    today: today,
                    // The calendar's bound: two years back.
                    firstDate: DateTime(today.year - 2, today.month, today.day),
                    onSelected: (day) =>
                        setState(() => _day = startOfDay(day)),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SoftPillButton(
                      key: const ValueKey('edit-day-calendar'),
                      onTap: _pickOtherDay,
                      icon: Icons.calendar_month_rounded,
                      label:
                          '${l10n.foodOtherDateLine1} ${l10n.foodOtherDateLine2}',
                      semanticLabel: l10n.foodOtherDateCalendarSemantics,
                      tone: SoftPillTone.neutral,
                    ),
                  ),
                  const SizedBox(height: 22),
                  PrimaryActionButton(
                    key: const ValueKey('edit-meal-save-button'),
                    onTap: _dirty && !_saving ? _save : null,
                    icon: Icons.check_rounded,
                    label: l10n.commonSave,
                  ),
                  if (widget.onCopyMeals != null) ...[
                    const SizedBox(height: 10),
                    SoftPillButton(
                      key: const ValueKey('edit-meal-copy-button'),
                      onTap: _dirty || _saving ? null : _copy,
                      icon: Icons.content_copy_rounded,
                      label: l10n.foodCopyAction,
                      semanticLabel: _dirty
                          ? '${l10n.foodCopyAction} ${l10n.foodCopySaveFirst}'
                          : null,
                      tone: SoftPillTone.neutral,
                      expand: true,
                    ),
                    if (_dirty) ...[
                      const SizedBox(height: 6),
                      ExcludeSemantics(
                        child: Text(
                          l10n.foodCopySaveFirst,
                          key: const ValueKey('edit-meal-copy-save-first'),
                          textAlign: TextAlign.center,
                          style: AppType.ui(12.5, color: t.ink2, height: 1.4),
                        ),
                      ),
                    ],
                  ],
                  if (widget.onRemoveMeal != null) ...[
                    const SizedBox(height: 10),
                    SoftPillButton(
                      key: const ValueKey('edit-meal-delete-button'),
                      onTap: _saving ? null : _delete,
                      icon: Icons.delete_outline_rounded,
                      label: l10n.foodDeleteMealButton,
                      tone: SoftPillTone.danger,
                      expand: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.slot,
    required this.mealName,
    required this.onClose,
  });

  final MealSlot slot;
  final String mealName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SheetHeader(
      leading: SlotIconTile(slot: slot, size: 40),
      title: l10n.foodEditMealTitle,
      subtitle: mealName,
      subtitleMaxLines: 1,
      onClose: onClose,
      closeKey: const ValueKey('edit-meal-sheet-close'),
      closeTooltip: l10n.commonClose,
    );
  }
}

/// Compact live summary of the (possibly already adjusted) values.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result, required this.adjusted});

  final MealAnalysisResult result;
  final bool adjusted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final row = Row(
        children: [
          Icon(Icons.local_fire_department_outlined, color: t.accent, size: 18),
          const SizedBox(width: 10),
          // The source sits at the right edge while both fit one line and
          // moves under the figure otherwise, so large text does not squeeze
          // "158 kcal · 250 g" into a word per line.
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [
                // No-break spaces keep each number with its unit: a wrapped
                // figure breaks after the "·" only.
                Text(
                  result.hasNoPortionWeight
                      ? '${result.caloriesKcal}\u00a0kcal · ${result.servingsLabel(context.l10n)}'
                      : '${result.caloriesKcal}\u00a0kcal · ${result.estimatedGrams}\u00a0g',
                  key: const ValueKey('edit-meal-summary-figure'),
                  style: AppType.display(16, color: t.ink),
                ),
                Text(
                  adjusted
                      ? context.l10n.foodAdjustedLabel
                      : result.resolvedSourceLabel(context.l10n),
                  key: const ValueKey('edit-meal-summary-source'),
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w600,
                    color: adjusted ? t.ink : t.ink2,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    return AppCard(
      key: const ValueKey('edit-meal-summary'),
      radius: rCard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row,
          // Empty (no "P 0 g") when no macro is known.
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 8),
            child: SavedMealNutrients(result: result),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: AppType.eyebrow(context.t.ink2, size: 11),
    );
  }
}

/// Servings of an entry without a weight: round minus and plus around the
/// count in a pill, half a serving per step (the meal plan's stepper).
class _ServingsStepper extends StatelessWidget {
  const _ServingsStepper({
    required this.label,
    required this.onLess,
    required this.onMore,
  });

  final String label;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.foodServingsSection,
      child: FieldCapsule(
        key: const ValueKey('edit-meal-servings'),
        focused: false,
        shape: SheetFieldShape.pill,
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            _StepButton(
              actionKey: const ValueKey('edit-meal-servings-less'),
              icon: Icons.remove_rounded,
              semanticLabel: l10n.onboardingStepDownSemanticLabel,
              onTap: onLess,
            ),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  label,
                  key: const ValueKey('edit-meal-servings-value'),
                  textAlign: TextAlign.center,
                  style: AppType.ui(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
            _StepButton(
              actionKey: const ValueKey('edit-meal-servings-more'),
              icon: Icons.add_rounded,
              semanticLabel: l10n.onboardingStepUpSemanticLabel,
              onTap: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

/// Round 44 px stepper button in the accent tint.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.actionKey,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final Key actionKey;
  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: PressScale(
        enabled: enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Material(
            color: t.accentTint,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: actionKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: 44,
                child: Icon(icon, size: 22, color: t.accentText),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a new name for a logged entry, prefilled with [initial]; null
/// when closed without saving.
Future<String?> showMealRenameSheet(
  BuildContext context, {
  required String initial,
}) => showEatovaSheet<String>(context, _RenameSheet(initial: initial));

class _RenameSheet extends StatefulWidget {
  const _RenameSheet({required this.initial});

  final String initial;

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  )..addListener(() => setState(() {}));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty;

  void _save() {
    if (!_valid) return;
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SingleChildScrollView(
      key: const ValueKey('meal-rename-sheet'),
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            title: l10n.foodRenameAction,
            onClose: () => Navigator.of(context).pop(),
            closeKey: const ValueKey('meal-rename-close'),
            closeTooltip: l10n.commonClose,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          FieldCapsule(
            focusNode: _focus,
            child: Semantics(
              label: l10n.foodAddItemNameLabel,
              child: TextField(
                key: const ValueKey('meal-rename-field'),
                controller: _name,
                focusNode: _focus,
                autofocus: true,
                cursorOpacityAnimates: false,
                cursorColor: t.accent,
                maxLength: LoggedMealLimits.mealNameMaxChars,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                style: AppType.ui(16, weight: FontWeight.w600, color: t.ink),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  hintText: l10n.foodAddItemNameLabel,
                  hintStyle: AppType.ui(14, color: t.ink2),
                  counterText: '',
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('meal-rename-save'),
            onTap: _valid ? _save : null,
            icon: Icons.check_rounded,
            label: l10n.commonSave,
          ),
        ],
      ),
    );
  }
}
