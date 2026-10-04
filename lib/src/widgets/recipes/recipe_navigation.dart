import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../design/controls.dart' show SelectionTone;

/// The weekly planner's local navigation ("Week" / "Shopping list") in the
/// app's segmented language: a card-coloured capsule track on the page with
/// the chosen option as an accent pill, like the settings segments. Labels
/// that do not fit side by side (large text on a narrow phone) stack into
/// full-width rows inside the same track.
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

  static const double _inset = 4;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, const Duration(milliseconds: 180));
    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = constraints.maxWidth - _inset * 2;
        final style = AppType.ui(14, weight: FontWeight.w700);
        var widest = 0.0;
        for (final label in labels) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.width);
          painter.dispose();
        }
        final stacked = (widest + 32) * labels.length > inner;
        final shape = stacked
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(rControl))
            : const StadiumBorder();
        final segments = [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              key: itemKeys?[i],
              selected: i == selected,
              button: true,
              child: Material(
                color: i == selected ? t.selectedFill : Colors.transparent,
                animationDuration: motion,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onSelected(i),
                  customBorder: shape,
                  focusColor: t.accent.withValues(alpha: 0.20),
                  hoverColor: t.accent.withValues(alpha: 0.10),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    alignment: stacked
                        ? AlignmentDirectional.centerStart
                        : Alignment.center,
                    padding: EdgeInsets.symmetric(
                      horizontal: stacked ? 16 : 10,
                      vertical: 10,
                    ),
                    child: Text(
                      labels[i],
                      textAlign: stacked ? TextAlign.start : TextAlign.center,
                      style: style.copyWith(
                        color: i == selected ? t.onSelected : t.ink2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ];
        return Container(
          padding: const EdgeInsets.all(_inset),
          decoration: BoxDecoration(
            color: t.surf,
            border: Border.all(color: t.cardBorder),
            borderRadius: BorderRadius.circular(
              stacked ? rControl + _inset : rPill,
            ),
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0) const SizedBox(height: _inset),
                      segments[i],
                    ],
                  ],
                )
              : Row(
                  children: [
                    for (final segment in segments) Expanded(child: segment),
                  ],
                ),
        );
      },
    );
  }
}
