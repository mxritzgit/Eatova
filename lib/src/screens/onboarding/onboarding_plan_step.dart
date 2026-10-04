import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/target_bmi_hint.dart';
import 'onboarding_chrome.dart';
import 'onboarding_models.dart';

// ---------------------------------------------------------------------------
// The plan reveal: the payoff of the questions.
//
//   hero       daily kcal (counting from maintenance to the target, so a
//              deficit is SEEN) and the three macros, in the Goals hero's
//              language: `surf`, the violet glow, the macro tones on dots only
//   path       today's weight -> target, the forecast, the target BMI hint
//   warning    when a safety limit changed the chosen pace
//   breakdown  BMR -> maintenance -> goal delta: the card adds up
//   answers    one row per answer; a tap reopens that question
// ---------------------------------------------------------------------------

/// One answer on the plan, reopening [step] when tapped.
@immutable
class OnboardingReviewItem {
  const OnboardingReviewItem(this.step, this.label, this.value);

  final OnboardingStep step;
  final String label;
  final String value;
}

class OnboardingPlanStep extends StatelessWidget {
  const OnboardingPlanStep({
    super.key,
    required this.firstName,
    required this.profile,
    required this.targets,
    required this.countFrom,
    required this.answers,
    required this.onEdit,
  });

  final String firstName;

  /// The draft the plan was computed from.
  final UserProfile profile;

  /// Computed from exactly [profile]; passed through instead of running the
  /// calculator a second time.
  final KcalTargets targets;

  /// Where the daily target starts counting (the number shown before).
  final int countFrom;
  final List<OnboardingReviewItem> answers;
  final ValueChanged<OnboardingStep> onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    // The EFFECTIVE goal, like the breakdown's goal row (which shows
    // `targets.effectivePaceLabel`): a direction with no reachable target
    // plans maintain, and the path card shows no second pole then.
    final goal = profile.effectiveWeightGoal;
    final timeline = onboardingTimelineText(l10n, profile, targets);
    // Computed once: the same string drives the text AND its visibility.
    final paceWarning = targets.paceWarning(l10n);

    return LivelyStaggerScope(
      child: OnboardingStepFrame(
        eyebrow: OnboardingStep.summary.phaseLabel(l10n),
        title: l10n.onboardingSummaryTitle(firstName),
        subtitle: l10n.onboardingSummarySubtitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: livelyStagger(<Widget>[
            _PlanHero(targets: targets, countFrom: countFrom),
            const SizedBox(height: 12),
            _PathCard(profile: profile, goal: goal, timeline: timeline),
            if (paceWarning != null) ...<Widget>[
              const SizedBox(height: 12),
              _WarningNote(paceWarning),
            ],
            const SizedBox(height: 26),
            _Breakdown(targets: targets, profile: profile),
            const SizedBox(height: 26),
            _Answers(items: answers, onEdit: onEdit),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                l10n.onboardingSummaryFootnote,
                style: AppType.ui(12.5, color: t.ink2, height: 1.45),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The card frame of the plan: `surf`, the faint card edge.
BoxDecoration _cardDecoration(AppTokens t, {double radius = rCard}) =>
    BoxDecoration(
      color: t.surf,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: t.cardBorder),
    );

class _PlanHero extends StatelessWidget {
  const _PlanHero({required this.targets, required this.countFrom});

  final KcalTargets targets;
  final int countFrom;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final eyebrow = l10n.onboardingSummaryKcalEyebrow;
    // The number is large text already; past 1.5x it would push the unit off
    // a narrow phone without adding legibility (as on the Goals hero).
    final numberScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.5);
    return Container(
      key: const ValueKey('onboarding-plan-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: _cardDecoration(t, radius: rHero),
      child: Stack(
        children: <Widget>[
          // The Today hero's violet glow, pulled behind the number.
          Positioned(
            top: -90,
            right: -70,
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        eyebrow.toUpperCase(),
                        semanticsLabel: eyebrow,
                        style: AppType.sectionEyebrow(t.accentText),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ExcludeSemantics(
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: t.accentTint,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.calculate_outlined,
                          size: 17,
                          color: t.accentText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                MergeSemantics(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: 8,
                    children: <Widget>[
                      CountingText(
                        value: targets.kcal.toDouble(),
                        from: countFrom.toDouble(),
                        format: (v) => '${v.round()}',
                        textKey: const ValueKey('onboarding-summary-kcal'),
                        maxLines: 1,
                        textScaler: numberScaler,
                        style: AppType.display(60, color: t.ink, height: 1),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          l10n.commonKcalUnit,
                          style: AppType.ui(
                            16,
                            weight: FontWeight.w700,
                            color: t.ink2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Divider(height: 1, thickness: 1, color: t.line),
                const SizedBox(height: 16),
                _MacroRow(
                  tiles: <_MacroTile>[
                    _MacroTile(
                      label: l10n.todayMacroProtein,
                      grams: targets.proteinG,
                      color: t.protein,
                    ),
                    _MacroTile(
                      label: l10n.foodMacroTileCarbsLabel,
                      grams: targets.carbsG,
                      color: t.carbs,
                    ),
                    _MacroTile(
                      label: l10n.todayMacroFat,
                      grams: targets.fatG,
                      color: t.fat,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The three macro columns; each reserves its width from the text scaler and
/// the row becomes one line per macro instead of shrinking the text (F8-09).
class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.tiles});

  final List<_MacroTile> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        // 88 px holds "Kohlenhydrate" over "240 g" at 1.0 in a third.
        final minTile = MediaQuery.textScalerOf(context).scale(88);
        final perRow = ((constraints.maxWidth + gap) / (minTile + gap))
            .floor()
            .clamp(1, 3);
        if (perRow < 3) {
          return Column(
            children: <Widget>[
              for (var i = 0; i < tiles.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                tiles[i].asLine(context),
              ],
            ],
          );
        }
        final width = (constraints.maxWidth - gap * 2) / 3;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var i = 0; i < tiles.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: gap),
              SizedBox(width: width, child: tiles[i]),
            ],
          ],
        );
      },
    );
  }
}

class _MacroTile extends StatelessWidget {
  const _MacroTile({
    required this.label,
    required this.grams,
    required this.color,
  });

  final String label;
  final int grams;

  /// Macro tone for the MARKER only, never for text: on `surf` in light mode
  /// `carbs` reaches 3.39:1 and `fat` 3.73:1 — enough for a graphic (WCAG
  /// 1.4.11), short of text (4.5:1).
  final Color color;

  Widget _dot() => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _amount(BuildContext context) {
    final t = context.t;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '$grams',
            style: AppType.display(22, weight: FontWeight.w800, color: t.ink),
          ),
          TextSpan(
            text: ' ${context.l10n.commonUnitG}',
            style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
      maxLines: 1,
    );
  }

  /// One line per macro for large text sizes.
  Widget asLine(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: Row(
        children: <Widget>[
          _dot(),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
            ),
          ),
          const SizedBox(width: 10),
          _amount(context),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // One spoken unit per macro: "Protein, 131 g".
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _dot(),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _amount(context),
        ],
      ),
    );
  }
}

/// Today's weight to the target, with the forecast sentence. A maintaining
/// plan has no second pole and shows the sentence alone.
class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.profile,
    required this.goal,
    required this.timeline,
  });

