import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova Design Tokens
//
// Three locks govern this file (anti-slop discipline):
//   1. COLOR  – lime is the ONE brand/interaction color. Data colors encode
//               macros only. State colors signal feedback only. No overlap.
//   2. SHAPE  – one radius scale (rChip / rControl / rCard / rSheet / rPill).
//   3. THEME  – dark only, off-black surfaces, never pure #000.
// ---------------------------------------------------------------------------

// --- Surfaces (off-black, layered) -----------------------------------------
const Color bg = Color(0xFF0B0D11);
const Color surface = Color(0xFF14171D);
const Color surfaceSoft = Color(0xFF1B1F27);

// --- BRAND ACCENT -----------------------------------------------------------
// The single locked interaction color: every CTA, active tab, focus ring,
// selected state, primary highlight. Nothing decorative competes with it.
const Color lime = Color(0xFFB6F36A);
// Lighter brand tint for subtle single-hue gradients/sheen on brand surfaces.
// Use [lime, limeBright] instead of any multi-hue gradient.
const Color limeBright = Color(0xFFD8FF9E);

// --- STITCH "FORGE" FOOD-TAB PALETTE (food-tab-scoped) -----------------------
// Brighter lime that deliberately breaks the app-wide lime lock, food tab only.
const Color forgeLime = Color(0xFFC3F400);      // primary food-tab accent
const Color forgeLimeDim = Color(0xFFABD600);   // dimmed variant
// Translucent panel fill of the glass calorie card (~rgba(42,42,42,0.6)).
const Color forgeGlassFill = Color(0x992A2A2A);
// Hairline border of the glass card (~rgba(255,255,255,0.05)).
const Color forgeGlassBorder = Color(0x0DFFFFFF);

// --- COACH-TAB ACCENT (coach-tab-scoped) -------------------------------------
// Indigo that breaks the lime lock, coach tab only (same pattern as forgeLime).
// The warm second tone exists only for the coach orb's sweep gradient.
const Color coachAccent = Color(0xFF4A63C9);
const Color coachAccentWarm = Color(0xFFF4D8A8);

// --- DATA ENCODING ----------------------------------------------------------
// Reserved EXCLUSIVELY for macro/metric coding. Never an interaction color,
// never decoration. One macro, one color, everywhere.
const Color macroProtein = lime; // protein rides the brand tone
const Color macroCarbs = Color(0xFF7DD3FC); // carbs
const Color macroFat = Color(0xFFFDBA74); // fat

// --- STATE FEEDBACK ---------------------------------------------------------
// Distinct from brand and data. Warning != the fat macro tone.
const Color warning = Color(0xFFFCA56B);
const Color danger = Color(0xFFF4736B);

// --- Back-compat aliases ----------------------------------------------------
// Legacy names kept so untouched screens still build during the migration.
// cyan -> carbs, orange -> fat.
const Color cyan = macroCarbs;
const Color orange = macroFat;

// --- Meal-slot encoding (categorical) ---------------------------------------
// breakfast = macroFat (amber), lunch = lime, snack = macroCarbs (cyan).
// Dinner gets its own tone.
const Color slotDinner = Color(0xFFE07A9B); // dusk rose

// --- Wellness / recovery accent ---------------------------------------------
// One calm tone for sleep, caffeine, recovery and secondary tiles.
const Color wellnessTone = Color(0xFF6E93C9); // steel blue

// --- Text + lines -----------------------------------------------------------
const Color textPrimary = Color(0xFFF5F6F8);
const Color textMuted = Color(0xFF8A8F99);
const Color hairline = Color(0x1AFFFFFF);

// --- DEPTH ------------------------------------------------------------------
// Tinted depth, never pure black: the shadow carries the background hue.
const Color shadowTint = Color(0x59060810);
// A 1px inner top-edge highlight that gives surfaces a physical lit edge.
const Color cardHighlight = Color(0x12FFFFFF);
// Top-of-card sheen (between surface and surfaceSoft) for a lit gradient.
const Color cardSheenTop = Color(0xFF181C24);

/// Reusable soft elevation for raised surfaces (cards, sheets, pills).
const List<BoxShadow> cardShadow = <BoxShadow>[
  BoxShadow(
    color: shadowTint,
    blurRadius: 28,
    offset: Offset(0, 14),
    spreadRadius: -10,
  ),
];

// --- SHAPE SCALE ------------------------------------------------------------
// One documented radius system. Pick the role, not a random number.
//   rChip    chips, small toggles, tags
//   rControl inputs, buttons, list rows
//   rCard    cards, panels
//   rSheet   bottom sheets, large containers
//   rPill    fully-round interactive (pills, FAB, avatars)
const double rChip = 8;
const double rControl = 12;
const double rCard = 16;
const double rSheet = 24;
const double rPill = 999;

Color shiftColor(String shift) {
  return switch (shift) {
    'Kraft' => lime,
    'Muskelaufbau' => lime,
    'Ausdauer' => macroFat,
    'Mobility' => macroCarbs,
    'Recovery' => macroCarbs,
    'Frei' => macroCarbs,
    _ => textPrimary,
  };
}
