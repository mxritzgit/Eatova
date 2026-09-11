import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova design tokens (Balance Duo, 2026-09-11)
//
// Colors live as a ThemeExtension read via `context.t`; top-level `const`
// colors could not carry a light mode.
//
// Three locks still hold:
//   1. COLOR – `lime`/`forest` carry brand and interaction, macro colors
//              encode nutrients ONLY, `danger`/`warning` signal state only.
//   2. SHAPE – one radius scale (rChip / rControl / rCard / rSheet / rHero /
//              rPill), at the bottom of this file.
//   3. LAYER – Material 3 carries behavior, these tokens carry the pixels.
//              No widget hardcodes a color.
// ---------------------------------------------------------------------------

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.surf,
    required this.surf2,
    required this.tile,
    required this.line,
    required this.ink,
    required this.ink2,
    required this.forest,
    required this.onForest,
    required this.lime,
    required this.onLime,
    required this.accent,
    required this.progressAccent,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.proteinSurface,
    required this.carbsSurface,
    required this.fatSurface,
    required this.snack,
    required this.danger,
    required this.warning,
    required this.shadowTint,
    required this.field,
    required this.fieldFocus,
    required this.fieldError,
    required this.scrim,
  });

  /// Page ground (scaffold).
  final Color bg;

  /// Card/panel surface on [bg].
  final Color surf;

  /// Second, slightly offset surface (banners, image placeholders).
  final Color surf2;

  /// Very faint fill for icon tiles and bar tracks.
  final Color tile;

  /// Dividers and card borders (1 px, deliberately faint).
  final Color line;

  /// Primary text.
  final Color ink;

  /// Secondary text, icons, labels.
  final Color ink2;

  /// Soft lavender brand surface. Legacy name retained for existing screens.
  final Color forest;

  /// Text/icon on [forest].
  final Color onForest;

  /// Contrasting violet accent, paired with [onLime]. Legacy token name.
  final Color lime;

  /// Text/icon on the contrasting accent.
  final Color onLime;

  /// Stroke/fill for graphics sitting ON a light card. In dark mode [forest]
  /// is a *surface* and unusable as ink, hence its own token instead of a
  /// brightness branch.
  final Color accent;

  /// Softer progress ink, readable against an unfilled surface track.
  final Color progressAccent;
  Color get proteinProgress => Color.lerp(protein, surf, 0.12)!;
  Color get carbsProgress => Color.lerp(carbs, surf, 0.12)!;
  Color get fatProgress => Color.lerp(fat, surf, 0.12)!;

  /// Macro encoding. Never an interaction color, never decoration.
  final Color protein, carbs, fat;

  /// Nutrient-specific pastel surfaces; use the matching stroke for progress.
  final Color proteinSurface, carbsSurface, fatSurface;

  Color get brandSurface => forest;
  Color get onBrandSurface => onForest;

  /// Photography and camera overlays must stay light in either theme.
  Color get onImage => const Color(0xFFFFFFFF);
  Color get imageAccent => const Color(0xFFD2C6FF);

  /// Fourth categorical color for the snack slot (the macro tones are reserved
  /// for nutrients, and a grey snack would read as disabled).
  final Color snack;

  /// State signals. Separate from brand and data.
  final Color danger, warning;

  /// Tinted shadow for raised surfaces (never pure black).
  final Color shadowTint;

  /// Input capsule at rest.
  ///
  /// APP-WIDE FOCUS LANGUAGE for every text input (repo rule): no hairline,
  /// no focus ring, no red ring. The capsule is [field] with [softShadow];
  /// focus LIGHTENS it to [fieldFocus]; an error tints it to [fieldError]
  /// and adds the error line. `FieldCapsule` / `SheetField` implement it —
  /// private capsules must use these three tokens, never surf/surf2/tile.
  ///
  /// Own tones, deliberately none of surf/surf2/bg: the capsule must stay
  /// visible on a card (surf) AND on a sheet (bg). Constraint: `ink2` (hint)
  /// needs 4.5:1 on all three, which caps how dark the light-mode tones may
  /// go — bg and surf are only 1.13:1 apart there, so ≥ 1.2:1 against both
  /// at once is impossible; the shadow carries the rest of the edge.
  final Color field;

  /// Input capsule with focus — always LIGHTER than [field], in both modes,
  /// and never identical to surf/bg (a focused field on a dialog vanished).
  final Color fieldFocus;

  /// Input capsule in error: a faint [danger] tint, no red ring. Pre-mixed
  /// as a token because `ink2` (hint text) has little headroom on [field] —
  /// a runtime blend dropped it under 4.5:1 in both modes.
  final Color fieldError;

  /// Modal barrier behind sheets and dialogs.
  final Color scrim;

  static const AppTokens light = AppTokens(
    bg: Color(0xFFF8F8FC),
    surf: Color(0xFFFFFFFF),
    surf2: Color(0xFFF0EEF6),
    tile: Color(0x0D16151F),
    line: Color(0x1816151F),
    ink: Color(0xFF16151F),
    ink2: Color(0xFF625F6D),
    forest: Color(0xFFEAE5FF),
    onForest: Color(0xFF090812),
    lime: Color(0xFF6550A8),
    onLime: Color(0xFFFFFFFF),
    accent: Color(0xFF6550A8),
    progressAccent: Color(0xFF9782DC),
    protein: Color(0xFF31845A),
    carbs: Color(0xFF2887A0),
    fat: Color(0xFFA97917),
    proteinSurface: Color(0xFFDDF5E4),
    carbsSurface: Color(0xFFDDF3FC),
    fatSurface: Color(0xFFFFEFC1),
    snack: Color(0xFF99718F),
    danger: Color(0xFFB23A28),
    warning: Color(0xFF8A6212),
    shadowTint: Color(0x1416151F),
    field: Color(0xFFEAE7F0),
    fieldFocus: Color(0xFFF2EFF8),
    fieldError: Color(0xFFF9EDE7),
    scrim: Color(0x8C16151F),
  );

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF111016),
    surf: Color(0xFF1B1922),
    surf2: Color(0xFF25222F),
    tile: Color(0x12FFFFFF),
    line: Color(0x1AFFFFFF),
    ink: Color(0xFFF3F0FA),
    ink2: Color(0xFFADA7BC),
    forest: Color(0xFF302744),
    onForest: Color(0xFFFCFAFF),
    lime: Color(0xFFCAB8FF),
    onLime: Color(0xFF241B39),
    accent: Color(0xFFCAB8FF),
    progressAccent: Color(0xFFCAB8FF),
    protein: Color(0xFF8ED6AB),
    carbs: Color(0xFF8DD4EC),
    fat: Color(0xFFE7C56C),
    proteinSurface: Color(0xFF213C2C),
    carbsSurface: Color(0xFF203741),
    fatSurface: Color(0xFF3C3321),
    snack: Color(0xFFD4A5C8),
    danger: Color(0xFFF08A72),
    warning: Color(0xFFF0B458),
    shadowTint: Color(0x590C0914),
    field: Color(0xFF302B3B),
    fieldFocus: Color(0xFF383143),
    fieldError: Color(0xFF382A36),
    scrim: Color(0xA60C0914),
  );

  /// Tokens of the nearest theme. Throws deliberately when the extension is
  /// missing — a screen without tokens is a wiring bug, not a display bug.
  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>()!;

  /// A tone of [farbe] readable on its own faint tint.
  ///
  /// A glyph in the full category color on ~16 % of the same color works in
  /// dark mode but failed in light (carb amber at 2.15:1). Blending towards
  /// [ink] fixes it without a brightness branch: [ink] is dark in the light
  /// palette and light in the dark one, so the correction self-orients while
  /// the hue survives.
  Color readableOnTint(Color farbe) =>
      Color.alphaBlend(farbe.withValues(alpha: 0.55), ink);

  @override
  AppTokens copyWith({
    Color? bg,
    Color? surf,
    Color? surf2,
    Color? tile,
    Color? line,
    Color? ink,
    Color? ink2,
    Color? forest,
    Color? onForest,
    Color? lime,
    Color? onLime,
    Color? accent,
    Color? progressAccent,
    Color? protein,
    Color? carbs,
    Color? fat,
    Color? proteinSurface,
    Color? carbsSurface,
    Color? fatSurface,
    Color? snack,
    Color? danger,
    Color? warning,
    Color? shadowTint,
    Color? field,
    Color? fieldFocus,
    Color? fieldError,
    Color? scrim,
  }) {
    return AppTokens(
      bg: bg ?? this.bg,
      surf: surf ?? this.surf,
      surf2: surf2 ?? this.surf2,
      tile: tile ?? this.tile,
      line: line ?? this.line,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      forest: forest ?? this.forest,
      onForest: onForest ?? this.onForest,
      lime: lime ?? this.lime,
      onLime: onLime ?? this.onLime,
      accent: accent ?? this.accent,
      progressAccent: progressAccent ?? this.progressAccent,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      proteinSurface: proteinSurface ?? this.proteinSurface,
      carbsSurface: carbsSurface ?? this.carbsSurface,
      fatSurface: fatSurface ?? this.fatSurface,
      snack: snack ?? this.snack,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
      shadowTint: shadowTint ?? this.shadowTint,
      field: field ?? this.field,
      fieldFocus: fieldFocus ?? this.fieldFocus,
      fieldError: fieldError ?? this.fieldError,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppTokens(
      bg: c(bg, other.bg),
      surf: c(surf, other.surf),
      surf2: c(surf2, other.surf2),
      tile: c(tile, other.tile),
      line: c(line, other.line),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      forest: c(forest, other.forest),
      onForest: c(onForest, other.onForest),
      lime: c(lime, other.lime),
      onLime: c(onLime, other.onLime),
      accent: c(accent, other.accent),
      progressAccent: c(progressAccent, other.progressAccent),
      protein: c(protein, other.protein),
      carbs: c(carbs, other.carbs),
      fat: c(fat, other.fat),
      proteinSurface: c(proteinSurface, other.proteinSurface),
      carbsSurface: c(carbsSurface, other.carbsSurface),
      fatSurface: c(fatSurface, other.fatSurface),
      snack: c(snack, other.snack),
      danger: c(danger, other.danger),
      warning: c(warning, other.warning),
      shadowTint: c(shadowTint, other.shadowTint),
      field: c(field, other.field),
      fieldFocus: c(fieldFocus, other.fieldFocus),
      fieldError: c(fieldError, other.fieldError),
      scrim: c(scrim, other.scrim),
    );
  }
}

