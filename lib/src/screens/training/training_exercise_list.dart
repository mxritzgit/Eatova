import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// Shared readable prescription, used by the library and Coach draft review.
/// The exercise order is a real sequence: each row leads with the app's one
/// number style ([StepNumber]), centred on the name's first line.
class TrainingExerciseList extends StatelessWidget {
  const TrainingExerciseList({super.key, required this.exercises});

  final List<TrainingExercise> exercises;

  static const double _number = 32;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = AppType.rowTitle(t.ink);
    final line =
        MediaQuery.textScalerOf(context).scale(title.fontSize ?? 15) *
        (title.height ?? AppType.normalHeight);
    final numberTop = line > _number ? (line - _number) / 2 : 0.0;
    final textTop = line < _number ? (_number - line) / 2 : 0.0;
    return Column(
      children: [
        for (var i = 0; i < exercises.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: kSpace12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: numberTop),
                  child: StepNumber(i + 1, size: _number),
                ),
                const SizedBox(width: kRowLeadingGap),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: textTop),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(exercises[i].name, style: title),
                        const SizedBox(height: 3),
                        Text(
                          exercises[i].isTimed
                              ? l10n.trainingPageSetsTime(
                                  exercises[i].sets,
                                  exercises[i].durationSeconds!,
                                )
                              : l10n.trainingPageSetsReps(
                                  exercises[i].sets,
                                  exercises[i].reps!,
                                ),
                          style: AppType.callout(t.ink2),
                        ),
                        if (exercises[i].restSeconds > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              l10n.trainingPageRestSeconds(
                                exercises[i].restSeconds,
                              ),
                              style: AppType.subhead(t.ink2),
                            ),
                          ),
                        if (exercises[i].notes.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: kSpace8),
                            child: Text(
                              exercises[i].notes,
                              style: AppType.callout(t.ink2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (exercises[i].isTimed)
                  ExcludeSemantics(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: kSpace8,
                        top: (math.max(line, _number) - AppIconSize.standard) /
                            2,
                      ),
                      child: Icon(
                        AppIcons.timer,
                        size: AppIconSize.standard,
                        color: t.ink2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
