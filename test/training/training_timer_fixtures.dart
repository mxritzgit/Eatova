import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';

TrainingPlan timerPlan({
  bool longText = false,
  int duration = 30,
}) => TrainingPlan(
  id: 'timer_test',
  proposal: CoachTrainingProposal(
    title: 'Strength & focus',
    workouts: [
      TrainingWorkout(
        title: 'Full body',
        exercises: [
          TrainingExercise(
            name: longText
                ? 'Langsame kontrollierte Kniebeugen mit bewusster Atmung'
                : 'Hold',
            sets: 2,
            durationSeconds: duration,
            restSeconds: 15,
            notes: longText
                ? 'Bleibe in einer angenehmen Position. Atme ruhig weiter und bewege dich kontrolliert. '
                      'Nutze einen stabilen Untergrund und pausiere bei Bedarf.'
                : 'Breathe steadily.',
          ),
          TrainingExercise(name: 'Squats', sets: 2, reps: 12, restSeconds: 0),
        ],
      ),
      TrainingWorkout(
        title: 'Mobility',
        exercises: [
          TrainingExercise(name: 'Reach', sets: 1, reps: 8, restSeconds: 20),
        ],
      ),
    ],
  ),
);

class TimerTestClock {
  Duration value = Duration.zero;
  Duration now() => value;
  void elapse(Duration duration) => value += duration;
}
