import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// Das Eatova-Theme — Material 3 als Fundament, [AppTokens] als sichtbare
/// Schicht.
///
/// Die Arbeitsteilung (Design-Refactor 2026-08-09): Material traegt Verhalten,
/// Semantik und Plattform-Korrektheit (Ripple, Fokus, Screenreader, Scroll-
/// Physik, Dialoge); die Pixel kommen aus den Tokens. Deshalb setzt diese
/// Datei ein echtes [ColorScheme] — SDK-Widgets, die wir nicht selbst
/// zeichnen (DatePicker, Snackbar, Cursor), sollen ohne lokale Sonderfaelle
/// richtig aussehen.
///
/// Zwei Schriften statt einer: Bricolage Grotesque fuer Zahlen/Ueberschriften,
/// Archivo fuer alles Uebrige — beide gebuendelt unter assets/fonts.
ThemeData buildEatovaTheme(Brightness brightness) {
  final t = brightness == Brightness.light ? AppTokens.light : AppTokens.dark;

  final scheme = ColorScheme.fromSeed(
    seedColor: t.forest,
    brightness: brightness,
  ).copyWith(
    primary: t.forest,
    onPrimary: t.onForest,
    secondary: t.lime,
    onSecondary: t.onLime,
    surface: t.bg,
    onSurface: t.ink,
    surfaceContainerHighest: t.surf2,
    outline: t.ink2,
    outlineVariant: t.line,
    error: t.danger,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);

  final textTheme = base.textTheme
      .apply(
        fontFamily: AppType.uiFamily,
        bodyColor: t.ink,
        displayColor: t.ink,
      )
      .copyWith(
        bodyMedium: AppType.ui(14, color: t.ink, height: 1.45),
        bodySmall: AppType.ui(13, color: t.ink2, height: 1.45),
      );

  return base.copyWith(
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    extensions: <ThemeExtension<dynamic>>[t],
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    splashColor: t.ink.withValues(alpha: 0.05),
    highlightColor: t.ink.withValues(alpha: 0.03),
    dividerColor: t.line,
    dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: t.ink2, size: 20),
    cardTheme: CardThemeData(
      color: t.surf,
      elevation: 0,
      shadowColor: t.shadowTint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.line),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.forest,
      contentTextStyle:
          AppType.ui(13.5, weight: FontWeight.w500, color: t.onForest),
      actionTextColor: t.lime,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rControl),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 8,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.bg,
      modalBackgroundColor: t.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: false,
      dragHandleColor: t.line,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
        side: BorderSide(color: t.line),
      ),
      titleTextStyle: AppType.display(20, weight: FontWeight.w700, color: t.ink),
      contentTextStyle: AppType.ui(13.5, color: t.ink2, height: 1.45),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.line),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.accent,
      linearTrackColor: t.tile,
      circularTrackColor: t.tile,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.surf,
      selectedColor: t.forest,
      side: BorderSide(color: t.line),
      labelStyle: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
      secondaryLabelStyle:
          AppType.ui(12, weight: FontWeight.w600, color: t.onForest),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rChip),
      ),
    ),
    // Eingabefelder: weiche Kapsel, KEIN Fokusring (Nutzer-Feedback) — der
    // Fokus zeigt sich ueber die aufgehellte Flaeche, nicht ueber eine
    // leuchtende Kontur. Der 1-px-Rand ist derselbe [AppTokens.line], der
    // auch jede Karte umschliesst; er rahmt nicht das Feld ein, er setzt es
    // wie jede andere Flaeche vom Grund ab.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surf,
      hintStyle: AppType.ui(14, color: t.ink2),
      labelStyle: AppType.ui(14, color: t.ink2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide(color: t.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide(color: t.line),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide(color: t.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide(color: t.danger),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: t.accent,
      selectionColor: t.lime.withValues(alpha: 0.35),
      selectionHandleColor: t.accent,
    ),
    // Kalender-Dialog (Datumsauswahl im Food-Tab/Edit-Sheet) im App-Stil:
    // ruhige Flaeche, kein Header-Block, Akzent nur fuer Heute/Auswahl.
    // Bewusst die Standard-Widgets (DatePickerDialog) — nur Toene.
    datePickerTheme: DatePickerThemeData(
      backgroundColor: t.surf,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      headerBackgroundColor: Colors.transparent,
      headerForegroundColor: t.ink,
      headerHelpStyle: AppType.ui(
        11,
        weight: FontWeight.w700,
        color: t.ink2,
        letterSpacing: 1.1,
      ),
      headerHeadlineStyle: AppType.display(26, color: t.ink),
      weekdayStyle: AppType.ui(
        12,
        weight: FontWeight.w700,
        color: t.ink2,
        letterSpacing: 0.4,
      ),
      dayStyle: AppType.ui(13, weight: FontWeight.w600),
      // Tages-Zellen: Auswahl als satte Akzent-Flaeche, Heute nur als Ring,
      // Disabled deutlich zurueckgenommen, Press/Hover als weiche
      // Flaechen-Aufhellung statt Material-Splash-Grau.
      dayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.onForest;
        if (states.contains(WidgetState.disabled)) {
          return t.ink2.withValues(alpha: 0.35);
        }
        return t.ink;
      }),
      dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.forest;
        return Colors.transparent;
      }),
      dayOverlayColor: WidgetStateProperty.all(t.ink.withValues(alpha: 0.06)),
      todayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.onForest;
        return t.accent;
      }),
      todayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.forest;
        return Colors.transparent;
      }),
      todayBorder: BorderSide(color: t.accent, width: 1.2),
      // Jahres-Raster im selben Ton wie die Tage.
      yearStyle: AppType.ui(13, weight: FontWeight.w600),
      yearForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.onForest;
        return t.ink;
      }),
      yearBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.forest;
        return Colors.transparent;
      }),
      yearOverlayColor: WidgetStateProperty.all(t.ink.withValues(alpha: 0.06)),
      // Fusszeile: Abbrechen zurueckhaltend, OK traegt den Akzent.
      cancelButtonStyle: TextButton.styleFrom(
        foregroundColor: t.ink2,
        textStyle: AppType.ui(13, weight: FontWeight.w600),
      ),
      confirmButtonStyle: TextButton.styleFrom(
        foregroundColor: t.accent,
        textStyle: AppType.ui(13, weight: FontWeight.w800),
      ),
      dividerColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: t.surf,
      dialBackgroundColor: t.tile,
      dialHandColor: t.forest,
      dialTextColor: t.ink,
      hourMinuteColor: t.tile,
      hourMinuteTextColor: t.ink,
      helpTextStyle: AppType.ui(
        11,
        weight: FontWeight.w700,
        color: t.ink2,
        letterSpacing: 1.1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
    ),
  );
}
