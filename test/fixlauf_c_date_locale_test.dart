// Fix run for review 2026-08-27, F3-04 (+ F3-10): the day chips of the edit
// sheet and of the food tab hardcoded "27.8." — under `en` the snack of the
// same action says "8/27". Both now go through DateFormat.Md(localeName); the
// edit sheet also reads clock.now(), so the test pins "today".

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

/// Thursday, 27 August 2026, 10:00.
final DateTime _jetzt = DateTime(2026, 8, 27, 10);

const MealAnalysisResult _result = MealAnalysisResult(
  mealName: 'Test-Bowl',
  caloriesKcal: 350,
  estimatedGrams: 350,
  kcalPer100G: 100,
  protein: '30 g',
  carbs: '40 g',
  fat: '10 g',
  confidence: 'Hoch',
  portionNotes: 'Test.',
);

LoggedMeal? _update(
  String id, {
  MealAnalysisResult? result,
  MealSlot? slot,
  DateTime? day,
}) =>
    null;

Widget _app(Widget home, Locale locale) => MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

/// Phone viewport; overflows are collected and asserted empty, not swallowed.
List<String> _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
  return overflows;
}

Future<List<String>> _openEditSheet(WidgetTester tester, Locale locale) async {
  final overflows = _telefon(tester);
  await withClock(Clock.fixed(_jetzt), () async {
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showEditMealSheet(
                  context,
                  meal: LoggedMeal(
                    id: 'meal-1',
                    result: _result,
                    loggedAt: _jetzt,
                    forcedSlot: MealSlot.breakfast,
                    localDay: '2026-08-27',
                  ),
                  onUpdateMeal: _update,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        locale,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-meal-day-picker')), findsOneWidget);
  });
  return overflows;
}

Future<List<String>> _pumpFoodTab(WidgetTester tester, Locale locale) async {
  final overflows = _telefon(tester);
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: MealAnalysisScreen(
          dailyConsumedKcal: 0,
          selectedDate: DateTime.now(),
        ),
      ),
      locale,
    ),
  );
  await tester.pumpAndSettle();
  return overflows;
}

void main() {
  setUpAll(initializeDateFormatting);

  group('Bearbeiten-Sheet, Tag-Chips', () {
    testWidgets('englisch: „8/27" statt „27.8."', (tester) async {
      final overflows = await _openEditSheet(tester, const Locale('en'));
      expect(find.text('8/27'), findsOneWidget);
      expect(find.text('27.8.'), findsNothing);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });

    testWidgets('deutsch bleibt „27.8."', (tester) async {
      final overflows = await _openEditSheet(tester, const Locale('de'));
      expect(find.text('27.8.'), findsOneWidget);
      expect(find.text('8/27'), findsNothing);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });
  });

  group('Food-Tab, Datumsstreifen', () {
    testWidgets('englisch formatiert die Chips mit DateFormat.Md', (tester) async {
      final overflows = await _pumpFoodTab(tester, const Locale('en'));
      final heute = DateTime.now();
      expect(find.text(DateFormat.Md('en').format(heute)), findsWidgets);
      expect(find.text('${heute.day}.${heute.month}.'), findsNothing);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });

    testWidgets('deutsch formatiert die Chips mit DateFormat.Md', (tester) async {
      final overflows = await _pumpFoodTab(tester, const Locale('de'));
      final heute = DateTime.now();
      expect(find.text(DateFormat.Md('de').format(heute)), findsWidgets);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });
  });
}
