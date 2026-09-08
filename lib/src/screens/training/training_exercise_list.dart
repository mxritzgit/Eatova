import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';

/// Shared readable prescription, used by the library and Coach draft review.
class TrainingExerciseList extends StatelessWidget {
  const TrainingExerciseList({super.key, required this.exercises});

  final List<TrainingExercise> exercises;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final largeText = MediaQuery.textScalerOf(context).scale(17) > 25.5;
    final numberStyle = AppType.display(17, color: t.ink2);
    final numberMeasure = TextPainter(
      text: TextSpan(
        text: exercises.length.toString().padLeft(2, '0'),
        style: numberStyle,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final numberWidth = (numberMeasure.width + 12).clamp(40.0, double.infinity);
    numberMeasure.dispose();
    return Column(
      children: [
        for (var i = 0; i < exercises.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: SizedBox(
                    width: numberWidth,
                    child: Text(
                      largeText
                          ? '${i + 1}'
                          : (i + 1).toString().padLeft(2, '0'),
                      maxLines: 1,
                      softWrap: false,
                      style: numberStyle,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercises[i].name,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 5),
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
                        style: AppType.ui(14, color: t.ink2),
                      ),
                      if (exercises[i].restSeconds > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            l10n.trainingPageRestSeconds(
                              exercises[i].restSeconds,
                            ),
                            style: AppType.ui(13, color: t.ink2),
                          ),
                        ),
                      if (exercises[i].notes.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            exercises[i].notes,
                            style: AppType.ui(14, color: t.ink2, height: 1.45),
                          ),
                        ),
                    ],
                  ),
                ),
                if (exercises[i].isTimed)
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.timer_outlined,
                        size: 20,
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
