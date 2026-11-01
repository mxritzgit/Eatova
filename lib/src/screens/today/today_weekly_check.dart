import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart' show paceLabelForWeeklyRateKg;
import '../../services/energy_check.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_prompt_card.dart';

/// The weekly check explained (2026-10-19), from Today's progress line and
/// the result card: what it compares, what it needs, how far it may move
/// the goal. The numbers come from [EnergyCheck]'s constants, so the text
/// cannot drift from the rules. [onOpenFoodLog] and [onLogWeight] close the
/// sheet first.
Future<void> showWeeklyCheckExplainer(
  BuildContext context, {
  VoidCallback? onOpenFoodLog,
  VoidCallback? onLogWeight,
}) => showEatovaSheet<void>(
  context,
  _WeeklyCheckExplainer(onOpenFoodLog: onOpenFoodLog, onLogWeight: onLogWeight),
);

class _WeeklyCheckExplainer extends StatelessWidget {
  const _WeeklyCheckExplainer({this.onOpenFoodLog, this.onLogWeight});

  final VoidCallback? onOpenFoodLog;
  final VoidCallback? onLogWeight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    void then(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    final logWeight = onLogWeight;
    final openLog = onOpenFoodLog;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('weekly-check-explainer'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SheetHeader(
              title: l10n.weeklyCheckExplainTitle,
              onClose: () => Navigator.of(context).pop(),
              closeKey: const ValueKey('weekly-check-explainer-close'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Three rules of one check: what it compares, what it
                  // needs, how far it may move the goal.
                  BulletList(
                    items: <String>[
                      l10n.weeklyCheckExplainCompare(EnergyCheck.windowDays),
                      l10n.weeklyCheckExplainData(
                        EnergyCheck.minLoggedDays,
                        EnergyCheck.minWeighInDays,
                        EnergyCheck.minWeighInSpanDays,
                      ),
                      l10n.weeklyCheckExplainStep(
                        EnergyCheck.maxStepKcal,
                        EnergyCheck.maxAdjustmentKcal,
                      ),
                    ],
                    gap: kSpace12,
                    style: AppType.body(t.ink2),
                  ),
                  if (logWeight != null || openLog != null)
                    const SizedBox(height: kSpace24),
                  if (logWeight != null)
                    SoftPillButton(
                      key: const ValueKey('weekly-check-explainer-weigh'),
                      icon: AppIcons.monitorWeight,
                      label: l10n.todayWeighChipLog,
                      expand: true,
                      onTap: () => then(logWeight),
                    ),
                  if (logWeight != null && openLog != null)
                    const SizedBox(height: 8),
                  if (openLog != null)
                    SoftPillButton(
                      key: const ValueKey('weekly-check-explainer-log'),
                      icon: AppIcons.restaurant,
                      label: l10n.todayOpenFoodLog,
                      tone: SoftPillTone.neutral,
                      expand: true,
                      onTap: () => then(openLog),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The week's result on Today (2026-10-19), quiet and without buttons that
/// change anything: shown once a week ([EnergyCheck.resultWeekday]) when the
/// check estimates but proposes nothing. Only numbers the check computes:
/// the observed expenditure, whether the goal fits or is held at a limit,
/// and the measured weight change against the plan's pace. "Verstanden"
/// hides it until next week (2026-10-22).
class TodayWeeklyResultCard extends StatelessWidget {
  const TodayWeeklyResultCard({
    super.key,
    required this.estimate,
    required this.onExplain,
    this.onAskCoach,
    this.onAcknowledge,
  });

  final EnergyCheckEstimate estimate;
  final VoidCallback onExplain;

  /// Prepares a question about the result in the Coach (2026-10-22); null
  /// hides the pill.
  final VoidCallback? onAskCoach;

  /// "Verstanden"; null shows no such button.
  final VoidCallback? onAcknowledge;

  /// Rounded to 10: the estimate is not precise to the calorie.
  static int _tens(double kcal) => (kcal / 10).round() * 10;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final e = estimate;
    final callout = AppType.callout(t.ink2);
    final acknowledge = onAcknowledge;
    final ask = onAskCoach;
    return TodayPromptCard(
      key: const ValueKey('today-weekly-result'),
      label: l10n.weeklyCheckResultTitle,
      title: l10n.weeklyCheckResultTitle,
      icon: AppIcons.insights,
      details: <Widget>[
        const SizedBox(height: kSpace12),
        Text(
          l10n.weeklyCheckResultBurn(_tens(e.observedKcal)),
          key: const ValueKey('today-weekly-result-burn'),
          style: AppType.rowTitle(t.ink),
        ),
        const SizedBox(height: kSpace4),
        Text(
          e.withinNoise
              ? l10n.weeklyCheckResultFits(e.currentGoalKcal)
              : l10n.weeklyCheckResultHeld(e.currentGoalKcal),
          key: const ValueKey('today-weekly-result-goal'),
          style: callout,
        ),
        const SizedBox(height: kSpace4),
        Text(
          l10n.weeklyCheckResultRate(
            paceLabelForWeeklyRateKg(e.weeklyRateKg, l10n),
            paceLabelForWeeklyRateKg(e.planWeeklyRateKg, l10n),
          ),
          key: const ValueKey('today-weekly-result-rate'),
          style: callout,
        ),
        const SizedBox(height: kSpace8),
        Text(
          l10n.todayEnergyCheckBasis(e.loggedDays, e.weighInDays),
          style: AppType.subhead(t.ink3),
        ),
        TodayCardLink(
          buttonKey: const ValueKey('today-weekly-result-more'),
          icon: AppIcons.info,
          label: l10n.weeklyCheckResultMore,
          onTap: onExplain,
        ),
      ],
      actionsGap: kSpace4,
      // No lit answer and no full-width pills: the result changes nothing.
      actions: <Widget>[
        if (acknowledge != null || ask != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: kSpace8,
              runSpacing: kSpace8,
              children: <Widget>[
                if (acknowledge != null)
                  SoftPillButton(
                    key: const ValueKey('today-weekly-result-seen'),
                    icon: AppIcons.check,
                    label: l10n.weeklyCheckResultSeen,
                    onTap: acknowledge,
                  ),
                if (ask != null)
                  SoftPillButton(
                    key: const ValueKey('today-weekly-result-ask-coach'),
                    icon: AppIcons.chatBubble,
                    label: l10n.coachAskAction,
                    tone: SoftPillTone.neutral,
                    onTap: ask,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
