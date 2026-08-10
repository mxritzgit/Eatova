import '../../models/user_profile.dart';

/// Historischer Ort von „Profil & Ziele".
///
/// Seit dem Design-Refactor 2026-08-09 sind die Einstellungen eine Route
/// (`screens/settings/settings_screen.dart`) und kein modales BottomSheet
/// mehr; die 1922 Zeilen sind dorthin umgezogen. Zurueck bleibt nur noch der
/// Rueckgabetyp.
///
/// **Warum er noch hier steht und nicht beim Screen:** die Schale
/// (`lib/src/app/eatova_home_page.dart`, fremde Datei) importiert BEIDE
/// Dateien — `settings_screen.dart` fuer den Screen und diese hier fuer das
/// Ergebnis. Wuerde [SettingsResult] beim Screen wohnen und diese Datei ihn
/// nur re-exportieren, meldete der Analyzer in der Schale
/// `unnecessary_import`, und die CI laeuft mit `--fatal-infos`. Sobald die
/// Schale ihre Zeile 31 streicht, zieht die Klasse zum Screen und diese Datei
/// entfaellt.
///
/// **Entfallen am 2026-08-10:** das Feld `resetDay`. „Tagesdaten zurücksetzen"
/// ist auf Nutzer-Entscheid ersatzlos gestrichen — samt dem Knopf
/// `settings-reset-day` in `GoalsScreen`, `HomeStore.resetTodayData` und dem
/// Reset-Zweig in `applySettings`.
class SettingsResult {
  const SettingsResult({
    required this.profile,
    required this.notificationsEnabled,
  });

  final UserProfile profile;

  /// Zustand des Erinnerungen-Schalters beim Speichern. Der Aufrufer vergleicht
  /// mit dem vorigen Stand und ruft requestPermission()/reschedule bzw.
  /// cancelAll auf (PROD-1).
  final bool notificationsEnabled;
}
