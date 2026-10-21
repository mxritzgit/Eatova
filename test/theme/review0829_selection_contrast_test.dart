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

import '../support/harness.dart';

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

/// Fill of one settings-pill segment: the [Material] right around the keyed
/// [InkWell].
Color _segmentFarbe(WidgetTester tester, String key) => tester
    .widget<Material>(
      find
          .ancestor(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(Material),
          )
          .first,
    )
    .color!;

/// Label colour of one settings-pill segment.
Color _segmentLabel(WidgetTester tester, String key) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(Text),
      ),
    )
    .style!
    .color!;

/// The settings pill's recessed track: its outermost [Container].
Color _spurFarbe(WidgetTester tester, Finder pille) {
  final box = tester.widget<Container>(
    find.descendant(of: pille, matching: find.byType(Container)).first,
  );
  return (box.decoration! as BoxDecoration).color!;
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
        // As the settings screen builds it: full row width.
        await pumpLocalized(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 335,
              child: SettingsThemeModePill(
                mode: ThemeMode.dark,
                onChanged: (_) {},
              ),
            ),
          ),
          brightness: brightness,
        );

        const dunkel = 'settings-theme-mode-dark';
        const hell = 'settings-theme-mode-light';
        final gewaehlt = _segmentFarbe(tester, dunkel);
        final ungewaehlt = _segmentFarbe(tester, hell);
        final spur = _spurFarbe(tester, find.byType(SettingsThemeModePill));

        // The selected segment is the app-wide selection fill; an unselected
        // one paints nothing, so the eye compares the fill with the track.
        expect(gewaehlt, t.selectedFill);
        expect(ungewaehlt, Colors.transparent);
        expect(spur, t.bg, reason: 'die Spur ist der vertiefte Seitengrund');

        expect(
          _kontrast(gewaehlt, spur),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: Segment gegen die Spur',
        );
        final gewaehltesLabel = _segmentLabel(tester, dunkel);
        final ungewaehltesLabel = _segmentLabel(tester, hell);
        expect(
          _kontrast(gewaehltesLabel, gewaehlt),
          greaterThanOrEqualTo(_text),
          reason: '$name: Text auf der gewaehlten Flaeche',
        );
        expect(
          _kontrast(ungewaehltesLabel, spur),
          greaterThanOrEqualTo(_text),
          reason: '$name: Text auf der Spur',
        );
        expect(
          _kontrast(gewaehltesLabel, ungewaehltesLabel),
          greaterThanOrEqualTo(_zustand),
          reason: '$name: die beiden Beschriftungen unterscheiden sich',
        );
      });
    });
  });

  // The app's calendar is its own FoodDatePicker (food_month_calendar_test.dart
  // pins its selected day); no stock DatePickerDialog is shown anywhere, so
  // the theme's datePickerTheme is not measured here.

  // ------------------------------------------------------------------------
  // P9-02c — the clock is another carrier of the same language: filled = `ink`,
  // label = `bg`. Reached by the reminder time picker and the weigh-in time.
  // Measured out of the built ThemeData; the group below mounts it.
  // ------------------------------------------------------------------------
  group('TimePicker: Zeiger, Zifferblatt und Stunden-/Minutenfeld', () {
    /// Resolves a slot that may be a flat [Color] or a [WidgetStateColor],
    /// then composites it on the dialog so a tint can be measured.
    Color slot(Color? roh, Set<WidgetState> zustand, Color grund) =>
        _ueber(WidgetStateProperty.resolveAs<Color>(roh!, zustand), grund);

    for (final fall in [(name: 'hell', helligkeit: Brightness.light), (name: 'dunkel', helligkeit: Brightness.dark)]) {
      test('${fall.name}: Zeiger, Stunde/Minute und AM/PM tragen', () {
        final t = _tokens(fall.helligkeit);
        final thema = buildEatovaTheme(fall.helligkeit).timePickerTheme;
        final blatt = _ueber(thema.dialBackgroundColor!, t.surf);
        final zeiger = _ueber(thema.dialHandColor!, blatt);

        expect(_kontrast(zeiger, blatt), greaterThanOrEqualTo(_zustand));
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{WidgetState.selected},
                zeiger),
            zeiger,
          ),
          greaterThanOrEqualTo(_text),
        );
        expect(
          _kontrast(
            slot(thema.dialTextColor, <WidgetState>{}, blatt),
            blatt,
          ),
          greaterThanOrEqualTo(_text),
        );

        final feldAn = slot(
          thema.hourMinuteColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final feldAus = slot(thema.hourMinuteColor, <WidgetState>{}, t.surf);
        // Which of the two fields is being edited is the header's only state.
        expect(_kontrast(feldAn, feldAus), greaterThanOrEqualTo(_zustand),
            reason: '${fall.name}: Stunde/Minute gewaehlt gegen ungewaehlt');
        expect(
          _kontrast(
            slot(thema.hourMinuteTextColor,
                <WidgetState>{WidgetState.selected}, feldAn),
            feldAn,
          ),
          greaterThanOrEqualTo(_text),
          reason: '${fall.name}: die Zahl im gewaehlten Feld',
        );
        expect(
          _kontrast(
            slot(thema.hourMinuteTextColor, <WidgetState>{}, feldAus),
            feldAus,
          ),
          greaterThanOrEqualTo(_text),
          reason: '${fall.name}: die Zahl im ungewaehlten Feld',
        );

        // AM/PM: only reachable in 12-hour locales (EN), easy to forget.
        final periodeAn = slot(
          thema.dayPeriodColor,
          <WidgetState>{WidgetState.selected},
          t.surf,
        );
        final periodeAus = slot(thema.dayPeriodColor, <WidgetState>{}, t.surf);
        expect(_kontrast(periodeAn, periodeAus), greaterThanOrEqualTo(_zustand),
            reason: '${fall.name}: gewaehlte gegen ungewaehlte Haelfte');
        expect(
          _kontrast(
            slot(thema.dayPeriodTextColor,
                <WidgetState>{WidgetState.selected}, periodeAn),
            periodeAn,
          ),
          greaterThanOrEqualTo(_text),
          reason: '${fall.name}: Beschriftung der gewaehlten Haelfte',
        );
        expect(
          _kontrast(
            slot(thema.dayPeriodTextColor, <WidgetState>{}, periodeAus),
            periodeAus,
          ),
          greaterThanOrEqualTo(_text),
          reason: '${fall.name}: Beschriftung der ungewaehlten Haelfte',
        );

        // The dialog itself stays the app surface, like the calendar.
        expect(thema.backgroundColor, t.surf);
      });
    }
  });

  group('Material-Akzent bleibt von der weichen Markenflaeche getrennt', () {
    for (final brightness in Brightness.values) {
      test('$brightness: auch Material-Defaults tragen lesbare Farben', () {
        final t = _tokens(brightness);
        final scheme = buildEatovaTheme(brightness).colorScheme;
        expect(scheme.primary, t.accent);
        expect(_kontrast(scheme.primary, scheme.surfaceContainerHighest), greaterThanOrEqualTo(_zustand));
        expect(_kontrast(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(_text));
        expect(_kontrast(t.onBrandSurface, t.brandSurface), greaterThanOrEqualTo(_text));
      });
    }
  });

  // This group opens a real `showTimePicker` and reads the colours back off
  // the painted widgets — proof that the theme lands on pixels (and that the
  // larger clock digits still fit, in both modes and both locales).
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
