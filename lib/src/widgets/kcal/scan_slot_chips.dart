import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/motion.dart';

/// Slot picker as a chip row over a live camera image, shared by the AI scan
/// (`MealCameraSheet`) and the barcode scanner (`BarcodeScannerSheet`). The
/// active chip carries the slot accent color; the choice decides which slot
/// the detected meal lands in. One source for both scan paths, so they read
/// as the same pattern.
class ScanSlotChips extends StatelessWidget {
  const ScanSlotChips({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;

  /// Prefix of the chip keys (`<keyPrefix>-<slot.name>`), so tests can tell
  /// the camera and barcode chips apart.
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
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final slot in _slots) ...[
          Flexible(
            child: _SlotChip(
              slot: slot,
              selected: slot == selected,
              keyPrefix: keyPrefix,
              onTap: () => onSelected(slot),
            ),
          ),
          if (slot != _slots.last) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _SlotChip extends StatelessWidget {
  const _SlotChip({
    required this.slot,
    required this.selected,
    required this.keyPrefix,
    required this.onTap,
  });

  final MealSlot slot;
  final bool selected;
  final String keyPrefix;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The chip sits on the live camera image, so it uses the DARK palette in
    // both themes rather than `accentIn(context)`: the light-mode slot tones
    // (lunch = deep blue) would push the black label to 3.6:1. A fixed palette
    // for a surface that is always dark, not a brightness branch.
    final accent = slot.accentOn(AppTokens.dark);
    return InkWell(
      key: ValueKey('$keyPrefix-${slot.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(rPill),
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.92)
              : Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(rPill),
          border: Border.all(
            color: selected ? accent : Colors.white.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              slot.icon,
              size: 13,
              color: selected ? Colors.black : Colors.white,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                slot.shortLabel(context.l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
