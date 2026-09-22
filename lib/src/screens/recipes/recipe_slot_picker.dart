part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Slot picker sheet: asks for the MealSlot after the add tap.
//
// Keeps the portion draft visible until its local transaction commits.
// ---------------------------------------------------------------------------
class _MealSlotPickerSheet extends StatefulWidget {
  const _MealSlotPickerSheet({required this.recipe, required this.onSave});

  final FitnessRecipe recipe;
  final Future<bool> Function(MealSlot slot, double servings) onSave;

  @override
  State<_MealSlotPickerSheet> createState() => _MealSlotPickerSheetState();
}

class _MealSlotPickerSheetState extends State<_MealSlotPickerSheet> {
  double? _servings = 1;
  bool _saving = false;
  FitnessRecipe get recipe => widget.recipe;

  MealAnalysisResult? _selectedResult(AppLocalizations l10n) {
    if (_servings == null || !recipe.canLogServings(_servings!)) return null;
    try {
      return recipe.toMealResultForServings(_servings!, l10n);
    } on FormatException {
      return null;
    }
  }

  Future<void> _save(MealSlot slot) async {
    if (_saving || _servings == null) return;
    final servings = _servings!;
    setState(() => _saving = true);
    final saved = await widget.onSave(slot, servings);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop((slot: slot, servings: servings));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = _selectedResult(l10n);
    const slots = <MealSlot>[
      MealSlot.breakfast,
      MealSlot.lunch,
      MealSlot.dinner,
      MealSlot.snack,
    ];

    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        top: false,
        // Four rows plus the header exceed the sheet height at 2x text scale.
        child: SingleChildScrollView(
          child: Padding(
            key: const ValueKey('recipe-meal-picker-sheet'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: HeadingSemantics(
                        level: 1,
                        child: Text(
                          l10n.recipesWhenToLogTitle,
                          style: AppType.display(
                            24,
                            color: t.ink,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SquareIconButton(
                      icon: Icons.close_rounded,
                      semanticLabel: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onTap: _saving ? null : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.recipePortionSheetIntro,
                  style: AppType.ui(14, color: t.ink2, height: 1.45),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: t.brandSurface,
                    borderRadius: BorderRadius.circular(rCard),
                  ),
                  child: RecipePhotoRow(
                    recipe: recipe,
                    photoWidth: 76,
                    photoHeight: 82,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recipe.title,
                          style: AppType.display(
                            18,
                            color: t.onBrandSurface,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          result == null
                              ? _recipeSummary(recipe, l10n)
                              : '${result.caloriesKcal} kcal · ${result.protein} ${l10n.todayMacroProtein}',
                          style: AppType.ui(13, color: t.ink2, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                IgnorePointer(
                  ignoring: _saving,
                  child: RecipePortionSelector(
                    onChanged: (value) => setState(() => _servings = value),
                  ),
                ),
                if (result == null) ...[
                  const SizedBox(height: 12),
                  Text(
                    recipe.hasUnclearNutritionBasis
                        ? l10n.recipeImportBasisHint
                        : recipe.hasPendingNutrition
                        ? l10n.recipeImportNutritionPendingHint
                        : l10n.recipeEditCannotLog,
                    key: const ValueKey('recipe-log-unavailable'),
                    style: AppType.ui(14, color: t.ink2, height: 1.4),
                  ),
                ],
                const SizedBox(height: 18),
                for (var i = 0; i < slots.length; i++) ...[
                  _MealSlotButton(
                    slot: slots[i],
                    onTap: result == null || _saving
                        ? null
                        : () => _save(slots[i]),
                  ),
                  if (i != slots.length - 1) const SizedBox(height: 9),
                ],
                const SizedBox(height: 10),
                // Colours and shape come from the button theme; only the
                // stature is local.
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: double.infinity,
                    minHeight: 46,
                  ),
                  child: TextButton(
                    key: const ValueKey('recipe-meal-picker-cancel'),
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(
                      l10n.commonCancel,
                      style: AppType.ui(13.5, weight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MealSlotButton extends StatelessWidget {
  const _MealSlotButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accent = slot.accentIn(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: t.surf,
          borderRadius: BorderRadius.circular(rControl),
          child: InkWell(
            key: ValueKey('recipe-meal-picker-${slot.name}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(rControl),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: slot.diarySurface(t),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AppIcon(slot.symbol, size: 24, color: accent),
                  ),

                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      slot.label(context.l10n),
                      style: AppType.ui(
                        16,
                        weight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                  ),
                  Icon(Icons.add_rounded, color: t.accent, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
