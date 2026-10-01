import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'support/harness.dart';

// German Material localization. EatovaApp no longer pins locale to de; it
// follows the device via resolveEatovaLocale. This file checks the de branch:
// a German device still gets German SDK dialogs in 24h format instead of
// English with AM/PM, so the device language is pinned explicitly here.
//
// The tests boot the REAL app shell and check both the localization values on
// a context from the app tree and a really opened DatePicker (the SDK dialog
// the app uses, edit_meal_sheet.dart and meal_plan_editor.dart; lib has no
// showTimePicker).

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

  testWidgetsRobust('showDatePicker aus dem App-Baum rendert deutsch',
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
    // The same SDK dialog as the day picker of the edit sheet.
    unawaited(showDatePicker(
      context: context,
      initialDate: DateTime(2026, 3, 20),
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2026, 12, 31),
      helpText: 'Tag wählen',
    ));
    await tester.pumpAndSettle();

    expect(find.text('Tag wählen'), findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);
    // The month header is spelled differently in de and en.
    expect(find.text('März 2026'), findsOneWidget);
    expect(find.text('March 2026'), findsNothing);

    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
  });
}
