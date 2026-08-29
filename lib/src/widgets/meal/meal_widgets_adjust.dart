part of 'meal_widgets.dart';

/// Opens the component adjustment sheet.
///
/// **D5, no `showDragHandle`:** the route's handle sits outside every guard, so
/// dragging it bypassed the confirmation. [_SheetGrabber] draws it inside.
///
/// The return type is the component list, not `Object?` (P8-03b): the sheet
/// only ever pops that list or nothing, and `mealPortionAdjustment` used to
/// carry a runtime type check for a branch that cannot happen. `null` means
/// "apply nothing" — cancel, barrier, discard.
Future<List<MealComponent>?> showWeightAdjustmentSheet(
  BuildContext context,
  MealAnalysisResult result,
) {
  return showModalBottomSheet<List<MealComponent>>(
    context: context,
    backgroundColor: context.t.bg,
    isScrollControlled: true,
    builder: (context) => _MealItemAdjustmentSheet(result: result),
  );
}

// ---------------------------------------------------------------------------
// D5: discard confirmation, drag guard and the sheet's own grabber
// ---------------------------------------------------------------------------

/// "Discard changes?" — shared confirmation for EVERY way of closing a filled
/// form; `true` = discard. `barrierDismissible` stays `true`: the dialog's own
/// barrier swallows the tap, so a cancel cannot dismiss the route it protects.
Future<bool> _confirmDiscardChanges(BuildContext context, String text) async {
  final t = context.t;
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.foodDiscardChangesTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(text, style: AppType.ui(13, color: t.ink2, height: 1.4)),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// The sheet's grab handle, drawn inside [_DiscardDragGuard] rather than on the
/// route (see [showWeightAdjustmentSheet]). Its tap calls [onDismiss] →
/// `maybePop` — without it a screen-reader user could not leave the sheet.
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: onDismiss,
      child: SizedBox(
        width: double.infinity,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.t.ink2,
                borderRadius: const BorderRadius.all(Radius.circular(rPill)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// D5: intercepts the drag-down dismiss of a modal bottom sheet. A `PopScope`
/// only sees the barrier tap; a drag goes `onClosing` → **`Navigator.pop`** and
/// never asks. The lever is the gesture arena — a drag recogniser in the child
/// beats `_BottomSheetGestureDetector`. [active] false keeps it closable.
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
  /// Minimum downward distance counted as "close". Small: the guard swallows
  /// the gesture regardless.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` in bottom_sheet.dart.
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
      // Without translucent, gaps between the children stay uncovered.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// The sheet
// ---------------------------------------------------------------------------

/// Portion bounds for one component, in grams; mirrors
/// `PlausibilityLimits.portionGramsMin/Max` from `model_limits.dart`, the same
/// window `MealComponent.adjustedToGrams` clamps to. Mirrored rather than
/// imported because this is a `part` file and the library's imports are fixed
/// — like [_makroMaxG] does for `LoggedMealLimits.macroGMax`.
///
/// **Typed values are rejected, not clamped** (P8-02): bending 12000 g to
/// 10000 g and saving it silently falsifies the input.
const int _postenMinG = 1;
const int _postenMaxG = 10000;

/// Upper bound for one component's calories, in kcal; mirrors
/// `LoggedMealLimits.caloriesKcalMax`, the window `MealComponent.adjustedToGrams`
/// clamps to. Mirrored for the same reason as [_postenMaxG].
const int _postenMaxKcal = 10000;

/// Is [grams] a portion the sheet may work with? The single range gate behind
/// the field listener, the start value and the add dialog — one bound, not
/// three copies (P8-02b).
bool _plausiblesPostenGewicht(int grams) =>
    grams >= _postenMinG && grams <= _postenMaxG;

/// One component in the sheet: model, input field, start weight and current
/// weight. Only created in [_MealItemAdjustmentSheetState._neuerPosten].
class _Posten {
  _Posten({required this.item, required this.controller})
    : startGramm = item.grams,
      gramm = item.grams,
      // P8-02b: the listener never fires for the INITIAL text, so an
      // implausible start weight (a scan item at 0 g — `clampMealEstimatedG`
      // starts at 0) reached "Übernehmen" unflagged and was saved clamped to
      // 1 g. The start value has to pass the same gate as every typed one.
      ungueltig = !_plausiblesPostenGewicht(item.grams),
      startUngueltig = !_plausiblesPostenGewicht(item.grams);

  final MealComponent item;
  final TextEditingController controller;

  /// Weight at open time — the [_dirty] reference, not "was ever typed".
  final int startGramm;

  /// Was the start weight already implausible? [gewichtVeraendert] compares
  /// against this, so an untouched 0 g item does not open the discard dialog.
  final bool startUngueltig;

  /// The last **valid** weight, always within [_postenMinG].._postenMaxG.
  ///
  /// An implausible input leaves it untouched and raises [ungueltig], so row,
  /// total card and save path keep citing ONE number. Before P8-02 this held
  /// the raw typed value while everything downstream clamped it.
  int gramm;

  /// The field holds something that is not a plausible portion — empty, 0 or
  /// past the bound. Apply stays locked and a hint says why.
  bool ungueltig;

  /// [ungueltig] counts as changed too: the field no longer shows the start
  /// value, so a drag-away must still ask before discarding it. Compared
  /// against [startUngueltig], not against `false` — otherwise a sheet that
  /// OPENED invalid would ask on every close (P8-02b).
  bool get gewichtVeraendert =>
      gramm != startGramm || ungueltig != startUngueltig;

  /// This component recalculated to the last valid weight — **one**
  /// calculation for preview, total row and save path (B1: preferring
  /// `kcalPer100G` over `caloriesKcal` showed 654 kcal but saved 156).
  MealComponent get angepasst => item.adjustedToGrams(gramm);
}

class _MealItemAdjustmentSheet extends StatefulWidget {
  const _MealItemAdjustmentSheet({required this.result});

  final MealAnalysisResult result;

  @override
  State<_MealItemAdjustmentSheet> createState() => _MealItemAdjustmentSheetState();
}

class _MealItemAdjustmentSheetState extends State<_MealItemAdjustmentSheet> {
  /// Registry of ALL components — the only list here.
  final List<_Posten> _posten = <_Posten>[];

  /// Component count at open time. Reference for [_dirty] and [_statusLine];
  /// a length delta would count a barcode hit's synthesized fallback.
  late final int _startAnzahl;

  Set<int> _removed = const <int>{};

  @override
  void initState() {
    super.initState();
    // Fall back to one synthesized item when there is no itemized breakdown.
    final quelle = widget.result.items.isNotEmpty
        ? widget.result.items
        : <MealComponent>[
            MealComponent(
              name: widget.result.mealName,
              grams: widget.result.estimatedGrams,
              caloriesKcal: widget.result.caloriesKcal,
              kcalPer100G: widget.result.kcalPer100G,
            ),
          ];
    for (final item in quelle) {
      _neuerPosten(item);
    }
    _startAnzahl = _posten.length;
  }

  /// The ONLY place a component is created: a factory, because the field count
  /// is variable. Hands out the [_dirty] start value, the listener tracking
  /// weight AND `PopScope.canPop`, and the `dispose()` via [_posten].
  void _neuerPosten(MealComponent item) {
    final controller = TextEditingController(text: item.grams.toString());
    final posten = _Posten(item: item, controller: controller);
    controller.addListener(() {
      final getippt = int.tryParse(controller.text.trim());
      final ungueltig = getippt == null || !_plausiblesPostenGewicht(getippt);
      // An implausible input keeps the last valid weight (P8-02).
      final neuesGramm = ungueltig ? posten.gramm : getippt;
      // The listener also fires on pure cursor movement — nothing to do then.
      if (neuesGramm == posten.gramm && ungueltig == posten.ungueltig) return;
      posten.gramm = neuesGramm;
      posten.ungueltig = ungueltig;
      if (mounted) setState(() {});
    });
    _posten.add(posten);
  }

  @override
  void dispose() {
    for (final posten in _posten) {
      // The listener hangs on this very controller and dies with it.
      posten.controller.dispose();
    }
    super.dispose();
  }

  void _remove(int index) {
    setState(() => _removed = {..._removed, index});
  }

  void _undoRemove(int index) {
    setState(() => _removed = {..._removed}..remove(index));
  }

  void _appendItem(MealComponent item) {
    setState(() => _neuerPosten(item));
  }

  /// The remaining components, in their original order.
  List<int> get _uebrigeIndizes => [
    for (var index = 0; index < _posten.length; index++)
      if (!_removed.contains(index)) index,
  ];

  /// D5: does what "apply" would deliver NOW differ from the state at open?
  /// Compares the RESULT — remaining components and weights — not the fields,
  /// since [_removed] and manual additions are state too.
  bool get _dirty {
    final uebrig = _uebrigeIndizes;
    if (uebrig.length != _startAnzahl) return true;
    for (var n = 0; n < uebrig.length; n++) {
      // Position n no longer holds original component n — one was removed and
      // a manually added one moved up.
      if (uebrig[n] != n) return true;
      if (_posten[n].gewichtVeraendert) return true;
    }
    return false;
  }

  /// Do ALL remaining components carry complete macros?
  /// [MealAnalysisResult.adjustedToItems] decides on exactly this whether the
  /// meal's macros are summed or unknown. Empty is `true`, like `every`.
  bool get _restTraegtMakros {
    for (final index in _uebrigeIndizes) {
      if (!_posten[index].item.hasMacros) return false;
    }
    return true;
  }

  Future<void> _addItemDialog() async {
    final newItem = await showDialog<MealComponent>(
      context: context,
      builder: (context) =>
          _AddItemDialog(restTraegtMakros: _restTraegtMakros),
    );
    if (newItem != null) {
      _appendItem(newItem);
    }
  }

  String _statusLine(int addedCount, AppLocalizations l10n) {
    final parts = <String>[];
    if (_removed.isNotEmpty) {
      parts.add(l10n.foodItemsRemovedCount(_removed.length));
    }
    if (addedCount > 0) parts.add(l10n.foodItemsAddedCount(addedCount));
    if (parts.isEmpty) {
      return l10n.foodAdjustItemsHint;
    }
    return parts.join(' · ');
  }

  /// D5: runs for every intercepted dismiss attempt (barrier tap, system back,
  /// grabber semantics, drag). Repeated attempts do not stack dialogs.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(
      context,
      context.l10n.foodDiscardItemsBody,
    );
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Dialog already popped. Deliberately WITHOUT a result: discarding yields
    // `null` like a cancel, which callers treat as "apply nothing".
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final uebrig = _uebrigeIndizes;
    // ONE instance per component per build: the row prints it and the total
    // card sums the very same objects, so "row and total agree" is a fact, not
    // a promise (P8-02: the row printed the raw typed grams next to clamped
    // calories while the card summed the clamped ones).
    final angepasstJeIndex = <int, MealComponent>{
      for (final index in uebrig) index: _posten[index].angepasst,
    };
    final adjustedItems = angepasstJeIndex.values.toList(growable: false);
    final totalGrams = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.grams,
    );
    final totalKcal = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.caloriesKcal,
    );
    final invalidGrams = [
      for (final index in uebrig)
        if (_posten[index].ungueltig) index,
    ];
    final canSave = adjustedItems.isNotEmpty && invalidGrams.isEmpty;
    final addedCount = _posten.length - _startAnzahl;

    return PopScope<List<MealComponent>?>(
      // Only while something is at stake. `Navigator.pop` — apply — bypasses
      // `canPop`.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // OUTSIDE the scroll area: a drag on a scrollable belongs to it.
              _SheetGrabber(
                onDismiss: () => Navigator.of(context).maybePop(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.foodAdjustItemsTitle,
                        style: AppType.display(20, color: t.ink),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusLine(addedCount, l10n),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w500,
                          color: t.ink2,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      for (var index = 0; index < _posten.length; index++) ...[
                        if (_removed.contains(index))
                          _RemovedItemCard(
                            name: _posten[index].item.name,
                            onUndo: () => _undoRemove(index),
                          )
                        else
                          _ItemEditCard(
                            index: index,
                            item: _posten[index].item,
                            controller: _posten[index].controller,
                            angepasst: angepasstJeIndex[index]!,
                            gramsInvalid: _posten[index].ungueltig,
                            onRemove: () => _remove(index),
                          ),
                        const SizedBox(height: 10),
                      ],
                      OutlinedButton.icon(
                        key: const ValueKey('analyse-item-add-button'),
                        onPressed: _addItemDialog,
                        icon: const Icon(Icons.add_rounded, size: 17),
                        label: Text(
                          l10n.foodAddItemTitle,
                          style: AppType.ui(13.5, weight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.ink,
                          side: BorderSide(color: t.line),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(rControl),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      AppCard(
                        key: const ValueKey('analyse-adjusted-kcal-preview'),
                        radius: rCard,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calculate_outlined,
                              color: t.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n.foodAdjustedTotalApprox(
                                    totalGrams, totalKcal),
                                style: AppType.display(18, color: t.ink),
                              ),
                            ),
                            if (adjustedItems.isNotEmpty)
                              Text(
                                l10n.foodItemsCountLabel(adjustedItems.length),
                                style: AppType.display(
                                  11,
                                  weight: FontWeight.w500,
                                  color: t.ink2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (adjustedItems.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.foodAtLeastOneItemRequired,
                          style: AppType.ui(
                            11,
                            weight: FontWeight.w600,
                            color: t.warning,
                          ),
                        ),
                      ],
                      // The offending row may have scrolled out of view, so the
                      // locked button states its own reason (P8-02).
                      if (invalidGrams.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.foodItemWeightInvalidHint(
                            _postenMinG,
                            _postenMaxG,
                          ),
                          key: const ValueKey('analyse-invalid-weight-hint'),
                          style: AppType.ui(
                            11,
                            weight: FontWeight.w600,
                            color: t.warning,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const ValueKey('analyse-save-weight-button'),
                          onPressed: canSave
                              ? () => Navigator.pop(context, adjustedItems)
                              : null,
                          icon: const Icon(Icons.check_rounded, size: 17),
                          label: Text(
                            l10n.foodApplyButton,
                            style: AppType.ui(14, weight: FontWeight.w600),
                          ),
                          // Colours/shape from filledButtonTheme (F8-10).
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
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

class _ItemEditCard extends StatelessWidget {
  const _ItemEditCard({
    required this.index,
    required this.item,
    required this.controller,
    required this.angepasst,
    required this.gramsInvalid,
    required this.onRemove,
  });

  final int index;
  final MealComponent item;
  final TextEditingController controller;

  /// Exactly the instance the total card sums — the row's grams and calories
  /// come from it, not from a second calculation (P8-02).
  final MealComponent angepasst;

  /// The field holds an implausible portion: the row keeps showing
  /// [angepasst], and a hint explains why "Übernehmen" is locked.
  final bool gramsInvalid;

  final VoidCallback onRemove;

  /// Stepper changes use the SAME channel as typing, via the controller
  /// listener — one source, no second state.
  ///
  /// Clamping is right HERE, unlike for typed input: stepping against an end
  /// asserts no number (same reasoning as `MealSuggestionItem._setGrams`). An
  /// empty field falls back to the last valid weight, not to the original one.
  void _bump(int delta) {
    final aktuell = int.tryParse(controller.text.trim()) ?? angepasst.grams;
    final neu = (aktuell + delta).clamp(_postenMinG, _postenMaxG);
    // P8-09: the `text` setter collapses the selection to offset -1
    // (editable_text.dart), and the stepper does not pull focus off the field,
    // so the next typed digits landed at the START of the number. Set the
    // caret explicitly, like `MealSuggestionItem._syncControllerText`.
    final text = '$neu';
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Soft capsule instead of hairline border + form label (design rule).
    return AppCard(
      key: ValueKey('analyse-item-card-$index'),
      radius: rCard,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
                ),
              ),
              IconButton(
                key: ValueKey('analyse-item-remove-$index'),
                onPressed: onRemove,
                tooltip: l10n.foodRemoveTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: t.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                _ItemStepperButton(
                  icon: Icons.remove_rounded,
                  semanticLabel: l10n.foodDecreaseItemSemantics(item.name),
                  onTap: () => _bump(-10),
                  onLongPress: () => _bump(-50),
                ),
                const SizedBox(width: 10),
                Expanded(
                  // Observer only (cannot take focus, skipped in traversal):
                  // `Focus.of` rebuilds the pill when the field's focus
                  // changes. Fill language: field / fieldFocus, no ring.
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    includeSemantics: false,
                    child: Builder(
                      builder: (context) => FieldCapsule(
                        focused: Focus.of(context).hasFocus,
                        shape: SheetFieldShape.pill,
                        // Sits on the item card, which is already raised.
                        shadow: false,
                        constraints: const BoxConstraints(minHeight: 46),
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 64,
                              // No `onChanged`: the `_neuerPosten` listener
                              // reads the controller and sees programmatic
                              // text too.
                              child: TextField(
                                key: ValueKey(
                                  'analyse-item-weight-input-$index',
                                ),
                                cursorOpacityAnimates: false,
                                controller: controller,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  // Five digits because the upper bound
                                  // (_postenMaxG = 10000 g) has five; the
                                  // range check below rejects the rest.
                                  LengthLimitingTextInputFormatter(5),
                                ],
                                textAlign: TextAlign.center,
                                style: AppType.display(18, color: t.ink),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isCollapsed: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'g',
                              style: AppType.ui(
                                13,
                                weight: FontWeight.w600,
                                color: t.ink2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _ItemStepperButton(
                  icon: Icons.add_rounded,
                  semanticLabel: l10n.foodIncreaseItemSemantics(item.name),
                  onTap: () => _bump(10),
                  onLongPress: () => _bump(50),
                ),
              ],
            ),
          ),
          if (gramsInvalid) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                l10n.foodPortionRangeHint(_postenMinG, _postenMaxG),
                key: ValueKey('analyse-item-weight-hint-$index'),
                style: AppType.ui(
                  11,
                  weight: FontWeight.w600,
                  color: t.warning,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              l10n.foodOriginallyLabel(item.gramsLabel, item.caloriesLabel),
              style: AppType.display(
                11,
                weight: FontWeight.w500,
                color: t.ink2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                Icon(
                  Icons.local_fire_department_outlined,
                  size: 14,
                  color: t.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  '${angepasst.grams} g · ${angepasst.caloriesKcal} kcal',
                  style: AppType.display(
                    12,
                    weight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                if (item.kcalPer100G != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ${item.kcalPer100G!.round()} kcal/100g',
                    style: AppType.display(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Round -/+ soft capsule of the component row, tinted [AppTokens.accent].
class _ItemStepperButton extends StatelessWidget {
  const _ItemStepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: t.surf2,
            borderRadius: BorderRadius.circular(rPill),
          ),
          child: Icon(icon, size: 20, color: t.accent),
        ),
      ),
    );
  }
}

class _RemovedItemCard extends StatelessWidget {
  const _RemovedItemCard({required this.name, required this.onUndo});

  final String name;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: rCard,
      color: t.surf2,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: AppType.ui(
                13,
                weight: FontWeight.w600,
                color: t.ink2,
              ).copyWith(decoration: TextDecoration.lineThrough),
            ),
          ),
          TextButton.icon(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              foregroundColor: t.ink,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: Text(
              context.l10n.foodUndoRemoveButton,
              style: AppType.ui(11, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Upper bound for one component's macro, in grams; mirrors
/// `LoggedMealLimits.macroGMax`. Typed values are **rejected, not clamped**.
const double _makroMaxG = 1000;

/// One macro input: optional, grams, comma OR dot as decimal separator.
/// Deliberately not `digitsOnly` — 0.5 g of fat must be typeable.
class _MacroField extends StatelessWidget {
  const _MacroField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    // No `onChanged`: button enablement and `PopScope.canPop` hang on the
    // `_AddItemDialogState._feld` listener.
    return TextField(
      key: fieldKey,
      cursorOpacityAnimates: false,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      decoration: InputDecoration(labelText: label, suffixText: 'g'),
    );
  }
}

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog({required this.restTraegtMakros});

  /// Do the remaining components carry complete macros? Only then can the meal
  /// keep its own.
  final bool restTraegtMakros;

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  /// Registry of ALL input fields. [_feld] is the only source of a controller
  /// and hands out the listener plus the `dispose()`, so none can be missed.
  final List<TextEditingController> _felder = <TextEditingController>[];

  late final TextEditingController _name;
  late final TextEditingController _grams;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  /// Macro fields start collapsed, so the common case stays three fields long.
  bool _makrosOffen = false;

  @override
  void initState() {
    super.initState();
    _name = _feld();
    _grams = _feld();
    _kcal = _feld();
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
  }

  TextEditingController _feld() {
    final controller = TextEditingController();
    controller.addListener(_onFeldChanged);
    _felder.add(controller);
    return controller;
  }

  void _onFeldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _felder) {
      controller
        ..removeListener(_onFeldChanged)
        ..dispose();
    }
    super.dispose();
  }

  /// D5: any field carries text. All six start empty, so "not empty" equals
  /// "changed". Merely expanding the macro section deliberately does not count.
  bool get _dirty => _felder.any((controller) => controller.text.isNotEmpty);

  /// Reads a macro field: empty -> `null` ("unknown"), else the number. `null`
  /// and `0` differ — "don't know" vs "none" ([MealComponent.hasMacros]).
  static double? _makro(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  /// `true` if the field is empty OR carries a number within range.
  static bool _makroFeldOk(TextEditingController controller) {
    if (controller.text.trim().isEmpty) return true;
    final wert = _makro(controller);
    return wert != null && wert.isFinite && wert >= 0 && wert <= _makroMaxG;
  }

  bool get _alleMakrosGesetzt =>
      _makro(_protein) != null &&
      _makro(_carbs) != null &&
      _makro(_fat) != null;

  bool get _makrosGueltig =>
      _makroFeldOk(_protein) && _makroFeldOk(_carbs) && _makroFeldOk(_fat);

  /// What the input means for the WHOLE meal's macros, shown up front (B8).
  String get _makroHinweis {
    final l10n = context.l10n;
    if (!_alleMakrosGesetzt) {
      return l10n.foodMacroHintIncomplete;
    }
    if (!widget.restTraegtMakros) {
      return l10n.foodMacroHintOthersIncomplete;
    }
    return l10n.foodMacroHintComplete;
  }

  /// `true` if the field is empty OR carries a whole number within range —
  /// the integer twin of [_makroFeldOk], so an untouched field does not shout.
  static bool _zahlFeldOk(TextEditingController controller, int min, int max) {
    final text = controller.text.trim();
    if (text.isEmpty) return true;
    final wert = int.tryParse(text);
    return wert != null && wert >= min && wert <= max;
  }

  /// P8-02b: `> 0` alone let 99999 g through, and everything downstream
  /// (`adjustedToGrams`) clamped it to 10000 g — the exact silent bend the
  /// component row rejects. Same story one field over: 99999 kcal came back as
  /// 10000. Both are rejected here now, with the reason on screen.
  bool get _grammGueltig => _zahlFeldOk(_grams, _postenMinG, _postenMaxG);

  bool get _kcalGueltig => _zahlFeldOk(_kcal, 0, _postenMaxKcal);

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    final g = int.tryParse(_grams.text.trim());
    final k = int.tryParse(_kcal.text.trim());
    return g != null &&
        _plausiblesPostenGewicht(g) &&
        k != null &&
        k >= 0 &&
        k <= _postenMaxKcal &&
        _makrosGueltig;
  }

  void _submit() {
    if (!_isValid) return;
    final name = _name.text.trim();
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    final per100 = grams > 0 ? kcal * 100 / grams : null;
    Navigator.pop(
      context,
      MealComponent(
        name: name,
        grams: grams,
        caloriesKcal: kcal,
        kcalPer100G: per100,
        proteinG: _makro(_protein),
        carbsG: _makro(_carbs),
        fatG: _makro(_fat),
      ),
    );
  }

  /// D5: runs for every intercepted dismiss attempt of this dialog. No drag
  /// guard needed: a dialog cannot be dragged away.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(
      context,
      context.l10n.foodDiscardNewItemBody,
    );
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Exactly ONE level closes: this dialog; the sheet keeps its weights.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return PopScope<MealComponent?>(
      // Only while something is filled in; an empty dialog closes immediately.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: AlertDialog(
        backgroundColor: t.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rSheet),
        ),
        title: Text(
          l10n.foodAddItemTitle,
          style: AppType.display(18, color: t.ink),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.foodAddItemManualHint,
                style: AppType.ui(
                  12,
                  weight: FontWeight.w500,
                  color: t.ink2,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('analyse-add-item-name'),
                cursorOpacityAnimates: false,
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.foodAddItemNameLabel,
                  hintText: l10n.foodAddItemNameHint,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('analyse-add-item-grams'),
                      cursorOpacityAnimates: false,
                      controller: _grams,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        // Same five digits as the component row's field: the
                        // bound (10000) has five, the range check below
                        // rejects the rest (P8-02b).
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.foodAddItemWeightLabel,
                        suffixText: 'g',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('analyse-add-item-kcal'),
                      cursorOpacityAnimates: false,
                      controller: _kcal,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.foodAddItemCaloriesLabel,
                        suffixText: 'kcal',
                      ),
                    ),
                  ),
                ],
              ),
              // The locked button states its own reason, like the row does.
              if (!_grammGueltig) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.foodPortionRangeHint(_postenMinG, _postenMaxG),
                  key: const ValueKey('analyse-add-item-grams-hint'),
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w600,
                    color: t.warning,
                  ),
                ),
              ],
              if (!_kcalGueltig) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.foodAddItemCaloriesRangeHint(0, _postenMaxKcal),
                  key: const ValueKey('analyse-add-item-kcal-hint'),
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w600,
                    color: t.warning,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              // Expandable instead of three more required fields.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('analyse-add-item-macros-toggle'),
                  onPressed: () =>
                      setState(() => _makrosOffen = !_makrosOffen),
                  style: TextButton.styleFrom(
                    foregroundColor: t.ink,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    _makrosOffen
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                  ),
                  label: Text(
                    l10n.foodAddItemMacrosToggle,
                    style: AppType.ui(12, weight: FontWeight.w600),
                  ),
                ),
              ),
              if (_makrosOffen) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-protein'),
                        controller: _protein,
                        label: l10n.todayMacroProtein,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-carbs'),
                        controller: _carbs,
                        label: l10n.foodMacroTileCarbsLabel,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-fat'),
                        controller: _fat,
                        label: l10n.todayMacroFat,
                      ),
                    ),
                  ],
                ),
                if (!_makrosGueltig) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.foodMacroRangeHint,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w600,
                      color: t.warning,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              Text(
                _makroHinweis,
                key: const ValueKey('analyse-add-item-macro-hint'),
                style: AppType.ui(
                  11,
                  weight: FontWeight.w500,
                  color: t.ink2,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            // maybePop, not pop: an explicit cancel also asks first.
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(l10n.commonCancel),
          ),
          // Colours/shape from filledButtonTheme (F8-10).
          FilledButton(
            key: const ValueKey('analyse-add-item-save'),
            onPressed: _isValid ? _submit : null,
            child: Text(
              l10n.commonAdd,
              style: AppType.ui(14, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
