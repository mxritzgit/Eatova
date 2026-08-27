// Language selection in settings (system / German / English) — mirror of
// `settings_theme_mode_test.dart`, with [LocaleScope] instead of
// [ThemeModeScope].
//
// [LocaleScope] must sit ABOVE the MaterialApp: the settings page is pushed as
// a route, and a scope inside `home` would not be an ancestor of it. That is
// why this suite builds with [localizedApp] and pumps itself instead of
// calling `pumpLocalized`.
//
// Language is a DEVICE setting, not a profile property: persisted immediately
// via [LocaleController], so there is nothing to save or discard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import 'support/harness.dart';

Future<void> _pumpSettings(
  WidgetTester tester, {
  LocaleController? controller,
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.light,
}) async {
  pinPhoneViewport(tester);

  final app = localizedApp(
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-settings'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const SettingsScreen(email: 'jonas@example.com'),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
    locale: locale,
    brightness: brightness,
  );

  await tester.pumpWidget(
    controller == null
        ? app
        : LocaleScope(controller: controller, child: app),
  );
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
}

Future<void> _tippeOption(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

LocaleController _controller({Locale? initial}) {
  final controller = LocaleController(initial: initial);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgetsRobust('die Pille zeigt den Override des Controllers',
      (tester) async {
    await _pumpSettings(tester, controller: _controller(initial: const Locale('en')));

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

  testWidgetsRobust('Sprach-Pill setzt den Override auf Englisch',
      (tester) async {
    final controller = _controller();

    await _pumpSettings(tester, controller: controller);
    expect(controller.override, isNull);

    await tester.tap(find.byKey(const ValueKey('settings-language-en')));
    await tester.pumpAndSettle();
    expect(controller.override, const Locale('en'));

    await _tippeOption(tester, 'settings-language-de');
    expect(controller.override, const Locale('de'));

    await _tippeOption(tester, 'settings-language-system');
    expect(controller.override, isNull);
  });

  testWidgetsRobust('ohne LocaleScope faellt die Zeile ersatzlos weg',
      (tester) async {
    // Previews and all legacy tests pump the page without a scope. A control
    // without a controller would be a dead control — so there is none.
    await _pumpSettings(tester);

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    expect(find.text('Sprache'), findsNothing);
    expect(find.byKey(const ValueKey('settings-language')), findsNothing);
  });

  // One case per brightness instead of two hand-written tests. A double pump
  // in ONE test would not do: the second `pumpWidget` keeps the navigator
  // state (including the pushed route) and hides the open button.
  renderMatrix(
    'Der Einstellungen-Screen rendert englisch',
    (tester, c) async {
      await _pumpSettings(
        tester,
        controller: _controller(initial: const Locale('en')),
        locale: c.locale,
        brightness: c.brightness,
      );
      expect(find.text('Language'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    locales: const <Locale>[Locale('en')],
  );
}
