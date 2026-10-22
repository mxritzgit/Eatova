import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart' show paceLabelForWeeklyRateKg;
import '../../services/energy_check.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

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
    final style = AppType.ui(14, color: t.ink2, height: 1.45);
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
                  Text(
                    l10n.weeklyCheckExplainCompare(EnergyCheck.windowDays),
                    style: style,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.weeklyCheckExplainData(
                      EnergyCheck.minLoggedDays,
                      EnergyCheck.minWeighInDays,
                      EnergyCheck.minWeighInSpanDays,
                    ),
                    style: style,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.weeklyCheckExplainStep(
                      EnergyCheck.maxStepKcal,
                      EnergyCheck.maxAdjustmentKcal,
                    ),
                    style: style,
                  ),
                  if (logWeight != null || openLog != null)
                    const SizedBox(height: 20),
                  if (logWeight != null)
                    SoftPillButton(
                      key: const ValueKey('weekly-check-explainer-weigh'),
                      icon: Icons.monitor_weight_outlined,
                      label: l10n.todayWeighChipLog,
                      expand: true,
                      onTap: () => then(logWeight),
                    ),
                  if (logWeight != null && openLog != null)
                    const SizedBox(height: 8),
                  if (openLog != null)
                    SoftPillButton(
                      key: const ValueKey('weekly-check-explainer-log'),
                      icon: Icons.restaurant_rounded,
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
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.weeklyCheckResultTitle,
      child: Container(
        key: const ValueKey('today-weekly-result'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: t.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconTile(icon: Icons.insights_rounded, color: t.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.weeklyCheckResultTitle,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.weeklyCheckResultBurn(_tens(e.observedKcal)),
              key: const ValueKey('today-weekly-result-burn'),
              style: AppType.ui(14.5, weight: FontWeight.w600, color: t.ink),
            ),
            const SizedBox(height: 4),
            Text(
              e.withinNoise
                  ? l10n.weeklyCheckResultFits(e.currentGoalKcal)
                  : l10n.weeklyCheckResultHeld(e.currentGoalKcal),
              key: const ValueKey('today-weekly-result-goal'),
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.weeklyCheckResultRate(
                paceLabelForWeeklyRateKg(e.weeklyRateKg, l10n),
                paceLabelForWeeklyRateKg(e.planWeeklyRateKg, l10n),
              ),
              key: const ValueKey('today-weekly-result-rate'),
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.todayEnergyCheckBasis(e.loggedDays, e.weighInDays),
              style: AppType.ui(12, color: t.ink3),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (onAcknowledge case final acknowledge?)
                    SoftPillButton(
                      key: const ValueKey('today-weekly-result-seen'),
                      icon: Icons.check_rounded,
                      label: l10n.weeklyCheckResultSeen,
                      onTap: acknowledge,
                    ),
                  SoftPillButton(
                    key: const ValueKey('today-weekly-result-more'),
                    icon: Icons.info_outline_rounded,
                    label: l10n.weeklyCheckResultMore,
                    tone: SoftPillTone.neutral,
                    onTap: onExplain,
                  ),
                  if (onAskCoach case final ask?)
                    SoftPillButton(
                      key: const ValueKey('today-weekly-result-ask-coach'),
                      icon: Icons.chat_bubble_outline_rounded,
                      label: l10n.coachAskAction,
                      tone: SoftPillTone.neutral,
                      onTap: ask,
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
