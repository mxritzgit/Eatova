import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../theme/app_colors.dart';
import '../../theme/meal_slot_style.dart';

/// Zeigt die bereits geloggten Mahlzeiten fuer den aktuellen Slot+Tag
/// oben im AddMealSheet — mit X-Button zum Entfernen und (wenn [onEdit]
/// verdrahtet ist) Tap auf die Zeile zum Bearbeiten.
class ExistingMealsList extends StatelessWidget {
  const ExistingMealsList({
    super.key,
    required this.meals,
    required this.slot,
    required this.onRemove,
    this.onEdit,
  });

  final List<LoggedMeal> meals;
  final MealSlot slot;
  final ValueChanged<String>? onRemove;

  /// Tap auf eine Zeile oeffnet das Bearbeiten-Sheet. Null -> Zeile nicht
  /// tippbar (bisheriges Verhalten).
  final ValueChanged<LoggedMeal>? onEdit;

  Color get _accent => slot.accent;

  @override
  Widget build(BuildContext context) {
    final totalKcal = meals.fold<int>(
      0,
      (sum, m) => sum + m.result.caloriesKcal,
    );
    return Container(
      key: const ValueKey('analyse-existing-meals'),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Schon hinzugefügt',
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                Text(
                  '$totalKcal kcal',
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < meals.length; i++) ...[
            if (i > 0)
              const Divider(
                color: hairline,
                height: 1,
                indent: 14,
                endIndent: 14,
              ),
            _ExistingMealRow(
              meal: meals[i],
              onRemove: onRemove,
              onEdit: onEdit,
            ),
          ],
        ],
      ),
    );
  }
}

class _ExistingMealRow extends StatelessWidget {
  const _ExistingMealRow({
    required this.meal,
    required this.onRemove,
    required this.onEdit,
  });

  final LoggedMeal meal;
  final ValueChanged<String>? onRemove;
  final ValueChanged<LoggedMeal>? onEdit;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meal.result.mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${meal.result.caloriesKcal} kcal · ${meal.result.estimatedGrams} g',
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              key: ValueKey('analyse-existing-remove-${meal.id}'),
              iconSize: 18,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => onRemove!(meal.id),
              icon: const Icon(Icons.close_rounded, color: textMuted),
              tooltip: 'Entfernen',
            ),
        ],
      ),
    );
    if (onEdit == null) return row;
    // A11y: die Zeile sieht aus wie reine Anzeige — als Button mit klarer
    // Aktion ansagen, sonst bleibt der Edit-Tap unentdeckbar.
    return Semantics(
      button: true,
      hint: 'Mahlzeit bearbeiten',
      child: InkWell(
        key: ValueKey('analyse-existing-edit-${meal.id}'),
        onTap: () => onEdit!(meal),
        borderRadius: BorderRadius.circular(rControl),
        child: row,
      ),
    );
  }
}
