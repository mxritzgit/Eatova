import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../../theme/meal_slot_style.dart';

/// Segmented control for picking a meal slot.
///
/// [keyPrefix] keeps the test keys unique per call site — add and edit sheet
/// can be open at the same time.
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
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    // Scales with the system text like the edit sheet's day picker, capped
    // so four segments do not eat the sheet at 2.0; exactly 56 at 1.0
    // (review F3-05). Minimum, not fixed: icon + label decide the rest.
    final hoehe = MediaQuery.textScalerOf(context).scale(56).clamp(56.0, 80.0);
    // A11y: button with selection state and the full slot name; the visible
    // short label alone would be a truncated word.
    return Semantics(
      button: true,
      selected: selected,
      label: slot.label(l10n),
      child: InkWell(
        key: keyValue,
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          constraints: BoxConstraints(minHeight: hoehe),
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
              // Not the full slot color on its own 16 % tint: that is only
              // 2.15:1 in light mode.
              Icon(
                slot.icon,
                size: 18,
                color: selected ? t.readableOnTint(color) : t.ink2,
              ),
              const SizedBox(height: 4),
              Text(
                slot.shortLabel(l10n),
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
