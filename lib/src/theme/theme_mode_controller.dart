import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds and persists the display mode (light/dark/system).
///
/// SharedPreferences on purpose, not the encrypted cache or the Supabase
/// profile row: the mode must apply before login and must not wait for a
/// sync. It is a device setting, not an account property.
///
/// Defaults to [ThemeMode.system] until someone switches explicitly.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController({ThemeMode initial = ThemeMode.system})
      : _mode = initial;

  static const String storageKey = 'eatova.v1.theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Reads the stored mode. Errors and unknown values fall back to
  /// [ThemeMode.system]; a broken prefs entry must not block startup.
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
      // Prefs unavailable (e.g. very early startup): system mode stays.
    }
  }

  /// Sets the mode and persists it. An unchanged value triggers neither a
  /// write nor a rebuild.
  Future<void> setMode(ThemeMode modus) async {
    if (modus == _mode) return;
    _mode = modus;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, modus.name);
    } catch (_) {
      // Not persisted — the session still runs in the chosen mode.
    }
  }

  /// Tests and synchronous priming only: sets without persisting.
  @visibleForTesting
  void setModeSync(ThemeMode modus) {
    if (modus == _mode) return;
    _mode = modus;
    notifyListeners();
  }

  /// Resolves [ThemeMode.system] against the platform brightness.
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

/// Passes the [ThemeModeController] down to arbitrarily deep screens.
///
/// An [InheritedNotifier] so a mode change rebuilds listeners automatically
/// and the switch always shows the real state.
class ThemeModeScope extends InheritedNotifier<ThemeModeController> {
  const ThemeModeScope({
    super.key,
    required ThemeModeController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller, or null outside the app shell (previews, single-widget
  /// tests). Callers should hide the switch instead of throwing.
  static ThemeModeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeModeScope>()
      ?.notifier;
}
