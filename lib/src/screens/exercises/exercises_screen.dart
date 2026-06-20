import 'package:flutter/material.dart';

import '../../models/exercises/workout.dart';
import '../../models/exercises/workout_library.dart';
import '../../theme/app_colors.dart';
import '../../widgets/exercises/exercise_interval_player.dart';
import 'workout_card.dart';

/// Übungen tab body: a short header plus one tappable card per guided workout.
///
/// Rendered inside the home page's outer [SingleChildScrollView]
/// (padding `EdgeInsets.fromLTRB(20, 12, 20, 24)`), so this returns
/// shrink-wrapped content — a [Column] with `mainAxisSize: MainAxisSize.min` —
/// and never a Scaffold, AppBar or unbounded scrollable of its own.
class ExercisesScreen extends StatelessWidget {
  const ExercisesScreen({super.key});

  void _startWorkout(BuildContext context, Workout workout) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExerciseIntervalPlayer(workout: workout),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('screen-exercises'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 4),
        const Text(
          'Übungen',
          style: TextStyle(
            color: textPrimary,
            fontSize: 30,
            height: 1.08,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Geführte Workouts mit Video-Anleitung — leg sofort los.',
          style: TextStyle(
            color: textMuted,
            fontSize: 13,
            height: 1.45,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 20),
        for (final Workout workout in guidedWorkouts) ...<Widget>[
          WorkoutCard(
            workout: workout,
            onTap: () => _startWorkout(context, workout),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}
