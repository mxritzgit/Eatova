import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
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

const String _barcodeFallback =
    'Barcode 4001724012345 nicht gefunden oder OpenFoodFacts nicht erreichbar.';

Widget _sheetHost(
  Future<MealAnalysisResult> resultFuture, {
  String failureMessage = _fallback,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
}) {
  return MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    home: Scaffold(
      body: MealAnalysisSheet(
        slot: MealSlot.lunch,
        resultFuture: resultFuture,
        previewImage: null,
        onAdd: onAdd ?? (_, __) => '',
        onUpdateMeal: (_, __) {},
        failureMessage: failureMessage,
      ),
    ),
  );
}

/// Ein Foto-KI-Ergebnis ohne Kalorienangabe. Ueber Suche und Barcode kommt so
/// etwas seit Welle 2 nicht mehr an (dort wirft der Service), der Foto-Pfad
/// laeuft aber an diesem Filter vorbei.
const _ohneKalorien = MealAnalysisResult(
  mealName: 'Unklarer Teller',
  caloriesKcal: 0,
  estimatedGrams: 250,
  kcalPer100G: 0,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'Niedrig',
  portionNotes: 'Das Modell konnte nichts Belastbares schaetzen.',
  sourceLabel: 'Foto-KI',
);

/// Dasselbe Ergebnis, nur mit Kalorien — die Gegenprobe zum Guard.
const _mitKalorien = MealAnalysisResult(
  mealName: 'Klarer Teller',
  caloriesKcal: 420,
  estimatedGrams: 250,
  kcalPer100G: 168,
  protein: '20 g',
  carbs: '40 g',
  fat: '15 g',
  confidence: 'Mittel',
  portionNotes: 'Normale Schaetzung.',
  sourceLabel: 'Foto-KI',
);

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

    // B7: Der Service WEISS seit Welle 2, dass das Produkt existiert, aber
    // keine loggbaren Naehrwerte hat. „nicht gefunden" waere dann gelogen —
    // der Nutzer haelt das Produkt in der Hand.
    test('ProductWithoutNutritionException -> die Meldung des Fehlers selbst',
        () {
      const ohneAngabe = ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Die Ofenfrische Salami',
        kcalPer100G: 0,
      );
      expect(
        mealAnalysisErrorMessage(ohneAngabe, _barcodeFallback),
        'Die Ofenfrische Salami gefunden, aber ohne Nährwertangaben. '
        'Bitte manuell eintragen.',
      );
      expect(
        mealAnalysisErrorMessage(ohneAngabe, _barcodeFallback),
        isNot(_barcodeFallback),
      );
    });

    test('unplausible Angabe nennt den gemessenen Wert', () {
      const unplausibel = ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Nussmus',
        kcalPer100G: 2180,
      );
      expect(unplausibel.isImplausible, isTrue);
      expect(
        mealAnalysisErrorMessage(unplausibel, _barcodeFallback),
        'Nussmus gefunden, aber die Nährwertangabe ist unplausibel '
        '(2180 kcal / 100 g). Bitte manuell eintragen.',
      );
    });
  });

  testWidgets(
      'Analyse-Sheet zeigt bei fehlenden Naehrwerten die Produkt-Meldung',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(
      _sheetHost(completer.future, failureMessage: _barcodeFallback),
    );

    completer.completeError(
      const ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Die Ofenfrische Salami',
        kcalPer100G: 0,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Die Ofenfrische Salami gefunden, aber ohne Nährwertangaben. '
        'Bitte manuell eintragen.',
      ),
      findsOneWidget,
    );
    expect(find.text(_barcodeFallback), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  // W2-08s letzte Bremse: `_addToDaily` rief `onAdd` bedingungslos. Suche und
  // Barcode liefern nichts Unloggbares mehr, der Foto-KI-Pfad laeuft aber an
  // diesem Filter vorbei.
  group('Guard vor onAdd', () {
    testWidgets('0 kcal wird nicht geloggt — und der Nutzer erfaehrt warum',
        (tester) async {
      var aufrufe = 0;
      await tester.pumpWidget(
        _sheetHost(
          Future<MealAnalysisResult>.value(_ohneKalorien),
          onAdd: (_, __) {
            aufrufe++;
            return 'id';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
      await tester.pump();
      await tester.pump();

      expect(aufrufe, 0, reason: 'nichts Unloggbares darf ins Tagebuch');
      // Kein stiller Abbruch: es steht da, warum, und was zu tun ist.
      expect(
        find.textContaining('Ohne Kalorienangabe'),
        findsOneWidget,
      );
      expect(find.textContaining('Anpassen'), findsWidgets);
      // Der Knopf bleibt bedienbar — nach dem Nachtragen soll er wirken.
      expect(find.text('Zu heute hinzugefügt'), findsNothing);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('mit Kalorien laeuft der Weg unveraendert durch',
        (tester) async {
      var aufrufe = 0;
      await tester.pumpWidget(
        _sheetHost(
          Future<MealAnalysisResult>.value(_mitKalorien),
          onAdd: (_, __) {
            aufrufe++;
            return 'id';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
      await tester.pump();
      await tester.pump();

      expect(aufrufe, 1);
      expect(find.text('Zu heute hinzugefügt'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
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
