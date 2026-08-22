import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// Wiring of the display mode in the real app shell.
//
// The other theme tests provide the [ThemeModeScope] themselves, leaving the
// one place the chain hangs on in the shipped app untested: `EatovaApp.build`.
// The settings screen reads the controller with `ThemeModeScope.maybeOf` and
// drops the appearance row entirely when it is null, so a missing or
// misplaced scope would silently remove the switch without any test failing.
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

  /// A context from the real app tree below the Navigator, the same position
  /// the pushed settings route looks up its controller from.
  BuildContext appContext(WidgetTester tester) =>
      tester.element(find.byKey(const ValueKey('screen-today')));

  testWidgets('die App-Schale stellt den ThemeModeScope, den die '
      'Einstellungs-Seite sucht', (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    // Exactly the call SettingsScreen makes.
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

    // The switch does nothing but this, and the app must really change
    // brightness, not just set a field.
    expect(Theme.of(appContext(tester)).brightness, Brightness.light);

    controller.setModeSync(ThemeMode.dark);
    await tester.pumpAndSettle();

    expect(app().themeMode, ThemeMode.dark);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark,
        reason: 'ein Moduswechsel muss den ganzen Baum umfaerben — sonst ist '
            'der Schalter in den Einstellungen wirkungslos');
  });
}
