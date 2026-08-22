import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/theme/theme_mode_controller.dart';

// The display mode is a device setting, not a profile column: it must apply
// before login and must not wait for a sync, hence SharedPreferences.
//
// Contract:
//   * no stored value -> ThemeMode.system
//   * setting persists and notifies listeners
//   * an unknown or broken value falls back to system silently

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('ohne gespeicherten Wert startet die App im System-Modus', () async {
    final controller = ThemeModeController();
    expect(controller.mode, ThemeMode.system,
        reason: 'vor dem Laden darf nichts anderes aufblitzen');

    await controller.load();
    expect(controller.mode, ThemeMode.system);
  });

  test('gesetzter Modus wird persistiert und beim naechsten Start gelesen',
      () async {
    final controller = ThemeModeController();
    await controller.load();

    await controller.setMode(ThemeMode.dark);
    expect(controller.mode, ThemeMode.dark);

    final neu = ThemeModeController();
    await neu.load();
    expect(neu.mode, ThemeMode.dark,
        reason: 'der Modus muss den Neustart ueberleben');
  });

  test('alle drei Modi ueberleben den Neustart', () async {
    for (final modus in ThemeMode.values) {
      final controller = ThemeModeController();
      await controller.load();
      await controller.setMode(modus);

      final neu = ThemeModeController();
      await neu.load();
      expect(neu.mode, modus);
    }
  });

  test('Setzen benachrichtigt Hoerer genau einmal', () async {
    final controller = ThemeModeController();
    await controller.load();

    var rufe = 0;
    controller.addListener(() => rufe++);

    await controller.setMode(ThemeMode.dark);
    expect(rufe, 1);

    // Same value again: no needless rebuild of the whole app.
    await controller.setMode(ThemeMode.dark);
    expect(rufe, 1);

    await controller.setMode(ThemeMode.light);
    expect(rufe, 2);
  });

  test('ein kaputter gespeicherter Wert faellt still auf system zurueck',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeModeController.storageKey: 'neonpink',
    });

    final controller = ThemeModeController();
    await controller.load();
    expect(controller.mode, ThemeMode.system);
  });

  test('isDark loest den System-Modus gegen die Plattform auf', () {
    final controller = ThemeModeController();

    expect(controller.isDark(Brightness.dark), isTrue,
        reason: 'system + dunkles Geraet = dunkel');
    expect(controller.isDark(Brightness.light), isFalse);

    controller.setModeSync(ThemeMode.dark);
    expect(controller.isDark(Brightness.light), isTrue,
        reason: 'manuell dunkel schlaegt die Plattform');

    controller.setModeSync(ThemeMode.light);
    expect(controller.isDark(Brightness.dark), isFalse);
  });
}
