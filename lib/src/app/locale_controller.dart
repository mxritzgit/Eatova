import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds and persists the display language (system/German/English).
///
/// SharedPreferences on purpose, not the encrypted LocalCache or the Supabase
/// profile row: the language applies before login and is a device, not an
/// account property. `override == null` means system, resolved by
/// [resolveEatovaLocale].
class LocaleController extends ChangeNotifier {
  LocaleController({Locale? initial}) : _override = initial;

  static const String storageKey = 'eatova.v1.locale';

  Locale? _override;
  Locale? get override => _override;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gelesen = _parse(prefs.getString(storageKey));
      if (gelesen != _override) {
        _override = gelesen;
        notifyListeners();
      }
    } catch (_) {
      // Prefs unavailable: stay on system.
    }
  }

  Future<void> setOverride(Locale? locale) async {
    if (locale == _override) return;
    _override = locale;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, locale?.languageCode ?? 'system');
    } catch (_) {
      // Not persisted; the session still runs in the chosen language.
    }
  }

  @visibleForTesting
  void setOverrideSync(Locale? locale) {
    if (locale == _override) return;
    _override = locale;
    notifyListeners();
  }

  static Locale? _parse(String? wert) => switch (wert) {
        'de' => const Locale('de'),
        'en' => const Locale('en'),
        _ => null,
      };
}

/// Spec §3: device speaks German -> de, anything else -> en.
/// Walks the device preference list in order, so [fr, de] lands on German and
/// [en, de] on English.
Locale resolveEatovaLocale(List<Locale>? deviceLocales) {
  for (final locale in deviceLocales ?? const <Locale>[]) {
    if (locale.languageCode == 'de') return const Locale('de');
    if (locale.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}

/// Passes the [LocaleController] down to deep screens; mirror of
/// [ThemeModeScope].
class LocaleScope extends InheritedNotifier<LocaleController> {
  const LocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LocaleScope>()
      ?.notifier;
}
