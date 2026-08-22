import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Calendar access to older days in the food tab: a calendar button next to
// the date chips whose selection runs through the same onDateSelected path as
// the chips. Plus the loading state for on-demand days, where dayLoading
// replaces the history with a spinner.

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

/// Food tab harness with the same de localization as EatovaApp.
Future<void> _pumpFoodTab(
  WidgetTester tester, {
  ValueChanged<DateTime>? onDateSelected,
  bool dayLoading = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
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
  // With dayLoading the spinner never stops, so pumpAndSettle would never
  // settle: pump a bounded amount instead.
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

    // German dialog (de delegates), custom help text.
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('Tag wählen'), findsOneWidget);
    expect(find.text('Abbrechen'), findsOneWidget);

    // Page to the PREVIOUS month and pick the 15th: it exists in every month,
    // is always in the past (lastDate = today never bites) and never collides
    // with the today special case.
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
    // History slots are absent while loading.
    expect(find.text('Tag wird geladen…'), findsOneWidget);
  });

  testWidgetsRobust('Ohne dayLoading rendert der Verlauf wie bisher',
      (WidgetTester tester) async {
    await _pumpFoodTab(tester);

    expect(find.byKey(const ValueKey('food-day-loading')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
