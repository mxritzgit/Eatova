import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../services/food_history_search.dart';
import '../../services/kcal_format.dart';
import '../../services/local_day.dart';
import '../../services/own_food_suggestions.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../design/design.dart';
import 'saved_meal_presentation.dart';

/// The two row lists of [OwnFoodSuggestions].
enum OwnFoodSection { frequent, fitting }

/// The sheet's item key for [hit] in [section] (expanded row, just-added
/// check).
String ownFoodItemKey(OwnFoodSection section, FoodHistoryHit hit) =>
    '${section.name}:${hit.key}';

/// The add sheet's suggestions from the user's own foods, above its recents
/// (2026-11-01): "Often at breakfast" with the usual combination below it,
/// then "What still fits?" ([ownFoodSuggestions]). Shows nothing without
/// enough repetition or data, so the sheet stays as it was.
///
/// Rows are built by the sheet ([itemBuilder]), which owns the add path;
/// the lists are recomputed only when an input changes (the store replaces
/// its lists per mutation, so identity is the fingerprint).
class OwnFoodSections extends StatefulWidget {
  const OwnFoodSections({
    super.key,
    required this.slot,
    required this.day,
    required this.diary,
    required this.favorites,
    required this.dayMeals,
    required this.labelBuilder,
    required this.itemBuilder,
    this.remainingKcal,
    this.onTakeUsual,
    this.expandedKey,
    this.gap = 20,
  });

  final MealSlot slot;

  /// The diary day the sheet logs into.
  final DateTime day;

  /// The diary rows the store holds.
  final List<LoggedMeal> diary;
  final List<FavoriteMeal> favorites;

  /// The entries already on [day].
  final List<LoggedMeal> dayMeals;

  /// kcal still open on [day] (budget incl. activity minus eaten); null
  /// hides "What still fits?".
  final int? remainingKcal;

  /// Section label with an optional trailing widget.
  final Widget Function(String text, Widget? trailing) labelBuilder;
  final Widget Function(OwnFoodSection section, FoodHistoryHit hit, int index)
  itemBuilder;

  /// Copies the usual meal's entries into [slot]; null hides the row.
  final Future<void> Function(UsualSlotMeal usual)? onTakeUsual;

  /// The sheet's open row ([ownFoodItemKey]), for the hairline fade.
  final String? expandedKey;

  /// Space below each section.
  final double gap;

  @override
  State<OwnFoodSections> createState() => _OwnFoodSectionsState();
}

class _OwnFoodSectionsState extends State<OwnFoodSections> {
  Object? _inputs;
  OwnFoodSuggestions _value = const OwnFoodSuggestions();
  bool _taking = false;

  OwnFoodSuggestions _current() {
    final now = clock.now();
    // A record compares its lists by identity and the rest by value.
    final inputs = (
      widget.diary,
      widget.favorites,
      widget.dayMeals,
      widget.slot,
      localDayKey(widget.day),
      localDayKey(now),
      widget.remainingKcal,
    );
    if (inputs == _inputs) return _value;
    _inputs = inputs;
    return _value = ownFoodSuggestions(
      diary: widget.diary,
      favorites: widget.favorites,
      slot: widget.slot,
      day: widget.day,
      dayMeals: widget.dayMeals,
      now: now,
      remainingKcal: widget.remainingKcal,
    );
  }

  Future<void> _takeUsual(UsualSlotMeal usual) async {
    final take = widget.onTakeUsual;
    if (take == null || _taking) return;
    setState(() => _taking = true);
    await take(usual);
    if (mounted) setState(() => _taking = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final value = _current();
    final usual = widget.onTakeUsual == null ? null : value.usual;
    final remaining = widget.remainingKcal;
    return Column(
      key: const ValueKey('own-food-sections'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (value.frequent.isNotEmpty) ...[
          widget.labelBuilder(
            l10n.foodSectionFrequentInSlot(widget.slot.name),
            null,
          ),
          _collection(OwnFoodSection.frequent, value.frequent),
          if (usual != null) ...[
            const SizedBox(height: 12),
            _UsualMealRow(
              slot: widget.slot,
              usual: usual,
              busy: _taking,
              onTap: () => _takeUsual(usual),
            ),
          ],
          SizedBox(height: widget.gap),
        ],
        if (value.fitting.isNotEmpty && remaining != null) ...[
          widget.labelBuilder(
            l10n.foodSectionStillFits,
            // Half the row, so the label keeps its words at large text.
            Expanded(
              child: Text(
                l10n.foodStillFitsLeft(remaining),
                key: const ValueKey('own-food-fits-left'),
                textAlign: TextAlign.end,
                style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink3),
              ),
            ),
          ),
          _collection(OwnFoodSection.fitting, value.fitting),
          SizedBox(height: widget.gap),
        ],
      ],
    );
  }

  Widget _collection(OwnFoodSection section, List<FoodHistoryHit> hits) =>
      SavedMealCollection(
        key: ValueKey('own-food-${section.name}'),
        dividerInset: kSavedMealDividerInset,
        expandedIndex: hits.indexWhere(
          (hit) => ownFoodItemKey(section, hit) == widget.expandedKey,
        ),
        children: [
          for (var i = 0; i < hits.length; i++)
            widget.itemBuilder(section, hits[i], i),
        ],
      );
}

/// "Your usual breakfast": the parts' names, count and kcal; one tap
/// copies them all into the slot through the store's copy with undo.
class _UsualMealRow extends StatelessWidget {
  const _UsualMealRow({
    required this.slot,
    required this.usual,
    required this.busy,
    required this.onTap,
  });

  final MealSlot slot;
  final UsualSlotMeal usual;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = l10n.foodUsualMealTitle(slot.name);
    final names = [
      for (final meal in usual.meals) mealTitleAndBrand(meal.result, l10n).$1,
    ].join(', ');
    final meta = l10n.foodCopyRepeatMeta(
      usual.meals.length,
      formatThousands(usual.kcal, l10n.localeName),
    );
    return Semantics(
      container: true,
      button: true,
      enabled: !busy,
      label: '$title, $names, $meta',
      hint: l10n.foodUsualMealHint,
      onTap: busy ? null : onTap,
      excludeSemantics: true,
      child: PressScale(
        enabled: !busy,
        scale: kPressScaleCard,
        child: Material(
          color: t.surf,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rCard),
            side: BorderSide(color: t.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('own-food-usual'),
            onTap: busy ? null : onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              // The geometry of the favorites entry row: 16 inset, 40 tile.
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: t.accentTint,
                      borderRadius: BorderRadius.circular(rChip),
                    ),
                    child: Icon(
                      Icons.replay_rounded,
                      size: 20,
                      color: t.accentText,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppType.ui(
                            15,
                            weight: FontWeight.w600,
                            color: t.accentText,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          names,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.ui(12.5, color: t.ink2, height: 1.3),
                        ),
                        Text(
                          meta,
                          style: AppType.ui(12.5, color: t.ink3, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  if (busy) ...[
                    const SizedBox(width: 8),
                    const AppSpinner(size: 16, strokeWidth: 2),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
