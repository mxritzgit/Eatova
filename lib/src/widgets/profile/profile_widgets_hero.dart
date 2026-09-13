part of 'profile_widgets.dart';

/// Real identity and profile choices, with no synthetic membership badges.
class IdentityCard extends StatelessWidget {
  const IdentityCard({super.key, required this.name, required this.profile});

  final String name;
  final UserProfile profile;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return '${parts.first.characters.first}${parts.last.characters.first}'
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('profile-studio-identity'),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: t.forest,
        borderRadius: BorderRadius.circular(rHero),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.profileStudioOverview,
                  style: AppType.ui(
                    13,
                    weight: FontWeight.w600,
                    color: t.onForest,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.lime,
                    shape: BoxShape.circle,
                  ),
                  child: _initials.isEmpty
                      ? Icon(Icons.person_outline, color: t.onLime)
                      : Padding(
                          padding: const EdgeInsets.all(10),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _initials,
                              style: AppType.display(20, color: t.onLime),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            name,
            style: AppType.display(
              MediaQuery.textScalerOf(context).scale(16) > 24 ? 20 : 30,
              color: t.onForest,
              height: 1.12,
            ),
          ),
          const SizedBox(height: 22),
          Divider(height: 1, color: t.onForest.withValues(alpha: 0.18)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              _IdentityValue(
                label: l10n.profileStudioFocus,
                value: profile.weightGoal.label(l10n),
              ),
              _IdentityValue(
                label: l10n.profileStudioActivity,
                value: profile.activityLevel.label(l10n),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IdentityValue extends StatelessWidget {
  const _IdentityValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppType.ui(11, color: context.t.onForest)),
      const SizedBox(height: 5),
      Text(
        value,
        style: AppType.ui(
          13,
          weight: FontWeight.w600,
          color: context.t.onForest,
        ),
      ),
    ],
  );
}

/// Goal overview: current weight → target weight, pace (kg/week), daily goal
/// and a rough time forecast.
///
/// Class name and constructor signature are API: `profile_hero_pace_test`
/// builds the card directly and pins five sentences character-exactly.
class GoalPlanCard extends StatelessWidget {
  const GoalPlanCard({super.key, required this.profile, this.onEdit});

  final UserProfile profile;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The card draws the PLAN, so it reads the effective goal (P9-08d): a
    // direction the two weights no longer support is "hold" here — for every
    // stored row, from the first read on and without rewriting the intent the
    // user picked. Without it the card kept titling "80 → 90" as "Abnehmen".
    final goal = profile.effectiveWeightGoal;
    final isMaintain = goal == WeightGoal.maintain;
    final gap = (profile.weightKg - profile.targetWeightKg).abs();
    // B2: with a concrete profile the card must show the EFFECTIVE result, not
    // the requested pace — the 1 % cap can turn a chosen −1 kg/week into
    // −0.75 kg/week. Compute targets once and pass them on, otherwise
    // calculate() runs twice and the card could mix two results.
    final targets = const KcalCalculator().calculate(profile);
    // Range linear…dynamic (Kcal review 2026-08-21), see
    // KcalCalculator.weeksToGoalRange.
    final weeks = profile.manualEnergy
        ? null
        : const KcalCalculator().weeksToGoalRange(profile, targets: targets);
    // Ready-made sentence from KcalTargets, else null.
    final paceWarning = isMaintain || profile.manualEnergy
        ? null
        : targets.paceWarning(l10n);
    // Manual goals keep their own kcal: automatic pace and forecast no longer
    // describe this plan. Match the rate shown on the goals screen.
    final pace = profile.manualEnergy
        ? paceLabelForWeeklyRateKg(
            (profile.dailyKcalGoal - targets.maintenanceKcal) *
                7 /
                kcalPerKgBodyMass,
            l10n,
          )
        : isMaintain
            ? l10n.profileStable
            : targets.effectivePaceLabel(l10n);
    // A directional goal carries the brand accent, "maintain" stays quiet.
    final accent = isMaintain ? t.ink2 : t.accent;

    return _ProfileSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(
                // The arrow follows the two numbers below it (P9-08c) — it drew
                // "80 → 90" under `trending_down` while it read the stored
                // goal. Since `goal` is the effective one the two can no longer
                // disagree; the read stays direct because these are the numbers
                // right under the icon. `targetPointsUp` is null only when both
                // weights are equal; the goal decides then.
                icon: isMaintain
                    ? Icons.trending_flat_rounded
                    : (profile.targetPointsUp ?? goal.isGain)
                        ? Icons.trending_up_rounded
                        : Icons.trending_down_rounded,
                color: accent,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.profileGoalPlanTitle,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      goal.label(l10n),
                      style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
                    ),
                  ],
                ),
              ),
              if (onEdit != null)
                // A11y: full 48 px tap area (not compact), glyph stays 18.
                IconButton(
                  key: const ValueKey('profile-goalplan-edit'),
                  onPressed: onEdit,
                  tooltip: l10n.profileGoalPlanEditTooltip,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  color: accent,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: _WeightPole(
                  label: l10n.profileWeightPoleCurrent,
                  value: '${profile.weightKg}',
                  color: t.ink,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: accent,
                  size: 22,
                ),
              ),
              Expanded(
                child: _WeightPole(
                  label: isMaintain
                      ? l10n.profileWeightPoleHold
                      : l10n.profileWeightPoleTarget,
                  value: '${profile.targetWeightKg}',
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                // paceWarning is not a separate text block here: the settings
                // sheet (W3-04) already shows it, and repeating the three-liner
                // would swamp the two-chip row. As a tooltip/semantics on the
                // pace chip it explains the number on demand.
                child: _MaybeTooltip(
                  message: paceWarning,
                  child: _PlanChip(
                    icon: Icons.speed_rounded,
                    label: l10n.profilePlanChipPace,
                    value: pace,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PlanChip(
                  icon: Icons.local_fire_department_rounded,
                  label: l10n.profilePlanChipDailyGoal,
                  value: '${profile.dailyKcalGoal} kcal',
                  color: t.ink,
                ),
              ),
            ],
          ),
          if (!isMaintain && gap > 0) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: t.tile,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.flag_rounded, color: accent, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      weeks != null
                          ? goalProgressWeeksText(l10n, gap: gap, weeks: weeks)
                          : l10n.profileGoalProgressNoWeeks(gap),
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w600,
                        color: t.ink,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Attaches [message] as a tooltip to [child], or passes [child] through.
/// Avoids an empty `Tooltip`, which would swallow long-press and announce a
/// description that does not exist.
class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) return child;
    return Tooltip(message: text, child: child);
  }
}

class _WeightPole extends StatelessWidget {
  const _WeightPole({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      children: <Widget>[
        Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 10.5)),
        const SizedBox(height: 4),
        // FittedBox: the big number grows with the system font, the half card
        // width does not.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                value,
                style: AppType.display(30, color: color, height: 1),
              ),
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  'kg',
                  style:
                      AppType.ui(12, weight: FontWeight.w700, color: t.ink2),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style:
                      AppType.ui(10.5, weight: FontWeight.w600, color: t.ink2),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: AppType.ui(13, weight: FontWeight.w700, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
