/// Ways into the app from outside it: the payload of a tapped reminder and
/// the type of an app-icon shortcut. One list, so a notification and a
/// shortcut that mean the same thing reach the same route in the shell.
///
/// The ids are stored with the OS (scheduled notifications, the launcher's
/// shortcut list), so they never change; unknown ids are ignored.
enum AppEntry {
  /// Food's add sheet for the current meal slot, on today (the evening and
  /// half-day reminders).
  logMeal('log-meal'),

  /// The in-app camera's AI scan; it asks for the AI consent first.
  photo('photo'),

  /// The barcode scanner.
  barcode('barcode'),

  /// The add sheet with "Describe" open; it asks for the AI consent first.
  describe('describe'),

  /// The weigh-in sheet (weigh-in reminder, shortcut).
  weighIn('weigh-in');

  const AppEntry(this.id);

  /// Notification payload and shortcut type.
  final String id;

  /// The entry for [id], or null for anything this app does not know.
  static AppEntry? tryParse(String? id) {
    for (final entry in values) {
      if (entry.id == id) return entry;
    }
    return null;
  }
}