  final UserProfile profile;
  final WeightGoal goal;
  final String timeline;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final directional = goal != WeightGoal.maintain;
    final kg = l10n.commonUnitKg;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: _cardDecoration(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (directional) ...<Widget>[
            _Poles(
              from: _Pole(
                label: l10n.onboardingPlanPathNow,
                value: '${profile.weightKg} $kg',
              ),
              to: _Pole(
                label: l10n.onboardingPlanPathGoal,
                value: '${profile.targetWeightKg} $kg',
                accent: true,
              ),
            ),
            const SizedBox(height: 16),
            Divider(height: 1, thickness: 1, color: t.line),
            const SizedBox(height: 14),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: ExcludeSemantics(
                  child: Icon(
                    directional ? Icons.flag_outlined : Icons.balance_rounded,
                    size: 18,
                    color: t.accentText,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  timeline,
                  key: const ValueKey('onboarding-summary-timeline'),
                  style: AppType.ui(
                    14,
                    weight: FontWeight.w600,
                    color: t.ink,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (directional)
            TargetBmiHint(
              margin: const EdgeInsets.only(top: 14),
              heightCm: profile.heightCm,
              targetWeightKg: profile.targetWeightKg,
            ),
        ],
      ),
    );
  }
}

class _Pole {
  const _Pole({required this.label, required this.value, this.accent = false});

  final String label;
  final String value;
  final bool accent;
}

/// "Today 82 kg -> Goal 76 kg", side by side, or as two lines once the
/// numbers would not fit half the card at the current text size.
class _Poles extends StatelessWidget {
  const _Poles({required this.from, required this.to});

