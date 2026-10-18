/// Local wall-clock time of the daily logging reminder (C4).
///
/// A pure value type: the planner takes it as a parameter, the cache stores it
/// per account and device, and the UI converts it to and from `TimeOfDay`.
class ReminderTime {
  const ReminderTime(this.hour, this.minute)
    : assert(hour >= 0 && hour < 24),
      assert(minute >= 0 && minute < 60);

  /// The hour every reminder used before the time became a choice.
  static const int defaultHour = 20;

  /// 20:00, the default until the user picks another time.
  static const ReminderTime standard = ReminderTime(defaultHour, 0);

  /// Null for anything that is not a time between 00:00 and 23:59, such as a
  /// corrupt cache blob.
  static ReminderTime? tryParse(Object? hour, Object? minute) {
    if (hour is! int || minute is! int) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return ReminderTime(hour, minute);
  }

  final int hour;
  final int minute;

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() =>
      'ReminderTime(${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')})';
}
