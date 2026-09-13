import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../design/design.dart';

/// One quiet context row, with the complete choices available on demand.
class MealSlotPicker extends StatefulWidget {
  const MealSlotPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'slot-select-',
  });

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;
  final String keyPrefix;

  @override
  State<MealSlotPicker> createState() => _MealSlotPickerState();
}

class _MealSlotPickerState extends State<MealSlotPicker> {
  bool _open = false;

  Future<void> _choose() async {
    if (_open) return;
    _open = true;
    try {
      final slot = await showEatovaSheet<MealSlot>(
        context,
        _MealSlotChoices(
          selected: widget.selected,
          keyPrefix: widget.keyPrefix,
        ),
      );
      if (mounted && slot != null && slot != widget.selected) {
        widget.onSelected(slot);
      }
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final slot = widget.selected;
    return Semantics(
      button: true,
      label: context.l10n.mealSlotPickerTitle,
      value: slot.label(context.l10n),
      excludeSemantics: true,
      onTap: _choose,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('${widget.keyPrefix}open'),
          onTap: _choose,
          borderRadius: BorderRadius.circular(rControl),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                _SlotMark(slot: slot, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.mealSlotPickerContext,
                        style: AppType.ui(11, color: t.ink2),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slot.label(context.l10n),
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.keyboard_arrow_down_rounded, color: t.ink2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MealSlotChoices extends StatelessWidget {
  const _MealSlotChoices({required this.selected, required this.keyPrefix});

  final MealSlot selected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      key: ValueKey('${keyPrefix}sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: HeadingSemantics(
                  level: 1,
                  child: Text(
                    l10n.mealSlotPickerTitle,
                    style: AppType.display(23, color: t.ink),
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('${keyPrefix}close'),
                tooltip: l10n.commonClose,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              20 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: Column(
              children: [
                for (final slot in MealSlot.values) ...[
                  _SlotChoice(
                    slot: slot,
                    selected: slot == selected,
                    actionKey: ValueKey('$keyPrefix${slot.name}'),
                  ),
                  if (slot != MealSlot.values.last)
                    Divider(
                      height: 1,
                      indent: MediaQuery.textScalerOf(context).scale(17) > 25.5
                          ? 12
                          : 68,
                      endIndent: 12,
                      color: t.line,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SlotChoice extends StatelessWidget {
  const _SlotChoice({
    required this.slot,
    required this.selected,
    required this.actionKey,
  });
  final MealSlot slot;
  final bool selected;
  final Key actionKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final hint = switch (slot) {
      MealSlot.breakfast => l10n.mealSlotPickerBreakfastHint,
      MealSlot.lunch => l10n.mealSlotPickerLunchHint,
      MealSlot.dinner => l10n.mealSlotPickerDinnerHint,
      MealSlot.snack => l10n.mealSlotPickerSnackHint,
    };
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? t.surf2 : Colors.transparent,
        borderRadius: BorderRadius.circular(rControl),
        child: InkWell(
          key: actionKey,
          borderRadius: BorderRadius.circular(rControl),
          onTap: () => Navigator.of(context).pop(slot),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Row(
              children: [
                if (MediaQuery.textScalerOf(context).scale(17) <= 25.5) ...[
                  _SlotMark(slot: slot, size: 44),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slot.label(l10n),
                        style: AppType.ui(
                          17,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hint,
                        style: AppType.ui(12, color: t.ink2, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (selected)
                  ExcludeSemantics(
                    child: Icon(Icons.check_rounded, size: 23, color: t.accent),
                  )
                else
                  const SizedBox(width: 23),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SlotMark extends StatelessWidget {
  const _SlotMark({required this.slot, required this.size});
  final MealSlot slot;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: slot.diarySurface(context.t),
        shape: BoxShape.circle,
      ),
      child: Icon(slot.diaryIcon, size: 21, color: context.t.ink),
    ),
  );
}
