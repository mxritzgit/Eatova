import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/energy_check.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';
import 'today_prompt_card.dart';

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
  /// The answer in flight (true: "Adjust"); it shows busy.
  bool? _pending;

  /// One answer at a time; a failed save keeps the card and names the error.
  Future<void> _answer(bool accept, Future<void> Function() action) async {
    if (_pending != null) return;
    setState(() => _pending = accept);
    await tryPersistChange(context, action);
    if (mounted) setState(() => _pending = null);
  }

  /// The tap of one answer's button: null while the other one runs.
  VoidCallback? _tap(bool accept, Future<void> Function() action) =>
      _pending == null || _pending == accept
      ? () => _answer(accept, action)
      : null;

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

    return TodayPromptCard(
      key: const ValueKey('today-energy-check'),
      label: l10n.todayEnergyCheckTitle,
      title: l10n.todayEnergyCheckTitle,
      icon: AppIcons.insights,
      body: body,
      details: <Widget>[
        const SizedBox(height: kSpace12),
        Text(
          l10n.todayEnergyCheckQuestion(p.currentGoalKcal, p.newGoalKcal),
          key: const ValueKey('today-energy-check-question'),
          style: AppType.rowTitle(t.ink),
        ),
      ],
      actions: <Widget>[
        PrimaryActionButton(
          key: const ValueKey('today-energy-check-accept'),
          label: l10n.todayEnergyCheckAccept,
          icon: AppIcons.check,
          // The touch floor the other in-card primaries use.
          height: kButtonMinHeight,
          busy: _pending ?? false,
          onTap: _tap(true, widget.onAccept),
        ),
        SoftPillButton(
          key: const ValueKey('today-energy-check-dismiss'),
          label: l10n.todayEnergyCheckDismiss,
          busy: _pending == false,
          onTap: _tap(false, widget.onDismiss),
          tone: SoftPillTone.quiet,
          expand: true,
        ),
      ],
      footnote: l10n.todayEnergyCheckBasis(p.loggedDays, p.weighInDays),
    );
  }
}
