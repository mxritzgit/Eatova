// Fix run for review 2026-08-27, wiring for F4-02 (Paket D): the photo-scan
// callers hand the result sheet a `retry` from the same request plus the
// request's cancel handle, and "enter manually" from a failed scan opens the
// manual-entry sheet in the chosen slot. Driven through the real callers
// (food tab via the MealCameraLauncher seam, add sheet via MealPhotoInput).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

const MealAnalysisResult _bowl = MealAnalysisResult(
  mealName: 'Bowl',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '30 g',
  carbs: '40 g',
  fat: '12 g',
  confidence: 'Mittel',
  portionNotes: 'Test.',
  sourceLabel: 'Foto-KI',
);

/// Fails the first attempt with a provider error, answers the second.
class _ZweiterVersuchAnalyzer implements MealAnalyzer {
  final List<MealAnalysisRequest> requests = <MealAnalysisRequest>[];

  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    requests.add(request);
    if (requests.length == 1) {
      throw const MealAnalysisServerError(
        statusCode: 502,
        code: 'provider_error',
        debugMessage: 'kaputt',
      );
    }
    return _bowl;
  }
}

/// The camera sheet attaches a cancel handle to every capture.
class _Kamera implements MealCameraLauncher {
  final MealAnalysisCancellation cancellation = MealAnalysisCancellation();
  MealSlot? slot;

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    slot = MealSlot.dinner;
    return MealCameraCapture(
      request: MealAnalysisRequest(
        imageId: 'test-photo',
        cancellation: cancellation,
      ),
      previewBytes: null,
      slot: MealSlot.dinner,
    );
  }
}

/// The picker path carries NO cancel handle (report D, note 1).
class _Galerie implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async =>
      const MealPhotoSelection(
        request: MealAnalysisRequest(imageId: 'gallery-photo'),
        previewBytes: null,
      );
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

/// `reducedMotion: false` keeps the motion behaviour from before the harness
/// migration; the sheets' AnimatedSize re-dirties itself at duration 0.
Widget _app(Widget body) =>
    localizedApp(body, reducedMotion: false, safeArea: false);

/// Phone viewport; overflows are collected and asserted empty at the end of
/// each test, not swallowed.
List<String> _telefon(WidgetTester tester) {
  pinPhoneViewport(tester);
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
  addTearDown(() => expect(overflows, isEmpty, reason: overflows.join('\n')));
  return overflows;
}

