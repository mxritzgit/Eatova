import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// The capsule outline of every input state: rounded, no visible side.
const InputBorder _noLine = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(rControl)),
  borderSide: BorderSide.none,
);

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
      // One handle geometry app-wide (same as [SheetHandle]).
      dragHandleColor: t.line,
      dragHandleSize: const Size(40, 4),
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
    // UNREACHED TODAY, kept as a net: `lib/` contains no Material Chip at all
    // (no Filter/Choice/Input/ActionChip, no bare `Chip`) — the app draws
    // `FilterChipPill` instead, and this block only ever styles SDK chips. It
    // stays so the day one appears it does not arrive in Material colours,
    // but it must not hand out the OLD selection language either: `forest` as
    // a selected fill measures 1.33:1 on `surf` in dark mode (P9-02). Same
    // ink/bg pair as `SelectionTone` in the design library.
    chipTheme: ChipThemeData(
      backgroundColor: t.surf,
      selectedColor: t.ink,
      side: BorderSide(color: t.line),
      labelStyle: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
      // The style of a SELECTED chip's label (Material's "secondary" slot).
      secondaryLabelStyle: AppType.ui(12, weight: FontWeight.w600, color: t.bg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rChip),
      ),
    ),
    // Material buttons without a local style used to fall back to
    // ColorScheme.primary = forest: 1.33:1 on `surf` in dark mode. One
    // semantics for all three: text = quiet `ink` (a screen sets `accent`
    // only for an explicitly affirmative action), filled = the primary action
    // (ink/bg, like [PrimaryActionButton]), outlined = line edge + ink.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.ink,
        disabledForegroundColor: t.ink2.withValues(alpha: 0.5),
        textStyle: AppType.ui(13, weight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.ink,
        foregroundColor: t.bg,
        disabledBackgroundColor: t.ink.withValues(alpha: 0.4),
        disabledForegroundColor: t.bg.withValues(alpha: 0.8),
        textStyle: AppType.ui(15, weight: FontWeight.w700),
        // Touch floor, NOT the 54 px primary height: a FilledButton also
        // sits in dialogs next to a TextButton.
        minimumSize: const Size(64, kButtonMinHeight),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rButton),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        disabledForegroundColor: t.ink2.withValues(alpha: 0.5),
        side: BorderSide(color: t.line),
        textStyle: AppType.ui(14, weight: FontWeight.w600),
        minimumSize: const Size(64, kButtonMinHeight),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rButton),
        ),
      ),
    ),
    // Input fields: borderless soft capsule (user rule) — no hairline, no
    // focus ring, no red ring. State lives in the FILL: rest `field`, focus
    // `fieldFocus` (lighter in both modes), error a danger tint plus the
    // error line. Every border slot is set, otherwise Material's default
    // underline bleeds through for the missing state.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.error)) return t.fieldError;
        if (states.contains(WidgetState.focused)) return t.fieldFocus;
        return t.field;
      }),
      hintStyle: AppType.ui(14, color: t.ink2),
      labelStyle: AppType.ui(14, color: t.ink2),
      floatingLabelStyle: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
      errorStyle: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: _noLine,
      enabledBorder: _noLine,
      focusedBorder: _noLine,
      errorBorder: _noLine,
      focusedErrorBorder: _noLine,
      disabledBorder: _noLine,
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
      // Day cells: selection as a solid surface, today only a ring, disabled
      // dimmed, press/hover as a soft lightening instead of grey Material
      // splash. The picked day is a SELECTION STATE and therefore speaks the
      // same ink/bg language as the chips (`SelectionTone`, P9-02): as
      // `forest`/`onForest` the dark-mode selection was 1.33:1 against the
      // dialog and its number 1.04:1 against an unpicked one — the day you
      // had chosen was effectively invisible.
      dayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.bg;
        if (states.contains(WidgetState.disabled)) {
          return t.ink2.withValues(alpha: 0.35);
        }
        return t.ink;
      }),
      dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.ink;
        return Colors.transparent;
      }),
      // Press feedback in `ink2`, not `ink`: on the picked day's own `ink`
      // fill an ink overlay has nothing left to darken.
      dayOverlayColor: WidgetStateProperty.all(t.ink2.withValues(alpha: 0.12)),
      todayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.bg;
        return t.accent;
      }),
      todayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.ink;
        return Colors.transparent;
      }),
      todayBorder: BorderSide(color: t.accent, width: 1.2),
      // Year grid in the same tones as the days.
      yearStyle: AppType.ui(13, weight: FontWeight.w600),
      yearForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.bg;
        return t.ink;
      }),
      yearBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.ink;
        return Colors.transparent;
      }),
      yearOverlayColor: WidgetStateProperty.all(t.ink2.withValues(alpha: 0.12)),
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
    // UNREACHED TODAY, kept as a net — same reasoning as `chipTheme`, and here
    // DELETING would have been the worse option: Material's M3 defaults take
    // the dial hand from `ColorScheme.primary`, which this file pins to
    // `forest`, so the exact defect below would come straight back through the
    // scheme (forest vs surfaceContainerHighest = surf2: 1.16:1 dark) and the
    // hour/minute box would arrive in an unvetted `primaryContainer` out of
    // `fromSeed`. `lib/` has no `showTimePicker` yet; a settable reminder time
    // (today the fixed `streakReminderHour` = 20:00) is the obvious caller.
    //
    // What was broken (P9-02c), all three pinned in
    // review0829_selection_contrast_test.dart:
    //   dialHandColor `forest` on the dial (`tile` over `surf`)  1.10:1 dark
    //   dialTextColor flat `ink` — i.e. also ON that forest hand  1.24:1 light
    //   hourMinuteColor identical for picked and unpicked         1.00:1 both
    // The clock is a SELECTION, so it speaks the one language that carries in
    // both palettes: filled = `ink`, label = `bg` (`SelectionTone`, P9-02).
    // `accent` — the obvious pick for the hand, and fine against the dial in
    // both modes — is `lime` in dark and `forest` in light, and NO single
    // token reads on both (ink 1.07 dark / 1.24 light), so the number on the
    // hand would have needed the brightness branch repo_rules forbids.
    timePickerTheme: TimePickerThemeData(
      backgroundColor: t.surf,
      elevation: 0,
      dialBackgroundColor: t.tile,
      dialHandColor: t.ink,
      dialTextColor: WidgetStateColor.resolveWith((states) {
        // The picked number sits inside the dot at the hand's end.
        if (states.contains(WidgetState.selected)) return t.bg;
        return t.ink;
      }),
      dialTextStyle: AppType.display(16, weight: FontWeight.w600),
      hourMinuteColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.ink;
        return t.tile;
      }),
      hourMinuteTextColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.bg;
        return t.ink;
      }),
      // Smaller than Material's displayLarge (57): Bricolage runs wide, and
      // the hour box is a fixed 96x80 with text scaling switched off.
      hourMinuteTextStyle: AppType.display(44, weight: FontWeight.w700),
      // AM/PM shows only in 12-hour locales (en) — same language again. An
      // unpicked half stays transparent so the dialog shows through.
      dayPeriodColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.ink;
        return Colors.transparent;
      }),
      dayPeriodTextColor: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return t.bg;
        return t.ink2;
      }),
      dayPeriodTextStyle: AppType.ui(14, weight: FontWeight.w700),
      dayPeriodBorderSide: BorderSide(color: t.line),
      entryModeIconColor: t.ink2,
      helpTextStyle: AppType.ui(
        11,
        weight: FontWeight.w700,
        color: t.ink2,
        letterSpacing: 1.1,
      ),
      // Footer like the calendar's: cancel muted, confirm carries the accent.
      cancelButtonStyle: TextButton.styleFrom(
        foregroundColor: t.ink2,
        textStyle: AppType.ui(13, weight: FontWeight.w600),
      ),
      confirmButtonStyle: TextButton.styleFrom(
        foregroundColor: t.accent,
        textStyle: AppType.ui(13, weight: FontWeight.w800),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
    ),
  );
}
