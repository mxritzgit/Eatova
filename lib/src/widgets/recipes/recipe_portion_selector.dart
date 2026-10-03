import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';
import '../../models/recipe_ingredient.dart';
import '../common/decimal_text.dart';
import '../design/controls.dart';
import '../design/sheets.dart';

/// Returns null while invalid so a parent cannot log the previous valid value.
class RecipePortionSelector extends StatefulWidget {
  const RecipePortionSelector({
    super.key,
    this.initialServings = 1,
    required this.onChanged,
    this.label,
    this.showPresets = true,
  });

  final double initialServings;
  final ValueChanged<double?> onChanged;
  final String? label;
  final bool showPresets;

  @override
  State<RecipePortionSelector> createState() => _RecipePortionSelectorState();
}

class _RecipePortionSelectorState extends State<RecipePortionSelector> {
  // Created on the first dependency pass: the prefill needs the locale's
  // decimal separator, which initState cannot read.
  TextEditingController? _field;
  TextEditingController get _controller => _field!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _field ??= TextEditingController(
      text: formatDecimalInput(
        widget.initialServings,
        context.l10n,
        maxFractionDigits: 3,
      ),
    );
  }

  @override
  void dispose() {
    _field?.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() {});
    widget.onChanged(parseRecipeServings(text));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final value = parseRecipeServings(_controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SheetField(
          label: widget.label ?? t.recipeCalcServings,
          hint: '1',
          controller: _controller,
          fieldKey: const ValueKey('recipe-portion-field'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          maxLength: 12,
          onChanged: _changed,
          errorText: value == null
              ? numberInputHint(NumberInput.parse(_controller.text), t) ??
                    t.recipeCalcServingsError
              : null,
        ),
        if (widget.showPresets)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final amount in [0.5, 1.0, 2.0])
                // The app's single-selection pill; 44 px keeps the touch
                // floor (the md chip alone is 42).
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: FilterChipPill(
                    key: ValueKey('recipe-portion-preset-$amount'),
                    label: t.recipePortionPresetLabel(amount),
                    selected: value == amount,
                    onTap: () {
                      _controller.text = formatDecimal(amount, t);
                      _changed(_controller.text);
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
