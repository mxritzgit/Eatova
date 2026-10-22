import 'dart:ui' show PlatformDispatcher;

import 'package:clock/clock.dart';

/// The Coach's daily question limit counts per UTC day: the server books
/// against `current_date` of a UTC database (claim_chat_quota), so the
/// counter resets at 00:00 UTC. That rule stays on the server; the app only
/// tells the user when that is on their own clock.
DateTime nextCoachQuotaReset(DateTime now) {
  final utc = now.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day + 1);
}

/// The UTC day the server books coach questions against, as `YYYY-MM-DD`:
/// the key of the quota the app remembers between starts.
String coachQuotaDay(DateTime now) {
  final utc = now.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
}

Duration _deviceOffset(DateTime utc) => utc.toLocal().timeZoneOffset;

/// The next reset as a local clock time: "02:00" in German, "2:00 AM" in
/// English, "02:00" too when the phone is set to 24 hours. A date is not
/// needed: the reset is always within 24 hours, and "tomorrow" was wrong
/// between local midnight and the reset (00:00-01:59 in Germany in summer).
///
/// [offsetOf] is the device zone's UTC offset at an instant (tests pin it);
/// [now] defaults to [clock], [alwaysUse24HourFormat] to the phone's setting.
String coachQuotaResetLabel(
  String localeName, {
  DateTime? now,
  Duration Function(DateTime utc)? offsetOf,
  bool? alwaysUse24HourFormat,
}) {
  final reset = nextCoachQuotaReset(now ?? clock.now());
  // Wall time of the reset in the device zone, read off a UTC value so the
  // process zone plays no part when [offsetOf] is given.
  final wall = reset.add((offsetOf ?? _deviceOffset)(reset));
  final minute = wall.minute.toString().padLeft(2, '0');
  final use24h =
      alwaysUse24HourFormat ??
      PlatformDispatcher.instance.alwaysUse24HourFormat;
  if (use24h || !localeName.toLowerCase().startsWith('en')) {
    return '${wall.hour.toString().padLeft(2, '0')}:$minute';
  }
  final hour12 = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
  return '$hour12:$minute ${wall.hour < 12 ? 'AM' : 'PM'}';
}
