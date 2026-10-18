import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/reminder_time.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/reminder_time_picker.dart';

/// Today's one-time offer of the daily reminder (C4).
///
/// The store decides when it shows (`HomeStore.reminderPromptVisible`: logs
/// on two days, reminders off, never answered). "Yes" runs the regular
/// opt-in with its permission dialog, "No thanks" only records the answer;
/// either way the card is gone for good. The time can be changed first.
class TodayReminderPromptCard extends StatefulWidget {
  const TodayReminderPromptCard({
    super.key,
    required this.time,
    required this.onAccept,
    required this.onDismiss,
    this.onChangeTime,
  });

  final ReminderTime time;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDismiss;

  /// Without it the time is shown but not offered for change.
  final ValueChanged<ReminderTime>? onChangeTime;

  @override
  State<TodayReminderPromptCard> createState() =>
      _TodayReminderPromptCardState();
}

class _TodayReminderPromptCardState extends State<TodayReminderPromptCard> {
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

  Future<void> _changeTime(ValueChanged<ReminderTime> onChange) async {
    final picked = await pickReminderTime(context, widget.time);
    if (picked == null || picked == widget.time) return;
    onChange(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final time = formatReminderTime(context, widget.time);
    final onChangeTime = widget.onChangeTime;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.reminderTimePromptTitle,
      child: Container(
        key: const ValueKey('today-reminder-prompt'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
                IconTile(
                  icon: Icons.notifications_none_rounded,
                  color: t.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.reminderTimePromptTitle,
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
              l10n.reminderTimePromptBody(time),
              key: const ValueKey('today-reminder-prompt-body'),
              style: AppType.ui(13.5, color: t.ink2, height: 1.4),
            ),
            if (onChangeTime != null) ...<Widget>[
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SoftPillButton(
                  key: const ValueKey('today-reminder-prompt-time'),
                  label: l10n.reminderTimePromptChangeTime,
                  icon: Icons.schedule_rounded,
                  tone: SoftPillTone.neutral,
                  semanticLabel: l10n.reminderTimeChangeSemantics(time),
                  onTap: _busy ? null : () => _changeTime(onChangeTime),
                ),
              ),
            ],
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: const ValueKey('today-reminder-prompt-accept'),
              label: l10n.reminderTimePromptAccept,
              icon: Icons.notifications_active_outlined,
              // The touch floor the other in-card primaries use.
              height: kButtonMinHeight,
              onTap: _busy ? null : () => _answer(widget.onAccept),
            ),
            const SizedBox(height: 8),
            SoftPillButton(
              key: const ValueKey('today-reminder-prompt-dismiss'),
              label: l10n.reminderTimePromptDismiss,
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
