import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/energy_check.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';

/// The weekly energy check on Today (docs/WEIGHT-TREND.md, stage 2): what
/// the last three weeks imply, the proposed goal, and the two answers. The
/// goal changes only on "Adjust"; "Not now" asks again in seven days.
class TodayEnergyCheckCard extends StatefulWidget {
  const TodayEnergyCheckCard({
    super.key,
    required this.proposal,
    required this.onAccept,
    required this.onDismiss,
  });

  final EnergyCheckProposal proposal;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDismiss;

  @override
  State<TodayEnergyCheckCard> createState() => _TodayEnergyCheckCardState();
}

class _TodayEnergyCheckCardState extends State<TodayEnergyCheckCard> {
  bool _busy = false;

  /// One answer at a time; a failed save keeps the card and names the error.
  Future<void> _answer(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await tryPersistChange(context, action);
    if (mounted) setState(() => _busy = false);
  }

  /// Rounded to 10: the estimate is not precise to the calorie.
  static int _tens(double kcal) => (kcal / 10).round() * 10;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final p = widget.proposal;
    final observed = _tens(p.observedKcal);
    final difference = _tens((p.observedKcal - p.modelledKcal).abs());
    final body = p.observedKcal > p.modelledKcal
        ? l10n.todayEnergyCheckBurnMore(observed, difference)
        : l10n.todayEnergyCheckBurnLess(observed, difference);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.todayEnergyCheckTitle,
      child: Container(
        key: const ValueKey('today-energy-check'),
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
                      l10n.todayEnergyCheckTitle,
                      style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              body,
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.todayEnergyCheckQuestion(p.currentGoalKcal, p.newGoalKcal),
              key: const ValueKey('today-energy-check-question'),
              style: AppType.ui(14.5, weight: FontWeight.w600, color: t.ink),
            ),
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: const ValueKey('today-energy-check-accept'),
              label: l10n.todayEnergyCheckAccept,
              icon: Icons.check_rounded,
              height: 46,
              onTap: _busy ? null : () => _answer(widget.onAccept),
            ),
            const SizedBox(height: 8),
            SoftPillButton(
              key: const ValueKey('today-energy-check-dismiss'),
              label: l10n.todayEnergyCheckDismiss,
              onTap: _busy ? null : () => _answer(widget.onDismiss),
              tone: SoftPillTone.neutral,
              expand: true,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.todayEnergyCheckBasis(p.loggedDays, p.weighInDays),
              textAlign: TextAlign.center,
              style: AppType.ui(12, color: t.ink3),
            ),
          ],
        ),
      ),
    );
  }
}
