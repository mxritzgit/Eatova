part of 'coach_chat_screen.dart';

/// A generated plan stays a draft until the review sheet confirms adoption.
class _TrainingPlanProposalCard extends StatelessWidget {
  const _TrainingPlanProposalCard({
    required this.proposal,
    required this.added,
    required this.enabled,
    this.onReview,
    this.onOpenTraining,
  });

  final CoachTrainingProposal proposal;
  final bool added;
  final bool enabled;
  final VoidCallback? onReview;
  final VoidCallback? onOpenTraining;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final exerciseCount = proposal.workouts.fold<int>(
      0,
      (count, workout) => count + workout.exercises.length,
    );
    return Column(
      key: const ValueKey('coach-plan-card'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.fitness_center_rounded, size: 18, color: t.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                added ? l10n.coachPlanAddedLabel : l10n.coachPlanCardEyebrow,
                style: AppType.ui(12, weight: FontWeight.w600, color: t.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          proposal.title,
          style: AppType.display(20, color: t.ink, height: 1.15),
        ),
        if (proposal.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            proposal.description,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          l10n.coachPlanCounts(proposal.workouts.length, exerciseCount),
          style: AppType.ui(14, color: t.ink2, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (added)
          Semantics(
            liveRegion: true,
            child: onOpenTraining == null
                ? Icon(Icons.check_circle_rounded, color: t.accent, size: 22)
                : TextButton.icon(
                    key: const ValueKey('coach-plan-open-training'),
                    onPressed: onOpenTraining,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.centerLeft,
                    ),
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    label: Text(l10n.coachPlanOpenTraining),
                  ),
          )
        else
          PrimaryActionButton(
            key: const ValueKey('coach-plan-review'),
            label: l10n.coachPlanReviewButton,
            icon: Icons.arrow_forward_rounded,
            onTap: enabled ? onReview : null,
          ),
      ],
    );
  }
}
