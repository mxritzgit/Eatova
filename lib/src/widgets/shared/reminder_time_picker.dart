import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/reminder_time.dart';

/// [time] the way the device shows times: 24 h or 12 h by locale, and 24 h
/// whenever the system asks for it ([MediaQuery.alwaysUse24HourFormatOf]).
String formatReminderTime(BuildContext context, ReminderTime time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: time.hour, minute: time.minute),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// The Material time picker in the app theme (`timePickerTheme`), starting at
/// [initial]. Null when the user cancels.
///
/// A 24-hour locale (de) gets the 24-hour flag too: the picker's keyboard
/// entry reads only that flag, so "7" became 19:00 after a PM start while
/// the dial showed 24 hours.
Future<ReminderTime?> pickReminderTime(
  BuildContext context,
  ReminderTime initial,
) async {
  final use24h =
      MediaQuery.alwaysUse24HourFormatOf(context) ||
      hourFormat(of: MaterialLocalizations.of(context).timeOfDayFormat()) !=
          HourFormat.h;
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    helpText: context.l10n.reminderTimePickerTitle,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
      child: child!,
    ),
  );
  if (picked == null) return null;
  return ReminderTime(picked.hour, picked.minute);
}
