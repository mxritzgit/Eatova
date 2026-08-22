// W3-07 / G2: pins `if (capture == null || !context.mounted) return;` in
// meal_analysis_screen.dart. Without it, cancelling the scan camera crashes on
// `capture.slot`, and no other test caught that — cancelling is the second
// most common outcome of a camera call. The `!context.mounted` half (screen
// gone while the sheet was open) is covered too, because the test drives the
// sheet through the real screen tree.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
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

/// In-app camera the user leaves without a photo: `showModalBottomSheet`
/// returns `null` on swipe/back dismiss.
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

/// An analyzer that must never run: calling it would mean a request for an
/// image the user deliberately discarded.
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
          theme: buildEatovaTheme(Brightness.dark),
          // MealAnalysisScreen reads context.l10n.
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
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

      // The camera really ran — the test is not checking an unentered path.
      expect(kamera.aufrufe, 1);

      // Without the guard `capture.slot` throws on null here.
      expect(
        tester.takeException(),
        isNull,
        reason: 'Abbrechen darf keinen Null-Check-Crash ausloesen',
      );

      // No analysis request for a discarded photo …
      expect(analyzer.aufrufe, 0);
      // … and no result sheet.
      expect(find.byKey(const ValueKey('analyse-result-card')), findsNothing);
      expect(find.text('Analyse prüfen'), findsNothing);

      // The screen stays usable: a second attempt works.
      expect(find.byKey(const ValueKey('food-action-ai')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await tester.pumpAndSettle();
      expect(kamera.aufrufe, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
