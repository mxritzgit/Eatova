import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// The Apple Health intro on Today (review 2026-10-19): what the steps are
/// for, before Apple's permission sheet asks. Shown once the onboarding is
/// done (`HomeStore.healthIntroVisible`); "Connect" opens the sheet, "Not
/// now" hides the card, and the profile's Health card still connects.
class TodayHealthPromptCard extends StatefulWidget {
  const TodayHealthPromptCard({
    super.key,
    required this.onConnect,
    required this.onDismiss,
  });

  final Future<void> Function() onConnect;
  final Future<void> Function() onDismiss;

  @override
  State<TodayHealthPromptCard> createState() => _TodayHealthPromptCardState();
}

class _TodayHealthPromptCardState extends State<TodayHealthPromptCard> {
  bool _busy = false;

  /// One answer at a time; the store removes the card once it is recorded.
  Future<void> _answer(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.healthPromptTitle,
      child: Container(
        key: const ValueKey('today-health-prompt'),
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
                IconTile.custom(color: t.activity, child: const StepsIcon()),
                const SizedBox(width: 12),
                Expanded(
                  child: HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.healthPromptTitle,
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
              l10n.healthPromptBody,
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: const ValueKey('today-health-prompt-connect'),
              label: l10n.healthPromptConnect,
              icon: Icons.favorite_border_rounded,
              // The touch floor the other in-card primaries use.
              height: kButtonMinHeight,
              onTap: _busy ? null : () => _answer(widget.onConnect),
            ),
            const SizedBox(height: 8),
            SoftPillButton(
              key: const ValueKey('today-health-prompt-dismiss'),
              label: l10n.healthPromptDismiss,
              onTap: _busy ? null : () => _answer(widget.onDismiss),
              tone: SoftPillTone.neutral,
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}
