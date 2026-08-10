import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocaleController', () {
    test('Default ist System (override null)', () {
      expect(LocaleController().override, isNull);
    });

    test('load liest den gespeicherten Wert', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'en'});
      final c = LocaleController();
      await c.load();
      expect(c.override, const Locale('en'));
    });

    test('kaputter Prefs-Eintrag faellt still auf System zurueck', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'klingonisch'});
      final c = LocaleController();
      await c.load();
      expect(c.override, isNull);
    });

    test('setOverride persistiert und benachrichtigt', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = LocaleController();
      var pings = 0;
      c.addListener(() => pings++);
      await c.setOverride(const Locale('en'));
      expect(c.override, const Locale('en'));
      expect(pings, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LocaleController.storageKey), 'en');
    });

    test('setOverride(null) speichert system', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'en'});
      final c = LocaleController();
      await c.load();
      await c.setOverride(null);
      expect(c.override, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LocaleController.storageKey), 'system');
    });

    test('unveraenderter Wert loest keine Benachrichtigung aus', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = LocaleController();
      var pings = 0;
      c.addListener(() => pings++);
      await c.setOverride(null);
      expect(pings, 0);
    });
  });

  group('resolveEatovaLocale (Spec §3: Geraet deutsch -> de, sonst en)', () {
    test('deutsches Geraet bekommt Deutsch', () {
      expect(resolveEatovaLocale(const [Locale('de', 'DE')]),
          const Locale('de'));
    });

    test('russisches Geraet bekommt Englisch', () {
      expect(resolveEatovaLocale(const [Locale('ru')]), const Locale('en'));
    });

    test('Praeferenzliste wird der Reihe nach gelaufen', () {
      expect(resolveEatovaLocale(const [Locale('fr'), Locale('de')]),
          const Locale('de'));
      expect(resolveEatovaLocale(const [Locale('en'), Locale('de')]),
          const Locale('en'));
    });

    test('leere/fehlende Liste faellt auf Englisch', () {
      expect(resolveEatovaLocale(const []), const Locale('en'));
      expect(resolveEatovaLocale(null), const Locale('en'));
    });
  });
}
