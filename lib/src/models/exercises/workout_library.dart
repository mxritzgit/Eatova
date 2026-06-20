import 'exercise_clip.dart';
import 'workout.dart';

/// Seeded exercise catalogue. Each clip maps to a bundled looping demo video
/// under `assets/videos/` generated as a clean 3D character demonstration.
///
/// Kept as top-level `const` values so workouts can reference them directly.

const ExerciseClip exSquat = ExerciseClip(
  id: 'squat',
  name: 'Kniebeugen',
  focus: 'Beine',
  videoAsset: 'assets/videos/ex_squat.mp4',
  cues: <String>['Brust aufrecht', 'Knie über den Zehen', 'Fersen am Boden'],
);

const ExerciseClip exJumpingJack = ExerciseClip(
  id: 'jumping_jack',
  name: 'Hampelmänner',
  focus: 'Cardio',
  videoAsset: 'assets/videos/ex_jumping_jack.mp4',
  cues: <String>['Locker abspringen', 'Arme ganz nach oben', 'Weich landen'],
);

const ExerciseClip exPushup = ExerciseClip(
  id: 'pushup',
  name: 'Liegestütze',
  focus: 'Oberkörper',
  videoAsset: 'assets/videos/ex_pushup.mp4',
  cues: <String>['Körper in einer Linie', 'Ellbogen leicht eng', 'Kontrolliert absenken'],
);

const ExerciseClip exGluteBridge = ExerciseClip(
  id: 'glute_bridge',
  name: 'Beckenheben',
  focus: 'Po & Core',
  videoAsset: 'assets/videos/ex_glute_bridge.mp4',
  cues: <String>['Po fest anspannen', 'Becken hoch drücken', 'Schultern am Boden'],
);

const ExerciseClip exPlank = ExerciseClip(
  id: 'plank',
  name: 'Unterarmstütz',
  focus: 'Core',
  videoAsset: 'assets/videos/ex_plank.mp4',
  cues: <String>['Bauch fest anspannen', 'Hüfte gerade halten', 'Ruhig weiteratmen'],
);

/// Every seeded exercise clip, in catalogue order.
const List<ExerciseClip> exerciseClipLibrary = <ExerciseClip>[
  exSquat,
  exJumpingJack,
  exPushup,
  exGluteBridge,
  exPlank,
];

/// Guided, video-led workouts shown in the Übungen tab. The final step of each
/// workout carries `restSeconds: 0` so the session ends right after the work
/// phase instead of a trailing rest.
const List<Workout> guidedWorkouts = <Workout>[
  Workout(
    id: 'full_body_express',
    title: 'Ganzkörper Express',
    subtitle: '5 Übungen · ca. 5 Min · ohne Geräte',
    steps: <WorkoutStep>[
      WorkoutStep(clip: exSquat),
      WorkoutStep(clip: exJumpingJack),
      WorkoutStep(clip: exPushup),
      WorkoutStep(clip: exGluteBridge),
      WorkoutStep(clip: exPlank, restSeconds: 0),
    ],
  ),
  Workout(
    id: 'core_cardio',
    title: 'Core & Cardio',
    subtitle: '4 Übungen · ca. 4 Min · ohne Geräte',
    steps: <WorkoutStep>[
      WorkoutStep(clip: exJumpingJack),
      WorkoutStep(clip: exPlank),
      WorkoutStep(clip: exGluteBridge),
      WorkoutStep(clip: exSquat, restSeconds: 0),
    ],
  ),
];

/// Look up a workout by its [Workout.id], or return `null` if unknown.
Workout? workoutById(String id) {
  for (final Workout w in guidedWorkouts) {
    if (w.id == id) return w;
  }
  return null;
}
