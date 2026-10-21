// W3-07 / G2: pins the `capture == null` exit in `_scanWithCamera`
// (meal_analysis_screen.dart). Cancelling is the second most common outcome
// of a camera call: it must neither crash nor open the next step (the photo
// preview), and the screen must stay usable for another try. A parent that
// goes away while a preview is open is covered in meal_scan_context_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/widgets/kcal/meal_scan_preview_sheet.dart';

import 'support/harness.dart';

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
    'Scan-Kamera abbrechen: kein Crash, keine Vorschau, keine Analyse',
    (tester) async {
      final kamera = _AbbrechendeKamera();
      final analyzer = _NieAufgerufenerAnalyzer();

      // MealAnalysisScreen reads context.l10n.
      await pumpLocalized(
        tester,
        MealAnalysisScreen(
          dailyConsumedKcal: 0,
          analyzer: analyzer,
          cameraLauncher: kamera,
        ),
        reducedMotion: false,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await tester.pumpAndSettle();

      // The camera really ran — the test is not checking an unentered path.
      expect(kamera.aufrufe, 1);

      expect(
        tester.takeException(),
        isNull,
        reason: 'Abbrechen darf keinen Null-Check-Crash ausloesen',
      );

      // No next step for a discarded photo: the preview (the step after the
      // camera) stays closed, and nothing is analysed.
      expect(find.byType(MealScanPreviewSheet), findsNothing);
      expect(analyzer.aufrufe, 0);

      // The screen stays usable: a second attempt works.
      expect(find.byKey(const ValueKey('food-action-ai')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await tester.pumpAndSettle();
      expect(kamera.aufrufe, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
