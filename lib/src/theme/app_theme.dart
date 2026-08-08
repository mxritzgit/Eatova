import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Premium-Dark Theme für Eatova.
///
/// Eine Schrift (SF Pro – Apples System-Font) trägt die gesamte App — Hierarchie entsteht über
/// Gewicht, Größe und Tracking, nicht über Font-Wechsel. Komponenten-Themes
/// setzen Tiefe (getönte Schatten statt Schwarz), die gelockte Radius-Skala
/// und Lime als einzige Interaktionsfarbe zentral, damit jeder Screen ohne
/// lokale Sonderfälle konsistent wirkt.
ThemeData buildEatovaTheme() {
  // SF Pro über Apples System-Font: 'CupertinoSystemText' löst auf iOS/macOS zu
  // San Francisco (SF Pro) auf; andere Plattformen nutzen ihren Default-Sans.
  // SF Pro liegt nicht auf Google Fonts und ist für Nicht-Apple-Plattformen
  // nicht lizenziert → System-Font statt gebündeltem Asset.
  const fontFamily = 'CupertinoSystemText';

  final base = ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: lime,
      brightness: Brightness.dark,
      surface: surface,
      primary: lime,
      // Dunkler Text/Icon auf der hellen Lime-Fläche (Kontrast-Lock).
      onPrimary: bg,
      error: danger,
    ),
    scaffoldBackgroundColor: bg,
  );

  final textTheme = base.textTheme
      .apply(
        fontFamily: fontFamily,
        bodyColor: textPrimary,
        displayColor: textPrimary,
      )
      .copyWith(
        bodyMedium: const TextStyle(
          fontFamily: fontFamily,
          color: textPrimary,
          fontSize: 14,
          height: 1.45,
        ),
        bodySmall: const TextStyle(
          fontFamily: fontFamily,
          color: textMuted,
          fontSize: 13,
          height: 1.45,
        ),
      );

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerColor: hairline,
    dividerTheme: const DividerThemeData(
      color: hairline,
      thickness: 1,
      space: 1,
    ),
    splashColor: lime.withValues(alpha: 0.06),
    highlightColor: lime.withValues(alpha: 0.04),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shadowColor: shadowTint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: const BorderSide(color: hairline),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceSoft,
      contentTextStyle: const TextStyle(
        fontFamily: fontFamily,
        color: textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 13.5,
      ),
      actionTextColor: lime,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rControl),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 8,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: surface,
      showDragHandle: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
        side: const BorderSide(color: hairline),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: lime,
      linearTrackColor: surfaceSoft,
      circularTrackColor: surfaceSoft,
    ),
    iconTheme: const IconThemeData(color: textPrimary, size: 22),
    // Kalender-Dialog (Datumsauswahl im Food-Tab/Edit-Sheet) im App-Stil:
    // dunkle Flaeche, kein Header-Block, Lime nur fuer Heute/Auswahl.
    // Bewusst die Standard-Widgets (DatePickerDialog) — nur Toene.
    datePickerTheme: DatePickerThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: Colors.transparent,
      headerForegroundColor: textPrimary,
      headerHelpStyle: const TextStyle(
        color: textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
      weekdayStyle: const TextStyle(
        color: textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      dayStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      todayBorder: const BorderSide(color: lime, width: 1.2),
      dividerColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
    ),
    chipTheme:ChipThemeData(
      backgroundColor: surfaceSoft,
      selectedColor: lime,
      side: BorderSide.none,
      labelStyle: const TextStyle(
        fontFamily: fontFamily,
        color: textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rChip),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceSoft,
      hintStyle: const TextStyle(fontFamily: fontFamily, color: textMuted),
      labelStyle: const TextStyle(fontFamily: fontFamily, color: textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: const BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(rControl),
        borderSide: const BorderSide(color: lime, width: 1.5),
      ),
    ),
  );
}
