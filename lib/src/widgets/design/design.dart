/// The shared design library — one import for all screens:
/// ```dart
/// import '../widgets/design/design.dart';
/// ```
///
/// These widgets read color via `context.t` ([AppTokens]) and type via
/// [AppType]; none of them knows `app_colors.dart` or a hardcoded color.
library;

export 'controls.dart';
export 'meters.dart';
export 'rows.dart';
export 'sheets.dart';
export 'surfaces.dart';
export 'text_scale.dart';
