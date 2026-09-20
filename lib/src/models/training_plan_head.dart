import 'training_plan.dart';

/// The permanent generation marker for a coach proposal, including deletion.
class TrainingPlanHead {
  const TrainingPlanHead({
    required this.sourceId,
    required this.planId,
    required this.incarnation,
    required this.deleted,
    this.plan,
  });

  final String sourceId;
  final String planId;
  final int incarnation;
  final bool deleted;
  final TrainingPlan? plan;

  factory TrainingPlanHead.fromJson(Map<dynamic, dynamic> json) {
    final source = json['source_id'];
    final id = json['plan_id'];
    final incarnation = json['incarnation'];
    final deleted = json['deleted'];
    final row = json['plan'];
    if (source is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,94}$').hasMatch(source) ||
        id != trainingPlanIdForMessage(source) ||
        incarnation is! int ||
        incarnation < 0 ||
        incarnation > 2147483647 ||
        deleted is! bool ||
        (row != null && row is! Map)) {
      throw const FormatException('Invalid training source head');
    }
    final plan = row == null ? null : TrainingPlan.fromRow(row as Map);
    if (plan != null &&
        (deleted ||
            plan.id != id ||
            plan.coachSourceId != source ||
            plan.incarnation != incarnation)) {
      throw const FormatException('Mismatched training source head');
    }
    return TrainingPlanHead(
      sourceId: source,
      planId: id as String,
      incarnation: incarnation,
      deleted: deleted,
      plan: plan,
    );
  }

  Map<String, dynamic> toJson() => {
    'source_id': sourceId,
    'plan_id': planId,
    'incarnation': incarnation,
    'deleted': deleted,
    'plan': plan?.toJson(),
  };
}

enum TrainingMutationOutcome { applied, headConflict, deleted }

class TrainingMutationResult {
  const TrainingMutationResult({
    required this.outcome,
    required this.incarnation,
  });
  final TrainingMutationOutcome outcome;
  final int incarnation;

  factory TrainingMutationResult.fromJson(Map<dynamic, dynamic> json) {
    final matches = TrainingMutationOutcome.values.where(
      (v) => v.name == json['outcome'],
    );
    final incarnation = json['incarnation'];
    if (matches.isEmpty ||
        incarnation is! int ||
        incarnation < 0 ||
        incarnation > 2147483647) {
      throw const FormatException('Invalid training mutation result');
    }
    return TrainingMutationResult(
      outcome: matches.single,
      incarnation: incarnation,
    );
  }
}
