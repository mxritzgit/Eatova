import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Sprachwahl in den Einstellungen (System / Deutsch / English) — Spiegel von
// `settings_theme_mode_test.dart`, nur mit [LocaleScope] statt
// [ThemeModeScope].
//
// Eine ROHE `MaterialApp` wie im Vorbild reicht hier NICHT: die Pille zieht
// ihre Beschriftungen aus `context.l10n`, und `AppLocalizations.of(context)`
// wirft ohne registrierten Delegate. Der Pump-Unterbau hier traegt deshalb
// zusaetzlich `locale` + `localizationsDelegates` (Vorbild:
// `test/widgets/design/design_harness.dart#designHarness`).
//
// Sie ist eine GERAETE-Einstellung, keine Profil-Eigenschaft: sie wird sofort
// ueber den [LocaleController] persistiert und ist deshalb nichts, das man
// speichern oder verwerfen koennte (Spiegel des Anzeige-Modus).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpSettings(
    WidgetTester tester, {
    LocaleController? controller,
    Locale locale = const Locale('de'),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    final app = MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: locale,
      supportedLocales: const <Locale>[Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-settings'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(
                    email: 'jonas@example.com',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      controller == null
          ? app
          : LocaleScope(controller: controller, child: app),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  Future<void> tippeOption(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('die Pille zeigt den Override des Controllers', (tester) async {
    final controller = LocaleController(initial: const Locale('en'));
    addTearDown(controller.dispose);

    await pumpSettings(tester, controller: controller);

    expect(find.text('PRÄFERENZEN'), findsOneWidget);
    expect(find.text('Sprache'), findsOneWidget);
    expect(
      tester
          .widget<SettingsLanguagePill>(
            find.byKey(const ValueKey('settings-language')),
          )
          .value,
      const Locale('en'),
    );
    for (final key in const <String>[
      'settings-language-system',
      'settings-language-de',
      'settings-language-en',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
  });

  testWidgets('Sprach-Pill setzt den Override auf Englisch', (tester) async {
    final controller = LocaleController();
    addTearDown(controller.dispose);

    await pumpSettings(tester, controller: controller);
    expect(controller.override, isNull);

    await tester.tap(find.byKey(const ValueKey('settings-language-en')));
    await tester.pumpAndSettle();
    expect(controller.override, const Locale('en'));

    await tippeOption(tester, 'settings-language-de');
    expect(controller.override, const Locale('de'));

    await tippeOption(tester, 'settings-language-system');
    expect(controller.override, isNull);
  });

  testWidgets('ohne LocaleScope faellt die Zeile ersatzlos weg',
      (tester) async {
    // Previews und alle Alt-Tests pumpen die Seite ohne Scope. Ein Schalter
    // ohne Controller waere ein toter Schalter — also gar keiner.
    await pumpSettings(tester);

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(find.text('Sprache'), findsNothing);
    expect(find.byKey(const ValueKey('settings-language')), findsNothing);
  });

  // Zwei getrennte Faelle statt eines doppelten Pumps in einem Test: ein
  // zweiter `pumpWidget`-Aufruf in DERSELBEN `testWidgets`-Funktion behaelt
  // den Navigator-Zustand (inkl. bereits gepushter Route) des ersten Pumps
  // bei — der „open-settings"-Knopf des zweiten Aufbaus war dadurch nicht
  // mehr auffindbar. Getrennte Tests sind ohnehin das Muster in
  // `settings_screen_render_test.dart` fuer Hell/Dunkel.
  testWidgets('Settings-Screen rendert englisch (hell)', (tester) async {
    final controller = LocaleController(initial: const Locale('en'));
    addTearDown(controller.dispose);
    await pumpSettings(
      tester,
      controller: controller,
      locale: const Locale('en'),
      brightness: Brightness.light,
    );
    expect(find.text('Language'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings-Screen rendert englisch (dunkel)', (tester) async {
    final controller = LocaleController(initial: const Locale('en'));
    addTearDown(controller.dispose);
    await pumpSettings(
      tester,
      controller: controller,
      locale: const Locale('en'),
      brightness: Brightness.dark,
    );
    expect(find.text('Language'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
