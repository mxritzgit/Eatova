import 'package:flutter/foundation.dart';

/// A single demonstrable exercise backed by a short, seamlessly looping
/// 3D demo clip (bundled under `assets/videos/`).
///
/// Instances are `const` and seeded in `workout_library.dart`; there is no
/// backend persistence for the exercise catalogue in v1.
@immutable
class ExerciseClip {
  const ExerciseClip({
    required this.id,
    required this.name,
    required this.focus,
    required this.videoAsset,
    required this.cues,
  });

  /// Stable slug, e.g. `squat`.
  final String id;

  /// German display name, e.g. `Kniebeugen`.
  final String name;

  /// Muscle focus / category, e.g. `Beine`.
  final String focus;

  /// Bundled asset path of the looping demo clip,
  /// e.g. `assets/videos/ex_squat.mp4`.
  final String videoAsset;

  /// Short German form cues shown while the exercise is running.
  final List<String> cues;
}
