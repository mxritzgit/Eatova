import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Shared item widget for search hits, favorites and recent meals in the
/// AddMealSheet.
///
/// Collapsed is a slim row; a tap expands into a stepper body with gram
/// adjustment and a single add button. After adding, the item collapses and
/// shows a green check as trailing.
class MealSuggestionItem extends StatefulWidget {
  const MealSuggestionItem({
    super.key,
    required this.result,
    required this.expanded,
    required this.onTap,
    required this.onAdd,
    this.imageUrl,
    this.fallbackIcon = Icons.fastfood_outlined,
    this.accent,
    this.justAdded = false,
    this.onRemove,
    this.addButtonKey,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final bool expanded;
  final VoidCallback onTap;
  final ValueChanged<MealAnalysisResult> onAdd;
  final String? imageUrl;
  final IconData fallbackIcon;

  /// Card accent. Null uses [AppTokens.accent]; a const default is impossible
  /// because the color depends on the display mode.
  final Color? accent;

  final bool justAdded;
  final VoidCallback? onRemove;
  final Key? addButtonKey;

  /// Whether this item is currently favorited (filled heart).
  final bool isFavorite;

  /// Optional favorite toggle in the header; null means no heart button.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

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
    if (oldWidget.result.estimatedGrams != widget.result.estimatedGrams) {
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
  /// `FilteringTextInputFormatter.digitsOnly` guards the type, not the range,
  /// so typing 12000 would silently log 1000. The last valid value stays, the
  /// button locks, and the user sees why.
  void _onGramsTextChanged(String value) {
    final parsed = int.tryParse(value.trim());
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
  MealAnalysisResult get _adjusted => _grams == widget.result.estimatedGrams
      ? widget.result
      : widget.result.adjustedToGrams(_grams);

  @override
  Widget build(BuildContext context) {
    // ONE instance per build: the preview shows it and the button passes on
    // exactly this object. Two getter calls would make "same number" a
    // promise instead of a fact; every portion change runs through setState.
    final angepasst = _adjusted;
    final t = context.t;
    final accent = widget.accent ?? t.accent;

    // Quiet card: 1 px border instead of a shadow. Expanded, it stands out
    // via the lighter surface, not via elevation.
    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 180)),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: widget.expanded ? t.surf : t.surf2,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: widget.expanded ? accent : t.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            result: widget.result,
            imageUrl: widget.imageUrl,
            fallbackIcon: widget.fallbackIcon,
            accent: accent,
            expanded: widget.expanded,
            justAdded: widget.justAdded,
            onTap: widget.onTap,
            onRemove: widget.onRemove,
            isFavorite: widget.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
            favoriteButtonKey: widget.favoriteButtonKey,
          ),
          AnimatedSize(
            duration: motionDuration(context, const Duration(milliseconds: 180)),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: widget.expanded
                ? _ExpandedBody(
                    accent: accent,
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
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.result,
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.onRemove,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;
  final bool expanded;
  final bool justAdded;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool isFavorite;
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  Widget build(BuildContext context) {
    // The subtitle must cite the same authority as the expanded preview, or
    // one card contradicts itself. `adjustedToGrams(100).caloriesKcal` is the
    // density that follows from caloriesKcal and estimatedGrams — the same
    // maths that gets logged, not the raw `kcalPer100G` side field.
    final t = context.t;
    final per100 = result.adjustedToGrams(100).caloriesKcal;
    final subtitle = per100 > 0
        ? '$per100 kcal / 100 g'
        : '${result.caloriesKcal} kcal · ${result.estimatedGrams} g';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
        child: Row(
          children: [
            _Avatar(
              imageUrl: imageUrl,
              fallbackIcon: fallbackIcon,
              accent: accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.mealName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      13.5,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.display(
                      11.5,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (onToggleFavorite != null)
              IconButton(
                key: favoriteButtonKey,
                onPressed: () => onToggleFavorite!(result),
                tooltip: isFavorite
                    ? context.l10n.foodRemoveFavoriteTooltip
                    : context.l10n.foodAddFavoriteTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  // The brand accent is the reserved action color —
                  // deliberately NOT the categorical item accent.
                  color: isFavorite ? t.accent : t.ink2,
                  size: 18,
                ),
              ),
            _Trailing(
              expanded: expanded,
              justAdded: justAdded,
              accent: accent,
              onRemove: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
  });

  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // OpenFoodFacts sends full-resolution product images; cap the decode at
    // the 42 px avatar size to save memory per search hit.
    final cachePx = (42 * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      width: 42,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: imageUrl == null
          ? Icon(fallbackIcon, color: accent, size: 19)
          : Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              cacheWidth: cachePx,
              cacheHeight: cachePx,
              errorBuilder: (_, __, ___) =>
                  Icon(fallbackIcon, color: accent, size: 19),
            ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.expanded,
    required this.justAdded,
    required this.accent,
    required this.onRemove,
  });

  final bool expanded;
  final bool justAdded;
  final Color accent;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    if (justAdded) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle_rounded, color: accent, size: 22),
      );
    }
    final t = context.t;
    final chevron = AnimatedRotation(
      duration: motionDuration(context, const Duration(milliseconds: 180)),
      turns: expanded ? 0.5 : 0,
      child: Icon(
        Icons.keyboard_arrow_down_rounded,
        color: t.ink2,
        size: 22,
      ),
    );
    if (onRemove == null) {
      return Padding(padding: const EdgeInsets.only(right: 8), child: chevron);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onRemove,
          tooltip: context.l10n.foodRemoveTooltip,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, color: t.ink2, size: 15),
        ),
        chevron,
        const SizedBox(width: 4),
      ],
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  const _ExpandedBody({
    required this.accent,
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
  });

  final Color accent;
  final int grams;
  final TextEditingController gramsController;

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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              _StepperButton(
                icon: Icons.remove_rounded,
                semanticLabel: l10n.foodDecreaseAmountSemantics,
                accent: accent,
                onTap: () => onBump(-step),
                onLongPress: () => onBump(-step * 5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _GramsField(
                  controller: gramsController,
                  onChanged: onTextChanged,
                ),
              ),
              const SizedBox(width: 10),
              _StepperButton(
                icon: Icons.add_rounded,
                semanticLabel: l10n.foodIncreaseAmountSemantics,
                accent: accent,
                onTap: () => onBump(step),
                onLongPress: () => onBump(step * 5),
              ),
            ],
          ),
          if (gramsInvalid) ...[
            const SizedBox(height: 6),
            Text(
              l10n.foodPortionRangeHint(
                PlausibilityLimits.portionGramsMin,
                PlausibilityLimits.portionGramsMax,
              ),
              key: const ValueKey('kcal-suggestion-grams-hint'),
              style: AppType.ui(
                11,
                weight: FontWeight.w600,
                color: t.warning,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent,
              inactiveTrackColor: t.tile,
              thumbColor: accent,
              overlayColor: accent.withValues(alpha: 0.15),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              min: minGrams.toDouble(),
              max: maxGrams.toDouble(),
              value: grams.clamp(minGrams, maxGrams).toDouble(),
              onChanged: onSliderChanged,
            ),
          ),
          const SizedBox(height: 6),
          _LivePreview(
            kcal: preview.caloriesKcal,
            protein: preview.protein,
            carbs: preview.carbs,
            fat: preview.fat,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: addButtonKey,
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                l10n.commonAdd,
                style: AppType.ui(14, weight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: t.forest,
                foregroundColor: t.onForest,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round soft capsule instead of a hairline square: the surface carries the
/// button, the icon carries the accent. No border (design rule).
class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.accent,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;

  /// A11y: the +/- icon alone tells a screen reader nothing.
  final String semanticLabel;

  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: context.t.tile,
            borderRadius: BorderRadius.circular(rPill),
          ),
          child: Icon(icon, size: 21, color: accent),
        ),
      ),
    );
  }
}

