import 'package:flutter/material.dart';

import '../../app/home_store.dart' show ReminderState;
import '../../l10n/l10n.dart';
import '../../models/reminder_time.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/reminder_time_picker.dart';
import 'settings_studio_widgets.dart';

/// The sentence for the reminder's [state] (D11: three states, three
/// sentences). Shared by this row and "Profil & Ziele", so both say the same
/// and both name the chosen [time].
String reminderStatusText(
  AppLocalizations l10n,
  ReminderState state,
  String time,
) => switch (state) {
  ReminderState.off => l10n.goalsReminderTextOff,
  ReminderState.active => l10n.reminderTimeActiveText(time),
  ReminderState.blocked => l10n.goalsReminderTextBlocked,
};

/// The reminder in the settings (C4): switch and time in one row, so the
/// reminder is found where settings are looked for, not only in the goals.
///
/// Both act at once, like the appearance and language rows: the switch runs
/// the store's opt-in (permission dialog included), the time re-plans. While
/// the system blocks notifications the switch is locked, as in the goals
/// (D11); the time stays settable.
class SettingsReminderRow extends StatelessWidget {
  const SettingsReminderRow({
    super.key,
    required this.state,
    required this.time,
    required this.onEnabledChanged,
    required this.onTimeChanged,
  });

  final ReminderState state;
  final ReminderTime time;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<ReminderTime> onTimeChanged;

  Future<void> _pickTime(BuildContext context) async {
    final picked = await pickReminderTime(context, time);
    if (picked == null || picked == time) return;
    onTimeChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final blocked = state == ReminderState.blocked;
    final active = state == ReminderState.active;
    final timeLabel = formatReminderTime(context, time);
    final stacked = settingsTileStacked(context);

    final tile = ExcludeSemantics(
      child: SettingsRowTile(
        icon: blocked
            ? Icons.notifications_off_outlined
            : Icons.notifications_none_rounded,
        tone: blocked ? t.warning : (active ? t.accent : null),
      ),
    );
    final toggle = AppToggle(
      key: const ValueKey('settings-reminder-toggle'),
      value: active,
      enabled: !blocked,
      semanticLabel: blocked
          ? l10n.goalsReminderBlockedSemantics
          : l10n.goalsReminderActiveSemantics,
      onChanged: onEnabledChanged,
    );
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.reminderTimeSettingsTitle,
          style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
        ),
        const SizedBox(height: 3),
        Text(
          reminderStatusText(l10n, state, timeLabel),
          key: const ValueKey('settings-reminder-status'),
          style: AppType.ui(13, color: t.ink2, height: 1.35),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The whole upper part is the switch's target, as in the goals.
        // Off while blocked: the locked switch adds no recognizer, so the
        // row would otherwise take the tap (D11 back door).
        InkWell(
          onTap: blocked ? null : () => onEnabledChanged(!active),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              kSettingsRowPad,
              14,
              kSettingsRowPad,
              10,
            ),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(children: <Widget>[tile, const Spacer(), toggle]),
                      const SizedBox(height: 10),
                      texts,
                    ],
                  )
                : Row(
                    children: <Widget>[
                      tile,
                      const SizedBox(width: kSettingsTileGap),
                      Expanded(child: texts),
                      const SizedBox(width: 10),
                      toggle,
                    ],
                  ),
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            stacked ? kSettingsRowPad : kSettingsRowPad + kSettingsTextInset,
            0,
            kSettingsRowPad,
            16,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('settings-reminder-time'),
              label: timeLabel,
              icon: Icons.schedule_rounded,
              tone: SoftPillTone.neutral,
              semanticLabel: l10n.reminderTimeChangeSemantics(timeLabel),
              onTap: () => _pickTime(context),
            ),
          ),
        ),
      ],
    );
  }
}
