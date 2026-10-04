import 'package:eatova/src/models/coach_training_context.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:flutter_test/flutter_test.dart';

CoachTrainingProposal _plan({String notes = ''}) => CoachTrainingProposal(
  title: 'Saved plan',
  workouts: [
    TrainingWorkout(
      title: 'A',
      exercises: [
        TrainingExercise(
          name: 'Squat',
          sets: 3,
          reps: 8,
          restSeconds: 60,
          notes: notes,
        ),
      ],
    ),
  ],
);

Map<String, dynamic> _brief() => {
  'schema_version': 1,
  'intent': 'create',
  'goal': 'Strength',
  'experience': 'beginner',
  'equipment': 'bodyweight',
  'sessions_per_week': 3,
  'minutes_per_session': 30,
  'selected_plan': null,
};

CoachTrainingContext _context({
  CoachTrainingIntent intent = CoachTrainingIntent.create,
  String goal = 'Strength',
  int sessionsPerWeek = 3,
  int minutesPerSession = 30,
  CoachTrainingProposal? selectedPlan,
}) => CoachTrainingContext(
  intent: intent,
  goal: goal,
  experience: CoachTrainingExperience.beginner,
  equipment: CoachTrainingEquipment.bodyweight,
  sessionsPerWeek: sessionsPerWeek,
  minutesPerSession: minutesPerSession,
  selectedPlan: selectedPlan,
);

void main() {
  test('brief carries only explicit data and a validated plan snapshot', () {
    for (final intent in [
      CoachTrainingIntent.adapt,
      CoachTrainingIntent.discuss,
    ]) {
      final brief = _context(intent: intent, selectedPlan: _plan());
      expect(
        brief.toJson(),
        _brief()
          ..addAll({'intent': intent.name, 'selected_plan': _plan().toJson()}),
      );
      expect(brief.selectedPlan!.workouts.single.exercises.single.reps, 8);
    }
    expect(_context().toJson(), _brief());
  });

  test('brief rejects malformed numbers, controls and inconsistent plans', () {
    final bad = <CoachTrainingContext Function()>[
      () => _context(intent: CoachTrainingIntent.adapt),
      () => _context(intent: CoachTrainingIntent.discuss),
      () => _context(selectedPlan: _plan()),
      () => _context(goal: 'x' * 201),
      () => _context(goal: '\u0085'),
      () => _context(goal: 'a\u0000b'),
      () => _context(goal: '\ud800'),
      () => _context(goal: 'a\u007fb'),
      for (final value in [0, 8]) () => _context(sessionsPerWeek: value),
      for (final value in [9, 181]) () => _context(minutesPerSession: value),
      () => _context(
        intent: CoachTrainingIntent.adapt,
        selectedPlan: _plan(notes: 'a\u007fb'),
      ),
    ];
    for (final build in bad) {
      expect(build, throwsFormatException);
    }
  });
}
