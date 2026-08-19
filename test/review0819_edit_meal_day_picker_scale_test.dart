import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

// ---------------------------------------------------------------------------
// Komplettreview 2026-08-19, Fund 3 — der Tag-Picker des Bearbeiten-Sheets
// lief bei grosser Systemschrift ueber.
//
// Eine waagerechte ListView gibt ihren Kindern eine STRAFFE Querachse: die
// Hoehe des Streifens IST die Hoehe jedes Chips. Fest verdrahtete 58 px
// liessen nach dem 9+9-Polster 40 px fuer zwei mitskalierende Textzeilen —
// zu wenig, sobald der Nutzer die Schrift hochdreht.
//
// Gemessen wird geometrisch statt ueber die Ueberlauf-Ausnahme: das Sheet
// traegt bei doppelter Schrift an anderen Stellen eigene Ueberlaeufe (der
// Bestands-Harness in edit_meal_sheet_test.dart schluckt sie deshalb), eine
// Ausnahme waere hier also kein Beweis FUER DIESE Stelle.
// ---------------------------------------------------------------------------

/// Der Wert, den der Entwurf setzt — und der vor dem Fix fest verdrahtet war.
const double entwurfshoehe = 58;

/// Das senkrechte Innenpolster eines Chips (oben wie unten).
const double chipPolster = 9;

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Test-Bowl',
      caloriesKcal: 350,
      estimatedGrams: 350,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _loggedMeal() => LoggedMeal(
      id: 'meal-1',
      result: _result(),
      loggedAt: DateTime.now(),
      forcedSlot: MealSlot.breakfast,
    );

LoggedMeal? _update(
  String id, {
  MealAnalysisResult? result,
  MealSlot? slot,
  DateTime? day,
}) =>
    null;

Future<void> _openSheet(
  WidgetTester tester, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Ueberlaeufe ANDERER Stellen des Sheets duerfen diesen Test nicht faerben —
  // hier zaehlt allein die Geometrie des Tag-Streifens.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.light),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Der `builder` liegt UEBER dem Navigator — nur so erreicht die
      // Skalierung auch die modale Sheet-Route.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEditMealSheet(
                context,
                meal: _loggedMeal(),
                onUpdateMeal: _update,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bei Normalschrift bleibt der Streifen exakt der des Entwurfs',
      (tester) async {
    await _openSheet(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('edit-meal-day-picker'))).height,
      entwurfshoehe,
    );
  });

  testWidgets('bei doppelter Systemschrift waechst der Streifen mit',
      (tester) async {
    await _openSheet(tester, textScaler: const TextScaler.linear(2));

    expect(
      tester.getSize(find.byKey(const ValueKey('edit-meal-day-picker'))).height,
      greaterThan(entwurfshoehe),
      reason: 'eine feste Hoehe zwingt die Chips in eine Groesse, die ihre '
          'zwei Textzeilen nicht mehr fasst',
    );
  });

  testWidgets('bei doppelter Systemschrift bleiben beide Zeilen im Chip',
      (tester) async {
    await _openSheet(tester, textScaler: const TextScaler.linear(2));

    final chip = find.byKey(const ValueKey('edit-day-chip-0'));
    expect(chip, findsOneWidget);

    final zeilen = find.descendant(of: chip, matching: find.byType(Text));
    expect(zeilen, findsNWidgets(2), reason: 'Wochentag und Datum');

    final rahmen = tester.getRect(chip);
    final unterkante = tester.getRect(zeilen.last).bottom;

    expect(
      unterkante,
      lessThanOrEqualTo(rahmen.bottom - chipPolster),
      reason: 'Die Datumszeile laeuft unten aus dem Chip heraus '
          '(Chip $rahmen, Zeilenunterkante $unterkante)',
    );
  });
}
