part of 'profile_widgets.dart';

/// The profile's hero: avatar, name and the two real profile choices (goal,
/// routine), with the logging streak and record under a hairline when the
/// screen passes them in.
///
/// Real data only: no membership badge and no "member since" — the account
/// has neither (pinned by `profile_screen_design_test`).
class IdentityCard extends StatelessWidget {
  const IdentityCard({
    super.key,
    required this.name,
    required this.profile,
    this.stats,
  });

  final String name;
  final UserProfile profile;

  /// The streak row under the hairline (a [ProfileStatRow]); none without.
  final Widget? stats;

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
    // Large system text: the avatar moves above the name so the name keeps
    // the full card width (surname on one line at 2.0 on a 320 px phone).
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final nameText = Text(
      name,
      style: AppType.display(
        large ? 20 : 26,
        weight: FontWeight.w700,
        color: t.ink,
        height: 1.12,
        letterSpacing: large ? null : -0.5,
      ),
    );
    final pills = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _IdentityPill(
          icon: Icons.flag_rounded,
          label: l10n.profileStudioFocus,
          value: profile.weightGoal.label(l10n),
        ),
        _IdentityPill(
          icon: Icons.directions_walk_rounded,
          label: l10n.profileStudioActivity,
          value: profile.activityLevel.label(l10n),
        ),
      ],
    );
    final identity = large
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _HeroAvatar(initials: _initials, size: 56),
              const SizedBox(height: 14),
              nameText,
              const SizedBox(height: 12),
              pills,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _HeroAvatar(initials: _initials, size: 64),
                  const SizedBox(width: 16),
                  Expanded(child: nameText),
                ],
              ),
              const SizedBox(height: 16),
              pills,
            ],
          );

    return Container(
      key: const ValueKey('profile-studio-identity'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rHero),
        border: Border.all(color: t.cardBorder),
      ),
      child: Stack(
        children: <Widget>[
          // The redesign's violet glow (as behind the Today arc), anchored
          // behind the avatar.
          Positioned(
            top: -90,
            left: -70,
            width: 300,
            height: 260,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: <Color>[
                      t.arcStart.withValues(alpha: 0.24),
                      t.arcStart.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                identity,
                if (stats != null) ...<Widget>[
                  const SizedBox(height: 18),
                  Divider(height: 1, thickness: 1, color: t.line),
                  const SizedBox(height: 16),
                  stats!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The initials in a circle with the accent ring — the large twin of the
/// Today header's avatar that opens this page.
class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({required this.initials, required this.size});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.surf2,
          shape: BoxShape.circle,
          border: Border.all(
            color: t.accent.withValues(alpha: 0.55),
            width: 2,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: t.accentGlow.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: initials.isEmpty
            ? Icon(Icons.person_outline_rounded, color: t.inkSoft)
            // Fixed circle, so the letters do not follow the system font.
            : Text(
                initials,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: AppType.display(
                  size * 0.36,
                  weight: FontWeight.w700,
                  color: t.inkSoft,
                  letterSpacing: -0.5,
                ),
              ),
      ),
    );
  }
}

/// One profile choice as a quiet capsule; the screen reader hears its field
/// name ("Your goal") before the value.
class _IdentityPill extends StatelessWidget {
  const _IdentityPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      container: true,
      label: label,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 6, 12, 6),
        decoration: BoxDecoration(
          color: t.surf2,
          borderRadius: BorderRadius.circular(rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: t.accentText),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                value,
                style: AppType.ui(
                  12.5,
                  weight: FontWeight.w600,
                  color: t.inkSoft,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Goal overview: current weight → target weight, pace (kg/week), daily goal
/// and a rough time forecast.
///
/// Class name and constructor signature are API: `profile_hero_pace_test`
/// builds the card directly and pins five sentences character-exactly.
class GoalPlanCard extends StatelessWidget {
  const GoalPlanCard({
    super.key,
    required this.profile,
    this.onEdit,
    this.currentWeightKg,
  });

  final UserProfile profile;
  final VoidCallback? onEdit;

  /// The plan weight ([WeightLog.planWeightKg]) for the "current" pole; null
  /// without a fresh, in-range trend, when the profile weight stands in.
  final double? currentWeightKg;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The plan follows the weight trend (docs/WEIGHT-TREND.md). The store
    // re-anchors the profile to it; deriving the card from the same weight
    // keeps pole, gap and forecast consistent until it has.
    final trendKg = currentWeightKg?.round();
    final plan = trendKg == null ? profile : profile.copyWith(weightKg: trendKg);
    // The card draws the PLAN, so it reads the effective goal (P9-08d): a
    // direction the two weights no longer support is "hold" here — for every
    // stored row, from the first read on and without rewriting the intent the
    // user picked. Without it the card kept titling "80 → 90" as "Abnehmen".
    final goal = plan.effectiveWeightGoal;
    final isMaintain = goal == WeightGoal.maintain;
    final gap = (plan.weightKg - plan.targetWeightKg).abs();
    // B2: with a concrete profile the card must show the EFFECTIVE result, not
    // the requested pace — the 1 % cap can turn a chosen −1 kg/week into
    // −0.75 kg/week. Compute targets once and pass them on, otherwise
    // calculate() runs twice and the card could mix two results.
    final targets = const KcalCalculator().calculate(plan);
    // Range linear…dynamic (Kcal review 2026-08-21), see
    // KcalCalculator.weeksToGoalRange.
    final weeks = plan.manualEnergy
        ? null
        : const KcalCalculator().weeksToGoalRange(plan, targets: targets);
    // Ready-made sentence from KcalTargets, else null.
    final paceWarning = isMaintain || plan.manualEnergy
        ? null
        : targets.paceWarning(l10n);
    // Manual goals keep their own kcal: automatic pace and forecast no longer
    // describe this plan. Match the rate shown on the goals screen.
    final pace = plan.manualEnergy
        ? paceLabelForWeeklyRateKg(
            (plan.dailyKcalGoal - targets.maintenanceKcal) *
                7 /
                kcalPerKgBodyMass,
            l10n,
          )
        : isMaintain
            ? l10n.profileStable
            : targets.effectivePaceLabel(l10n);
    // A directional goal carries the brand accent, "maintain" stays quiet.
    final accent = isMaintain ? t.ink2 : t.accent;
    final accentInk = isMaintain ? t.inkSoft : t.accentText;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    : (plan.targetPointsUp ?? goal.isGain)
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
                    const SizedBox(height: 2),
                    Text(
                      goal.label(l10n),
                      style: AppType.ui(
                        12.5,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
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
                  color: accentInk,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: _WeightPole(
                    label: l10n.profileWeightPoleCurrent,
                    value: currentWeightKg == null
                        ? '${plan.weightKg}'
                        : formatKgDe(currentWeightKg!, l10n),
                    color: t.ink,
                    alignment: CrossAxisAlignment.start,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: _JourneyArrow(color: accent),
                ),
                Expanded(
                  child: _WeightPole(
                    label: isMaintain
                        ? l10n.profileWeightPoleHold
                        : l10n.profileWeightPoleTarget,
                    value: '${plan.targetWeightKg}',
                    color: accentInk,
                    alignment: CrossAxisAlignment.end,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Divider(height: 1, thickness: 1, color: t.line),
          ),
          // paceWarning is not a separate text block here: the settings sheet
          // (W3-04) already shows it, and repeating the three-liner would
          // swamp the card. As a tooltip/semantics on the pace row it
          // explains the number on demand.
          _MaybeTooltip(
            message: paceWarning,
            child: _PlanRow(
              icon: Icons.speed_rounded,
              label: l10n.profilePlanChipPace,
              value: pace,
              valueColor: accentInk,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 8),
            child: Divider(height: 1, thickness: 1, color: t.line),
          ),
          _PlanRow(
            icon: Icons.local_fire_department_rounded,
            label: l10n.profilePlanChipDailyGoal,
            value: '${plan.dailyKcalGoal} kcal',
            valueColor: t.ink,
          ),
          if (!isMaintain && gap > 0) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: t.accentTint,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.flag_rounded, color: t.accentText, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        weeks != null
                            ? goalProgressWeeksText(
                                l10n,
                                gap: gap,
                                weeks: weeks,
                              )
                            : l10n.profileGoalProgressNoWeeks(gap),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w600,
                          color: t.inkSoft,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
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

/// One end of the weight journey: eyebrow over a large number with "kg".
class _WeightPole extends StatelessWidget {
  const _WeightPole({
    required this.label,
    required this.value,
    required this.color,
    required this.alignment,
  });

  final String label;
  final String value;
  final Color color;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: alignment,
      children: <Widget>[
        Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 10.5)),
        const SizedBox(height: 6),
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
                style: AppType.display(
                  36,
                  weight: FontWeight.w700,
                  color: color,
                  height: 1,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'kg',
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The track between the two weights: a faint line ending in an arrow chip.
class _JourneyArrow extends StatelessWidget {
  const _JourneyArrow({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: SizedBox(
        width: 56,
        height: 28,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  gradient: LinearGradient(
                    colors: <Color>[t.tile, color.withValues(alpha: 0.6)],
                  ),
                ),
              ),
            ),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: t.readableOnTint(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plan figure as a row: icon, label, value right-aligned.
class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 13, 8, 13),
      child: Row(
        children: <Widget>[
          Icon(icon, color: t.ink2, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: _SpreadRow(
              start: Text(
                label,
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w500,
                  color: t.ink2,
                ),
              ),
              end: Text(
                value,
                textAlign: TextAlign.right,
                style: AppType.ui(
                  14.5,
                  weight: FontWeight.w700,
                  color: valueColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
