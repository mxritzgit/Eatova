import '../../models/user_profile.dart';

/// Result type of the former settings sheet; the settings themselves are a
/// route now (`screens/settings/settings_screen.dart`).
///
/// It still lives here because `eatova_home_page.dart` imports both files; a
/// re-export would make the analyzer report `unnecessary_import` there, and CI
/// runs with `--fatal-infos`. Once that import goes, this file can move to the
/// screen and disappear.
class SettingsResult {
  const SettingsResult({
    required this.profile,
    required this.notificationsEnabled,
  });

  final UserProfile profile;

  /// State of the reminder switch at save time. The caller compares it with
  /// the previous state and calls requestPermission()/reschedule or cancelAll
  /// (PROD-1).
  final bool notificationsEnabled;
}
