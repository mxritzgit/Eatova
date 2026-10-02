import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../models/number_input.dart';
import '../../theme/app_tokens.dart';
import '../common/decimal_text.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/sheets.dart';
import 'food_glyphs.dart';
import 'saved_meal_presentation.dart';
import 'product_search_presentation.dart';

/// Shared item widget for search hits, favorites and recent meals in the
/// AddMealSheet.
///
/// Collapsed is a diary row (tile, name, amount, kcal); a tap opens a raised
/// panel with the portion stepper, the live result and ONE round accent "+".
/// After adding, the item collapses and its tile turns into an accent check.
class MealSuggestionItem extends StatefulWidget {
  const MealSuggestionItem({
    super.key,
    required this.result,
    required this.expanded,
    required this.onTap,
    required this.onAdd,
    this.imageUrl,
    this.justAdded = false,
    this.onRemove,
    this.addButtonKey,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.favoriteButtonKey,
    this.savedPresentation = false,
    this.productPresentation = false,
  });

  final MealAnalysisResult result;
  final bool expanded;
  final VoidCallback onTap;
  final ValueChanged<MealAnalysisResult> onAdd;
  final String? imageUrl;

  final bool justAdded;
  final VoidCallback? onRemove;
  final Key? addButtonKey;

  /// Whether this item is currently favorited (filled heart).
  final bool isFavorite;

  /// Optional favorite toggle; null means no heart. Pinned favorites and
  /// product hits show it in the row, recents in the open panel.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  /// Saved meals show the reusable portion instead of a product density.
  final bool savedPresentation;
  final bool productPresentation;

  @override
  State<MealSuggestionItem> createState() => _MealSuggestionItemState();
}

class _MealSuggestionItemState extends State<MealSuggestionItem> {
  static const int _step = 10;

  /// Upper end of the **slider** — a display bound, not a value limit.
  ///
  /// Mapping 1..10000 g onto a slider makes it unusable (one pixel is ~30 g),
  /// so this only limits how far the thumb reaches. Larger portions stay
  /// reachable via field and stepper, and the window grows with the value
  /// (see [_sliderMaxGrams]) instead of silently clamping back.
  static const int _sliderWindowGrams = 1000;

  /// The last **valid** value. An implausible typed input leaves it alone
  /// (see [_onGramsTextChanged]).
  late int _grams;
  late TextEditingController _gramsController;

  /// The field holds something that is not a plausible portion: add is locked
  /// and a hint is visible — rejected, not silently bent.
  bool _gramsInvalid = false;

  @override
  void initState() {
    super.initState();
    _grams = _fromForeignSource(widget.result.estimatedGrams);
    _gramsController = TextEditingController(text: _grams.toString());
  }

  @override
  void didUpdateWidget(covariant MealSuggestionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Identity, not just grams: the lists key rows by INDEX, so after an
    // unpin/filter this State receives the next row's result. Comparing
    // grams alone carried a user-edited 110 g onto a neighbour that also
    // ships 100 g (review B, 2026-08-27). Callers hand out stable result
    // instances across rebuilds, so identity does not reset spuriously.
    if (!identical(oldWidget.result, widget.result) ||
        oldWidget.result.estimatedGrams != widget.result.estimatedGrams) {
      _grams = _fromForeignSource(widget.result.estimatedGrams);
      _gramsInvalid = false;
      _syncControllerText();
    }
  }

  @override
  void dispose() {
    _gramsController.dispose();
    super.dispose();
  }

  /// The start portion comes from a foreign source (model answer, OFF,
  /// favorites cache) that cannot be asked back, so clamping is right here
  /// (`model_limits.dart`), with the same function `adjustedToGrams` uses.
  static int _fromForeignSource(int grams) => clampPortionGrams(grams);

  /// Right end of the slider; grows when the portion exceeds the display
  /// window, otherwise the thumb would show 1000 for 1200 g.
  int get _sliderMaxGrams =>
      _grams > _sliderWindowGrams ? _grams : _sliderWindowGrams;

