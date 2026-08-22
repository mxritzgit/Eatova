import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/services/meal_analyzer.dart';

// analyze-meal takes a `language` parameter; the app locale travels via
// MealAnalysisRequest.language into the request JSON. These tests cover the
// request/JSON level only — analyze() itself needs a real session.
void main() {
  final imageBytes = Uint8List.fromList(const [1, 2, 3]);

  group('MealAnalysisRequest.language', () {
    test('Default ist de (Abwaertskompatibilitaet ohne aktive Locale)', () {
      const request = MealAnalysisRequest(imageId: 'x', imageBytes: null);
      expect(request.language, 'de');
    });

    test('withLanguage tauscht nur die Sprache, alle anderen Felder bleiben',
        () {
      final request = MealAnalysisRequest(
        imageId: 'photo.jpg',
        imageBytes: imageBytes,
        portionHint: MealPortionHint.large,
        freeTextHint: 'extra Käse',
      );
      final withEn = request.withLanguage('en');

      expect(withEn.language, 'en');
      expect(withEn.imageId, request.imageId);
      expect(withEn.imageBytes, request.imageBytes);
      expect(withEn.portionHint, request.portionHint);
      expect(withEn.freeTextHint, request.freeTextHint);
    });
  });

  group('buildAnalyzeMealBody — language im Request-JSON', () {
    test('language: de (Default) landet im Body', () {
      final body = buildAnalyzeMealBody(
        const MealAnalysisRequest(imageId: 'x', imageBytes: null),
      );
      expect(body['language'], 'de');
    });

    test('language: en (via withLanguage) landet im Body', () {
      final body = buildAnalyzeMealBody(
        const MealAnalysisRequest(imageId: 'x', imageBytes: null)
            .withLanguage('en'),
      );
      expect(body['language'], 'en');
    });

    test('portionHint/freeTextHint reisen unveraendert mit', () {
      final body = buildAnalyzeMealBody(
        MealAnalysisRequest(
          imageId: 'x',
          imageBytes: imageBytes,
          portionHint: MealPortionHint.small,
          freeTextHint: '  viel   Sauce  ',
          language: 'en',
        ),
      );
      expect(body['portionHint'], 'small');
      expect(body['freeTextHint'], 'viel Sauce');
      expect(body['language'], 'en');
      expect(body.containsKey('imageBase64'), isTrue);
    });

    test('fehlende imageBytes lassen imageBase64 aus, language bleibt drin',
        () {
      final body = buildAnalyzeMealBody(
        const MealAnalysisRequest(imageId: 'x', language: 'en'),
      );
      expect(body.containsKey('imageBase64'), isFalse);
      expect(body['language'], 'en');
    });
  });
}
