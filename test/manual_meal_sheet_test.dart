import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

// Manueller Eintrag (Spec 2026-08-13): Formular pro 100 g + Portion.
// Menschen-Eingaben werden ABGELEHNT statt geklemmt: Save sperrt, Feld
// traegt den Bereichs-Fehler.

class _ResultHalter {
  MealAnalysisResult? result;
}

Future<_ResultHalter> _open(
  WidgetTester tester, {
  String? initialName,
}) async {
  final halter = _ResultHalter();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open-manual'),
              onPressed: () async {
                halter.result = await showManualMealSheet(
                  context,
                  initialName: initialName,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-manual')));
  await tester.pumpAndSettle();
  return halter;
}

FilledButton _saveButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('manual-meal-save')),
    );

void main() {
  testWidgets('Save sperrt, bis Name + kcal/100 g + Gramm gültig sind',
      (tester) async {
    await _open(tester);
    expect(_saveButton(tester).onPressed, isNull,
        reason: 'leeres Formular (Gramm ist mit 100 vorbelegt) sperrt');

    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Bauern-Mozzarella');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '2000');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull,
        reason: '2000 kcal/100 g ist physikalisch unmöglich');
    expect(find.text('0–900 kcal'), findsOneWidget,
        reason: 'Ablehnen mit Bereichs-Fehler statt stiller Klemmung');

    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '265');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('liefert das gerechnete Ergebnis samt Vorschau zurück',
      (tester) async {
    final halter = await _open(tester);
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Bauern-Mozzarella');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '265');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-grams')), '125');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-protein')), '18');
    await tester.pump();

    expect(find.byKey(const ValueKey('manual-meal-computed')), findsOneWidget);
    expect(find.text('= 331 kcal für 125 g'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
    await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
    await tester.pumpAndSettle();

    final r = halter.result;
    expect(r, isNotNull);
    expect(r!.mealName, 'Bauern-Mozzarella');
    expect(r.caloriesKcal, 331);
    expect(r.estimatedGrams, 125);
    expect(r.protein, '22,5 g');
    expect(r.carbs, '-');
    expect(r.sourceLabel, 'manual');
    expect(r.explicitZeroKcal, isFalse);
  });

  testWidgets('0 kcal (Wasser) ist speicherbar und trägt explicitZeroKcal',
      (tester) async {
    final halter = await _open(tester);
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-name')), 'Wasser');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-kcal100')), '0');
    await tester.enterText(
        find.byKey(const ValueKey('manual-meal-grams')), '500');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('manual-meal-save')));
    await tester.tap(find.byKey(const ValueKey('manual-meal-save')));
    await tester.pumpAndSettle();

    expect(halter.result?.caloriesKcal, 0);
    expect(halter.result?.explicitZeroKcal, isTrue);
  });

  testWidgets('initialName belegt das Namensfeld vor (Such-CTA)',
      (tester) async {
    await _open(tester, initialName: 'Bauernmozzarella');
    final feld = tester.widget<TextField>(
      find.byKey(const ValueKey('manual-meal-name')),
    );
    expect(feld.controller?.text, 'Bauernmozzarella');
  });

  testWidgets('Abbrechen liefert null', (tester) async {
    final halter = await _open(tester);
    // Sheet per Barriere-Tap schließen (oberhalb des Sheets tippen).
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(halter.result, isNull);
  });
}
