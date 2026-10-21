import 'package:flutter/material.dart';

import '../../app/home_store.dart' show ReminderState;
import '../../l10n/l10n.dart';
import '../../models/reminder_time.dart';
import '../../services/weigh_in_reminder_planner.dart'
    show weighInReminderTime;
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
/// (D11); the time stays settable, and [onOpenSystemSettings] is the way out
/// (review 2026-10-22: the hint alone was a dead end).
class SettingsReminderRow extends StatelessWidget {
  const SettingsReminderRow({
    super.key,
    required this.state,
    required this.time,
    required this.onEnabledChanged,
    required this.onTimeChanged,
    this.onOpenSystemSettings,
  });

  final ReminderState state;
  final ReminderTime time;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<ReminderTime> onTimeChanged;

  /// Opens the OS notification settings; offered only while blocked. Null
  /// hides the button (a button that opens nothing is the D11 lie again).
  final VoidCallback? onOpenSystemSettings;

  Future<void> _pickTime(BuildContext context) async {
    final picked = await pickReminderTime(context, time);
    if (picked == null || picked == time) return;
    onTimeChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final timeLabel = formatReminderTime(context, time);
    final openSettings = state == ReminderState.blocked
        ? onOpenSystemSettings
        : null;
    return _ReminderSwitchRow(
      keyPrefix: 'settings-reminder',
      icon: Icons.notifications_none_rounded,
      title: l10n.reminderTimeSettingsTitle,
      status: reminderStatusText(l10n, state, timeLabel),
      activeSemantics: l10n.goalsReminderActiveSemantics,
      state: state,
      onEnabledChanged: onEnabledChanged,
      actions: <Widget>[
        SoftPillButton(
          key: const ValueKey('settings-reminder-time'),
          label: timeLabel,
          icon: Icons.schedule_rounded,
          tone: SoftPillTone.neutral,
          semanticLabel: l10n.reminderTimeChangeSemantics(timeLabel),
          onTap: () => _pickTime(context),
        ),
        if (openSettings != null)
          _OpenSystemSettingsButton(
            key: const ValueKey('settings-reminder-open-system-settings'),
            onTap: openSettings,
          ),
      ],
    );
  }
}

/// The weigh-in reminder (review 2026-10-22): Monday and Thursday at 07:30,
/// so the weekly check gets its weigh-ins. Its own switch next to the
/// evening reminder, with the same three states and the same way out of a
/// blocked permission. The time is fixed.
class SettingsWeighInReminderRow extends StatelessWidget {
  const SettingsWeighInReminderRow({
    super.key,
    required this.state,
    required this.onEnabledChanged,
    this.onOpenSystemSettings,
  });

  final ReminderState state;
  final ValueChanged<bool> onEnabledChanged;

  /// As in [SettingsReminderRow]: shown only while blocked, null hides it.
  final VoidCallback? onOpenSystemSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final time = formatReminderTime(context, weighInReminderTime);
    final openSettings = state == ReminderState.blocked
        ? onOpenSystemSettings
        : null;
    return _ReminderSwitchRow(
      keyPrefix: 'settings-weigh-in-reminder',
      icon: Icons.monitor_weight_outlined,
      title: l10n.weighInReminderSettingsTitle,
      status: switch (state) {
        ReminderState.off => l10n.weighInReminderTextOff(time),
        ReminderState.active => l10n.weighInReminderTextActive(time),
        ReminderState.blocked => l10n.goalsReminderTextBlocked,
      },
      activeSemantics: l10n.weighInReminderSemantics,
      state: state,
      onEnabledChanged: onEnabledChanged,
      actions: <Widget>[
        if (openSettings != null)
          _OpenSystemSettingsButton(
            key: const ValueKey('settings-weigh-in-open-system-settings'),
            onTap: openSettings,
          ),
      ],
    );
  }
}

/// Icon tile, title, status sentence and switch of a reminder row; the
/// [actions] take their own line under it.
class _ReminderSwitchRow extends StatelessWidget {
  const _ReminderSwitchRow({
    required this.keyPrefix,
    required this.icon,
    required this.title,
    required this.status,
    required this.activeSemantics,
    required this.state,
    required this.onEnabledChanged,
    required this.actions,
  });

  final String keyPrefix;
  final IconData icon;
  final String title;
  final String status;
  final String activeSemantics;
  final ReminderState state;
  final ValueChanged<bool> onEnabledChanged;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final blocked = state == ReminderState.blocked;
    final active = state == ReminderState.active;
    final stacked = settingsTileStacked(context);

    final tile = ExcludeSemantics(
      child: SettingsRowTile(
        icon: blocked ? Icons.notifications_off_outlined : icon,
        tone: blocked ? t.warning : (active ? t.accent : null),
      ),
    );
    final toggle = AppToggle(
      key: ValueKey('$keyPrefix-toggle'),
      value: active,
      enabled: !blocked,
      semanticLabel: blocked
          ? l10n.goalsReminderBlockedSemantics
          : activeSemantics,
      onChanged: onEnabledChanged,
    );
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
        ),
        const SizedBox(height: 3),
        Text(
          status,
          key: ValueKey('$keyPrefix-status'),
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
            padding: EdgeInsets.fromLTRB(
              kSettingsRowPad,
              14,
              kSettingsRowPad,
              actions.isEmpty ? 14 : 10,
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
        if (actions.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              stacked ? kSettingsRowPad : kSettingsRowPad + kSettingsTextInset,
              0,
              kSettingsRowPad,
              16,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(spacing: 8, runSpacing: 8, children: actions),
            ),
          ),
      ],
    );
  }
}

/// "Open system settings" under a blocked reminder, as in the goals.
class _OpenSystemSettingsButton extends StatelessWidget {
  const _OpenSystemSettingsButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SoftPillButton(
    label: context.l10n.goalsOpenSystemSettings,
    icon: Icons.settings_outlined,
    onTap: onTap,
  );
}
