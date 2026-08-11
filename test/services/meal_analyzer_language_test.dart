import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/services/meal_analyzer.dart';

// Scan/Coach-PR (2026-08-11): analyze-meal bekommt einen `language`-Parameter
// (Spec §5, KI-Scan). Client-seitig reist die App-Sprache ueber
// MealAnalysisRequest.language ins Request-JSON (buildAnalyzeMealBody) —
// diese Tests decken die reine Request/JSON-Ebene ab, ohne HTTP/Supabase-Fake
// (analyze() selbst braucht eine echte Session und ist hier bewusst nicht
// Ziel).
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
