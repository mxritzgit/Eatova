import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/reminder_time.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/reminder_time_picker.dart';
import 'today_prompt_card.dart';

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
  /// The answer in flight (true: "Yes"); it shows busy.
  bool? _pending;

  bool get _busy => _pending != null;

  /// One answer at a time; the store removes the card once it is recorded.
  Future<void> _answer(bool accept, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _pending = accept);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  /// The tap of one answer's button: null while the other one runs.
  VoidCallback? _tap(bool accept, Future<void> Function() action) =>
      _pending == null || _pending == accept
      ? () => _answer(accept, action)
      : null;

  Future<void> _changeTime(ValueChanged<ReminderTime> onChange) async {
    final picked = await pickReminderTime(context, widget.time);
    if (picked == null || picked == widget.time) return;
    onChange(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final time = formatReminderTime(context, widget.time);
    final onChangeTime = widget.onChangeTime;

    return TodayPromptCard(
      key: const ValueKey('today-reminder-prompt'),
      label: l10n.reminderTimePromptTitle,
      title: l10n.reminderTimePromptTitle,
      icon: AppIcons.notifications,
      body: l10n.reminderTimePromptBody(time),
      bodyKey: const ValueKey('today-reminder-prompt-body'),
      details: <Widget>[
        if (onChangeTime != null) ...<Widget>[
          const SizedBox(height: kSpace12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('today-reminder-prompt-time'),
              label: l10n.reminderTimePromptChangeTime,
              icon: AppIcons.schedule,
              tone: SoftPillTone.neutral,
              semanticLabel: l10n.reminderTimeChangeSemantics(time),
              onTap: _busy ? null : () => _changeTime(onChangeTime),
            ),
          ),
        ],
      ],
      actions: <Widget>[
        PrimaryActionButton(
          key: const ValueKey('today-reminder-prompt-accept'),
          label: l10n.reminderTimePromptAccept,
          icon: AppIcons.notificationsActive,
          // The touch floor the other in-card primaries use.
          height: kButtonMinHeight,
          busy: _pending ?? false,
          onTap: _tap(true, widget.onAccept),
        ),
        SoftPillButton(
          key: const ValueKey('today-reminder-prompt-dismiss'),
          label: l10n.reminderTimePromptDismiss,
          busy: _pending == false,
          onTap: _tap(false, widget.onDismiss),
          tone: SoftPillTone.quiet,
          expand: true,
        ),
      ],
    );
  }
}
