import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
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
    final t = context.t;
    final color = slot.accentIn(context);
    // A11y: Segment als Button mit Auswahl-Zustand und vollem Slot-Namen
    // (das sichtbare Kurz-Label allein waere z.B. nur "Früh").
    return Semantics(
      button: true,
      selected: selected,
      label: slot.label,
      child: InkWell(
        key: keyValue,
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.16) : t.surf2,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: selected ? color : t.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Nicht die volle Slot-Farbe auf ihrer eigenen 16-%-Tint:
              // das traegt im Hell-Modus nur 2.15:1 (Kohlenhydrat-Amber).
              Icon(
                slot.icon,
                size: 18,
                color: selected ? t.readableOnTint(color) : t.ink2,
              ),
              const SizedBox(height: 4),
              Text(
                slot.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  11,
                  weight: FontWeight.w700,
                  color: selected ? t.ink : t.ink2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
