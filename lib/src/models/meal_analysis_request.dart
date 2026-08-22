import 'dart:typed_data';

enum MealPortionHint {
  small('klein', '~30% weniger als Standardportion'),
  normal('normal', 'Standardportion'),
  large('groß', '~50% mehr als Standardportion'),
  extraLarge('sehr groß', '~doppelte Standardportion');

  const MealPortionHint(this.label, this.guidance);

  final String label;
  final String guidance;
}

class MealAnalysisRequest {
  const MealAnalysisRequest({
    required this.imageId,
    this.imageBytes,
    this.portionHint,
    this.freeTextHint,
    this.language = 'de',
  });

  final String imageId;
  final Uint8List? imageBytes;
  final MealPortionHint? portionHint;
  final String? freeTextHint;

  /// App language at scan time (`'de'`/`'en'`), sent to the `analyze-meal`
  /// function so it names dishes in that language.
  ///
  /// Default `'de'` matches the server default, for construction sites without
  /// a locale (no `BuildContext` there). The actual caller sets the real
  /// language via [withLanguage] right before `MealAnalyzer.analyze()`.
  final String language;

  /// Copy with [language] replaced — see there.
  MealAnalysisRequest withLanguage(String language) => MealAnalysisRequest(
        imageId: imageId,
        imageBytes: imageBytes,
        portionHint: portionHint,
        freeTextHint: freeTextHint,
        language: language,
      );
}
