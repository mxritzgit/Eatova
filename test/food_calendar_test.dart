import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Kalender-Zugriff auf aeltere Tage im Food-Tab (2026-08-06): neben den
// Datums-Chips sitzt ein Kalender-Knopf (showDatePicker, dank de-Locale
// deutsch), dessen Auswahl ueber denselben onDateSelected-Pfad laeuft wie die
// Chips (setFoodDate-Kette im Store). Dazu der Lade-Zustand fuer on-demand
// nachgeladene Alt-Tage: dayLoading ersetzt den Verlauf durch einen Spinner.

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

/// Food-Tab-Haerness mit derselben de-Lokalisierung wie EatovaApp.
Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
  bool dayLoading = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: MealAnalysisScreen(
              dailyConsumedKcal: 0,
              onDateSelected: onDateSelected,
              dayLoading: dayLoading,
            ),
          ),
        ),
      ),
    ),
  );
  // Mit dayLoading dreht der Spinner endlos — pumpAndSettle wuerde nie
  // settlen, daher dort nur begrenzt pumpen.
  if (dayLoading) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgetsRobust(
      'Kalender-Knopf oeffnet deutschen DatePicker; Auswahl laeuft durch den '
      'Chip-Callback (onDateSelected)', (WidgetTester tester) async {
    DateTime? selected;
    await _pumpFoodTab(tester, onDateSelected: (d) => selected = d);

    expect(find.byKey(const ValueKey('food-date-calendar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('food-date-calendar')));
    await tester.pumpAndSettle();

    // Deutscher Dialog (de-Delegates), eigener Hilfetext.
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('Tag wählen'), findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);

    // Deterministisch in den VORMONAT blaettern und den 15. waehlen: den 15.
    // gibt es in jedem Monat, er liegt immer in der Vergangenheit (lastDate =
    // heute greift nie) und kollidiert nie mit dem Heute-Sonderfall.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('15'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final today = DateUtils.dateOnly(DateTime.now());
    expect(selected, DateTime(today.year, today.month - 1, 15));
    expect(find.byType(DatePickerDialog), findsNothing);
  });

  testWidgetsRobust('dayLoading zeigt den Spinner statt der Verlaufskarte',
      (WidgetTester tester) async {
    await _pumpFoodTab(tester, dayLoading: true);

    expect(find.byKey(const ValueKey('food-day-loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Verlaufs-Slots sind waehrend des Ladens nicht da.
    expect(find.text('Tag wird geladen…'), findsOneWidget);
  });

  testWidgetsRobust('Ohne dayLoading rendert der Verlauf wie bisher',
      (WidgetTester tester) async {
    await _pumpFoodTab(tester);

    expect(find.byKey(const ValueKey('food-day-loading')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