/// Frames plus microtasks; the loading card animates forever, so no
/// `pumpAndSettle` while the sheet is loading.
Future<void> _flush(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _fillManualForm(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('manual-meal-name')),
    'Bauern-Mozzarella',
  );
  await tester.enterText(
    find.byKey(const ValueKey('manual-meal-kcal100')),
    '265',
  );
  await tester.enterText(find.byKey(const ValueKey('manual-meal-grams')), '125');
  await tester.pump();
  final save = find.byKey(const ValueKey('manual-meal-save'));
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  group('Food-Tab (MealCameraLauncher-Naht)', () {
    testWidgets('Retry im Sheet löst einen zweiten analyze()-Aufruf mit '
        'demselben Request und Cancel-Handle aus', (tester) async {
      _telefon(tester);
      final analyzer = _ZweiterVersuchAnalyzer();
      final kamera = _Kamera();
      await tester.pumpWidget(_app(MealAnalysisScreen(
        dailyConsumedKcal: 0,
        analyzer: analyzer,
        cameraLauncher: kamera,
        productService: _StummerProduktdienst(),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('food-action-ai')));
      await _flush(tester);
      expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
      expect(analyzer.requests, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('analyse-retry')));
      await _flush(tester);

      expect(analyzer.requests, hasLength(2));
      expect(analyzer.requests[1].imageId, 'test-photo');
      expect(analyzer.requests[1].language, 'de');
      expect(analyzer.requests[1].cancellation, same(kamera.cancellation),
          reason: 'ein Handle über alle Versuche');
      expect(find.text('Bowl'), findsWidgets);
    });

    testWidgets('„Manuell eintragen" öffnet das Manuell-Sheet und loggt in '
        'den Slot der Aufnahme', (tester) async {
      // Pinned clock, and the reason is the whole point of the case:
      // `currentMealSlot()` is dinner between 15:00 and 21:00, exactly what
      // the capture says. Unpinned, "the capture's slot, not the clock" was a
      // tautology for six hours of every day — swapping the source for
      // `currentMealSlot()` stayed green all afternoon. 09:00 is breakfast, so
      // the two sources are now told apart whatever time the suite runs.
      await withClock(Clock.fixed(DateTime(2026, 8, 27, 9)), () async {
        _telefon(tester);
        final geloggt = <(MealAnalysisResult, MealSlot)>[];
        await tester.pumpWidget(_app(MealAnalysisScreen(
          dailyConsumedKcal: 0,
          analyzer: _ZweiterVersuchAnalyzer(),
          cameraLauncher: _Kamera(),
          productService: _StummerProduktdienst(),
          onAddMeal: (result, slot) {
            geloggt.add((result, slot));
            return 'id-1';
          },
        )));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('food-action-ai')));
        await _flush(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-manual-entry')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('manual-meal-save')), findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-error')), findsNothing);
        await _fillManualForm(tester);

        expect(geloggt, hasLength(1));
        expect(geloggt.single.$1.mealName, 'Bauern-Mozzarella');
        expect(geloggt.single.$1.caloriesKcal, 331);
        expect(geloggt.single.$2, MealSlot.dinner,
            reason: 'der Slot der Aufnahme, nicht die Uhrzeit');
        expect(
            find.text('331 kcal zu Abendessen hinzugefügt.'), findsOneWidget);
      });
    });
  });

  group('Add-Sheet (MealPhotoInput-Naht)', () {
    Future<_ZweiterVersuchAnalyzer> pumpSheet(
      WidgetTester tester, {
      String Function(MealAnalysisResult, MealSlot)? onAdd,
    }) async {
      _telefon(tester);
      final analyzer = _ZweiterVersuchAnalyzer();
      await tester.pumpWidget(_app(AddMealSheet(
        slot: MealSlot.lunch,
        analyzer: analyzer,
        productService: _StummerProduktdienst(),
        photoInput: _Galerie(),
        favorites: const [],
        onAdd: onAdd ?? (_, __) => 'id-1',
        onUpdateMeal: (_, __) {},
        onRemoveFavorite: (_) {},
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analyse-gallery-button')));
      await _flush(tester);
      expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
      return analyzer;
    }

    testWidgets('Retry nutzt denselben Request; der Picker-Request bekommt '
        'ein Cancel-Handle', (tester) async {
      final analyzer = await pumpSheet(tester);

      await tester.tap(find.byKey(const ValueKey('analyse-retry')));
      await _flush(tester);

      expect(analyzer.requests, hasLength(2));
      expect(analyzer.requests[0].cancellation, isNotNull);
      expect(analyzer.requests[1].cancellation,
          same(analyzer.requests[0].cancellation));
      expect(analyzer.requests[1].imageId, 'gallery-photo');
      expect(find.text('Bowl'), findsWidgets);
    });

    testWidgets('„Manuell eintragen" öffnet das Manuell-Sheet, der Eintrag '
        'landet im gewählten Slot und in der Liste', (tester) async {
      // Same pin as the camera case above: the sheet's slot is lunch, so
      // between 11:00 and 15:00 the clock says lunch too and "the chosen
      // slot" could not be told from "the current hour". 09:00 is breakfast.
      await withClock(Clock.fixed(DateTime(2026, 8, 27, 9)), () async {
        final geloggt = <MealSlot>[];
        await pumpSheet(tester, onAdd: (_, slot) {
          geloggt.add(slot);
          return 'id-1';
        });

        await tester.tap(find.byKey(const ValueKey('analyse-manual-entry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('manual-meal-save')), findsOneWidget);
        await _fillManualForm(tester);

        expect(geloggt, [MealSlot.lunch]);
        // F3-01 mirror: the manual entry shows up in "already added" at once.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('analyse-existing-meals')),
            matching: find.text('Bauern-Mozzarella'),
          ),
          findsOneWidget,
        );
      });
    });
  });
}
