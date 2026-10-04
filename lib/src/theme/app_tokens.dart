import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova design tokens (dark redesign, 2026-09-28)
//
// Colors live as a ThemeExtension read via `context.t`. The app follows the
// display mode (ThemeModeController: system, light or dark).
//
// The dark palette is the design's: page #09090C, cards #131318, a violet
// accent (#B9A5FF fill, #C8B8FF text), macro colors plus lighter "ink" tints
// for text and icons on dark cards. [AppTokens.light] mirrors every role on
// an off-white page with white cards (2026-10-04).
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
    required this.orbBody,
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
    required this.slotBreakfastTint,
    required this.slotBreakfastInk,
    required this.slotLunchTint,
    required this.slotLunchInk,
    required this.slotDinnerTint,
    required this.slotDinnerInk,
    required this.slotSnackTint,
    required this.slotSnackInk,
    required this.knob,
    required this.knobRing,
    required this.glowStrength,
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

  /// Translucent tint for icon tiles and bar tracks; on a dark card it lands
  /// on the design's track tone #24232D.
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

  /// Coach orb gradient stops: highlight, lit body, mid tone, shadow. The
  /// body is the lavender fill in dark; the light fill is a deep iris, which
  /// flattened the sphere into a dark ball, so the body is its own token.
  final Color orbLight, orbBody, orbMid, orbDeep;

  /// Macro encoding. Never an interaction color, never decoration.
  final Color protein, carbs, fat;

  /// Nutrient-specific tint surfaces; use the matching stroke for progress.
  final Color proteinSurface, carbsSurface, fatSurface;

  /// Macro tones for text and icons on cards and on their own tints.
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
  /// for nutrients, and a grey snack would read as disabled). In both
  /// palettes it is the accent itself, as in the design; the slot icon tiles
  /// use their own `slotSnack*` tokens.
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
  /// would vanish on a card, so the dark capsule is lifted to ≥ 1.2:1 there;
  /// the light one sits a step below the page. Constraint: `ink2` (hint)
  /// needs 4.5:1 on all three.
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

  /// Meal-slot icon tiles (translucent tint + glyph ink), the design's slot
  /// hues. Dedicated tokens: macro colors encode nutrients only (lock 1).
  final Color slotBreakfastTint, slotBreakfastInk;
  final Color slotLunchTint, slotLunchInk;
  final Color slotDinnerTint, slotDinnerInk;
  final Color slotSnackTint, slotSnackInk;

  /// Marker knob on a track and the ring around it: the calorie arc's tip,
  /// the BMI scale's marker. Dark draws a near-white dot (no ring); on a
  /// white card that dot inverted into a near-black one, so light uses a
  /// white knob with an accent ring, which also reads on a pale track.
  final Color knob, knobRing;

  /// Scales the alpha of the decorative violet glows (the light behind the
  /// heroes, the avatar and the auth header). 1 in dark, where they read as
  /// light; lower in light, where the same tint reads as a lavender cloud.
  final double glowStrength;

  /// The light palette (2026-10-04): every dark role mirrored on a soft
  /// off-white page with white cards. Same lavender family, same slot hues,
  /// same macro hue identity; the tones are deepened until they carry the
  /// same contrast roles as in the dark palette (pinned per pair in
  /// test/theme/app_tokens_test.dart). Depth comes from hairlines and soft
  /// indigo shadows instead of dark glows.
  static const AppTokens light = AppTokens(
    // Page #F4F3F8 under white cards (1.11:1): a calm grouped-list ground.
    bg: Color(0xFFF4F3F8),
    surf: Color(0xFFFFFFFF),
    // Offset surfaces step DOWN from white where the dark ones step up.
    surf2: Color(0xFFEFEDF5),
    surfRaised: Color(0xFFF6F5FA),
    surfWell: Color(0xFFF9F8FC),
    // 6 % of #2E2A55: #F3F2F5 on a card, #E8E7EE on the page.
    tile: Color(0x0F2E2A55),
    // 9 % / 14 % of #2E2A45: hairlines of 1.18:1 / 1.27:1 on a card.
    line: Color(0x172E2A45),
    lineStrong: Color(0x242E2A45),
    // White glass at 86 % over the blur.
    navGlass: Color(0xDBFFFFFF),
    ink: Color(0xFF17151F),
    inkSoft: Color(0xFF24222D),
    inkMuted: Color(0xFF363341),
    // ink2 holds 4.5:1 on every ground and field fill (5.4:1 on `field`);
    // ink3 holds it on bg/surf/surf2/surfRaised/surfWell and the nav glass.
    ink2: Color(0xFF5C5868),
    ink3: Color(0xFF6B6876),
    inkDisabled: Color(0xFF9F9CAA),
    inkFaint: Color(0xFFCBC8D4),
    // The accent fill at 16 % pre-mixed on the white card, like the dark
    // `forest`. `onForest` is a shade darker than `ink`, so muted 60 % text
    // still reaches 4.58:1 on it.
    forest: Color(0xFFE5E1F8),
    onForest: Color(0xFF110F1A),
    // Iris #5C42D2, the lavender deepened: white text 6.64:1 (4.71:1 at the
    // 78 % quiet label), the fill 6.0:1 against the page as a selection
    // state. `accentText` goes one step deeper for small text (8.0:1).
    lime: Color(0xFF5C42D2),
    onLime: Color(0xFFFFFFFF),
    onAccentMuted: Color(0xFFE2DAFF),
    accent: Color(0xFF5C42D2),
    accentText: Color(0xFF5134C2),
    accentTint: Color(0x1A5C42D2),
    accentTintStrong: Color(0x245C42D2),
    // A soft violet shadow, not a dark glow.
    accentGlow: Color(0x405C42D2),
    progressAccent: Color(0xFF7A62E4),
    // Mirrors the dark arc: the tip is the strongest stop. Both ≥ 3:1 on the
    // track (3.17:1 / 5.69:1); `arcStart` also tints the hero glows.
    arcStart: Color(0xFF8A70E8),
    arcEnd: Color(0xFF5B3FD3),
    arcTrack: Color(0xFFECEAF3),
    chartViolet: Color(0xFFD2C9F4),
    orbLight: Color(0xFFF4F0FF),
    // 60 % from the highlight to arcStart: a lit lavender on the light page.
    orbBody: Color(0xFFB4A3F1),
    orbMid: Color(0xFF5A3EE0),
    orbDeep: Color(0xFF2A1B66),
    // Macro hues deepened into the graphics window: ≥ 3:1 on page, card and
    // bar track, deliberately under 4.5:1 as text (the *Ink tones read).
    protein: Color(0xFF16925B),
    carbs: Color(0xFF2D7DD2),
    fat: Color(0xFFC06A08),
    // Macro tints (12 %, fat 14 %) pre-mixed on the white card.
    proteinSurface: Color(0xFFE3F2EB),
    carbsSurface: Color(0xFFE6EFFA),
    fatSurface: Color(0xFFF6EADC),
    proteinInk: Color(0xFF0F7146),
    carbsInk: Color(0xFF1D5FAA),
    fatInk: Color(0xFF94500A),
    activity: Color(0xFFDB6A1C),
    activityInk: Color(0xFFA34A0A),
    activityTint: Color(0x1FDB6A1C),
    success: Color(0xFF14774A),
    // As in the dark palette, the snack slot carries the accent.
    snack: Color(0xFF5C42D2),
    // Both stay ≥ 4.5:1 as unboxed text on the page and ≥ 3:1 as a glyph
    // on their own 10–16 % fills.
    danger: Color(0xFFB53327),
    warning: Color(0xFF94600A),
    // Soft indigo shadows (10 % raised / 15 % floating), never black.
    shadowTint: Color(0x1A1C1833),
    shadowFloat: Color(0x261C1833),
    // Rest capsule 1.28:1 on a card and 1.16:1 on a sheet; focus lightens it
    // towards the page (1.07:1 step), error is `danger` at 14 % on white.
    field: Color(0xFFE4E2EB),
    fieldFocus: Color(0xFFEBE9F1),
    fieldError: Color(0xFFF5E2E1),
    scrim: Color(0x5217151F),
    // Slot tints (12 %, dinner 14 %) with the matching *Ink glyphs.
    slotBreakfastTint: Color(0x1F2D7DD2),
    slotBreakfastInk: Color(0xFF1D5FAA),
    slotLunchTint: Color(0x1F16925B),
    slotLunchInk: Color(0xFF0F7146),
    slotDinnerTint: Color(0x24C06A08),
    slotDinnerInk: Color(0xFF94500A),
    slotSnackTint: Color(0x1F5C42D2),
    slotSnackInk: Color(0xFF5134C2),
    knob: Color(0xFFFFFFFF),
    knobRing: Color(0xFF5C42D2),
    glowStrength: 0.45,
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
    // The accent fill, as in the design.
    orbBody: Color(0xFFB9A5FF),
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
    // rgba(70,151,226,.16) / (29,176,113,.16) / (213,124,17,.18) /
    // (185,165,255,.16) with the design's glyph inks.
    slotBreakfastTint: Color(0x294697E2),
    slotBreakfastInk: Color(0xFF8CC4FF),
    slotLunchTint: Color(0x291DB071),
    slotLunchInk: Color(0xFF6FDCA4),
    slotDinnerTint: Color(0x2ED57C11),
    slotDinnerInk: Color(0xFFFFB866),
    slotSnackTint: Color(0x29B9A5FF),
    slotSnackInk: Color(0xFFC8B8FF),
    // The design's knob is `ink`; no ring.
    knob: Color(0xFFF5F3FA),
    knobRing: Color(0x00B9A5FF),
    glowStrength: 1,
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
    Color? orbBody,
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
    Color? slotBreakfastTint,
    Color? slotBreakfastInk,
    Color? slotLunchTint,
    Color? slotLunchInk,
    Color? slotDinnerTint,
    Color? slotDinnerInk,
    Color? slotSnackTint,
    Color? slotSnackInk,
    Color? knob,
    Color? knobRing,
    double? glowStrength,
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
      orbBody: orbBody ?? this.orbBody,
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
      slotBreakfastTint: slotBreakfastTint ?? this.slotBreakfastTint,
      slotBreakfastInk: slotBreakfastInk ?? this.slotBreakfastInk,
      slotLunchTint: slotLunchTint ?? this.slotLunchTint,
      slotLunchInk: slotLunchInk ?? this.slotLunchInk,
      slotDinnerTint: slotDinnerTint ?? this.slotDinnerTint,
      slotDinnerInk: slotDinnerInk ?? this.slotDinnerInk,
      slotSnackTint: slotSnackTint ?? this.slotSnackTint,
      slotSnackInk: slotSnackInk ?? this.slotSnackInk,
      knob: knob ?? this.knob,
      knobRing: knobRing ?? this.knobRing,
      glowStrength: glowStrength ?? this.glowStrength,
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
      orbBody: c(orbBody, other.orbBody),
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
      slotBreakfastTint: c(slotBreakfastTint, other.slotBreakfastTint),
      slotBreakfastInk: c(slotBreakfastInk, other.slotBreakfastInk),
      slotLunchTint: c(slotLunchTint, other.slotLunchTint),
      slotLunchInk: c(slotLunchInk, other.slotLunchInk),
      slotDinnerTint: c(slotDinnerTint, other.slotDinnerTint),
      slotDinnerInk: c(slotDinnerInk, other.slotDinnerInk),
      slotSnackTint: c(slotSnackTint, other.slotSnackTint),
      slotSnackInk: c(slotSnackInk, other.slotSnackInk),
      knob: c(knob, other.knob),
      knobRing: c(knobRing, other.knobRing),
      glowStrength: lerpDouble(glowStrength, other.glowStrength, t)!,
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

/// Design shadow for raised cards and controls: `0 10px 28px`, black 50 %
/// in dark, a 10 % indigo in light.
List<BoxShadow> raisedShadow(AppTokens t) => <BoxShadow>[
  BoxShadow(color: t.shadowTint, blurRadius: 28, offset: const Offset(0, 10)),
];

/// Design shadow for floating chrome (the nav bar): `0 12px 32px`, black
/// 55 % in dark, a 15 % indigo in light.
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

  /// Fallback of every Figtree style: Figtree lacks glyphs such as "≈"
  /// (U+2248), which the bundled display family has — no system font, so the
  /// glyph looks the same on every device.
  static const List<String> uiFallback = <String>[displayFamily];

  /// Both families' natural line height (ascent + descent = 1.2 em), the
  /// design's CSS `normal`; the theme's default for text without a height.
  static const double normalHeight = 1.2;

  /// Line height of the theme's body slots (bodyLarge/Medium/Small): running
  /// copy and text fields outside the redesigned tabs keep a readable rhythm,
  /// and a dense 16 px field keeps its 44 px touch height.
  static const double bodyHeight = 1.4;

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
      fontFamilyFallback: uiFallback,
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
        fontFamilyFallback: uiFallback,
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: size * 0.07,
      );

  /// Small all-caps caption above sections.
  static TextStyle eyebrow(Color color, {double size = 10}) => TextStyle(
    fontFamily: uiFamily,
    fontFamilyFallback: uiFallback,
    fontSize: size,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: 1.5,
  );
}
