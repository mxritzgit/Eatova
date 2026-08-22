import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/locale_controller.dart';

// WIRING of the display language in the REAL app shell. Mirror of
// test/theme/theme_mode_app_wiring_test.dart: a controller/widget check alone
// misses `EatovaApp.build`, the one place the chain hangs on in the shipped
// app.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpApp(WidgetTester tester, LocaleController c) async {
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

    await tester.pumpWidget(EatovaApp(localeController: c));
    await tester.pumpAndSettle();
  }

  testWidgets('Override en schaltet die App auf Englisch', (tester) async {
    final controller = LocaleController(initial: const Locale('en'));
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx), const Locale('en'));
  });

  testWidgets('System + russisches Geraet landet auf Englisch', (tester) async {
    tester.platformDispatcher.localesTestValue =
        const [Locale('ru'), Locale('ru', 'RU')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    final controller = LocaleController();
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx), const Locale('en'));
  });

  testWidgets('System + deutsches Geraet bleibt Deutsch', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    final controller = LocaleController();
    addTearDown(controller.dispose);

    await pumpApp(tester, controller);

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx), const Locale('de'));
  });
}
