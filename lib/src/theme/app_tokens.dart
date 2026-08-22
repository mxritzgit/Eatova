import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova design tokens (design refactor 2026-08-09)
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
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.snack,
    required this.danger,
    required this.warning,
    required this.shadowTint,
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

  /// The dark-green brand surface (hero cards, primary buttons).
  final Color forest;

  /// Text/icon on [forest].
  final Color onForest;

  /// The brand accent.
  final Color lime;

  /// Text/icon on [lime] — always dark, in both modes.
  final Color onLime;

  /// Stroke/fill for graphics sitting ON a light card. In dark mode [forest]
  /// is a *surface* and unusable as ink, hence its own token instead of a
  /// brightness branch.
  final Color accent;

  /// Macro encoding. Never an interaction color, never decoration.
  final Color protein, carbs, fat;

  /// Fourth categorical color for the snack slot (the macro tones are reserved
  /// for nutrients, and a grey snack would read as disabled).
  final Color snack;

  /// State signals. Separate from brand and data.
  final Color danger, warning;

  /// Tinted shadow for raised surfaces (never pure black).
  final Color shadowTint;

  static const AppTokens light = AppTokens(
    bg: Color(0xFFF2EFE6),
    surf: Color(0xFFFFFDF8),
    surf2: Color(0xFFEAE6DA),
    tile: Color(0x0D151E18),
    line: Color(0x1A151E18),
    ink: Color(0xFF151E18),
    // Darker than the draft (#6E7C73, only 4.31:1 on `surf`): `ink2` carries
    // small text (9.5–12.5 px), i.e. WCAG body text needing 4.5:1. This tone
    // holds 5.7 / 5.1 / 4.7 on surf / bg / surf2.
    ink2: Color(0xFF5A6862),
    forest: Color(0xFF123322),
    onForest: Color(0xFFF4F2E6),
    lime: Color(0xFFC9F26E),
    onLime: Color(0xFF123322),
    accent: Color(0xFF123322),
    protein: Color(0xFF3C5CCC),
    carbs: Color(0xFFDE9426),
    fat: Color(0xFFCE6448),
    snack: Color(0xFF3F7D68),
    danger: Color(0xFFB23A28),
    warning: Color(0xFF8A6212),
    shadowTint: Color(0x1A151E18),
  );

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF0B100D),
    surf: Color(0xFF141B17),
    surf2: Color(0xFF1F2823),
    tile: Color(0x12FFFFFF),
    line: Color(0x1AFFFFFF),
    ink: Color(0xFFEFEDE3),
    ink2: Color(0xFF8C9B91),
    forest: Color(0xFF16371F),
    onForest: Color(0xFFF1F3E4),
    lime: Color(0xFFCDF473),
    onLime: Color(0xFF123322),
    accent: Color(0xFFCDF473),
    protein: Color(0xFF7C95F5),
    carbs: Color(0xFFF0B458),
    fat: Color(0xFFE58366),
    snack: Color(0xFF6FC2A4),
    danger: Color(0xFFF08A72),
    warning: Color(0xFFF0B458),
    shadowTint: Color(0x59060810),
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
    Color? protein,
    Color? carbs,
    Color? fat,
    Color? snack,
    Color? danger,
    Color? warning,
    Color? shadowTint,
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
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      snack: snack ?? this.snack,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
      shadowTint: shadowTint ?? this.shadowTint,
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
      protein: c(protein, other.protein),
      carbs: c(carbs, other.carbs),
      fat: c(fat, other.fat),
      snack: c(snack, other.snack),
      danger: c(danger, other.danger),
      warning: c(warning, other.warning),
      shadowTint: c(shadowTint, other.shadowTint),
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
//   rPill    fully round (pills, FAB, avatars)
const double rChip = 11;
const double rControl = 15;
const double rCard = 22;
const double rSheet = 28;
const double rHero = 28;
const double rPill = 999;

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
