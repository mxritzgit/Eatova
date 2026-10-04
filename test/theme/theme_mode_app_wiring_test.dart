import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// Wiring of the display mode in the real app shell.
//
// The dark-only rollout (2026-09-28) ended with the light palette of
// 2026-10-04: the shell follows [ThemeModeController] (default: the device),
// hands the controller to the settings page through [ThemeModeScope], and
// styles the system bars for the brightness actually shown. Every case pins
// the device brightness, so none of them depends on the test binding's
// default.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpApp(
    WidgetTester tester, {
    ThemeModeController? controller,
    Brightness device = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.platformBrightnessTestValue = device;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await tester.pumpWidget(EatovaApp(themeModeController: controller));
    await tester.pumpAndSettle();
  }

  /// A context from the real app tree below the Navigator, the same position
  /// the pushed settings route looks up its controller from.
  BuildContext appContext(WidgetTester tester) =>
      tester.element(find.byKey(const ValueKey('screen-today')));

  MaterialApp app(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp));

  /// The outermost overlay style in the tree — the app-wide one.
  SystemUiOverlayStyle overlay(WidgetTester tester) => tester
      .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      )
      .first
      .value;

  test('ohne Wahl folgt der Controller dem Geraet', () {
    final controller = ThemeModeController();
    addTearDown(controller.dispose);
    expect(controller.mode, ThemeMode.system);
  });

  group('System-Modus folgt dem Geraet', () {
    for (final device in Brightness.values) {
      testWidgets('Geraet ${device.name} -> Palette ${device.name}',
          (tester) async {
        // The shell's OWN controller, loading from (empty) storage.
        await pumpApp(tester, device: device);

        expect(app(tester).themeMode, ThemeMode.system);
        expect(Theme.of(appContext(tester)).brightness, device);
        expect(
          appContext(tester).t.bg,
          device == Brightness.dark ? AppTokens.dark.bg : AppTokens.light.bg,
        );
      });
    }
  });

  group('eine gespeicherte Wahl schlaegt das Geraet', () {
    for (final (gespeichert, device, erwartet) in <(String, Brightness,
        Brightness)>[
      ('light', Brightness.dark, Brightness.light),
      ('dark', Brightness.light, Brightness.dark),
    ]) {
      testWidgets('"$gespeichert" auf einem Geraet in ${device.name}',
          (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          ThemeModeController.storageKey: gespeichert,
        });
        await pumpApp(tester, device: device);

        expect(Theme.of(appContext(tester)).brightness, erwartet);
        expect(
          appContext(tester).t.bg,
          erwartet == Brightness.dark ? AppTokens.dark.bg : AppTokens.light.bg,
        );
      });
    }
  });

  testWidgets('die App-Schale stellt den ThemeModeScope, den die '
      'Einstellungs-Seite sucht', (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller: controller);

    // Exactly the call SettingsScreen makes.
    final gefunden = ThemeModeScope.maybeOf(appContext(tester));
    expect(gefunden, isNotNull,
        reason: 'ohne Scope laesst die Einstellungs-Seite '
            '„Erscheinungsbild" kommentarlos weg — der Nutzer haette den '
            'Schalter nie');
    expect(identical(gefunden, controller), isTrue,
        reason: 'die Seite muss DEN Controller bekommen, den die Schale '
            'persistiert — nicht eine zweite Instanz');
  });

  testWidgets('der Modus der Schale steuert das Theme der MaterialApp',
      (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    // A DARK device, so the light pass cannot come from the device.
    await pumpApp(tester, controller: controller, device: Brightness.dark);

    expect(app(tester).themeMode, ThemeMode.light);
    expect(app(tester).darkTheme, isNotNull,
        reason: 'ohne darkTheme waere ThemeMode.dark folgenlos');
    expect(Theme.of(appContext(tester)).brightness, Brightness.light);
    expect(appContext(tester).t.bg, AppTokens.light.bg);

    controller.setModeSync(ThemeMode.dark);
    await tester.pumpAndSettle();

    expect(app(tester).themeMode, ThemeMode.dark);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark,
        reason: 'ein Moduswechsel muss den ganzen Baum umfaerben — sonst '
            'ist der Schalter in den Einstellungen wirkungslos');
    expect(appContext(tester).t.bg, AppTokens.dark.bg);

    controller.setModeSync(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark,
        reason: 'System = das (dunkle) Geraet');
  });

  testWidgets('main reicht den vorab geladenen Controller durch',
      (tester) async {
    // `_bootAndRun` loads the stored mode before runApp and hands the
    // controller in here, so the first frame is already in that mode.
    final controller = ThemeModeController(initial: ThemeMode.dark);
    addTearDown(controller.dispose);
    expect(
      identical(
        buildEatovaApp(themeModeController: controller).themeModeController,
        controller,
      ),
      isTrue,
    );
    expect(buildEatovaApp().themeModeController, isNull);
  });

  group('Status- und Navigationsleiste folgen der Helligkeit', () {
    testWidgets('dunkel: helle Symbole auf dunklem Grund', (tester) async {
      await pumpApp(tester, device: Brightness.dark);

      final style = overlay(tester);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.statusBarBrightness, Brightness.dark);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(style.statusBarColor, const Color(0x00000000));
      expect(style.systemNavigationBarColor, AppTokens.dark.bg);
    });

    testWidgets('hell: dunkle Symbole auf hellem Grund', (tester) async {
      await pumpApp(tester, device: Brightness.light);

      final style = overlay(tester);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.statusBarBrightness, Brightness.light);
      // SystemUiOverlayStyle.dark alone asks for LIGHT navigation icons
      // (it assumes a black bar); on the light page color they vanished.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarColor, const Color(0x00000000));
      expect(style.systemNavigationBarColor, AppTokens.light.bg);
    });
  });

  group('der Boot-Fehler-Screen folgt dem Geraet', () {
    for (final device in Brightness.values) {
      testWidgets(device.name, (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = device;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(buildBootErrorApp(StateError('boot')));
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold));
        final tokens =
            device == Brightness.dark ? AppTokens.dark : AppTokens.light;
        expect(Theme.of(context).brightness, device);
        expect(context.t.bg, tokens.bg);
        final style = overlay(tester);
        expect(
          style.statusBarIconBrightness,
          device == Brightness.dark ? Brightness.light : Brightness.dark,
        );
        expect(style.systemNavigationBarColor, tokens.bg);
      });
    }
  });
}
