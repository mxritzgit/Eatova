part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Slot-Picker-Sheet („Wann eintragen?"): Bottom-Sheet, das nach dem
// Hinzufügen-Tap den MealSlot (Frühstück/Mittag/Abend/Snack) abfragt.
// ---------------------------------------------------------------------------
class _MealSlotPickerSheet extends StatelessWidget {
  const _MealSlotPickerSheet({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    const slots = <MealSlot>[
      MealSlot.breakfast,
      MealSlot.lunch,
      MealSlot.dinner,
      MealSlot.snack,
    ];

    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('recipe-meal-picker-sheet'),
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(rSheet),
          border: Border.all(color: hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: hairline,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(rCard),
                  child: SizedBox(
                    width: 58,
                    height: 58,
                    child: _RecipeImage(recipe: recipe),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Wann eintragen?',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${recipe.caloriesKcal} kcal · ${recipe.proteinG} g Protein',
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < slots.length; i++) ...[
              _MealSlotButton(
                slot: slots[i],
                onTap: () => Navigator.of(context).pop(slots[i]),
              ),
              if (i != slots.length - 1) const SizedBox(height: 9),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: TextButton(
                key: const ValueKey('recipe-meal-picker-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: textMuted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rCard),
                  ),
                ),
                child: const Text(
                  'Abbrechen',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MealSlotButton extends StatelessWidget {
  const _MealSlotButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  Color get color => slot.accent;

  IconData get icon => slot.icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('recipe-meal-picker-${slot.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: color.withValues(alpha: 0.36)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                slot.label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}
