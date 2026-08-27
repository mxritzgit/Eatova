part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Slot picker sheet: asks for the MealSlot after the add tap.
//
// Runs through `showEatovaSheet`. Unlike the create sheet there is nothing to
// lose here — no form, so a drag dismiss is harmless.
// ---------------------------------------------------------------------------
class _MealSlotPickerSheet extends StatelessWidget {
  const _MealSlotPickerSheet({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    const slots = <MealSlot>[
      MealSlot.breakfast,
      MealSlot.lunch,
      MealSlot.dinner,
      MealSlot.snack,
    ];

    return SafeArea(
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
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(rControl),
                    child: SizedBox(
                      width: 58,
                      height: 58,
                      child: _RecipeImage(
                        recipe: recipe,
                        placeholderRadius: rControl,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.recipesWhenToLogTitle,
                          style: AppType.display(24, color: t.ink, height: 1.15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.recipesKcalProteinSummary(
                            recipe.caloriesKcal,
                            recipe.proteinG,
                          ),
                          style: AppType.ui(
                            12.5,
                            weight: FontWeight.w500,
                            color: t.ink2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              for (var i = 0; i < slots.length; i++) ...[
                _MealSlotButton(
                  slot: slots[i],
                  onTap: () => Navigator.of(context).pop(slots[i]),
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
                  onPressed: () => Navigator.of(context).pop(),
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
    );
  }
}

class _MealSlotButton extends StatelessWidget {
  const _MealSlotButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accent = slot.accentIn(context);
    return Material(
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
            border: Border.all(color: t.line),
          ),
          child: Row(
            children: [
              IconTile(icon: slot.icon, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  slot.label(context.l10n),
                  style: AppType.ui(
                    13.5,
                    weight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: t.ink2, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