  void _syncControllerText() {
    final next = _grams.toString();
    if (_gramsController.text != next) {
      _gramsController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  /// Stepper and slider have ends: dragging against them asserts no number,
  /// so clamping is not a silent falsification here — unlike typed input.
  void _setGrams(int value) {
    final geklemmt = clampPortionGrams(value);
    if (geklemmt == _grams && !_gramsInvalid) return;
    setState(() {
      _grams = geklemmt;
      _gramsInvalid = false;
    });
    _syncControllerText();
  }

  void _bumpGrams(int delta) => _setGrams(_grams + delta);

  /// Typed portions are **rejected, not clamped**.
  ///
  /// Neither a range ("12000" would silently log 10000) nor a decimal ("3,5"
  /// is not 35 g) is bent into shape. The last valid value stays, the button
  /// locks, and the user sees why.
  void _onGramsTextChanged(String value) {
    final parsed = NumberInput.parse(value).wholeValue;
    final gueltig = parsed != null && isPlausiblePortionGrams(parsed);
    setState(() {
      _gramsInvalid = !gueltig;
      if (gueltig) _grams = parsed;
    });
  }

  /// The meal at the currently set portion — **one** instance for preview and
  /// save path.
  ///
  /// Delegates to [MealAnalysisResult.adjustedToGrams] instead of copying the
  /// formula (B1: a density-first preview showed 78 kcal while 420 was
  /// logged); it also brings the clamps and macro scaling along.
  ///
  /// An unchanged portion keeps the original: the invariant
  /// `adjustedToGrams(estimatedGrams).caloriesKcal == caloriesKcal` makes that
  /// the same number, without `isAdjusted` or rewritten `portionNotes`.
  MealAnalysisResult get _adjusted => widget.result.isRecipeWithoutCookedWeight ||
      _grams == widget.result.estimatedGrams
      ? widget.result
      : widget.result.adjustedToGrams(_grams);

  @override
  Widget build(BuildContext context) {
    // ONE instance per build: the preview shows it and the button passes on
    // exactly this object. Two getter calls would make "same number" a
    // promise instead of a fact; every portion change runs through setState.
    final angepasst = _adjusted;
    final t = context.t;
    final l10n = context.l10n;
    final toggleFavorite = widget.onToggleFavorite == null
        ? null
        : () => widget.onToggleFavorite!(widget.result);

    final Widget header;
    if (widget.savedPresentation) {
      header = SavedMealHeader(
        result: widget.result,
        expanded: widget.expanded,
        justAdded: widget.justAdded,
        onTap: widget.onTap,
        isFavorite: widget.isFavorite,
        onToggleFavorite: toggleFavorite,
        favoriteButtonKey: widget.favoriteButtonKey,
      );
    } else if (widget.productPresentation) {
      header = ProductSearchHeader(
        result: widget.result,
        imageUrl: widget.imageUrl,
        expanded: widget.expanded,
        justAdded: widget.justAdded,
        onTap: widget.onTap,
        isFavorite: widget.isFavorite,
        onToggleFavorite: toggleFavorite,
        favoriteButtonKey: widget.favoriteButtonKey,
      );
    } else {
      header = _RecentHeader(
        result: widget.result,
        imageUrl: widget.imageUrl,
        expanded: widget.expanded,
        justAdded: widget.justAdded,
        onTap: widget.onTap,
        onRemove: widget.onRemove,
      );
    }

    // Secondary actions live in the open panel, so the row keeps ONE icon:
    // a recent keeps its X in the row and pins from here; a pinned favorite
    // unpins with its heart and is removed from here.
    final panelActions = <Widget>[
      if (!widget.savedPresentation &&
          !widget.productPresentation &&
          toggleFavorite != null)
        _PanelAction(
          key: widget.favoriteButtonKey,
          icon: widget.isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_outline_rounded,
          label: widget.isFavorite
              ? l10n.foodRemoveFavoriteTooltip
              : l10n.foodAddFavoriteTooltip,
          highlighted: widget.isFavorite,
          onTap: toggleFavorite,
        ),
      if (widget.savedPresentation && widget.onRemove != null)
        _PanelAction(
          icon: Icons.delete_outline_rounded,
          label: l10n.foodRemoveTooltip,
          onTap: widget.onRemove!,
        ),
    ];

    // The open row lifts onto a raised inset panel; closed rows are plain
    // diary rows on the card. The transparent Material keeps ink ripples
    // above the panel fill.
    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 180)),
      curve: kMotionCurve,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.expanded
            ? t.surfRaised
            : t.surfRaised.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(rTile),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            maybeAnimatedSize(
              context,
              duration: const Duration(milliseconds: 180),
              curve: kMotionCurve,
              alignment: Alignment.topCenter,
              child: widget.expanded
                  ? _PortionPanel(
                      productPresentation: widget.productPresentation,
                      grams: _grams,
                      gramsController: _gramsController,
                      preview: angepasst,
                      gramsInvalid: _gramsInvalid,
                      minGrams: PlausibilityLimits.portionGramsMin,
                      maxGrams: _sliderMaxGrams,
                      step: _step,
                      addButtonKey: widget.addButtonKey,
                      onBump: _bumpGrams,
                      onTextChanged: _onGramsTextChanged,
                      onSliderChanged: (v) => _setGrams(v.round()),
                      onAdd: _gramsInvalid
                          ? null
                          : () => widget.onAdd(angepasst),
                      actions: panelActions,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// A recent: name, diary amount, kcal, and the X that drops it from recents.
class _RecentHeader extends StatelessWidget {
  const _RecentHeader({
    required this.result,
    required this.imageUrl,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.onRemove,
  });

  final MealAnalysisResult result;
  final String? imageUrl;
  final bool expanded;
  final bool justAdded;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final (title, brand) = mealTitleAndBrand(result, l10n);
    final amount = mealAmountLabel(result, l10n);
    return MealItemRow(
      leading: MealItemTile(
        name: title,
        imageUrl: imageUrl,
        justAdded: justAdded,
      ),
      title: title,
      secondary: Text(brand == null ? amount : '$brand · $amount'),
      value: mealKcalOrUnknown(context, result),
      onTap: onTap,
      expanded: expanded,
      actions: [
        if (onRemove != null)
          IconButton(
            onPressed: onRemove,
            tooltip: l10n.foodRemoveTooltip,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(Icons.close_rounded, color: t.ink3, size: 18),
          ),
      ],
    );
  }
}

/// The open state: portion stepper, slider, the live result and the one add
/// button.
class _PortionPanel extends StatelessWidget {
  const _PortionPanel({
    required this.productPresentation,
    required this.grams,
    required this.gramsController,
    required this.preview,
    required this.gramsInvalid,
    required this.minGrams,
    required this.maxGrams,
    required this.step,
    required this.addButtonKey,
    required this.onBump,
    required this.onTextChanged,
    required this.onSliderChanged,
    required this.onAdd,
    required this.actions,
  });

  final int grams;
  final TextEditingController gramsController;
  final bool productPresentation;

  /// Exactly the instance [onAdd] passes on; the preview's kcal and macros
  /// come from it, not from a second calculation.
  final MealAnalysisResult preview;

  final bool gramsInvalid;
  final int minGrams;
  final int maxGrams;
  final int step;
  final Key? addButtonKey;
  final ValueChanged<int> onBump;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<double> onSliderChanged;

  /// `null` locks the button — the typed portion is implausible.
  final VoidCallback? onAdd;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview.isRecipeWithoutCookedWeight)
            Text(
              l10n.recipeCalcNoCookedWeight,
              style: AppType.ui(13, color: t.ink2, height: 1.4),
            )
          else ...[
            _PortionStepper(
              controller: gramsController,
              invalid: gramsInvalid,
              onChanged: onTextChanged,
              onBump: onBump,
              step: step,
            ),
            if (gramsInvalid) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  numberInputHint(
                        NumberInput.parse(gramsController.text),
                        l10n,
                        wholeNumber: true,
                      ) ??
                      l10n.foodPortionRangeHint(
                        PlausibilityLimits.portionGramsMin,
                        PlausibilityLimits.portionGramsMax,
                      ),
                  key: const ValueKey('kcal-suggestion-grams-hint'),
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w600,
                    color: t.warning,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: t.accent,
                inactiveTrackColor: t.tile,
                thumbColor: t.accent,
                overlayColor: t.accentTint,
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              ),
              child: Slider(
                min: minGrams.toDouble(),
                max: maxGrams.toDouble(),
                value: grams.clamp(minGrams, maxGrams).toDouble(),
                onChanged: onSliderChanged,
              ),
            ),
          ],
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _LivePreview(
                    result: preview,
                    kcalKey: ValueKey(
                      productPresentation
                          ? 'product-portion-calories'
                          : 'live-preview-kcal',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _AddButton(buttonKey: addButtonKey, onAdd: onAdd),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

/// The one primary action: a round accent "+" with a soft glow and press
/// dip. A FilledButton underneath, so the app's button theme, semantics and
/// disabled state apply; only shape and size are local.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.buttonKey, required this.onAdd});

  final Key? buttonKey;
  final VoidCallback? onAdd;

  static const double _size = 52;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onAdd != null;
    return PressScale(
      enabled: enabled,
      child: AnimatedContainer(
        duration: motionDuration(context, kMotionPressOut),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: enabled
                  ? t.accentGlow
                  : t.accentGlow.withValues(alpha: 0),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: FilledButton(
          key: buttonKey,
          onPressed: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onAdd!();
                }
              : null,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            fixedSize: const Size.square(_size),
            minimumSize: const Size.square(_size),
            padding: EdgeInsets.zero,
          ),
          child: Semantics(
            label: context.l10n.commonAdd,
            child: const FoodGlyphIcon(FoodGlyph.plus, size: 24),
          ),
        ),
      ),
    );
  }
}

