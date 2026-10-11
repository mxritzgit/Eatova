import '../l10n/l10n.dart';
import '../models/training_plan.dart';
import '../models/training_session.dart';
import 'rest_alerts.dart';

/// The alerts of a running rest or timed set (spec A5): its end under
/// [restAlertIdForSession] and, for a timed set a rest follows, that rest's
/// end under [restAlertFollowUpIdForSession]; the app applies that rest only
/// once it sees the interval end, so a lock during the interval would
/// otherwise miss it. D5: generic texts, no exercise names or weights on the
/// lock screen.
({PlannedRestAlert phase, PlannedRestAlert? followUp}) planRestAlerts({
  required String sessionId,
  required DateTime phaseEndsAt,
  required TrainingSessionPhase phase,
  required TrainingWorkout workout,
  required int exerciseIndex,
  required int setIndex,
  required AppLocalizations l10n,
}) {
  final rest = phase == TrainingSessionPhase.rest;
  final exercise = workout.exercises[exerciseIndex];
  final restFollows =
      !rest &&
      exercise.restSeconds > 0 &&
      !(exerciseIndex == workout.exercises.length - 1 &&
          setIndex == exercise.sets - 1);
  return (
    phase: (
      id: restAlertIdForSession(sessionId),
      at: phaseEndsAt,
      title: rest
          ? l10n.trainingRestAlertTitle
          : l10n.trainingIntervalAlertTitle,
      body: rest
          ? l10n.trainingRestAlertBody
          : restFollows
          ? l10n.trainingIntervalAlertBody
          : l10n.trainingTimerAlertSetDoneBody,
    ),
    followUp: restFollows
        ? (
            id: restAlertFollowUpIdForSession(sessionId),
            at: phaseEndsAt.add(Duration(seconds: exercise.restSeconds)),
            title: l10n.trainingRestAlertTitle,
            body: l10n.trainingRestAlertBody,
          )
        : null,
  );
}

/// [planRestAlerts] for a stored checkpoint: none while it is paused or
/// holds a pending completion.
List<PlannedRestAlert> plannedRestAlertsFor(
  TrainingSessionSnapshot snapshot,
  AppLocalizations l10n,
) {
  final ends = snapshot.phaseEndsAt;
  if (ends == null || snapshot.pendingCompletionAt != null) return const [];
  final planned = planRestAlerts(
    sessionId: snapshot.sessionId,
    phaseEndsAt: ends,
    phase: snapshot.phase,
    workout: snapshot.workout,
    exerciseIndex: snapshot.exerciseIndex,
    setIndex: snapshot.setIndex,
    l10n: l10n,
  );
  return [planned.phase, ?planned.followUp];
}
