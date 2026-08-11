import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// Die einzige wirklich NEUE Einstellung des Design-Refactors 2026-08-09:
// „Erscheinungsbild" als Drei-Segment-Pille (System / Hell / Dunkel).
//
// Sie ist eine GERAETE-Einstellung, keine Profil-Eigenschaft: sie wird sofort
// ueber den [ThemeModeController] persistiert und ist deshalb nichts, das man
// speichern oder verwerfen koennte.
//
// ## Warum diese Datei umgeschrieben wurde (2026-08-10)
//
// Die Pille stand zuerst auf „Profil & Ziele" — dem einzigen Screen, den es
// damals gab. Mit der Trennung (Nutzer-Entscheid) hat der Anzeige-Modus seinen
// richtigen Platz gefunden: in den EINSTELLUNGEN, neben Konto und Daten,
// waehrend „Profil & Ziele" nur noch Koerperdaten und Ziele traegt. Die
// Zusicherungen sind dieselben geblieben, nur der Screen darunter ist ein
// anderer; die Gruppe heisst dort „PRÄFERENZEN" statt „ANZEIGE", weil sie
// nicht mehr allein steht.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpSettings(
    WidgetTester tester, {
    ThemeModeController? controller,
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
      theme: buildEatovaTheme(Brightness.light),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
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
          : ThemeModeScope(controller: controller, child: app),
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

  testWidgets('die Pille zeigt den Modus des Controllers', (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpSettings(tester, controller: controller);

    expect(find.text('PRÄFERENZEN'), findsOneWidget);
    expect(find.text('Erscheinungsbild'), findsOneWidget);
    expect(
      tester
          .widget<SettingsThemeModePill>(
            find.byKey(const ValueKey('settings-theme-mode')),
          )
          .mode,
      ThemeMode.light,
    );
    for (final key in const <String>[
      'settings-theme-mode-system',
      'settings-theme-mode-light',
      'settings-theme-mode-dark',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
  });

  testWidgets('die drei Optionen schalten den Modus um', (tester) async {
    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    await pumpSettings(tester, controller: controller);
    expect(controller.mode, ThemeMode.system);

    await tippeOption(tester, 'settings-theme-mode-dark');
    expect(controller.mode, ThemeMode.dark);

    await tippeOption(tester, 'settings-theme-mode-light');
    expect(controller.mode, ThemeMode.light);

    await tippeOption(tester, 'settings-theme-mode-system');
    expect(controller.mode, ThemeMode.system);
  });

  testWidgets('ohne ThemeModeScope fehlt die Erscheinungsbild-Zeile ersatzlos',
      (tester) async {
    // Previews und alle Alt-Tests pumpen die Seite ohne Scope. Ein Schalter
    // ohne Controller waere ein toter Schalter — also gar keiner.
    await pumpSettings(tester);

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(find.text('Erscheinungsbild'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('ein Moduswechsel fragt beim Verlassen nichts nach',
      (tester) async {
    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    await pumpSettings(tester, controller: controller);
    await tippeOption(tester, 'settings-theme-mode-dark');

    // Zurueck: es gibt nichts zu verwerfen — der Modus ist bereits
    // persistiert, und ein Verwerfen-Dialog koennte ihn gar nicht
    // zuruecknehmen.
    await tester.ensureVisible(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
    expect(controller.mode, ThemeMode.dark);
  });
}
