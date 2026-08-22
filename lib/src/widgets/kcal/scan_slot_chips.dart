import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/motion.dart';

/// Slot-Auswahl als Chip-Reihe AUF einem Live-Kamerabild — gemeinsam fuer den
/// KI-Scan (`MealCameraSheet`) und den Barcode-Scanner (`BarcodeScannerSheet`).
/// Der aktive Chip traegt die Slot-Akzentfarbe; die Wahl bestimmt, in welchen
/// Slot die erkannte Mahlzeit wandert.
///
/// Bis 2026-08-22 lebte die Reihe privat in meal_camera_sheet.dart, und nur
/// die Kamera hatte sie: der Barcode-Knopf im Food-Tab landete stumm im
/// Uhrzeit-Slot, ohne dass man Mittag oder Abend waehlen konnte. Eine Quelle
/// fuer beide Scan-Wege, damit sie als dasselbe Muster gelesen werden.
class ScanSlotChips extends StatelessWidget {
  const ScanSlotChips({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;

  /// Praefix der Chip-Keys (`<keyPrefix>-<slot.name>`), damit Tests den
  /// Kamera- und den Barcode-Chip auseinanderhalten koennen.
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
    // Der Chip liegt AUF dem Live-Kamerabild, zusammen mit den harten
    // schwarz/weissen Scrims und Beschriftungen der Scan-Sheets — deshalb die
    // DUNKEL-Palette in beiden Anzeige-Modi, nicht `accentIn(context)`.
    // Dasselbe Argument wie beim Scanrahmen und beim Ausloeser: die hellen
    // Slot-Toene tragen auf einem beliebig hellen Bild, die dunklen des
    // Hell-Modus (Mittag = tiefes Blau) haetten das schwarze Chip-Label auf
    // 3,6:1 gedrueckt. Kein Brightness-Abzweig, sondern eine feste Palette
    // fuer eine Flaeche, die immer dunkel ist.
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