  final _Pole from;
  final _Pole to;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scaler = MediaQuery.textScalerOf(context);
    Widget label(_Pole pole) => Text(
      pole.label.toUpperCase(),
      semanticsLabel: pole.label,
      style: AppType.sectionEyebrow(t.ink2, size: 11),
    );
    Widget value(_Pole pole) => Text(
      pole.value,
      style: AppType.display(26, color: pole.accent ? t.accentText : t.ink),
    );
    final arrow = ExcludeSemantics(
      child: Icon(Icons.arrow_forward_rounded, size: 22, color: t.ink3),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two "300 kg" at 26 px plus the arrow need ~240 px at 1.0.
        if (scaler.scale(240) > constraints.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final pole in <_Pole>[from, to])
                MergeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Wrap(
                      spacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[label(pole), value(pole)],
                    ),
                  ),
                ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    label(from),
                    const SizedBox(height: 4),
                    value(from),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: arrow,
            ),
            Expanded(
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    label(to),
                    const SizedBox(height: 4),
                    value(to),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Why the plan differs from the chosen pace. Signal-banner contract
/// (hell_modus_audit_test): tone at 10 % as fill, the glyph in the tone, the
/// text in `ink`.
class _WarningNote extends StatelessWidget {
  const _WarningNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: t.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: t.warning.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.health_and_safety_outlined, size: 18, color: t.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('onboarding-summary-pace-warning'),
              style: AppType.ui(
                13,
                weight: FontWeight.w500,
                color: t.ink,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// BMR, maintenance and the goal delta: the plan, not the wish (B2). The goal
/// row reads the EFFECTIVE pace, so maintenance − target = delta holds.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.targets, required this.profile});

  final KcalTargets targets;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final unit = l10n.commonKcalUnit;
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Divider(height: 1, thickness: 1, color: t.line),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OnboardingSectionLabel(l10n.onboardingPlanBreakdownTitle),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: _cardDecoration(t),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _BreakdownRow(
                label: l10n.onboardingSummaryBmrLabel,
                value: '${targets.bmr} $unit',
              ),
              divider(),
              _BreakdownRow(
                label: l10n.onboardingSummaryMaintenanceLabel(
                  profile.activityLevel.label(l10n),
                ),
                value: '${targets.maintenanceKcal} $unit',
                valueKey: const ValueKey('onboarding-summary-maintenance'),
              ),
              divider(),
              _BreakdownRow(
                key: const ValueKey('onboarding-summary-goal-row'),
                label: l10n.onboardingSummaryGoalLabel(
                  targets.effectivePaceLabel(l10n),
                ),
                value: _signedKcalLabel(targets.effectiveKcalDelta, unit),
                highlight: targets.effectiveKcalDelta != 0,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Signed kcal label for a COMPUTED difference ([KcalTargets
/// .effectiveKcalDelta]), e.g. "−797 kcal" / "±0", with the real minus sign.
String _signedKcalLabel(int kcal, String unit) {
  if (kcal == 0) return '±0';
  final sign = kcal > 0 ? '+' : '−';
  return '$sign${kcal.abs()} $unit';
}

/// One breakdown row: EXACTLY two [Text] children — onboarding_screen_test
/// reads the goal row's texts as a list and compares them literally.
class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.highlight = false,
  });

  final String label;
  final String value;
  final Key? valueKey;

  /// Lifts the number into the accent; the sign carries the direction.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final labelText = Text(
      label,
      style: AppType.ui(13.5, weight: FontWeight.w500, color: t.ink2),
    );
    final valueText = Text(
      value,
      key: valueKey,
      style: AppType.display(
        15,
        weight: FontWeight.w700,
        color: highlight ? t.accentText : t.ink,
      ),
    );
    return MergeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Side by side while "−1100 kcal" (~80 px at 1.0) needs at most
          // 40 % of the row; beyond that (2x text) both would wrap into
          // slivers, so the value moves under its label.
          final side =
              MediaQuery.textScalerOf(context).scale(80) <=
              constraints.maxWidth * 0.4;
          if (!side) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                labelText,
                const SizedBox(height: 2),
                valueText,
              ],
            );
          }
          // The value is not Flexible: a Flexible next to an Expanded gets
          // half the row and parks a short number in the middle.
          return Row(
            children: <Widget>[
              Expanded(child: labelText),
              const SizedBox(width: 12),
              valueText,
            ],
          );
        },
      ),
    );
  }
}

/// The answers, one settings-style row each; a tap reopens the question and
/// Next brings the user straight back here.
class _Answers extends StatelessWidget {
  const _Answers({required this.items, required this.onEdit});

  final List<OnboardingReviewItem> items;
  final ValueChanged<OnboardingStep> onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OnboardingSectionLabel(l10n.onboardingReviewTitle),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: _cardDecoration(t),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (i, item) in items.indexed) ...<Widget>[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 18,
                      endIndent: 18,
                      color: t.line,
                    ),
                  SettingsRow(
                    key: ValueKey('onboarding-edit-${item.step.name}'),
                    title: item.label,
                    subtitle: item.value,
                    chevron: false,
                    dense: true,
                    trailing: ExcludeSemantics(
                      child: Icon(Icons.edit_outlined, size: 19, color: t.ink3),
                    ),
                    onTap: () => onEdit(item.step),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