/// Quiet secondary action in the open panel (pin a recent, remove a
/// favorite): a small soft pill, never competing with the accent "+".
class _PanelAction extends StatelessWidget {
  const _PanelAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      child: Material(
        color: t.tile,
        borderRadius: BorderRadius.circular(rPill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: highlighted ? t.accent : t.ink2,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w600,
                        color: t.inkSoft,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One soft capsule: minus, the typed grams, plus. The whole capsule is the
/// field's focus surface (rest `field`, focus `fieldFocus`, invalid
/// `fieldError`); no hairline, no ring.
class _PortionStepper extends StatefulWidget {
  const _PortionStepper({
    required this.controller,
    required this.invalid,
    required this.onChanged,
    required this.onBump,
    required this.step,
  });

  final TextEditingController controller;
  final bool invalid;
  final ValueChanged<String> onChanged;
  final ValueChanged<int> onBump;
  final int step;

  @override
  State<_PortionStepper> createState() => _PortionStepperState();
}

class _PortionStepperState extends State<_PortionStepper> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return FieldCapsule(
      focusNode: _focus,
      error: widget.invalid,
      shape: SheetFieldShape.pill,
      // Sits on the raised panel already.
      shadow: false,
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          _StepperButton(
            icon: Icons.remove_rounded,
            semanticLabel: l10n.foodDecreaseAmountSemantics,
            onTap: () => widget.onBump(-widget.step),
            onLongPress: () => widget.onBump(-widget.step * 5),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Two equal halves: the number ends just left of the centre,
                // the unit starts right of it, and both shrink on narrow
                // phones at large text instead of overflowing.
                Expanded(
                  child: TextField(
                    cursorOpacityAnimates: false,
                    cursorColor: t.accent,
                    controller: widget.controller,
                    focusNode: _focus,
                    onChanged: widget.onChanged,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: false,
                      decimal: false,
                    ),
                    inputFormatters: const [
                      // Five digits because the upper bound
                      // (PlausibilityLimits.portionGramsMax = 10000 g) has
                      // five; four made the top of the valid range
                      // unenterable. Digits, not characters: "1.000" must
                      // reach the validator whole.
                      DigitBudgetFormatter(5),
                    ],
                    textAlign: TextAlign.right,
                    style: AppType.display(20, color: t.ink),
                    decoration: const InputDecoration(
                      // Null out the theme borders explicitly: the global
                      // inputDecorationTheme carries a hairline and focus
                      // ring.
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'g',
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w600,
                      color: t.ink2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _StepperButton(
            icon: Icons.add_rounded,
            semanticLabel: l10n.foodIncreaseAmountSemantics,
            onTap: () => widget.onBump(widget.step),
            onLongPress: () => widget.onBump(widget.step * 5),
          ),
        ],
      ),
    );
  }
}

/// A 48 pt round button inside the capsule: the capsule carries the surface,
/// the icon the accent. Long press steps five times.
class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;

  /// A11y: the +/- icon alone tells a screen reader nothing.
  final String semanticLabel;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: PressScale(
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox.square(
              dimension: 48,
              child: Icon(icon, size: 22, color: t.accentText),
            ),
          ),
        ),
      ),
    );
  }
}

/// The result of the set portion: the kcal as the hero number, the macro
/// legend below.
class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.result, required this.kcalKey});

  final MealAnalysisResult result;
  final Key kcalKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${result.caloriesKcal}',
                style: AppType.display(26, color: t.ink, height: 1.1),
              ),
              TextSpan(
                text: ' kcal',
                style: AppType.ui(14, weight: FontWeight.w600, color: t.ink3),
              ),
            ],
          ),
          key: kcalKey,
        ),
        const SizedBox(height: 4),
        SavedMealNutrients(
          result: result,
          legendKey: const ValueKey('live-preview-macros'),
        ),
      ],
    );
  }
}
