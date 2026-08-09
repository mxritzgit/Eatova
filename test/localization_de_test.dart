import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

// Deutsche Material-Lokalisierung (2026-08-06): EatovaApp pinnt locale/
// supportedLocales auf de und verdrahtet die flutter_localizations-Delegates.
// Damit rendern SDK-Dialoge — allen voran showTimePicker (Schlafziel im
// Settings-Sheet, settings_sheet.dart) und showDatePicker (Food-Tab-Kalender,
// Edit-Sheet) — deutsch und im 24h-Format statt Englisch + AM/PM.
//
// Die Tests fahren die ECHTE App-Schale (EatovaApp -> MaterialApp) und
// pruefen erstens die Localization-Werte auf einem Context aus dem App-Baum
// (exakt der Pfad, den showTimePicker intern nutzt) und zweitens einen real
// geoeffneten TimePicker.

// Viewport-Pinning + Overflow-Toleranz wie in widget_test.dart.
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
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();

    // Design-Refactor 2026-08: die App landet auf „Heute" (Index 0); der
    // Food-Tab wird im lazy IndexedStack erst beim ersten Besuch gebaut.
    // Gebraucht wird hier nur IRGENDEIN Context aus dem echten App-Baum —
    // der Landepunkt ist der stabilste.
    final context =
        tester.element(find.byKey(const ValueKey('screen-today')));
    expect(Localizations.localeOf(context), const Locale('de'));

    final l10n = MaterialLocalizations.of(context);
    expect(l10n.cancelButtonLabel, 'Abbrechen');
    // Exakt der Format-Entscheid, den showTimePicker trifft: fuer de liefert
    // GlobalMaterialLocalizations HH:mm — unabhaengig vom Geraete-Flag.
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
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();

    // Design-Refactor 2026-08: die App landet auf „Heute" (Index 0); der
    // Food-Tab wird im lazy IndexedStack erst beim ersten Besuch gebaut.
    // Gebraucht wird hier nur IRGENDEIN Context aus dem echten App-Baum —
    // der Landepunkt ist der stabilste.
    final context =
        tester.element(find.byKey(const ValueKey('screen-today')));
    // Gleicher Aufruf wie das Schlafziel-Feld im Settings-Sheet
    // (settings_sheet.dart, _SleepGoalField).
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
