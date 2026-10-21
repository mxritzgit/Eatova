import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/services/meal_analyzer.dart';

// The analyze-meal request body: the app locale travels via
// MealAnalysisRequest.language into the JSON, next to the hint and the photo.
// That the copies keep photo, language and cancellation is pinned in
// meal_scan_context_test.dart; analyze() itself needs a real session.
void main() {
  final imageBytes = Uint8List.fromList(const [1, 2, 3]);

  test('ohne aktive Locale ist die Sprache de, auch im Body', () {
    const request = MealAnalysisRequest(imageId: 'x', imageBytes: null);
    expect(request.language, 'de');
    expect(buildAnalyzeMealBody(request)['language'], 'de');
  });

  test('der Body traegt Sprache, normalisierten Hinweis, Portionshinweis und '
      'das Foto', () {
    final body = buildAnalyzeMealBody(
      MealAnalysisRequest(
        imageId: 'x',
        imageBytes: imageBytes,
        freeTextHint: '  viel   Sauce  ',
      ).withLanguage('en'),
    );
    expect(body['language'], 'en');
    expect(body['freeTextHint'], 'viel Sauce');
    expect(body['portionHint'], 'normal');
    expect(body['imageBase64'], base64Encode(imageBytes));
  });

  test('fehlende imageBytes lassen imageBase64 aus, language bleibt drin', () {
    final body = buildAnalyzeMealBody(
      const MealAnalysisRequest(imageId: 'x', language: 'en'),
    );
    expect(body.containsKey('imageBase64'), isFalse);
    expect(body['language'], 'en');
  });

  // Perf round 2026-08-31, finding 6: base64 + jsonEncode of a photo (worst
  // case >13 MB string churn) ran on the UI isolate, right as the scan spinner
  // starts. The top-level encode function is what analyze() hands to
  // compute(); it must produce byte-identical JSON.
  test('encodeAnalyzeMealBody liefert dasselbe JSON wie '
      'jsonEncode(buildAnalyzeMealBody(...))', () {
    final request = MealAnalysisRequest(
      imageId: 'photo.jpg',
      imageBytes: imageBytes,
      freeTextHint: '  viel   Sauce  ',
      language: 'en',
    );
    expect(
      encodeAnalyzeMealBody(request),
      jsonEncode(buildAnalyzeMealBody(request)),
    );
  });
}
