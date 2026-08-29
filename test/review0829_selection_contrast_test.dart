// ---------------------------------------------------------------------------
// P9-02 — the SELECTED state of pills and chips must be visible, in BOTH modes.
//
// The app-wide selection language used to be "filled = forest". In light mode
// that is a near-black green on a near-white card (13.57:1); in dark mode
// `forest` #16371F is itself a dark SURFACE and the same pairing collapses:
//
//   forest vs surf  (unselected chip)   1.335:1
//   forest vs tile-over-surf (track)    1.101:1
//   onForest vs ink2 (the two labels)   2.590:1
//
// WCAG 1.4.11 asks 3:1 of the visual information that identifies the state of
// a control, so the bug was purely MODE-ASYMMETRIC — the same code, correct in
// light, invisible in dark.
//
// This suite reads the colours back OUT of the mounted widgets (not out of the
// token table: the point is which token the widget picks) and runs the WCAG
// 2.1 maths on them, in light and in dark, for all three controls that carry
// the language. Semi-transparent grounds (`tile` track, `line` border) are
// composited first — `computeLuminance()` ignores alpha.
// ---------------------------------------------------------------------------

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// --- WCAG 2.1 maths (own implementation, deliberately not shared) -----------

/// sRGB channel -> linear light.
double _linear(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// Relative luminance of an OPAQUE colour.
double _luminanz(Color c) =>
    0.2126 * _linear(c.r) + 0.7152 * _linear(c.g) + 0.0722 * _linear(c.b);

/// `(L1 + 0.05) / (L2 + 0.05)`, 1.0 … 21.0.
double _kontrast(Color a, Color b) {
  final la = _luminanz(a);
  final lb = _luminanz(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Composites [vorn] over the opaque [hinten].
Color _ueber(Color vorn, Color hinten) {
  final a = vorn.a;
  double kanal(double v, double h) => v * a + h * (1 - a);
  return Color.from(
    alpha: 1.0,
    red: kanal(vorn.r, hinten.r),
    green: kanal(vorn.g, hinten.g),
    blue: kanal(vorn.b, hinten.b),
  );
}

/// WCAG 1.4.11: a non-text state indicator needs 3:1 against what surrounds it.
const double _zustand = 3.0;

/// WCAG 1.4.3: the label ON the selected fill stays body text.
const double _text = 4.5;

// --- reading the colours out of the tree ------------------------------------

Color _materialFarbe(WidgetTester tester, Finder von) => tester
    .widget<Material>(
      find.descendant(of: von, matching: find.byType(Material)).first,
    )
    .color!;

Color _textFarbe(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!.color!;

/// Painted capsule of one segment. The settings pill keys the GestureDetector
/// AROUND the capsule, [SegmentedPill] has no keys and is found via its label
/// INSIDE it — hence the two finders.
Color _kapselFarbe(WidgetTester tester, Finder kapsel) {
  final box = tester.widget<AnimatedContainer>(kapsel.first);
  return (box.decoration! as BoxDecoration).color!;
}

Finder _kapselIn(Finder segment) =>
    find.descendant(of: segment, matching: find.byType(AnimatedContainer));

Finder _kapselUm(Finder label) =>
    find.ancestor(of: label, matching: find.byType(AnimatedContainer));

/// The pill's own track: the first [DecoratedBox] of the subtree.
Color _spurFarbe(WidgetTester tester, Finder pille) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: pille, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color!;
}

const Map<String, Brightness> _modi = <String, Brightness>{
  'hell': Brightness.light,
  'dunkel': Brightness.dark,
};

AppTokens _tokens(Brightness b) =>
    b == Brightness.light ? AppTokens.light : AppTokens.dark;

void main() {
  group('FilterChipPill: der gewaehlte Chip hebt sich ab', () {
    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      testWidgets('$name: Flaeche gewaehlt vs. ungewaehlt >= 3:1',
          (tester) async {
        await pumpLocalized(
          tester,
          const Align(child: FilterChipPill(label: 'Alle', selected: false)),
          brightness: brightness,
        );
        final ungewaehlt = _materialFarbe(tester, find.byType(FilterChipPill));
        final ungewaehltesLabel = _textFarbe(tester, 'Alle');

        await pumpLocalized(
          tester,
          const Align(child: FilterChipPill(label: 'Alle', selected: true)),
          brightness: brightness,
        );
        final gewaehlt = _materialFarbe(tester, find.byType(FilterChipPill));
        final gewaehltesLabel = _textFarbe(tester, 'Alle');

        expect(
          _kontrast(gewaehlt, ungewaehlt),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: der gewaehlte Chip ist vom ungewaehlten nicht zu '
              'unterscheiden (WCAG 1.4.11)',
        );
        // The chip bars sit on the page ground as well as on cards.
        for (final grund in <(String, Color)>[('bg', t.bg), ('surf', t.surf)]) {
          expect(
            _kontrast(gewaehlt, grund.$2),
            greaterThanOrEqualTo(_zustand),
            reason: '$name: gewaehlte Flaeche gegen ${grund.$1}',
          );
        }
        expect(
          _kontrast(gewaehltesLabel, ungewaehltesLabel),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: auch die beiden Beschriftungen bleiben ununter'
              'scheidbar',
        );
        expect(
          _kontrast(gewaehltesLabel, gewaehlt),
          greaterThanOrEqualTo(_text),
          reason: '$name: Text auf der gewaehlten Flaeche',
        );
      });
    });
  });

  group('Einstellungs-Pille: das gewaehlte Segment hebt sich ab', () {
    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      testWidgets('$name: Segment gegen die Spur >= 3:1', (tester) async {
        await pumpLocalized(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SettingsThemeModePill(
              mode: ThemeMode.dark,
              onChanged: (_) {},
            ),
          ),
          brightness: brightness,
        );

        final pille = find.byType(SettingsThemeModePill);
        final gewaehlt = _kapselFarbe(
          tester,
          _kapselIn(
            find.byKey(const ValueKey<String>('settings-theme-mode-dark')),
          ),
        );
        final ungewaehlt = _kapselFarbe(
          tester,
          _kapselIn(
            find.byKey(const ValueKey<String>('settings-theme-mode-light')),
          ),
        );

        // An unselected segment paints nothing: what the eye compares the
        // selected capsule with is the pill's own translucent track.
        expect(ungewaehlt, Colors.transparent);
        final spur = _spurFarbe(tester, pille);
        expect(spur.a, lessThan(1.0), reason: 'die Spur ist eine Toenung');

        // The pill lives inside a SettingsGroup card (`surf`); measured
        // against `bg` too, because the sheets put it on the page ground.
        for (final grund in <(String, Color)>[('surf', t.surf), ('bg', t.bg)]) {
          expect(
            _kontrast(gewaehlt, _ueber(spur, grund.$2)),
            greaterThanOrEqualTo(_zustand),
            reason: '$name: Segment gegen die Spur ueber ${grund.$1}',
          );
        }
      });
    });
  });

  group('SegmentedPill traegt dieselbe Sprache', () {
    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      testWidgets('$name: aktive Option gegen die Spur >= 3:1', (tester) async {
        await pumpLocalized(
          tester,
          Align(
            child: SegmentedPill(
              options: const <String>['kg', 'lb'],
              selected: 'kg',
              onChanged: (_) {},
            ),
          ),
          brightness: brightness,
        );

        final aktiv = _kapselFarbe(tester, _kapselUm(find.text('kg')));
        expect(
          _kapselFarbe(tester, _kapselUm(find.text('lb'))),
          Colors.transparent,
        );
        expect(
          _kontrast(aktiv, _ueber(t.tile, t.surf)),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: aktive Option gegen die eigene Spur',
        );
        expect(
          _kontrast(_textFarbe(tester, 'kg'), _textFarbe(tester, 'lb')),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: aktive gegen inaktive Beschriftung',
        );
      });
    });
  });

  // The calendar is the fourth carrier of the same language and the one that
  // was worst off: as `forest`/`onForest` the picked day sat at 1.33:1 on the
  // dialog and its NUMBER at 1.04:1 against an unpicked one — invisible in
  // dark mode. Read out of the built ThemeData, since the cells themselves
  // are stock DatePickerDialog widgets.
  group('DatePicker: der gewaehlte Tag hebt sich ab', () {
    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      test('$name: Flaeche und Zahl des gewaehlten Tages', () {
        final thema = buildEatovaTheme(brightness).datePickerTheme;
        Color tag(WidgetStateProperty<Color?>? p, Set<WidgetState> zustand) =>
            p!.resolve(zustand)!;

        final flaeche = tag(
          thema.dayBackgroundColor,
          <WidgetState>{WidgetState.selected},
        );
        final zahl = tag(
          thema.dayForegroundColor,
          <WidgetState>{WidgetState.selected},
        );
        final andereZahl = tag(thema.dayForegroundColor, <WidgetState>{});

        expect(
          _kontrast(flaeche, thema.backgroundColor!),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: gewaehlter Tag gegen den Dialog',
        );
        expect(
          _kontrast(zahl, andereZahl),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: die Zahl des gewaehlten Tages gegen eine andere',
        );
        expect(_kontrast(zahl, flaeche), greaterThanOrEqualTo(_text));
        expect(thema.backgroundColor, t.surf);
      });
    });
  });

  // The numbers themselves, so a future token or language change has to walk
  // past them. Values recomputed by hand (sRGB linearised, alpha composited)
  // for the fix of 2026-08-29.
  group('Die Zahlen der Auswahlsprache', () {
    for (final fall in <({
      String name,
      AppTokens t,
      double gegenSurf,
      double gegenBg,
      double gegenSpur,
      double labels,
    })>[
      (
        name: 'hell',
        t: AppTokens.light,
        gegenSurf: 16.784,
        gegenBg: 14.840,
        gegenSpur: 15.184,
        labels: 5.086,
      ),
      (
        name: 'dunkel',
        t: AppTokens.dark,
        gegenSurf: 14.925,
        gegenBg: 16.353,
        gegenSpur: 12.307,
        labels: 6.592,
      ),
    ]) {
      test('${fall.name}: gewaehlte Flaeche und Beschriftung', () {
        final t = fall.t;
        // The language: filled = `ink`, label = `bg` — the pair
        // [PrimaryActionButton] uses. `forest` is NOT a state carrier.
        expect(_kontrast(t.ink, t.surf), closeTo(fall.gegenSurf, 0.01));
        expect(_kontrast(t.ink, t.bg), closeTo(fall.gegenBg, 0.01));
        expect(
          _kontrast(t.ink, _ueber(t.tile, t.surf)),
          closeTo(fall.gegenSpur, 0.01),
        );
        expect(_kontrast(t.bg, t.ink2), closeTo(fall.labels, 0.01));
      });
    }

    test('forest bleibt als Zustandstraeger disqualifiziert', () {
      // Not a regression guard for the palette — the reason the language had
      // to move. `forest` keeps every job it has as a SURFACE (hero cards,
      // snackbar, coach bubble), those are not state indicators.
      const d = AppTokens.dark;
      expect(_kontrast(d.forest, d.surf), lessThan(_zustand));
      expect(_kontrast(d.forest, _ueber(d.tile, d.surf)), lessThan(_zustand));
      expect(_kontrast(d.onForest, d.ink2), lessThan(_zustand));
      // …and in light mode it was never the problem.
      const h = AppTokens.light;
      expect(_kontrast(h.forest, h.surf), greaterThan(13.0));
    });
  });

  // ------------------------------------------------------------------------
  // P9-02c — the clock is the fifth carrier of the same language. The block is
  // UNREACHED today (`lib/` has no `showTimePicker`), which is exactly why it
  // needs a test: nothing else would ever notice it drifting. Measured out of
  // the built ThemeData, like the calendar above.
  // ------------------------------------------------------------------------
  group('TimePicker: Zeiger, Zifferblatt und Stunden-/Minutenfeld', () {
    /// Resolves a slot that may be a flat [Color] or a [WidgetStateColor],
    /// then composites it on the dialog so a tint can be measured.
    Color slot(Color? roh, Set<WidgetState> zustand, Color grund) =>
        _ueber(WidgetStateProperty.resolveAs<Color>(roh!, zustand), grund);

    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      test('$name: der Zeiger steht auf dem Zifferblatt', () {
        final thema = buildEatovaTheme(brightness).timePickerTheme;
        final zifferblatt = _ueber(thema.dialBackgroundColor!, t.surf);
        final zeiger = _ueber(thema.dialHandColor!, zifferblatt);

        expect(
          _kontrast(zeiger, zifferblatt),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: der Zeiger zeigt die gewaehlte Stunde an und muss '
              'sich vom Zifferblatt abheben (WCAG 1.4.11)',
        );
        // The picked number sits INSIDE the dot at the hand's end.
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{WidgetState.selected},
                zeiger),
            zeiger,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: die Zahl auf dem Zeiger',
        );
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{}, zifferblatt),
            zifferblatt,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: die uebrigen Zahlen auf dem Zifferblatt',
        );
      });

      test('$name: Stunde und Minute sind unterscheidbar', () {
        final thema = buildEatovaTheme(brightness).timePickerTheme;
        final gewaehlt = slot(
          thema.hourMinuteColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final ungewaehlt = slot(thema.hourMinuteColor, <WidgetState>{}, t.surf);

        expect(
          _kontrast(gewaehlt, ungewaehlt),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: welches der beiden Felder gerade bearbeitet wird, '
              'ist die einzige Zustandsinformation des Kopfbereichs',
        );
        expect(
          _kontrast(
            slot(thema.hourMinuteTextColor,
                <WidgetState>{WidgetState.selected}, gewaehlt),
            gewaehlt,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: die Zahl im gewaehlten Feld',
        );
        expect(
          _kontrast(
            slot(thema.hourMinuteTextColor, <WidgetState>{}, ungewaehlt),
            ungewaehlt,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: die Zahl im ungewaehlten Feld',
        );
      });

      test('$name: die AM/PM-Umschaltung traegt dieselbe Sprache', () {
        // Only reachable in 12-hour locales (EN), therefore easy to forget.
        final thema = buildEatovaTheme(brightness).timePickerTheme;
        final gewaehlt = slot(
          thema.dayPeriodColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final ungewaehlt = slot(thema.dayPeriodColor, <WidgetState>{}, t.surf);

        expect(
          _kontrast(gewaehlt, ungewaehlt),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: gewaehlte gegen ungewaehlte Haelfte',
        );
        expect(
          _kontrast(
            slot(thema.dayPeriodTextColor,
                <WidgetState>{WidgetState.selected}, gewaehlt),
            gewaehlt,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: Beschriftung der gewaehlten Haelfte',
        );
        expect(
          _kontrast(
            slot(thema.dayPeriodTextColor, <WidgetState>{}, ungewaehlt),
            ungewaehlt,
          ),
          greaterThanOrEqualTo(_text),
          reason: '$name: Beschriftung der ungewaehlten Haelfte',
        );
      });
    });

    // The numbers, so a future edit has to walk past them. Recomputed by hand
    // (sRGB linearised, `tile` composited on `surf`) for the fix of
    // 2026-08-29; the "vorher" column is in the group below.
    for (final fall in <({
      String name,
      Brightness helligkeit,
      double zeiger,
      double zahlAufZeiger,
      double zahlAufBlatt,
      double feld,
      double zahlImFeld,
      double amPm,
      double amPmAus,
    })>[
      (
        name: 'hell',
        helligkeit: Brightness.light,
        zeiger: 15.184,
        zahlAufZeiger: 14.840,
        zahlAufBlatt: 15.184,
        feld: 15.184,
        zahlImFeld: 14.840,
        amPm: 16.784,
        amPmAus: 5.752,
      ),
      (
        name: 'dunkel',
        helligkeit: Brightness.dark,
        zeiger: 12.307,
        zahlAufZeiger: 16.353,
        zahlAufBlatt: 12.307,
        feld: 12.307,
        zahlImFeld: 16.353,
        amPm: 14.925,
        amPmAus: 6.016,
      ),
    ]) {
      test('${fall.name}: die Zahlen der Uhr', () {
        final t = _tokens(fall.helligkeit);
        final thema = buildEatovaTheme(fall.helligkeit).timePickerTheme;
        final blatt = _ueber(thema.dialBackgroundColor!, t.surf);
        final zeiger = _ueber(thema.dialHandColor!, blatt);

        expect(_kontrast(zeiger, blatt), closeTo(fall.zeiger, 0.01));
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{WidgetState.selected},
                zeiger),
            zeiger,
          ),
          closeTo(fall.zahlAufZeiger, 0.01),
        );
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{}, blatt),
            blatt,
          ),
          closeTo(fall.zahlAufBlatt, 0.01),
        );

        final feldAn = slot(
          thema.hourMinuteColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final feldAus = slot(thema.hourMinuteColor, <WidgetState>{}, t.surf);
        expect(_kontrast(feldAn, feldAus), closeTo(fall.feld, 0.01));
        expect(
          _kontrast(
            slot(thema.hourMinuteTextColor,
                <WidgetState>{WidgetState.selected}, feldAn),
            feldAn,
          ),
          closeTo(fall.zahlImFeld, 0.01),
        );

        final periodeAn = slot(
          thema.dayPeriodColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final periodeAus = slot(thema.dayPeriodColor, <WidgetState>{}, t.surf);
        expect(_kontrast(periodeAn, periodeAus), closeTo(fall.amPm, 0.01));
        expect(
          _kontrast(
            slot(thema.dayPeriodTextColor, <WidgetState>{}, periodeAus),
            periodeAus,
          ),
          closeTo(fall.amPmAus, 0.01),
        );

        // The dialog itself stays the app surface, like the calendar.
        expect(thema.backgroundColor, t.surf);
      });
    }
  });

  // Why the block was repaired instead of deleted: deleting it does NOT
  // remove the defect, it hands it to Material. The M3 defaults take the dial
  // hand from `ColorScheme.primary`, and this app pins `primary` to `forest`.
  group('P9-02c: Loeschen waere kein Fix gewesen', () {
    test('Material haette den Zeiger wieder aus forest genommen', () {
      final schema = buildEatovaTheme(Brightness.dark).colorScheme;
      expect(schema.primary, AppTokens.dark.forest);
      // _TimePickerDefaultsM3: dialHandColor = primary,
      // dialBackgroundColor = surfaceContainerHighest.
      expect(
        _kontrast(schema.primary, schema.surfaceContainerHighest),
        lessThan(_zustand),
        reason: 'ohne eigenen Block waere der Zeiger im Dunkelmodus wieder '
            'unsichtbar',
      );
    });

    test('die drei alten Messwerte, damit niemand zurueckdreht', () {
      const d = AppTokens.dark;
      const h = AppTokens.light;
      // 1) hand `forest` on the dial (`tile` over `surf`) — dark.
      expect(_kontrast(d.forest, _ueber(d.tile, d.surf)), closeTo(1.101, 0.01));
      // 2) the number ON that hand was a flat `ink` — broken in LIGHT mode,
      //    the mirror image of the dark-mode bug.
      expect(_kontrast(h.ink, h.forest), closeTo(1.237, 0.01));
      // 3) picked and unpicked hour/minute box were the same `tile`.
      expect(_kontrast(_ueber(d.tile, d.surf), _ueber(d.tile, d.surf)), 1.0);
    });

    test('accent als Zeiger haette einen Helligkeits-Abzweig gebraucht', () {
      // The obvious candidate: `accent` reads fine against the dial in both
      // modes — but NO token reads on `accent` in both, and the number on the
      // hand needs one. `ink`/`bg` is the pair that carries in both palettes.
      const d = AppTokens.dark;
      const h = AppTokens.light;
      expect(_kontrast(d.accent, _ueber(d.tile, d.surf)), greaterThan(11.0));
      expect(_kontrast(h.accent, _ueber(h.tile, h.surf)), greaterThan(11.0));
      // …and here it falls apart:
      expect(_kontrast(d.ink, d.accent), lessThan(_zustand));
      expect(_kontrast(h.ink, h.accent), lessThan(_zustand));
      expect(_kontrast(d.onForest, d.accent), lessThan(_zustand));
      expect(_kontrast(h.onLime, h.accent), lessThan(_zustand));
    });
  });

  // The block is dead, so nothing else ever MOUNTS it. This group does: it
  // opens a real `showTimePicker` and reads the colours back off the painted
  // widgets — proof that the theme lands on pixels (and that the larger clock
  // digits still fit, in both modes and both locales).
  group('TimePicker: der reparierte Block kommt auch an', () {
    Future<void> oeffne(
      WidgetTester tester, {
      required Brightness brightness,
      required Locale locale,
    }) async {
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTimePicker(
              context: context,
              initialTime: const TimeOfDay(hour: 20, minute: 37),
            ),
            child: const Text('auf'),
          ),
        ),
        brightness: brightness,
        locale: locale,
        surfaceSize: const Size(420, 920),
      );
      await tester.tap(find.text('auf'));
      await tester.pumpAndSettle();
    }

    /// Colour of the [Material] the [label] is painted on.
    Color grundVon(WidgetTester tester, String label) => tester
        .widget<Material>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Material))
              .first,
        )
        .color!;

    _modi.forEach((name, brightness) {
      final t = _tokens(brightness);

      testWidgets('$name: das Minutenfeld wechselt beim Antippen die Sprache',
          (tester) async {
        // 24-hour locale: the minute 37 is not on the dial (it labels in
        // steps of five), so the finder stays unambiguous.
        await oeffne(tester, brightness: brightness, locale: const Locale('de'));

        expect(grundVon(tester, '37'), t.tile, reason: '$name: Minute ruht');
        expect(_textFarbe(tester, '37'), t.ink);

        await tester.tap(find.text('37'));
        await tester.pumpAndSettle();

        expect(grundVon(tester, '37'), t.ink, reason: '$name: Minute gewaehlt');
        expect(_textFarbe(tester, '37'), t.bg);
      });

      testWidgets('$name: AM/PM im englischen Gebietsschema',
          (tester) async {
        await oeffne(tester, brightness: brightness, locale: const Locale('en'));

        // 20:37 is PM.
        expect(grundVon(tester, 'PM'), t.ink);
        expect(_textFarbe(tester, 'PM'), t.bg);
        expect(grundVon(tester, 'AM'), Colors.transparent);
        expect(_textFarbe(tester, 'AM'), t.ink2);
      });
    });
  });
}
