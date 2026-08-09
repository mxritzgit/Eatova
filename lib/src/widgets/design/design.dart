/// Die gemeinsame Design-Bibliothek (Design-Refactor 2026-08).
///
/// Ein Import fuer alle Screens:
/// ```dart
/// import '../widgets/design/design.dart';
/// ```
///
/// Die Widgets lesen Farbe ueber `context.t` ([AppTokens]) und Schrift ueber
/// [AppType]; keiner von ihnen kennt `app_colors.dart` oder eine harte Farbe.
library;

export 'controls.dart';
export 'meters.dart';
export 'rows.dart';
export 'sheets.dart';
export 'surfaces.dart';
