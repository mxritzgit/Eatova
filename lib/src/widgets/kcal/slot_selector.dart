import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../theme/app_colors.dart';
import '../../theme/meal_slot_style.dart';

/// Segmented-Control fuer die Slot-Wahl (Frühstück/Mittag/Abend/Snack).
///
/// Aus dem AddMealSheet extrahiert (dort vorher privat), damit das
/// Bearbeiten-Sheet exakt dasselbe Muster nutzt statt es zu duplizieren.
/// [keyPrefix] haelt die Test-Keys pro Einsatzort eindeutig — das Add-Sheet
/// behaelt seine historischen `slot-select-*`-Keys, das Edit-Sheet nutzt
/// `edit-slot-select-*` (beide Sheets koennen gleichzeitig offen sein).
class SlotSelector extends StatelessWidget {
  const SlotSelector({
    super.key,
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'slot-select-',
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;
  final String keyPrefix;

  static const List<MealSlot> _slots = <MealSlot>[
    MealSlot.breakfast,
    MealSlot.lunch,
    MealSlot.dinner,
    MealSlot.snack,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _slots.length; i++) ...[
          Expanded(
            child: _SlotSegment(
              keyValue: ValueKey('$keyPrefix${_slots[i].name}'),
              slot: _slots[i],
              selected: _slots[i] == selected,
              onTap: () => onSelected(_slots[i]),
            ),
          ),
          if (i != _slots.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _SlotSegment extends StatelessWidget {
  const _SlotSegment({
    required this.keyValue,
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  final Key keyValue;
  final MealSlot slot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = slot.accent;
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rControl),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : surfaceSoft,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: selected ? color : hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              slot.icon,
              size: 18,
              color: selected ? color : textMuted,
            ),
            const SizedBox(height: 4),
            Text(
              slot.shortLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? textPrimary : textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
