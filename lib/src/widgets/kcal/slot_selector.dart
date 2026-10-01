import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import 'meal_slot_picker.dart';

/// Segmented control for picking a meal slot in the edit sheet; the same
/// control as the entry sheets' [MealSlotPicker].
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

  @override
  Widget build(BuildContext context) => MealSlotSegments(
    selected: selected,
    onSelected: onSelected,
    keyPrefix: keyPrefix,
  );
}