/// Borderless gram capsule following the coach composer pattern: no hairline,
/// no focus ring — focus is a surface lightening, the number is the hero.
class _GramsField extends StatefulWidget {
  const _GramsField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_GramsField> createState() => _GramsFieldState();
}

class _GramsFieldState extends State<_GramsField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focused != _focus.hasFocus) {
        setState(() => _focused = _focus.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 160)),
      curve: Curves.easeOutCubic,
      height: 48,
      decoration: BoxDecoration(
        // Focus = surface lightening, no ring: `surf` sits one step above
        // `tile` in both modes and takes exactly this role.
        color: _focused ? t.surf : t.tile,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: TextField(
              cursorOpacityAnimates: false,
              controller: widget.controller,
              focusNode: _focus,
              onChanged: widget.onChanged,
              keyboardType: const TextInputType.numberWithOptions(
                signed: false,
                decimal: false,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                // Five digits because the upper bound
                // (PlausibilityLimits.portionGramsMax = 10000 g) has five;
                // four made the top of the valid range unenterable.
                LengthLimitingTextInputFormatter(5),
              ],
              textAlign: TextAlign.center,
              style: AppType.display(18, color: t.ink),
              decoration: const InputDecoration(
                // Null out the theme borders explicitly: the global
                // inputDecorationTheme carries a hairline and focus ring.
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
            style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final int kcal;
  final String protein;
  final String carbs;
  final String fat;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '=',
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.0,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$kcal kcal',
          style: AppType.display(20, color: t.ink, height: 1.0),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _macroLine(context.l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppType.display(
              11.5,
              weight: FontWeight.w600,
              color: t.ink2,
            ),
          ),
        ),
      ],
    );
  }

  String _macroLine(AppLocalizations l10n) {
    final parts = <String>[];
    if (protein != '-') parts.add(l10n.foodMacroProteinShort(protein));
    if (carbs != '-') parts.add(l10n.foodMacroCarbsShort(carbs));
    if (fat != '-') parts.add(l10n.foodMacroFatShort(fat));
    return parts.join(' · ');
  }
}
