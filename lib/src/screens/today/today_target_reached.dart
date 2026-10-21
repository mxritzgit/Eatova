import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart' show targetHoldBandKg;
import '../../theme/app_tokens.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';

/// The reached target on Today (2026-10-22), once the weight trend got there
/// (`HomeStore.targetReachedPrompt`): the plan holds the weight now,
/// and the user decides what comes next. "Hold" stores maintain as the goal;
/// "New goal" opens the goals page. The card stays until one of them ends the
/// reached state.
class TodayTargetReachedCard extends StatefulWidget {
  const TodayTargetReachedCard({
    super.key,
    required this.targetKg,
    required this.gain,
    required this.onHold,
    required this.onNewGoal,
  });

  final int targetKg;

  /// The goal's direction, which the way back names.
  final bool gain;
  final Future<void> Function() onHold;
  final VoidCallback onNewGoal;

  @override
  State<TodayTargetReachedCard> createState() => _TodayTargetReachedCardState();
}

class _TodayTargetReachedCardState extends State<TodayTargetReachedCard> {
  bool _busy = false;

  /// One save at a time; a failed one keeps the card and names the error.
  Future<void> _hold() async {
    if (_busy) return;
    setState(() => _busy = true);
    await tryPersistChange(context, widget.onHold);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final band = NumberFormat('0.#', l10n.localeName).format(targetHoldBandKg);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.todayTargetReachedTitle,
      child: Container(
        key: const ValueKey('today-target-reached'),
        padding: const EdgeInsets.all(16),
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
                IconTile(icon: Icons.flag_rounded, color: t.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.todayTargetReachedTitle,
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
              widget.gain
                  ? l10n.todayTargetReachedBodyGain(widget.targetKg, band)
                  : l10n.todayTargetReachedBodyLose(widget.targetKg, band),
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: const ValueKey('today-target-reached-hold'),
              label: l10n.todayTargetReachedHold,
              icon: Icons.check_rounded,
              // The touch floor the other in-card primaries use.
              height: kButtonMinHeight,
              onTap: _busy ? null : _hold,
            ),
            const SizedBox(height: 8),
            SoftPillButton(
              key: const ValueKey('today-target-reached-new-goal'),
              label: l10n.todayTargetReachedNewGoal,
              icon: Icons.tune_rounded,
              onTap: _busy ? null : widget.onNewGoal,
              tone: SoftPillTone.neutral,
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}
