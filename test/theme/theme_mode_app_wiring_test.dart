import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// VERDRAHTUNG des Anzeige-Modus in der ECHTEN App-Schale.
//
// Warum diese Datei existiert (Verifikation Design-Refactor 2026-08-09):
// test/settings_theme_mode_test.dart und test/theme/theme_mode_controller_test
// pruefen den Schalter und den Controller — aber BEIDE stellen den
// [ThemeModeScope] selbst. Damit blieb genau die eine Stelle ungeprueft, an
// der die Kette in der ausgelieferten App haengt: `EatovaApp.build`.
//
// Das ist keine theoretische Luecke. `SettingsScreen._praeferenzenGruppe()` liest
// den Controller mit `ThemeModeScope.maybeOf(context)` und laesst die Gruppe
// bei `null` die Zeile ERSATZLOS weg (settings_screen.dart) — bewusst, damit
// Previews keinen toten Schalter zeigen. Faellt der Scope in eatova_app.dart
// weg oder rutscht er unter den Navigator, verschwindet „Erscheinungsbild"
// still aus den Einstellungen: kein Absturz, keine Fehlermeldung, und alle
// zehn bestehenden Theme-Tests bleiben gruen, weil sie den Scope ja selbst
// mitbringen. Dieser Test ist das fehlende Gegenstueck.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpApp(WidgetTester tester, ThemeModeController c) async {
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

    await tester.pumpWidget(EatovaApp(themeModeController: c));
    await tester.pumpAndSettle();
  }

  /// Ein Context aus dem echten App-Baum, UNTERHALB des Navigators — also
  /// dieselbe Lage, aus der die gepushte Einstellungs-Route ihren Controller
  /// sucht.
  BuildContext appContext(WidgetTester tester) =>
      tester.element(find.byKey(const ValueKey('screen-today')));

  testWidgets('die App-Schale stellt den ThemeModeScope, den die '
      'Einstellungs-Seite sucht', (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    // Exakt der Aufruf aus SettingsScreen._praeferenzenGruppe().
    final gefunden = ThemeModeScope.maybeOf(appContext(tester));
    expect(gefunden, isNotNull,
        reason: 'ohne Scope laesst die Einstellungs-Seite „Erscheinungsbild" '
            'kommentarlos weg — der Nutzer haette den Schalter nie');
    expect(identical(gefunden, controller), isTrue,
        reason: 'die Seite muss DEN Controller bekommen, den die Schale '
            'persistiert — nicht eine zweite Instanz');
  });

  testWidgets('der Modus der Schale steuert das Theme der MaterialApp',
      (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.light);
    expect(app().darkTheme, isNotNull,
        reason: 'ohne darkTheme waere ThemeMode.dark folgenlos');

    // Der Umschalter tut nichts anderes als das hier — und die App muss
    // daraufhin wirklich die Helligkeit wechseln, nicht nur ein Feld setzen.
    expect(Theme.of(appContext(tester)).brightness, Brightness.light);

    controller.setModeSync(ThemeMode.dark);
    await tester.pumpAndSettle();

    expect(app().themeMode, ThemeMode.dark);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark,
        reason: 'ein Moduswechsel muss den ganzen Baum umfaerben — sonst ist '
            'der Schalter in den Einstellungen wirkungslos');
  });
}
