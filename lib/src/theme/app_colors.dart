import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// FitPilot Design Tokens
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
// Helleres Lime aus dem Stitch-"FORGE"-Ernährungs-Entwurf. Bricht BEWUSST den
// app-weiten Lime-Lock NUR im Food-Tab (User-freigegeben). Falls es gut wirkt,
// kann es später app-weit nachgezogen werden.
const Color forgeLime = Color(0xFFC3F400);      // primärer Food-Tab-Akzent
const Color forgeLimeDim = Color(0xFFABD600);   // gedämpfte Variante
// Translucent-Panel-Fill der Glass-Kalorienkarte (~rgba(42,42,42,0.6)).
const Color forgeGlassFill = Color(0x992A2A2A);
// Hairline-Rand der Glass-Karte (~rgba(255,255,255,0.05)).
const Color forgeGlassBorder = Color(0x0DFFFFFF);

// --- COACH-TAB ACCENT (coach-tab-scoped) -------------------------------------
// Indigo aus dem "AI Coach v2"-Entwurf (2026-08-03). Bricht BEWUSST den
// app-weiten Lime-Lock NUR im Coach-Tab (User-freigegeben, gleiches Muster
// wie forgeLime im Food-Tab). Der warme Zweitton existiert nur fuer den
// Sweep-Verlauf des Coach-Orbs.
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
// Wide-usage legacy names, kept so untouched screens still build while the
// rainbow palette is migrated to the semantic names wave by wave.
// cyan -> carbs, orange -> fat.
const Color cyan = macroCarbs;
const Color orange = macroFat;

// --- Meal-slot encoding (categorical) ---------------------------------------
// breakfast = macroFat (amber), lunch = lime, snack = macroCarbs (cyan).
// Dinner gets its own refined tone (replaces the old candy-pink).
const Color slotDinner = Color(0xFFE07A9B); // dusk rose

// --- Wellness / recovery accent ---------------------------------------------
// One calm tone for sleep, caffeine, recovery and secondary categorical tiles.
// Replaces the scattered decorative candy-pink.
const Color wellnessTone = Color(0xFF6E93C9); // steel blue

// --- Text + lines -----------------------------------------------------------
const Color textPrimary = Color(0xFFF5F6F8);
const Color textMuted = Color(0xFF8A8F99);
const Color hairline = Color(0x1AFFFFFF);

// --- DEPTH ------------------------------------------------------------------
// Premium dark relies on tinted depth, never pure black. The shadow carries
// the background hue so elevation reads as soft, not as a black halo.
const Color shadowTint = Color(0x59060810);
// A 1px inner top-edge highlight that gives surfaces a physical lit edge.
const Color cardHighlight = Color(0x12FFFFFF);
// Top-of-card sheen tone (sits between surface and surfaceSoft) for a faint
// lit gradient from the top edge down into the card body.
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
