import 'package:flutter/foundation.dart';

import 'exercise_clip.dart';

/// One timed step inside a [Workout]: a [clip] performed for [workSeconds],
/// followed by [restSeconds] of rest before the next step starts.
@immutable
class WorkoutStep {
  const WorkoutStep({
    required this.clip,
    this.workSeconds = 40,
    this.restSeconds = 20,
  });

  final ExerciseClip clip;

  /// Seconds the exercise video runs (looping) during the work phase.
  final int workSeconds;

  /// Seconds of rest shown after the work phase (0 on the final step).
  final int restSeconds;
}

/// A guided, video-led bodyweight workout made of timed [steps].
@immutable
class Workout {
  const Workout({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.steps,
  });

  /// Stable slug, e.g. `full_body_express`.
  final String id;

  /// German display title, e.g. `Ganzkörper Express`.
  final String title;

  /// Short German descriptor, e.g. `5 Übungen · ca. 5 Min · ohne Geräte`.
  final String subtitle;

  final List<WorkoutStep> steps;

  int get exerciseCount => steps.length;

  /// Total work + rest seconds across every step.
  int get totalSeconds =>
      steps.fold(0, (sum, step) => sum + step.workSeconds + step.restSeconds);

  Duration get totalDuration => Duration(seconds: totalSeconds);

  /// Whole minutes, rounded, for compact display (e.g. `5`).
  int get totalMinutes => (totalSeconds / 60).round();
}
