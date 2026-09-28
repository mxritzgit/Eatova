import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// Wiring of the display mode in the real app shell.
//
// Since the dark-only rollout (2026-09-28, `kDarkOnly`) the shell renders the
// dark theme whatever the stored preference says, and it withholds the
// [ThemeModeScope] so the settings page drops its appearance row instead of
// showing a switch that changes nothing. The controller itself stays wired
// (loaded, persisted), so flipping `kDarkOnly` brings the switch back.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpApp(WidgetTester tester, [ThemeModeController? c]) async {
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

  MaterialApp app(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp));

  test('the app is dark-only for now', () {
    expect(kDarkOnly, isTrue,
        reason: 'user decision 2026-09-28 ("erstmal dunkel"); flipping it '
            'must be a deliberate change that also updates this suite');
  });

  testWidgets('a stored "light" preference still renders the dark theme',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeModeController.storageKey: 'light',
    });

    // The shell's OWN controller, loading from storage like in production.
    await pumpApp(tester);

    expect(app(tester).themeMode, ThemeMode.dark);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark);
    expect(appContext(tester).t.bg, AppTokens.dark.bg);
    // The preference itself is untouched — nothing overwrote it.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeModeController.storageKey), 'light');
  });

  testWidgets('a controller switched to light does not leave the dark theme',
      (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark);

    controller.setModeSync(ThemeMode.system);
    await tester.pumpAndSettle();
    controller.setModeSync(ThemeMode.light);
    await tester.pumpAndSettle();

    expect(app(tester).themeMode, ThemeMode.dark);
    expect(Theme.of(appContext(tester)).brightness, Brightness.dark);
    // The light palette stays wired for the switch back.
    expect(app(tester).theme?.extension<AppTokens>()?.bg, AppTokens.light.bg);
    expect(app(tester).darkTheme?.extension<AppTokens>()?.bg,
        AppTokens.dark.bg);
  });

  testWidgets('without a user choice the shell offers no appearance scope',
      (tester) async {
    final controller = ThemeModeController(initial: ThemeMode.light);
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    // Exactly the call SettingsScreen makes; null drops the appearance row.
    expect(ThemeModeScope.maybeOf(appContext(tester)), isNull,
        reason: 'under kDarkOnly the switch would change nothing, so the '
            'settings page must not show it');
  });

  testWidgets('status and navigation bar are styled for a dark app',
      (tester) async {
    await pumpApp(tester);

    final regions = tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .toList();
    expect(regions, isNotEmpty);
    final style = regions.first.value;
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
    expect(style.statusBarColor, const Color(0x00000000));
    expect(style.systemNavigationBarColor, AppTokens.dark.bg);
  });
}
