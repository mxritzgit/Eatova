import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Haelt die Anzeigesprache (System/Deutsch/Englisch) und persistiert sie.
///
/// Bewusst SharedPreferences und NICHT der verschluesselte LocalCache oder
/// die Supabase-Profil-Zeile: die Sprache muss vor dem Login greifen und ist
/// eine Geraete-, keine Konto-Eigenschaft (Spiegel von ThemeModeController).
///
/// `override == null` heisst System: die Aufloesung uebernimmt
/// [resolveEatovaLocale] ueber die Geraete-Sprachliste.
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
      // Prefs nicht verfuegbar: System bleibt.
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
      // Nicht persistiert — die Sitzung laeuft trotzdem in der Wahl.
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

/// Spec §3: Geraet spricht Deutsch -> de, alles andere -> en. Die
/// Praeferenzliste des Geraets wird der Reihe nach gelaufen, damit
/// [fr, de] bei Deutsch landet und [en, de] bei Englisch.
Locale resolveEatovaLocale(List<Locale>? deviceLocales) {
  for (final locale in deviceLocales ?? const <Locale>[]) {
    if (locale.languageCode == 'de') return const Locale('de');
    if (locale.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}

/// Reicht den [LocaleController] an tiefe Screens durch (der Schalter sitzt
/// in den Einstellungen, gesetzt wird er ganz oben) — Spiegel von
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
