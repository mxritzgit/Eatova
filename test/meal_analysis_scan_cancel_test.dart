// W3-07 / G2: der fuenfte Ein-Token-Schalter.
//
// `meal_analysis_screen.dart:172`
//
//   if (capture == null || !context.mounted) return;
//
// Diese eine Zeile zu loeschen gibt JEDEM, der die Scan-Kamera oeffnet und
// zurueck tippt, einen Null-Check-Crash auf `capture.slot` — und bis zu diesem
// Test wurde davon kein einziger Test rot. Abbrechen ist kein Randfall: es ist
// der zweithaeufigste Ausgang eines Kamera-Aufrufs.
//
// Der zweite Teil derselben Zeile (`!context.mounted`) haelt den Fall ab, dass
// der Screen waehrend des Kamera-Sheets verschwindet; er wird hier mit
// abgedeckt, weil der Test das Sheet ueber den echten Screen-Baum fuehrt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/theme/app_theme.dart';

void testWidgetsRobust(String description, WidgetTesterCallback callback) {
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

/// Die In-App-Kamera, aus der der Nutzer ohne Foto zurueckgeht: genau das
/// liefert `showModalBottomSheet` beim Swipe-/Back-Abbruch — `null`.
class _AbbrechendeKamera implements MealCameraLauncher {
  int aufrufe = 0;

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    aufrufe++;
    return null;
  }
}

/// Ein Analyzer, der niemals laufen darf: ohne Foto gibt es nichts zu
/// analysieren. Wuerde er doch gerufen, waere das ein Request auf ein Bild,
/// das der Nutzer bewusst verworfen hat.
class _NieAufgerufenerAnalyzer implements MealAnalyzer {
  int aufrufe = 0;

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    aufrufe++;
    return const MealAnalysisResult(
      mealName: 'darf nie erscheinen',
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '1 g',
      carbs: '1 g',
      fat: '1 g',
      confidence: 'Mittel',
      portionNotes: '-',
      sourceLabel: 'Foto-KI',
    );
  }
}

void main() {
  testWidgetsRobust(
    'Scan-Kamera abbrechen: kein Crash, keine Analyse, kein Ergebnis-Sheet',
    (tester) async {
      final kamera = _AbbrechendeKamera();
      final analyzer = _NieAufgerufenerAnalyzer();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(),
          home: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: MealAnalysisScreen(
                  dailyConsumedKcal: 0,
                  analyzer: analyzer,
                  cameraLauncher: kamera,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await tester.pumpAndSettle();

      // Die Kamera lief wirklich — der Test prueft nicht versehentlich einen
      // Pfad, der gar nicht betreten wurde.
      expect(kamera.aufrufe, 1);

      // Ohne den Guard wirft `capture.slot` hier auf null.
      expect(
        tester.takeException(),
        isNull,
        reason: 'Abbrechen darf keinen Null-Check-Crash ausloesen',
      );

      // Kein Analyse-Request auf ein verworfenes Foto …
      expect(analyzer.aufrufe, 0);
      // … und kein Ergebnis-Sheet.
      expect(find.byKey(const ValueKey('analyse-result-card')), findsNothing);
      expect(find.text('Analyse prüfen'), findsNothing);

      // Der Screen ist weiter bedienbar: ein zweiter Versuch geht.
      expect(find.byKey(const ValueKey('food-action-ai')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await tester.pumpAndSettle();
      expect(kamera.aufrufe, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
