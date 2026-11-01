import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_prompt_card.dart';

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

/// The scale import's one-time question on Today (review 2026-10-22): the
/// health source holds weigh-ins Eatova does not have
/// (`HomeStore.healthWeightImportOfferVisible`). "Import automatically"
/// takes them and every later one, "Not now" leaves them there; the
/// profile's Health card has the same switch.
class TodayWeightImportCard extends StatelessWidget {
  const TodayWeightImportCard({
    super.key,
    required this.onAccept,
    required this.onDismiss,
    this.healthConnect = false,
  });

  final Future<void> Function() onAccept;
  final Future<void> Function() onDismiss;
  final bool healthConnect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _HealthPromptCard(
      cardKey: const ValueKey('today-weight-import'),
      connectKey: const ValueKey('today-weight-import-accept'),
      dismissKey: const ValueKey('today-weight-import-dismiss'),
      title: l10n.healthWeightImportTitle,
      body: l10n.healthWeightImportBody(
        healthConnect ? 'Health Connect' : 'Apple Health',
      ),
      connectLabel: l10n.healthWeightImportAccept,
      icon: AppIcons.monitorWeight,
      onConnect: onAccept,
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
    this.icon,
  });

  final Key cardKey, connectKey, dismissKey;
  final String title, body, connectLabel;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDismiss;

  /// The topic's icon; null is the steps glyph of the connect question.
  final IconData? icon;

  @override
  State<_HealthPromptCard> createState() => _HealthPromptCardState();
}

class _HealthPromptCardState extends State<_HealthPromptCard> {
  /// The answer in flight (true: the primary one); it shows busy.
  bool? _pending;

  /// One answer at a time; the store removes the card once it is recorded.
  Future<void> _answer(bool primary, Future<void> Function() action) async {
    if (_pending != null) return;
    setState(() => _pending = primary);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  /// The tap of one answer's button: null while the other one runs.
  VoidCallback? _tap(bool primary, Future<void> Function() action) =>
      _pending == null || _pending == primary
      ? () => _answer(primary, action)
      : null;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final steps = widget.icon == null;
    return TodayPromptCard(
      key: widget.cardKey,
      label: widget.title,
      title: widget.title,
      icon: widget.icon,
      glyph: steps ? const StepsIcon() : null,
      glyphColor: steps ? t.activity : null,
      body: widget.body,
      actions: <Widget>[
        PrimaryActionButton(
          key: widget.connectKey,
          label: widget.connectLabel,
          icon: steps ? AppIcons.link : AppIcons.check,
          // The touch floor the other in-card primaries use.
          height: kButtonMinHeight,
          busy: _pending ?? false,
          onTap: _tap(true, widget.onConnect),
        ),
        SoftPillButton(
          key: widget.dismissKey,
          label: l10n.healthPromptDismiss,
          busy: _pending == false,
          onTap: _tap(false, widget.onDismiss),
          tone: SoftPillTone.quiet,
          expand: true,
        ),
      ],
    );
  }
}
