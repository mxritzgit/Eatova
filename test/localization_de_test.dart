import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

// German Material localization. EatovaApp no longer pins locale to de; it
// follows the device via resolveEatovaLocale. This file checks the de branch:
// a German device still gets German SDK dialogs in 24h format instead of
// English with AM/PM, so the device language is pinned explicitly here.
//
// The tests boot the REAL app shell and check both the localization values on
// a context from the app tree (the path showTimePicker uses internally) and a
// really opened TimePicker.

// Viewport pinning + overflow tolerance as in widget_test.dart.
void testWidgetsRobust(
  String description,
  WidgetTesterCallback callback,
) {
  testWidgets(description, (tester) async {
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

    await callback(tester);
  });
}

void main() {
  testWidgetsRobust(
      'App laeuft unter de-Locale: Material-Strings deutsch, '
      'TimePicker-Format 24h (HH:mm)', (WidgetTester tester) async {
    // Pin the device language: without an override the app resolves via
    // resolveEatovaLocale (see the file header).
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();

    // Any context from the real app tree will do; the landing tab is the most
    // stable one (the food tab is built lazily on first visit).
    final context =
        tester.element(find.byKey(const ValueKey('screen-today')));
    expect(Localizations.localeOf(context), const Locale('de'));

    final l10n = MaterialLocalizations.of(context);
    expect(l10n.cancelButtonLabel, 'Abbrechen');
    // Exactly the format decision showTimePicker makes: for de,
    // GlobalMaterialLocalizations returns HH:mm regardless of the device flag.
    expect(
      l10n.timeOfDayFormat(
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      ),
      TimeOfDayFormat.HH_colon_mm,
    );
  });

  testWidgetsRobust(
      'showTimePicker aus dem App-Baum rendert deutsch und ohne AM/PM',
      (WidgetTester tester) async {
    // Pin the device language: without an override the app resolves via
    // resolveEatovaLocale (see the file header).
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();

    // Any context from the real app tree will do; the landing tab is the most
    // stable one (the food tab is built lazily on first visit).
    final context =
        tester.element(find.byKey(const ValueKey('screen-today')));
    // Same call as the sleep-goal field in settings_sheet.dart.
    unawaited(showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 30),
      helpText: 'Schlafziel',
    ));
    await tester.pumpAndSettle();

    expect(find.text('Schlafziel'), findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);
    expect(find.text('AM'), findsNothing);
    expect(find.text('PM'), findsNothing);

    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
  });
}
