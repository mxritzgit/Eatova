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

  /// App-Sprache zum Zeitpunkt des Scans (`'de'`/`'en'`) — reist im
  /// `language`-Feld an die `analyze-meal`-Function mit (Scan/Coach-PR,
  /// 2026-08-11): der Server formuliert Gerichtenamen in dieser Sprache statt
  /// „deutsch wenn möglich". Default `'de'`: dieselbe Abwaertskompatibilitaet
  /// wie serverseitig — Konstruktions-Stellen ohne aktive Locale
  /// (`MealPhotoInput.pick`/`meal_camera_sheet.dart`, beide ohne
  /// `BuildContext` an dieser Stelle) bleiben unveraendert deutsch. Der
  /// tatsaechliche Aufrufer (`add_meal_sheet.dart`/`meal_analysis_screen.dart`)
  /// setzt die echte App-Sprache unmittelbar vor `MealAnalyzer.analyze()` ueber
  /// [withLanguage] nach — genau dort ist `context.l10n` sicher verfuegbar.
  final String language;

  /// Kopie mit ausgetauschter [language] — s. dort.
  MealAnalysisRequest withLanguage(String language) => MealAnalysisRequest(
        imageId: imageId,
        imageBytes: imageBytes,
        portionHint: portionHint,
        freeTextHint: freeTextHint,
        language: language,
      );
}
