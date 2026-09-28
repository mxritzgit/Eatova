import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova design tokens (dark redesign, 2026-09-28)
//
// Colors live as a ThemeExtension read via `context.t`. The app currently
// renders [AppTokens.dark] only (`kDarkOnly` in eatova_app.dart);
// [AppTokens.light] stays dormant so switching back is a one-line change.
//
// The dark palette is the design's: page #09090C, cards #131318, a violet
// accent (#B9A5FF fill, #C8B8FF text), macro colors plus lighter "ink" tints
// for text and icons on dark cards.
//
// Three locks still hold:
//   1. COLOR – the accent (legacy names `lime`/`forest`) carries brand and
//              interaction, macro colors encode nutrients ONLY,
//              `danger`/`warning` signal state only.
//   2. SHAPE – one radius scale (rChip / rControl / rCard / rTile / rSheet /
//              rHero / rPill …), at the bottom of this file.
//   3. LAYER – Material 3 carries behavior, these tokens carry the pixels.
//              No widget hardcodes a color.
// ---------------------------------------------------------------------------

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.surf,
    required this.surf2,
    required this.surfRaised,
    required this.surfWell,
    required this.tile,
    required this.line,
    required this.lineStrong,
    required this.navGlass,
    required this.ink,
    required this.inkSoft,
    required this.inkMuted,
    required this.ink2,
    required this.ink3,
    required this.inkDisabled,
    required this.inkFaint,
    required this.forest,
    required this.onForest,
    required this.lime,
    required this.onLime,
    required this.onAccentMuted,
    required this.accent,
    required this.accentText,
    required this.accentTint,
    required this.accentTintStrong,
    required this.accentGlow,
    required this.progressAccent,
    required this.arcStart,
    required this.arcEnd,
    required this.arcTrack,
    required this.chartViolet,
    required this.orbLight,
    required this.orbMid,
    required this.orbDeep,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.proteinSurface,
    required this.carbsSurface,
    required this.fatSurface,
    required this.proteinInk,
    required this.carbsInk,
    required this.fatInk,
    required this.activity,
    required this.activityInk,
    required this.activityTint,
    required this.success,
    required this.snack,
    required this.danger,
    required this.warning,
    required this.shadowTint,
    required this.shadowFloat,
    required this.field,
    required this.fieldFocus,
    required this.fieldError,
    required this.scrim,
  });

  /// Page ground (scaffold).
  final Color bg;

  /// Card/panel surface on [bg].
  final Color surf;

  /// Second, slightly offset surface (banners, image placeholders, secondary
  /// buttons and chips on a card).
  final Color surf2;

  /// Raised sub-surface between [surf] and [surf2] (wells, day cells).
  final Color surfRaised;

  /// Quiet well behind illustrations and photos on a card.
  final Color surfWell;

  /// Translucent tint for icon tiles and bar tracks; on a card it lands on
  /// the design's track tone #24232D.
  final Color tile;

  /// Dividers and card borders (1 px, deliberately faint).
  final Color line;

  /// Card border — the same faint 1 px edge as [line].
  Color get cardBorder => line;

  /// Stronger 1 px outline: floating nav bar, unselected chips, icon buttons.
  final Color lineStrong;

  /// Translucent fill of the floating glass nav bar (sits over a blur).
  final Color navGlass;

  /// Primary text.
  final Color ink;

  /// Near-primary text for chip labels and secondary controls.
  final Color inkSoft;

  /// Strong-muted text: kcal values, day numbers, control icons.
  final Color inkMuted;

  /// Secondary text, icons, labels.
  final Color ink2;

  /// Tertiary/meta text (captions, units, inactive nav items). Meets 4.5:1 on
  /// [bg], [surf], [surf2] and [surfRaised] — NOT on [tile] or the [field]
  /// capsule, where hints stay [ink2].
  final Color ink3;

  /// Disabled text and icons.
  final Color inkDisabled;

  /// Faintest marks (idle dots). Decorative only, never text.
  final Color inkFaint;

  /// Accent tint surface (opaque). Legacy token name retained for existing
  /// screens.
  final Color forest;

  /// Text/icon on [forest].
  final Color onForest;

  /// Accent fill, paired with [onLime]. Legacy token name; new code reads
  /// [accentFill].
  final Color lime;

  /// Text/icon on the accent fill.
  final Color onLime;

  /// The accent fill (buttons, the selected day, the send button).
  Color get accentFill => lime;

  /// Text/icon on [accentFill].
  Color get onAccentFill => onLime;

  /// Secondary label on [accentFill] (e.g. the weekday above the date).
  final Color onAccentMuted;

  /// Stroke/fill for graphics sitting on a card (rings, cursor, today mark).
  final Color accent;

  /// Accent for text, links and icons.
  final Color accentText;

  /// Translucent accent tint behind accent text (pills, add buttons).
  final Color accentTint;

  /// Slightly stronger accent tint (active nav capsule, accent icon tiles).
  final Color accentTintStrong;

  /// Glow shadow under accent-filled controls.
  final Color accentGlow;

  /// Softer progress ink, readable against an unfilled surface track.
  final Color progressAccent;
  Color get proteinProgress => Color.lerp(protein, surf, 0.12)!;
  Color get carbsProgress => Color.lerp(carbs, surf, 0.12)!;
  Color get fatProgress => Color.lerp(fat, surf, 0.12)!;

  /// Calorie arc gradient (start → end) and its unfilled track.
  final Color arcStart, arcEnd, arcTrack;

  /// Deep violet for chart bars.
  final Color chartViolet;

  /// Coach orb gradient stops around [lime]: highlight, body, shadow.
  final Color orbLight, orbMid, orbDeep;

  /// Macro encoding. Never an interaction color, never decoration.
  final Color protein, carbs, fat;

  /// Nutrient-specific tint surfaces; use the matching stroke for progress.
  final Color proteinSurface, carbsSurface, fatSurface;

  /// Macro tones for text and icons on dark surfaces and on their own tints.
  final Color proteinInk, carbsInk, fatInk;

  /// Activity/energy: bar fill, text/icon tone and translucent tile tint.
  final Color activity, activityInk, activityTint;

  /// Positive/success text.
  final Color success;

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

  /// Shadow for raised surfaces.
  final Color shadowTint;

  /// Shadow for floating chrome (the nav bar).
  final Color shadowFloat;

  /// Input capsule at rest.
  ///
  /// APP-WIDE FOCUS LANGUAGE for every text input (repo rule): no hairline,
  /// no focus ring, no red ring. The capsule is [field] with [softShadow];
  /// focus LIGHTENS it to [fieldFocus]; an error tints it to [fieldError]
  /// and adds the error line. `FieldCapsule` / `SheetField` implement it —
  /// private capsules must use these three tokens, never surf/surf2/tile.
  ///
  /// Own tones, deliberately none of surf/surf2/bg: the capsule must stay
  /// visible on a card (surf) AND on a sheet (bg). The design draws its
  /// inputs as #1B1A22 plus a white hairline; without the hairline that fill
  /// would vanish on a card, so the dark capsule is lifted to ≥ 1.2:1 there.
  /// Constraint: `ink2` (hint) needs 4.5:1 on all three.
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

  /// Dormant since the dark-only rollout (2026-09-28); kept compiling so the
  /// light theme can come back with the `kDarkOnly` switch.
  static const AppTokens light = AppTokens(
    bg: Color(0xFFF8F8FC),
    surf: Color(0xFFFFFFFF),
    surf2: Color(0xFFF0EEF6),
    surfRaised: Color(0xFFF4F2F9),
    surfWell: Color(0xFFEFEDF5),
    tile: Color(0x0D16151F),
    line: Color(0x1816151F),
    lineStrong: Color(0x2416151F),
    navGlass: Color(0xD6FFFFFF),
    ink: Color(0xFF16151F),
    inkSoft: Color(0xFF1F1E29),
    inkMuted: Color(0xFF2E2C38),
    ink2: Color(0xFF625F6D),
    ink3: Color(0xFF6E6B7A),
    inkDisabled: Color(0xFFA9A6B4),
    inkFaint: Color(0xFFC9C6D2),
    forest: Color(0xFFEAE5FF),
    onForest: Color(0xFF090812),
    lime: Color(0xFF6550A8),
    onLime: Color(0xFFFFFFFF),
    onAccentMuted: Color(0xFFE4DDFF),
    accent: Color(0xFF6550A8),
    accentText: Color(0xFF6550A8),
    accentTint: Color(0x1A6550A8),
    accentTintStrong: Color(0x216550A8),
    accentGlow: Color(0x406550A8),
    progressAccent: Color(0xFF9782DC),
    arcStart: Color(0xFF6550A8),
    arcEnd: Color(0xFFB7A6F0),
    arcTrack: Color(0xFFEAE7F0),
    chartViolet: Color(0xFFD7CFF2),
    orbLight: Color(0xFFF1ECFF),
    orbMid: Color(0xFF6A4BF0),
    orbDeep: Color(0xFF2A1B66),
    protein: Color(0xFF31845A),
    carbs: Color(0xFF2887A0),
    fat: Color(0xFFA97917),
    proteinSurface: Color(0xFFDDF5E4),
    carbsSurface: Color(0xFFDDF3FC),
    fatSurface: Color(0xFFFFEFC1),
    proteinInk: Color(0xFF2E7D55),
    carbsInk: Color(0xFF1F6F85),
    fatInk: Color(0xFF8A6212),
    activity: Color(0xFFE07A2E),
    activityInk: Color(0xFFA5520F),
    activityTint: Color(0x24FF914D),
    success: Color(0xFF2E7D55),
    snack: Color(0xFF99718F),
    danger: Color(0xFFB23A28),
    warning: Color(0xFF8A6212),
    shadowTint: Color(0x1416151F),
    shadowFloat: Color(0x2416151F),
    field: Color(0xFFEAE7F0),
    fieldFocus: Color(0xFFF2EFF8),
    fieldError: Color(0xFFF9EDE7),
    scrim: Color(0x8C16151F),
  );

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF09090C),
    surf: Color(0xFF131318),
    surf2: Color(0xFF1F1E27),
    surfRaised: Color(0xFF1B1A22),
    surfWell: Color(0xFF16151C),
    // 10 % of #BDB3EA: exactly #24232D on `surf`, #1B1A22 on `bg`.
    tile: Color(0x1ABDB3EA),
    // rgba(255, 255, 255, 0.06) / 0.08
    line: Color(0x0FFFFFFF),
    lineStrong: Color(0x14FFFFFF),
    // rgba(24, 23, 31, 0.84)
    navGlass: Color(0xD618171F),
    ink: Color(0xFFF5F3FA),
    inkSoft: Color(0xFFE6E3EE),
    inkMuted: Color(0xFFD9D6E4),
    ink2: Color(0xFFB1AEC0),
    ink3: Color(0xFF8B8898),
    inkDisabled: Color(0xFF5E5B6B),
    inkFaint: Color(0xFF4A4756),
    // The accent tint (#B9A5FF at 16 %) pre-mixed on a card.
    forest: Color(0xFF2E2A3D),
    onForest: Color(0xFFF5F3FA),
    lime: Color(0xFFB9A5FF),
    onLime: Color(0xFF16112A),
    onAccentMuted: Color(0xFF3A2F66),
    accent: Color(0xFFB9A5FF),
    accentText: Color(0xFFC8B8FF),
    // rgba(185, 165, 255, 0.14) / 0.16
    accentTint: Color(0x24B9A5FF),
    accentTintStrong: Color(0x29B9A5FF),
    // rgba(140, 110, 255, 0.35)
    accentGlow: Color(0x598C6EFF),
    progressAccent: Color(0xFFB9A5FF),
    arcStart: Color(0xFF7C5CFF),
    arcEnd: Color(0xFFD9CCFF),
    arcTrack: Color(0xFF24212F),
    chartViolet: Color(0xFF3A3354),
    orbLight: Color(0xFFF1ECFF),
    orbMid: Color(0xFF6A4BF0),
    orbDeep: Color(0xFF2A1B66),
    protein: Color(0xFF1DB071),
    carbs: Color(0xFF4697E2),
    fat: Color(0xFFD57C11),
    // Macro tints (16 %, fat 18 %) pre-mixed on a card.
    proteinSurface: Color(0xFF152C26),
    carbsSurface: Color(0xFF1B2838),
    fatSurface: Color(0xFF362617),
    proteinInk: Color(0xFF6FDCA4),
    carbsInk: Color(0xFF8CC4FF),
    fatInk: Color(0xFFFFB866),
    activity: Color(0xFFFF9A4D),
    activityInk: Color(0xFFFFB27A),
    // rgba(255, 145, 77, 0.14)
    activityTint: Color(0x24FF914D),
    success: Color(0xFF6FDCA4),
    snack: Color(0xFFB9A5FF),
    danger: Color(0xFFF08A72),
    warning: Color(0xFFF0B458),
    // rgba(0, 0, 0, 0.5) raised / 0.55 floating
    shadowTint: Color(0x80000000),
    shadowFloat: Color(0x8C000000),
    field: Color(0xFF26252F),
    fieldFocus: Color(0xFF2F2E39),
    fieldError: Color(0xFF3A2F36),
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
    Color? surfRaised,
    Color? surfWell,
    Color? tile,
    Color? line,
    Color? lineStrong,
    Color? navGlass,
    Color? ink,
    Color? inkSoft,
    Color? inkMuted,
    Color? ink2,
    Color? ink3,
    Color? inkDisabled,
    Color? inkFaint,
    Color? forest,
    Color? onForest,
    Color? lime,
    Color? onLime,
    Color? onAccentMuted,
    Color? accent,
    Color? accentText,
    Color? accentTint,
    Color? accentTintStrong,
    Color? accentGlow,
    Color? progressAccent,
    Color? arcStart,
    Color? arcEnd,
    Color? arcTrack,
    Color? chartViolet,
    Color? orbLight,
    Color? orbMid,
    Color? orbDeep,
    Color? protein,
    Color? carbs,
    Color? fat,
    Color? proteinSurface,
    Color? carbsSurface,
    Color? fatSurface,
    Color? proteinInk,
    Color? carbsInk,
    Color? fatInk,
    Color? activity,
    Color? activityInk,
    Color? activityTint,
    Color? success,
    Color? snack,
    Color? danger,
    Color? warning,
    Color? shadowTint,
    Color? shadowFloat,
    Color? field,
    Color? fieldFocus,
    Color? fieldError,
    Color? scrim,
  }) {
    return AppTokens(
      bg: bg ?? this.bg,
      surf: surf ?? this.surf,
      surf2: surf2 ?? this.surf2,
      surfRaised: surfRaised ?? this.surfRaised,
      surfWell: surfWell ?? this.surfWell,
      tile: tile ?? this.tile,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      navGlass: navGlass ?? this.navGlass,
      ink: ink ?? this.ink,
      inkSoft: inkSoft ?? this.inkSoft,
      inkMuted: inkMuted ?? this.inkMuted,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      inkDisabled: inkDisabled ?? this.inkDisabled,
      inkFaint: inkFaint ?? this.inkFaint,
      forest: forest ?? this.forest,
      onForest: onForest ?? this.onForest,
      lime: lime ?? this.lime,
      onLime: onLime ?? this.onLime,
      onAccentMuted: onAccentMuted ?? this.onAccentMuted,
      accent: accent ?? this.accent,
      accentText: accentText ?? this.accentText,
      accentTint: accentTint ?? this.accentTint,
      accentTintStrong: accentTintStrong ?? this.accentTintStrong,
      accentGlow: accentGlow ?? this.accentGlow,
      progressAccent: progressAccent ?? this.progressAccent,
      arcStart: arcStart ?? this.arcStart,
      arcEnd: arcEnd ?? this.arcEnd,
      arcTrack: arcTrack ?? this.arcTrack,
      chartViolet: chartViolet ?? this.chartViolet,
      orbLight: orbLight ?? this.orbLight,
      orbMid: orbMid ?? this.orbMid,
      orbDeep: orbDeep ?? this.orbDeep,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      proteinSurface: proteinSurface ?? this.proteinSurface,
      carbsSurface: carbsSurface ?? this.carbsSurface,
      fatSurface: fatSurface ?? this.fatSurface,
      proteinInk: proteinInk ?? this.proteinInk,
      carbsInk: carbsInk ?? this.carbsInk,
      fatInk: fatInk ?? this.fatInk,
      activity: activity ?? this.activity,
      activityInk: activityInk ?? this.activityInk,
      activityTint: activityTint ?? this.activityTint,
      success: success ?? this.success,
      snack: snack ?? this.snack,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
      shadowTint: shadowTint ?? this.shadowTint,
      shadowFloat: shadowFloat ?? this.shadowFloat,
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
      surfRaised: c(surfRaised, other.surfRaised),
      surfWell: c(surfWell, other.surfWell),
      tile: c(tile, other.tile),
      line: c(line, other.line),
      lineStrong: c(lineStrong, other.lineStrong),
      navGlass: c(navGlass, other.navGlass),
      ink: c(ink, other.ink),
      inkSoft: c(inkSoft, other.inkSoft),
      inkMuted: c(inkMuted, other.inkMuted),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      inkDisabled: c(inkDisabled, other.inkDisabled),
      inkFaint: c(inkFaint, other.inkFaint),
      forest: c(forest, other.forest),
      onForest: c(onForest, other.onForest),
      lime: c(lime, other.lime),
      onLime: c(onLime, other.onLime),
      onAccentMuted: c(onAccentMuted, other.onAccentMuted),
      accent: c(accent, other.accent),
      accentText: c(accentText, other.accentText),
      accentTint: c(accentTint, other.accentTint),
      accentTintStrong: c(accentTintStrong, other.accentTintStrong),
      accentGlow: c(accentGlow, other.accentGlow),
      progressAccent: c(progressAccent, other.progressAccent),
      arcStart: c(arcStart, other.arcStart),
      arcEnd: c(arcEnd, other.arcEnd),
      arcTrack: c(arcTrack, other.arcTrack),
      chartViolet: c(chartViolet, other.chartViolet),
      orbLight: c(orbLight, other.orbLight),
      orbMid: c(orbMid, other.orbMid),
      orbDeep: c(orbDeep, other.orbDeep),
      protein: c(protein, other.protein),
      carbs: c(carbs, other.carbs),
      fat: c(fat, other.fat),
      proteinSurface: c(proteinSurface, other.proteinSurface),
      carbsSurface: c(carbsSurface, other.carbsSurface),
      fatSurface: c(fatSurface, other.fatSurface),
      proteinInk: c(proteinInk, other.proteinInk),
      carbsInk: c(carbsInk, other.carbsInk),
      fatInk: c(fatInk, other.fatInk),
      activity: c(activity, other.activity),
      activityInk: c(activityInk, other.activityInk),
      activityTint: c(activityTint, other.activityTint),
      success: c(success, other.success),
      snack: c(snack, other.snack),
      danger: c(danger, other.danger),
      warning: c(warning, other.warning),
      shadowTint: c(shadowTint, other.shadowTint),
      shadowFloat: c(shadowFloat, other.shadowFloat),
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
// Brightness-independent, so still top-level constants. Values follow the
// dark redesign (2026-09-28).
//   rChip    chips, small switches, tags, small icon squares
//   rControl inputs, list rows, icon tiles, square control buttons
//   rThumb   image thumbnails, day cells, search capsules
//   rTile    compact stat tiles (macro tiles)
//   rCard    list cards, panels
//   rNav     the floating nav bar
//   rSheet   bottom sheets, dialogs
//   rHero    large brand surfaces (calorie hero, identity card)
//   rButton  the primary action (PrimaryActionButton, FilledButton, sheet
//            action) — ONE radius for one semantics; a full pill at the
//            54 px primary height
//   rPill    fully round (pills, FAB, avatars, round buttons)
const double rChip = 12;
const double rControl = 14;
const double rThumb = 18;
const double rTile = 20;
const double rCard = 24;
const double rNav = 26;
const double rButton = 27;
const double rSheet = 28;
const double rHero = 28;
const double rPill = 999;

/// Minimum height of the PRIMARY action only: [PrimaryActionButton] and the
/// [SheetScaffold] action. Themed Filled/OutlinedButtons stay at
/// [kButtonMinHeight] so dialog actions next to a TextButton do not tower.
const double kPrimaryButtonHeight = 54;

/// Touch-target floor for themed Material buttons (Filled/Outlined).
const double kButtonMinHeight = 48;

/// Soft elevation for floating surfaces (sheets, input capsules). Depth
/// normally comes from [AppTokens.line]; shadows stay the exception for
/// things that really sit above the content.
List<BoxShadow> softShadow(AppTokens t) => <BoxShadow>[
  BoxShadow(
    color: t.shadowTint,
    blurRadius: 28,
    offset: const Offset(0, 14),
    spreadRadius: -10,
  ),
];

/// Design shadow for raised cards and controls: `0 10px 28px` black 50 %.
List<BoxShadow> raisedShadow(AppTokens t) => <BoxShadow>[
  BoxShadow(color: t.shadowTint, blurRadius: 28, offset: const Offset(0, 10)),
];

/// Design shadow for floating chrome (the nav bar): `0 12px 32px` black 55 %.
List<BoxShadow> floatingShadow(AppTokens t) => <BoxShadow>[
  BoxShadow(color: t.shadowFloat, blurRadius: 32, offset: const Offset(0, 12)),
];

// --- TYPE --------------------------------------------------------------------
// Two bundled families (assets/fonts, NO google_fonts):
//   * Bricolage Grotesque for numbers and headings — tight negative tracking,
//     tabular figures so calorie values do not jump while counting.
//   * Figtree for everything else (body, labels, buttons).
// Bundled on purpose: no runtime request to Google (privacy policy), no
// fallback flash, identical offline.
class AppType {
  const AppType._();

  static const String displayFamily = 'BricolageGrotesque';
  static const String uiFamily = 'Figtree';

  /// The shared title scale for tabs and pushed pages. Tab titles follow the
  /// dark redesign: 36 px, -0.03 em, line height 1.05, ExtraBold (the design's
  /// 750 has no static cut; 800 is the nearest bundled weight). Render tab
  /// titles with [pageTitleScaler].
  static TextStyle pageTitle(Color color, {bool subpage = false}) => subpage
      ? display(24, color: color, height: 1.1)
      : display(36, color: color, height: 1.05);

  /// Largest text scale a tab title follows: at the app's 2.0x cap the 36 px
  /// title reaches 60 px — what the pre-redesign 30 px title reached — so
  /// "Training" stays one word on a 320 px phone. A 36 px heading is large
  /// text already; body text keeps the full 2.0x.
  static const double pageTitleMaxScale = 60 / 36;

  /// The text scaler for a tab title (and for measuring one).
  static TextScaler pageTitleScaler(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(maxScaleFactor: pageTitleMaxScale);

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

  /// The dark redesign's eyebrow above a card or section title ("TONIGHT'S
  /// PICK", "LEFT TODAY"): 12 px, weight 700, 0.07 em tracking; the design
  /// colors it `accentText`. A style cannot uppercase: callers pass
  /// `text.toUpperCase()` and keep the original as `semanticsLabel`, so screen
  /// readers do not spell it out.
  static TextStyle sectionEyebrow(Color color, {double size = 12}) =>
      TextStyle(
        fontFamily: uiFamily,
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: size * 0.07,
      );

  /// Small all-caps caption above sections.
  static TextStyle eyebrow(Color color, {double size = 10}) => TextStyle(
    fontFamily: uiFamily,
    fontSize: size,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: 1.5,
  );
}