/// Shorthand for build(): `final t = context.t;`
extension TokensX on BuildContext {
  AppTokens get t => AppTokens.of(this);
}

// --- SHAPE SCALE -------------------------------------------------------------
// Brightness-independent, so still top-level constants.
//   rChip    chips, small switches, tags
//   rControl inputs, buttons, list rows
//   rCard    cards, panels
//   rSheet   bottom sheets, dialogs
//   rHero    large brand surfaces (calorie hero, identity card)
//   rButton  the primary action (PrimaryActionButton, FilledButton, sheet
//            action) — ONE radius for one semantics
//   rPill    fully round (pills, FAB, avatars)
const double rChip = 11;
const double rControl = 15;
const double rButton = 18;
const double rCard = 22;
const double rSheet = 28;
const double rHero = 28;
const double rPill = 999;

/// Minimum height of the PRIMARY action only: [PrimaryActionButton] and the
/// [SheetScaffold] action. Themed Filled/OutlinedButtons stay at
/// [kButtonMinHeight] so dialog actions next to a TextButton do not tower.
const double kPrimaryButtonHeight = 54;

/// Touch-target floor for themed Material buttons (Filled/Outlined).
const double kButtonMinHeight = 48;

/// Soft elevation for floating surfaces (nav bar, sheets). Depth normally
/// comes from [AppTokens.line]; shadows stay the exception for things that
/// really sit above the content.
List<BoxShadow> softShadow(AppTokens t) => <BoxShadow>[
  BoxShadow(
    color: t.shadowTint,
    blurRadius: 28,
    offset: const Offset(0, 14),
    spreadRadius: -10,
  ),
];

// --- TYPE --------------------------------------------------------------------
// Two bundled families (assets/fonts, NO google_fonts):
//   * Bricolage Grotesque for numbers and headings — tight negative tracking,
//     tabular figures so calorie values do not jump while counting.
//   * Archivo for everything else (body, labels, buttons).
// Bundled on purpose: no runtime request to Google (privacy policy), no
// fallback flash, identical offline.
class AppType {
  const AppType._();

  static const String displayFamily = 'BricolageGrotesque';
  static const String uiFamily = 'Archivo';

  /// Numbers and headings.
  static TextStyle display(
    double size, {
    FontWeight weight = FontWeight.w800,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: displayFamily,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing ?? -size * 0.03,
      height: height,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
  }

  /// Body text, labels, buttons.
  static TextStyle ui(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: uiFamily,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// Small all-caps caption above sections.
  static TextStyle eyebrow(Color color, {double size = 10}) => TextStyle(
    fontFamily: uiFamily,
    fontSize: size,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: 1.5,
  );
}
