import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Eatova Design Tokens  (Design-Refactor 2026-08-09)
//
// Vorher lagen alle Farben als Top-Level-`const` in app_colors.dart und wurden
// direkt importiert. Das schloss einen Hell-Modus konstruktiv aus: eine
// Konstante kann nicht zwei Werte haben. Die Farbwelt haengt jetzt als
// ThemeExtension am Theme und wird ueber `context.t` gelesen.
//
// Drei Schlösser gelten weiter (Anti-Slop-Disziplin aus app_colors.dart):
//   1. FARBE  – `lime`/`forest` tragen Marke und Interaktion. Makro-Farben
//               kodieren AUSSCHLIESSLICH Naehrwerte. `danger`/`warning`
//               signalisieren nur Zustand. Keine Ueberschneidung.
//   2. FORM   – eine Radius-Skala (rChip / rControl / rCard / rSheet / rHero /
//               rPill), unten in dieser Datei.
//   3. SCHICHT– Material 3 traegt Verhalten und Semantik, diese Tokens tragen
//               die Pixel. Kein Widget schreibt eine Farbe hart hin.
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

  /// Seiten-Grund (Scaffold).
  final Color bg;

  /// Karten-/Panel-Flaeche auf [bg].
  final Color surf;

  /// Zweite, leicht abgesetzte Flaeche (Banner, Bild-Platzhalter).
  final Color surf2;

  /// Sehr schwache Fuellung fuer Icon-Kacheln und Balken-Spuren.
  final Color tile;

  /// Trennlinien und Kartenraender (1 px, bewusst sehr schwach).
  final Color line;

  /// Haupttext.
  final Color ink;

  /// Sekundaertext, Icons, Beschriftungen.
  final Color ink2;

  /// Die dunkelgruene Marken-Flaeche (Hero-Karten, primaere Buttons).
  final Color forest;

  /// Text/Icon auf [forest].
  final Color onForest;

  /// Der Marken-Akzent.
  final Color lime;

  /// Text/Icon auf [lime] — immer dunkel, in beiden Modi.
  final Color onLime;

  /// Strich-/Fuellfarbe fuer Grafiken, die AUF einer hellen Karte sitzen.
  /// Im Dunkelmodus ist [forest] eine *Flaeche* und taugt dort nicht als
  /// Tinte — deshalb dieser eigene Token statt einer Fallunterscheidung.
  final Color accent;

  /// Makro-Kodierung. Nie Interaktionsfarbe, nie Dekoration.
  final Color protein, carbs, fat;

  /// Vierte kategorische Farbe fuer den Snack-Slot (die drei Makro-Toene
  /// sind fuer Naehrwerte reserviert, ein grauer Snack laese sich wie
  /// „deaktiviert").
  final Color snack;

  /// Zustands-Signale. Getrennt von Marke und Daten.
  final Color danger, warning;

  /// Getoenter Schatten fuer erhabene Flaechen (nie reines Schwarz).
  final Color shadowTint;

  static const AppTokens light = AppTokens(
    bg: Color(0xFFF2EFE6),
    surf: Color(0xFFFFFDF8),
    surf2: Color(0xFFEAE6DA),
    tile: Color(0x0D151E18),
    line: Color(0x1A151E18),
    ink: Color(0xFF151E18),
    // Dunkler als der Entwurf (#6E7C73): dessen Ton erreichte auf `surf` nur
    // 4.31:1 und auf `surf2` 3.51:1. `ink2` traegt hier fast durchgehend
    // KLEINE Schrift (9,5–12,5 px), ist also normaler Fliesstext im Sinne der
    // WCAG und braucht 4.5:1. Dieser Ton haelt 5.7 / 5.1 / 4.7 auf
    // surf / bg / surf2.
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

  /// Die Tokens des naechstgelegenen Themes. Wirft bewusst, wenn die
  /// Extension fehlt — ein Screen ohne Tokens ist ein Verdrahtungsfehler,
  /// kein Anzeigefehler, und soll im Test sofort auffallen.
  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>()!;

  /// Ein Ton von [farbe], der auf ihrer eigenen schwachen Tint lesbar ist.
  ///
  /// Das Muster „Glyph in der vollen Kategoriefarbe auf derselben Farbe mit
  /// ~16 % Deckung" (MealAvatar, Slot-Waehler) sieht dunkel gut aus und
  /// scheiterte hell: Kohlenhydrat-Amber kam auf 2.15:1. Die Mischung
  /// Richtung [ink] loest das ohne Helligkeits-Abzweig im Widget — [ink] ist
  /// in der hellen Palette dunkel und in der dunklen hell, die Korrektur geht
  /// also von selbst in die richtige Richtung. Der Farbton bleibt erhalten.
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

/// Kurzform fuer den Zugriff im build(): `final t = context.t;`
extension TokensX on BuildContext {
  AppTokens get t => AppTokens.of(this);
}

// --- FORM-SKALA --------------------------------------------------------------
// Helligkeitsunabhaengig, deshalb weiter als Top-Level-Konstanten.
//   rChip    Chips, kleine Schalter, Tags
//   rControl Eingaben, Buttons, Listenzeilen
//   rCard    Karten, Panels
//   rSheet   Bottom-Sheets, Dialoge
//   rHero    grosse Marken-Flaechen (Kalorien-Hero, Identitaets-Karte)
//   rPill    vollrund (Pillen, FAB, Avatare)
const double rChip = 11;
const double rControl = 15;
const double rCard = 22;
const double rSheet = 28;
const double rHero = 28;
const double rPill = 999;

/// Weiche Erhebung fuer schwebende Flaechen (Nav-Leiste, Sheets). Die neue
/// Sprache traegt Tiefe primaer ueber [AppTokens.line]; Schatten bleiben die
/// Ausnahme fuer Dinge, die wirklich ueber dem Inhalt liegen.
List<BoxShadow> softShadow(AppTokens t) => <BoxShadow>[
      BoxShadow(
        color: t.shadowTint,
        blurRadius: 28,
        offset: const Offset(0, 14),
        spreadRadius: -10,
      ),
    ];

// --- SCHRIFT -----------------------------------------------------------------
// Zwei gebuendelte Familien (assets/fonts, KEIN google_fonts):
//   * Bricolage Grotesque traegt Zahlen und Ueberschriften — enge Negativ-
//     Laufweite, tabellarische Ziffern, damit Kalorienwerte beim Zaehlen
//     nicht springen.
//   * Archivo traegt alles Uebrige (Fliesstext, Beschriftungen, Buttons).
// Bewusst gebuendelt statt ueber google_fonts geladen: kein Laufzeit-Request
// an Google (Datenschutzerklaerung), kein Fallback-Aufblitzen, offline
// identisch.
class AppType {
  const AppType._();

  static const String displayFamily = 'BricolageGrotesque';
  static const String uiFamily = 'Archivo';

  /// Zahlen und Ueberschriften.
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

  /// Fliesstext, Beschriftungen, Buttons.
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

  /// Kleine Versalien-Beschriftung ueber Abschnitten.
  static TextStyle eyebrow(Color color, {double size = 10}) => TextStyle(
        fontFamily: uiFamily,
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 1.5,
      );
}
