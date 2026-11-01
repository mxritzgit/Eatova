/// The shared design library — one import for all screens:
/// ```dart
/// import '../widgets/design/design.dart';
/// ```
///
/// These widgets read color via `context.t` ([AppTokens]) and type via
/// [AppType]; none of them knows `app_colors.dart` or a hardcoded color.
/// Icons come from [AppIcons] (exported here), sizes from [AppIconSize].
/// The API overview for screens: docs/design/UI-FOUNDATION-2026-11-01.md.
library;

export '../../theme/app_icons.dart';
export 'app_icon.dart';
export 'controls.dart';
export 'creation.dart';
export 'dialogs.dart';
export 'lists.dart';
export 'menus.dart';
export 'meters.dart';
export 'option_card.dart';
export 'readable_width.dart';
export 'rows.dart';
export 'sheets.dart';
export 'slot_icon_tile.dart';
export 'soft_actions.dart';
export 'spinner.dart';
export 'states.dart';
export 'steps_icon.dart';
export 'surfaces.dart';
export 'tab_chrome.dart';
export 'text_scale.dart';
