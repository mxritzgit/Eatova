import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Haelt den Anzeige-Modus (Hell/Dunkel/System) und persistiert ihn.
///
/// Bewusst SharedPreferences und NICHT der verschluesselte [LocalCache] oder
/// die Supabase-Profil-Zeile: der Modus muss schon vor dem Login greifen
/// (Auth-Screens) und darf nicht auf einen Sync warten. Er ist eine Geraete-
/// Einstellung, keine Konto-Eigenschaft — auf einem zweiten Geraet darf der
/// Nutzer eine andere Wahl treffen.
///
/// Default ist [ThemeMode.system] (Nutzer-Entscheid 2026-08-09): die App
/// folgt dem Geraet, bis jemand aktiv umschaltet.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController({ThemeMode initial = ThemeMode.system})
      : _mode = initial;

  static const String storageKey = 'eatova.v1.theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Liest den gespeicherten Modus. Fehler und unbekannte Werte fallen still
  /// auf [ThemeMode.system] zurueck — ein kaputter Prefs-Eintrag darf den
  /// Start nicht blockieren.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gespeichert = prefs.getString(storageKey);
      final gelesen = _parse(gespeichert);
      if (gelesen != _mode) {
        _mode = gelesen;
        notifyListeners();
      }
    } catch (_) {
      // Prefs nicht verfuegbar (z. B. sehr fruehe Startphase): System bleibt.
    }
  }

  /// Setzt den Modus und schreibt ihn weg. Ein unveraenderter Wert loest
  /// weder Schreibvorgang noch Rebuild aus.
  Future<void> setMode(ThemeMode modus) async {
    if (modus == _mode) return;
    _mode = modus;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, modus.name);
    } catch (_) {
      // Nicht persistiert — die Sitzung laeuft trotzdem im gewaehlten Modus.
    }
  }

  /// Nur fuer Tests und synchrone Vorbelegung: setzt ohne zu persistieren.
  @visibleForTesting
  void setModeSync(ThemeMode modus) {
    if (modus == _mode) return;
    _mode = modus;
    notifyListeners();
  }

  /// Loest [ThemeMode.system] gegen die Plattform-Helligkeit auf.
  bool isDark(Brightness plattform) => switch (_mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system => plattform == Brightness.dark,
      };

  static ThemeMode _parse(String? wert) {
    return switch (wert) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
  }
}

/// Reicht den [ThemeModeController] an beliebig tiefe Screens durch (der
/// Schalter sitzt in den Einstellungen, gesetzt wird er ganz oben).
///
/// [InheritedNotifier], damit ein Moduswechsel die Hoerer automatisch neu
/// baut — der Schalter zeigt so immer den echten Zustand, auch wenn ihn
/// jemand anders umlegt.
class ThemeModeScope extends InheritedNotifier<ThemeModeController> {
  const ThemeModeScope({
    super.key,
    required ThemeModeController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Der Controller, oder null ausserhalb der App-Schale (Previews, Tests,
  /// die nur ein Einzel-Widget pumpen). Aufrufer sollen dann den Schalter
  /// ausblenden statt zu werfen.
  static ThemeModeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeModeScope>()
      ?.notifier;
}
