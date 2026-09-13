import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';

const trainingStudioImage = 'assets/training/nightstudio.png';

class _TrainingReveal extends StatelessWidget {
  const _TrainingReveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = motionDuration(context, const Duration(milliseconds: 180));
    return duration == Duration.zero
        ? child
        : AnimatedSize(
            duration: duration,
            alignment: Alignment.topCenter,
            child: child,
          );
  }
}

/// Bundled editorial artwork; it never represents a user's exercise or result.
class TrainingStudioArtwork extends StatelessWidget {
  const TrainingStudioArtwork({super.key, this.backgroundColor});

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final backdrop = backgroundColor ?? t.bg;
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            trainingStudioImage,
            fit: BoxFit.cover,
            alignment: Alignment.centerRight,
            errorBuilder: (_, _, _) => ColoredBox(color: backdrop),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  backdrop,
                  backdrop.withValues(alpha: 0.65),
                  backdrop.withValues(alpha: 0),
                ],
                stops: const [0, 0.35, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  backdrop.withValues(alpha: 0.2),
                  backdrop.withValues(alpha: 0),
                  backdrop,
                ],
                stops: const [0, 0.65, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TrainingStartButton extends StatelessWidget {
  const TrainingStartButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.play_arrow_rounded,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 24),
      label: Text(label, style: AppType.ui(16, weight: FontWeight.w700)),
      style: FilledButton.styleFrom(
        backgroundColor: context.t.lime,
        foregroundColor: context.t.onLime,
        disabledBackgroundColor: context.t.lime.withValues(alpha: 0.38),
        disabledForegroundColor: context.t.onLime.withValues(alpha: 0.8),
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
        ),
      ),
    ),
  );
}

class TrainingWorkoutTabs extends StatelessWidget {
  const TrainingWorkoutTabs({
    super.key,
    required this.workouts,
    required this.selected,
    required this.onSelected,
  });

  final List<TrainingWorkout> workouts;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var i = 0; i < workouts.length; i++)
        Semantics(
          selected: i == selected,
          button: true,
          onTap: () => onSelected(i),
          label:
              '${context.l10n.trainingPageWorkoutNumber(i + 1)}: ${workouts[i].title}',
          excludeSemantics: true,
          child: Tooltip(
            message: workouts[i].title,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('training-workout-$i'),
                onTap: () => onSelected(i),
                borderRadius: BorderRadius.circular(rChip),
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 52,
                    minHeight: 48,
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == selected ? context.t.lime : context.t.line,
                        width: i == selected ? 3 : 1,
                      ),
                    ),
                  ),
                  child: Text(
                    String.fromCharCode(65 + i),
                    textAlign: TextAlign.center,
                    style: AppType.display(
                      19,
                      color: i == selected ? context.t.lime : context.t.ink2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class TrainingExercisePreview extends StatefulWidget {
  const TrainingExercisePreview({super.key, required this.exercises});

  final List<TrainingExercise> exercises;

  @override
  State<TrainingExercisePreview> createState() =>
      _TrainingExercisePreviewState();
}

class _TrainingExercisePreviewState extends State<TrainingExercisePreview> {
  final Set<int> _expanded = {};
  bool _all = false;

  @override
  void didUpdateWidget(covariant TrainingExercisePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.exercises, widget.exercises)) {
      _expanded.clear();
      _all = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final visible = _all
        ? widget.exercises.length
        : widget.exercises.length.clamp(0, 3);
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visible; i++)
          Builder(
            builder: (context) {
              final exercise = widget.exercises[i];
              final expanded = _expanded.contains(i);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey('training-exercise-$i'),
                      onTap: () => setState(() {
                        expanded ? _expanded.remove(i) : _expanded.add(i);
                      }),
                      borderRadius: BorderRadius.circular(rControl),
                      child: Semantics(
                        expanded: expanded,
                        button: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          child: Row(
                            children: [
                              if (!large) ...[
                                ExcludeSemantics(
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: t.surf2,
                                      borderRadius: BorderRadius.circular(
                                        rChip,
                                      ),
                                      border: Border.all(color: t.line),
                                    ),
                                    child: Text(
                                      (i + 1).toString().padLeft(2, '0'),
                                      style: AppType.display(26, color: t.lime),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      exercise.name,
                                      style: AppType.ui(
                                        large ? 15 : 17,
                                        weight: FontWeight.w700,
                                        color: t.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      exercise.isTimed
                                          ? l10n.trainingPageSetsTime(
                                              exercise.sets,
                                              exercise.durationSeconds!,
                                            )
                                          : l10n.trainingPageSetsReps(
                                              exercise.sets,
                                              exercise.reps!,
                                            ),
                                      style: AppType.ui(15, color: t.ink2),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                expanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.chevron_right_rounded,
                                color: t.ink2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _TrainingReveal(
                    child: expanded
                        ? Padding(
                            padding: EdgeInsets.fromLTRB(
                              large ? 0 : 70,
                              0,
                              12,
                              16,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.trainingPageRestSeconds(
                                    exercise.restSeconds,
                                  ),
                                  style: AppType.ui(14, color: t.lime),
                                ),
                                if (exercise.notes.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    exercise.notes,
                                    style: AppType.ui(
                                      14,
                                      color: t.ink2,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Divider(color: t.line, height: 1),
                ],
              );
            },
          ),
        if (widget.exercises.length > 3)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('training-all-exercises'),
              onPressed: () => setState(() => _all = !_all),
              icon: Icon(
                _all ? Icons.expand_less_rounded : Icons.arrow_forward_rounded,
              ),
              label: Text(
                _all
                    ? l10n.trainingStudioLessExercises
                    : l10n.trainingStudioAllExercises(widget.exercises.length),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
