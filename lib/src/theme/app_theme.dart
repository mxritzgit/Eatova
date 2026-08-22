import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// The Eatova theme — Material 3 as the base, [AppTokens] as the visible layer.
///
/// Material owns behaviour, semantics and platform correctness (ripple, focus,
/// screen reader, scroll physics, dialogs); the pixels come from the tokens.
/// Hence a real [ColorScheme]: SDK widgets we do not draw ourselves
/// (DatePicker, Snackbar, cursor) must look right without local special cases.
/// Two fonts: Bricolage Grotesque for numbers/headings, Archivo for the rest.
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
    // Input fields: soft capsule, NO focus ring (user feedback) — focus shows
    // as a lightened surface. The 1 px edge is the same [AppTokens.line] every
    // card uses; it separates the surface, it does not frame the field.
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
    // Calendar dialog in app style: quiet surface, no header block, accent only
    // for today/selection. Stock DatePickerDialog widgets, only recoloured.
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
      // Day cells: selection as a solid accent surface, today only a ring,
      // disabled dimmed, press/hover as a soft lightening instead of grey
      // Material splash.
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
      // Year grid in the same tones as the days.
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
      // Footer: cancel is muted, confirm carries the accent.
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
