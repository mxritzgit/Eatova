import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/recipe_ingredient.dart';
import '../../theme/app_tokens.dart';
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
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.initialServings));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _format(double n) =>
      n.isFinite && n == n.roundToDouble() ? '${n.round()}' : '$n';

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
          errorText: value == null ? t.recipeCalcServingsError : null,
        ),
        if (widget.showPresets)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final amount in [0.5, 1.0, 2.0])
                ChoiceChip(
                  label: Text(t.recipeCalcServingsCount(_format(amount))),
                  selected: value == amount,
                  selectedColor: context.t.surf2,
                  onSelected: (_) {
                    _controller.text = _format(amount);
                    _changed(_controller.text);
                  },
                ),
            ],
          ),
      ],
    );
  }
}
