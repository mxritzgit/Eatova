import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

// Seit meal_analyzer.dart explizite .timeout(...) auf Request-Abschluss und
// Body-Lesen traegt, kommt ein haengender LLM-Provider als TimeoutException
// beim Analyse-Sheet an. Der Nutzer soll dann eine ehrliche "dauert zu
// lange"-Meldung sehen — nicht die generische "Prüfe Internet, Supabase und
// OpenRouter"-Meldung, die eine kaputte Verbindung unterstellt.

const String _fallback =
    'Analyse fehlgeschlagen. Prüfe Internet, Supabase und OpenRouter.';
const String _timeoutText =
    'Das dauert gerade zu lange. Bitte versuch es gleich nochmal.';

Widget _sheetHost(Future<MealAnalysisResult> resultFuture) {
  return MaterialApp(
    home: Scaffold(
      body: MealAnalysisSheet(
        slot: MealSlot.lunch,
        resultFuture: resultFuture,
        previewImage: null,
        onAdd: (_, __) => '',
        onUpdateMeal: (_, __) {},
        failureMessage: _fallback,
      ),
    ),
  );
}

void main() {
  group('mealAnalysisErrorMessage', () {
    test('TimeoutException -> freundliche Timeout-Meldung', () {
      final error =
          TimeoutException('Future not completed', const Duration(seconds: 60));
      expect(mealAnalysisErrorMessage(error, _fallback), _timeoutText);
    });

    test('andere Fehler -> generische Meldung des jeweiligen Flows', () {
      expect(
        mealAnalysisErrorMessage(const HttpException('boom'), _fallback),
        _fallback,
      );
      expect(
        mealAnalysisErrorMessage(const FormatException('bad'), _fallback),
        _fallback,
      );
    });
  });

  testWidgets('Analyse-Sheet zeigt bei Timeout die Timeout-Meldung als Snack',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(_sheetHost(completer.future));

    completer.completeError(
      TimeoutException('Future not completed', const Duration(seconds: 60)),
    );
    await tester.pump(); // Fehler verarbeiten
    await tester.pump(); // Snack einblenden

    expect(find.text(_timeoutText), findsOneWidget);
    expect(find.text(_fallback), findsNothing);

    // Snack ablaufen lassen (kSnackError 3000 ms + Safety-Net 400 ms), damit
    // am Testende keine Timer haengen.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('Analyse-Sheet zeigt bei sonstigen Fehlern die Flow-Meldung',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(_sheetHost(completer.future));

    completer.completeError(const HttpException('provider down'));
    await tester.pump();
    await tester.pump();

    expect(find.text(_fallback), findsOneWidget);
    expect(find.text(_timeoutText), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
