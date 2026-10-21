import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// The health intro on Today (reviews 2026-10-19 and 2026-10-22): what the
/// steps are for, before the permission prompt asks. Shown once the
/// onboarding is done (`HomeStore.healthIntroVisible`); "Connect" opens the
/// prompt, "Not now" hides the card, and the profile's Health card still
/// connects. [healthConnect] picks Health Connect's wording over Apple
/// Health's.
class TodayHealthPromptCard extends StatelessWidget {
  const TodayHealthPromptCard({
    super.key,
    required this.onConnect,
    required this.onDismiss,
    this.healthConnect = false,
  });

  final Future<void> Function() onConnect;
  final Future<void> Function() onDismiss;
  final bool healthConnect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _HealthPromptCard(
      cardKey: const ValueKey('today-health-prompt'),
      connectKey: const ValueKey('today-health-prompt-connect'),
      dismissKey: const ValueKey('today-health-prompt-dismiss'),
      title: healthConnect
          ? l10n.healthConnectPromptTitle
          : l10n.healthPromptTitle,
      body: healthConnect ? l10n.healthConnectPromptBody : l10n.healthPromptBody,
      connectLabel: healthConnect
          ? l10n.healthConnectPromptConnect
          : l10n.healthPromptConnect,
      onConnect: onConnect,
      onDismiss: onDismiss,
    );
  }
}

/// Card body shared by Today's health prompts: an icon and title, one short
/// paragraph, the primary answer and "Not now".
class _HealthPromptCard extends StatefulWidget {
  const _HealthPromptCard({
    required this.cardKey,
    required this.connectKey,
    required this.dismissKey,
    required this.title,
    required this.body,
    required this.connectLabel,
    required this.onConnect,
    required this.onDismiss,
  });

  final Key cardKey, connectKey, dismissKey;
  final String title, body, connectLabel;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDismiss;

  @override
  State<_HealthPromptCard> createState() => _HealthPromptCardState();
}

class _HealthPromptCardState extends State<_HealthPromptCard> {
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
      label: widget.title,
      child: Container(
        key: widget.cardKey,
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
                      widget.title,
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
              widget.body,
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: widget.connectKey,
              label: widget.connectLabel,
              icon: Icons.favorite_border_rounded,
              // The touch floor the other in-card primaries use.
              height: kButtonMinHeight,
              onTap: _busy ? null : () => _answer(widget.onConnect),
            ),
            const SizedBox(height: 8),
            SoftPillButton(
              key: widget.dismissKey,
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
