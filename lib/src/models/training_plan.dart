import 'coach_training_proposal.dart';
import 'training_limits.dart';
import 'training_workout.dart';

export 'training_limits.dart' show TrainingLimits;
export 'training_workout.dart';

/// An adopted or manually created plan. Ownership is set only by the store.
final class TrainingPlan {
  TrainingPlan({required String id, required this.proposal})
    : id = TrainingJson.id(id);

  final String id;
  final CoachTrainingProposal proposal;

  String get title => proposal.title;
  String get description => proposal.description;
  String get goal => proposal.goal;
  List<TrainingWorkout> get workouts => proposal.workouts;
  int get estimatedDurationSeconds => proposal.estimatedDurationSeconds;

  /// Local cache and outbox envelopes carry no client-supplied owner.
  factory TrainingPlan.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {'id', 'plan'});
    return TrainingPlan.fromRow(json);
  }

  factory TrainingPlan.fromRow(Map<dynamic, dynamic> row) {
    final id = TrainingJson.id(row['id']);
    final rawPlan = row['plan'];
    if (rawPlan is! Map) {
      throw const FormatException('Invalid training plan');
    }
    final proposal = CoachTrainingProposal.fromJson(rawPlan);
    if (proposal == null) {
      throw const FormatException('Invalid training plan');
    }
    return proposal.toTrainingPlan(id: id);
  }

  Map<String, dynamic> toJson() => {'id': id, 'plan': proposal.toJson()};

  Map<String, dynamic> toRow() => toJson();

  TrainingPlan copyWith({CoachTrainingProposal? proposal}) =>
      TrainingPlan(id: id, proposal: proposal ?? this.proposal);
}

/// Idempotent adoption across double taps, app restarts, and sync retries.
String trainingPlanIdForMessage(String messageId) =>
    TrainingJson.id('coach_${TrainingJson.id(messageId)}');
