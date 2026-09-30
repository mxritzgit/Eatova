import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// Quiet local navigation shared by the recipe library and weekly planner.
class RecipeNavigation extends StatelessWidget {
  const RecipeNavigation({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.itemKeys,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final List<Key>? itemKeys;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
        final children = [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              key: itemKeys?[i],
              selected: i == selected,
              button: true,
              child: Material(
                color: i == selected ? t.brandSurface : Colors.transparent,
                borderRadius: BorderRadius.circular(rControl),
                child: InkWell(
                  borderRadius: BorderRadius.circular(rControl),
                  onTap: () => onSelected(i),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: Text(
                        labels[i],
                        textAlign: TextAlign.center,
                        style:
                            AppType.ui(
                              14,
                              color: i == selected ? t.onBrandSurface : t.ink2,
                              weight: i == selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ).copyWith(
                              decoration: i == selected
                                  ? TextDecoration.underline
                                  : null,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ];
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final child in children) child],
          );
        }
        return Row(
          children: [for (final child in children) Expanded(child: child)],
        );
      },
    );
  }
}
