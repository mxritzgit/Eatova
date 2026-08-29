// ---------------------------------------------------------------------------
// P9-02c — the four LIVE controls that kept painting `forest` as their
// selection, measured on the MOUNTED widget.
//
// review0829_selection_contrast_test.dart proved the language itself
// (`SelectionTone` = `ink`/`bg`) and the controls that already carried it. It
// could not see the four that did not, because they are private classes deep
// inside three screens and no test ever read their colours:
//
//   1. _FoodDateChip        food tab, date strip
//   2. _CalendarDayButton   food tab, the square button next to the strip
//   3. _DayPicker chips     edit-meal sheet, the same chips again
//   4. _TileCard/_RowCard   onboarding, sex and activity/goal cards
//
// As `forest`/`onForest` they measured, in the DARK palette:
//
//   fill vs. surf                        1.3349:1   (needs 3:1)
//   weekday  lime  vs. ink2              2.3270:1
//   date     onForest vs. ink            1.0440:1
//
// — i.e. the state was invisible in dark mode while looking perfectly correct
// in light mode (13.57:1). A palette-level test cannot find that: the tokens
// are fine, the WIDGET picks the wrong pair. So this suite reads the colours
// back OUT of the built tree and runs the WCAG 2.1 maths on them, in light AND
// dark. Turning any of the four back to `forest` turns this file red.
//
// The source-text half of the same guard — "no conditional forest in lib/" —
// is auswahl_sprache_regel_test.dart.
// ---------------------------------------------------------------------------

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

import '../support/harness.dart';

// --- WCAG 2.1 maths ---------------------------------------------------------

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
///
/// In FLOAT, not in bytes: since Flutter 3.27 `Color` carries doubles, and a
/// byte-rounded composite drifts in the third digit.
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

Finder _drin(Key key, Type typ) =>
    find.descendant(of: find.byKey(key), matching: find.byType(typ));

/// The painted capsule of a keyed chip/card — every one of the four is an
/// [AnimatedContainer] under its keyed [InkWell].
BoxDecoration _deko(WidgetTester tester, Key key) =>
    tester.widget<AnimatedContainer>(_drin(key, AnimatedContainer).first)
        .decoration! as BoxDecoration;

Color _fuellung(WidgetTester tester, Key key) => _deko(tester, key).color!;

Color _rand(WidgetTester tester, Key key) =>
    (_deko(tester, key).border! as Border).top.color;

/// Colour of the [index]-th [Text] inside the keyed subject.
Color _textFarbe(WidgetTester tester, Key key, int index) => tester
    .widgetList<Text>(_drin(key, Text))
    .elementAt(index)
    .style!
    .color!;

/// Colour of the [index]-th [Icon] inside the keyed subject.
Color _iconFarbe(WidgetTester tester, Key key, [int index = 0]) =>
    tester.widgetList<Icon>(_drin(key, Icon)).elementAt(index).color!;

const Map<String, Brightness> _modi = <String, Brightness>{
  'hell': Brightness.light,
  'dunkel': Brightness.dark,
};

AppTokens _tokens(Brightness b) =>
    b == Brightness.light ? AppTokens.light : AppTokens.dark;

/// The one contract all four share, measured on the colours actually painted.
///
/// [gewaehlteFlaeche] / [ungewaehlteFlaeche] are the two fills, [aufDerFlaeche]
/// are the label/glyph colours of the SELECTED state (already composited if
/// they carry alpha), [gegenueber] their unselected counterparts in the same
/// order.
void _erwarteAuswahlsprache({
  required String modus,
  required AppTokens t,
  required String was,
  required Color gewaehlteFlaeche,
  required Color ungewaehlteFlaeche,
  required List<Color> aufDerFlaeche,
  required List<Color> gegenueber,
}) {
  // 1. The fill is the state carrier — against the other state and against
  //    both grounds a chip bar can sit on.
  expect(
    _kontrast(gewaehlteFlaeche, ungewaehlteFlaeche),
    greaterThanOrEqualTo(_zustand),
    reason: '$modus/$was: gewaehlt und ungewaehlt sind nicht zu unterscheiden '
        '(WCAG 1.4.11)',
  );
  for (final grund in <(String, Color)>[('bg', t.bg), ('surf', t.surf)]) {
    expect(
      _kontrast(gewaehlteFlaeche, grund.$2),
      greaterThanOrEqualTo(_zustand),
      reason: '$modus/$was: gewaehlte Flaeche gegen ${grund.$1}',
    );
  }
  // 2. Everything printed ON that fill stays readable…
  for (var i = 0; i < aufDerFlaeche.length; i++) {
    expect(
      _kontrast(aufDerFlaeche[i], gewaehlteFlaeche),
      greaterThanOrEqualTo(_text),
      reason: '$modus/$was: Kanal $i auf der gewaehlten Flaeche',
    );
  }
  // 3. …and no channel collapses against its unselected counterpart. This is
  //    the one that caught `lime` vs `ink2` (2.33:1) and `onForest` vs `ink`
  //    (1.04:1).
  for (var i = 0; i < gegenueber.length; i++) {
    expect(
      _kontrast(aufDerFlaeche[i], gegenueber[i]),
      greaterThanOrEqualTo(_zustand),
      reason: '$modus/$was: Kanal $i gewaehlt gegen ungewaehlt',
    );
  }
}

// --- subjects ---------------------------------------------------------------

Future<void> _pumpFoodTab(
  WidgetTester tester, {
  required Brightness brightness,
  DateTime? selectedDate,
}) async {
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: 0,
      selectedDate: selectedDate,
    ),
    brightness: brightness,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    settle: true,
  );
}

LoggedMeal _mahlzeit() => LoggedMeal(
      id: 'm1',
      loggedAt: DateTime(2026, 8, 29, 12),
      localDay: localDayKey(DateTime(2026, 8, 29)),
      result: const MealAnalysisResult(
        mealName: 'Test-Bowl',
        caloriesKcal: 350,
        estimatedGrams: 350,
        kcalPer100G: 100,
        protein: '30 g',
        carbs: '40 g',
        fat: '10 g',
        confidence: 'Hoch',
        portionNotes: 'Test.',
        sourceLabel: 'Foto-KI',
      ),
      forcedSlot: MealSlot.breakfast,
    );

Future<void> _oeffneEditSheet(
  WidgetTester tester, {
  required Brightness brightness,
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showEditMealSheet(
            context,
            meal: _mahlzeit(),
            onUpdateMeal: (String id, {
              MealAnalysisResult? result,
              MealSlot? slot,
              DateTime? day,
            }) =>
                null,
          ),
          child: const Text('auf'),
        ),
      ),
    ),
    brightness: brightness,
  );
  await tester.tap(find.text('auf'));
  await tester.pumpAndSettle();
}

/// Onboarding up to [schritte] taps on "next" (intro = 0).
Future<void> _zumSchritt(
  WidgetTester tester,
  int schritte, {
  required Brightness brightness,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    OnboardingScreen(
      firstName: 'Moritz',
      initialProfile: const UserProfile(),
      onComplete: (_) {},
    ),
    brightness: brightness,
    scaffold: false,
    safeArea: false,
    settle: true,
  );
  for (var i = 0; i < schritte; i++) {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }
}

void main() {
  // =========================================================================
  // 1. _FoodDateChip — the food tab's date strip
  // =========================================================================
  group('Food-Datumsstreifen: der gewaehlte Tag traegt SelectionTone', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Flaeche, Wochentag und Datumszahl', (tester) async {
        await _pumpFoodTab(tester, brightness: brightness);

        const gewaehlt = ValueKey<String>('food-date-chip-0'); // heute
        const ungewaehlt = ValueKey<String>('food-date-chip-1'); // gestern

        final flaeche = _fuellung(tester, gewaehlt);
        final andere = _fuellung(tester, ungewaehlt);
        // Text 0 = weekday (onSelected @ 78 %), text 1 = the date.
        final wochentag = _ueber(_textFarbe(tester, gewaehlt, 0), flaeche);
        final datum = _textFarbe(tester, gewaehlt, 1);

        // Measured first, so a revert fails on the RATIO in dark mode…
        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Datums-Chip',
          gewaehlteFlaeche: flaeche,
          ungewaehlteFlaeche: andere,
          aufDerFlaeche: <Color>[wochentag, datum],
          gegenueber: <Color>[
            _textFarbe(tester, ungewaehlt, 0),
            _textFarbe(tester, ungewaehlt, 1),
          ],
        );

        // …and on the TOKEN in light mode, where `forest` would still clear
        // every threshold above (13.57:1). Both halves are needed.
        expect(flaeche, t.ink, reason: '$modus: Fuellung ist selectedFill');
        expect(andere, t.surf);
        expect(datum, t.bg, reason: '$modus: Datumszahl ist onSelected');
        // Ring in the fill colour, so the geometry does not depend on the
        // state (it used to drop to `Colors.transparent`).
        expect(_rand(tester, gewaehlt), t.ink);
        expect(_rand(tester, ungewaehlt), t.line);
      });
    });
  });

  // =========================================================================
  // 2. _CalendarDayButton — square button at the end of the strip
  // =========================================================================
  group('Food-Kalenderknopf: gefuellt wie ein aktiver Chip', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Flaeche und Glyphe', (tester) async {
        const knopf = ValueKey<String>('food-date-calendar');

        // Selection inside the strip -> the button rests.
        await _pumpFoodTab(tester, brightness: brightness);
        final ruht = _fuellung(tester, knopf);
        final ruhendeGlyphe = _iconFarbe(tester, knopf);
        expect(ruht, t.surf);
        expect(_rand(tester, knopf), t.line);

        // A day beyond the 30 chips -> the button carries the selection.
        await _pumpFoodTab(
          tester,
          brightness: brightness,
          selectedDate: DateUtils.dateOnly(DateTime.now())
              .subtract(const Duration(days: 90)),
        );
        final aktiv = _fuellung(tester, knopf);
        final glyphe = _iconFarbe(tester, knopf);

        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Kalenderknopf',
          gewaehlteFlaeche: aktiv,
          ungewaehlteFlaeche: ruht,
          aufDerFlaeche: <Color>[glyphe],
          gegenueber: <Color>[ruhendeGlyphe],
        );

        expect(aktiv, t.ink, reason: '$modus: Fuellung ist selectedFill');
        expect(glyphe, t.bg, reason: '$modus: Glyphe ist onSelected');
        expect(_rand(tester, knopf), t.ink);

        // The archive chip that appears with it carries the same language.
        const archiv = ValueKey<String>('food-date-chip-archive');
        expect(_fuellung(tester, archiv), t.ink);
        expect(_textFarbe(tester, archiv, 1), t.bg);
      });
    });
  });

  // =========================================================================
  // 3. _DayPicker — the same chips inside the edit-meal sheet
  // =========================================================================
  group('Bearbeiten-Sheet: die Tages-Chips tragen dieselbe Sprache', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Flaeche, Wochentag und Datumszahl', (tester) async {
        await _oeffneEditSheet(tester, brightness: brightness);
        expect(find.byKey(const ValueKey('edit-meal-day-picker')),
            findsOneWidget);

        const gewaehlt = ValueKey<String>('edit-day-chip-0');
        const ungewaehlt = ValueKey<String>('edit-day-chip-1');

        final flaeche = _fuellung(tester, gewaehlt);
        final andere = _fuellung(tester, ungewaehlt);
        final wochentag = _ueber(_textFarbe(tester, gewaehlt, 0), flaeche);
        final datum = _textFarbe(tester, gewaehlt, 1);

        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Sheet-Tages-Chip',
          gewaehlteFlaeche: flaeche,
          ungewaehlteFlaeche: andere,
          aufDerFlaeche: <Color>[wochentag, datum],
          gegenueber: <Color>[
            _textFarbe(tester, ungewaehlt, 0),
            _textFarbe(tester, ungewaehlt, 1),
          ],
        );

        expect(flaeche, t.ink, reason: '$modus: Fuellung ist selectedFill');
        expect(andere, t.surf);
        expect(datum, t.bg);
        expect(_rand(tester, gewaehlt), t.ink);
        expect(_rand(tester, ungewaehlt), t.line);
      });
    });
  });

  // =========================================================================
  // 4. _TileCard / _RowCard — the onboarding cards
  // =========================================================================
  group('Onboarding: gewaehlte Karten tragen SelectionTone', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Geschlechts-Kachel (_TileCard)', (tester) async {
        // Step 1 = sex; UserProfile() defaults to `neutral`.
        await _zumSchritt(tester, 1, brightness: brightness);

        const gewaehlt = ValueKey<String>('onboarding-sex-neutral');
        const ungewaehlt = ValueKey<String>('onboarding-sex-female');

        final flaeche = _fuellung(tester, gewaehlt);
        final andere = _fuellung(tester, ungewaehlt);
        final glyphe = _iconFarbe(tester, gewaehlt);
        final beschriftung = _textFarbe(tester, gewaehlt, 0);

        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Geschlechts-Kachel',
          gewaehlteFlaeche: flaeche,
          ungewaehlteFlaeche: andere,
          aufDerFlaeche: <Color>[glyphe, beschriftung],
          gegenueber: <Color>[
            _iconFarbe(tester, ungewaehlt),
            _textFarbe(tester, ungewaehlt, 0),
          ],
        );

        expect(flaeche, t.ink, reason: '$modus: Fuellung ist selectedFill');
        expect(andere, t.surf);
        expect(_rand(tester, gewaehlt), t.ink);
        expect(glyphe, t.bg, reason: '$modus: Glyphe ist onSelected, nicht '
            'lime — auf ink waere lime 1,07:1 im Dunkelmodus');
        expect(beschriftung, t.bg);
      });

      testWidgets('$modus: Aktivitaets-Zeile (_RowCard) inkl. Haekchen',
          (tester) async {
        // Step 5 = activity; UserProfile() defaults to `sedentary`.
        await _zumSchritt(tester, 5, brightness: brightness);

        const gewaehlt = ValueKey<String>('onboarding-activity-sedentary');
        const ungewaehlt = ValueKey<String>('onboarding-activity-moderate');

        final flaeche = _fuellung(tester, gewaehlt);
        final andere = _fuellung(tester, ungewaehlt);
        // Text 0 = title, 1 = subtitle (onSelected @ 78 %), 2 = trailing.
        final titel = _textFarbe(tester, gewaehlt, 0);
        final unterzeile = _ueber(_textFarbe(tester, gewaehlt, 1), flaeche);
        final zusatz = _textFarbe(tester, gewaehlt, 2);
        // The row has no leading icon, so the ONLY icon is the state tick.
        final haekchen = _iconFarbe(tester, gewaehlt);

        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Aktivitaets-Zeile',
          gewaehlteFlaeche: flaeche,
          ungewaehlteFlaeche: andere,
          aufDerFlaeche: <Color>[titel, unterzeile, zusatz, haekchen],
          gegenueber: <Color>[
            _textFarbe(tester, ungewaehlt, 0),
            _textFarbe(tester, ungewaehlt, 1),
            _textFarbe(tester, ungewaehlt, 2),
          ],
        );

        expect(flaeche, t.ink, reason: '$modus: Fuellung ist selectedFill');
        expect(andere, t.surf);
        expect(_rand(tester, gewaehlt), t.ink);
        expect(titel, t.bg);
        expect(zusatz, t.bg);
        expect(haekchen, t.bg, reason: '$modus: das Haekchen ist der zweite '
            'Zustandskanal und muss auf der Fuellung lesen');
        expect(_drin(ungewaehlt, Icon), findsNothing,
            reason: 'nur die gewaehlte Zeile traegt ein Haekchen');
      });

      testWidgets('$modus: Ziel-Zeile traegt auch ihr fuehrendes Icon',
          (tester) async {
        // Step 6 = goal. The leading icon only exists here, and it was the
        // fourth channel that stayed `lime`.
        await _zumSchritt(tester, 6, brightness: brightness);
        await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
        await tester.pumpAndSettle();

        const gewaehlt = ValueKey<String>('onboarding-goal-lose');
        final flaeche = _fuellung(tester, gewaehlt);
        // Icon 0 = leading, icon 1 = the tick.
        for (var i = 0; i < 2; i++) {
          expect(
            _kontrast(_iconFarbe(tester, gewaehlt, i), flaeche),
            greaterThanOrEqualTo(_zustand),
            reason: '$modus: Icon $i auf der gewaehlten Ziel-Zeile',
          );
        }
        expect(flaeche, t.ink);
        expect(_iconFarbe(tester, gewaehlt, 0), t.bg);
        expect(_iconFarbe(tester, gewaehlt, 1), t.bg);
      });
    });
  });

  // =========================================================================
  // The numbers — vorher/nachher, so a revert has to walk past them
  // =========================================================================
  group('Die Messwerte der vier Stellen', () {
    test('dunkel: was forest/onForest an diesen Stellen wirklich war', () {
      const d = AppTokens.dark;
      // Fill of the selected chip on the card ground.
      expect(_kontrast(d.forest, d.surf), closeTo(1.3349, 0.001));
      // Weekday / icon: lime (selected) vs ink2 (unselected).
      expect(_kontrast(d.lime, d.ink2), closeTo(2.3270, 0.001));
      // The date number: onForest (selected) vs ink (unselected).
      expect(_kontrast(d.onForest, d.ink), closeTo(1.0440, 0.001));
      // …and `lime` ON the new fill, the reason weekday, icon, trailing and
      // tick all had to move too.
      expect(_kontrast(d.lime, d.ink), closeTo(1.0661, 0.001));
    });

    test('was SelectionTone an denselben Stellen liefert', () {
      for (final fall in <({String name, AppTokens t, double flaeche})>[
        (name: 'hell', t: AppTokens.light, flaeche: 16.7841),
        (name: 'dunkel', t: AppTokens.dark, flaeche: 14.9247),
      ]) {
        final t = fall.t;
        expect(_kontrast(t.ink, t.surf), closeTo(fall.flaeche, 0.001));
        // Label on the fill, and selected vs. unselected label.
        expect(_kontrast(t.bg, t.ink), greaterThanOrEqualTo(_text));
        expect(_kontrast(t.bg, t.ink2), greaterThanOrEqualTo(_zustand));
        // The 78 % channel (weekday, subtitle) on the fill and against ink2.
        final leise = _ueber(t.bg.withValues(alpha: 0.78), t.ink);
        expect(_kontrast(leise, t.ink), greaterThanOrEqualTo(_text));
        expect(_kontrast(leise, t.ink2), greaterThanOrEqualTo(_zustand));
      }
    });

    test('hell allein haette den Fehler nie gezeigt', () {
      // Why every case above runs in BOTH palettes: in light mode the old
      // pairing cleared every threshold, which is exactly how it survived.
      const h = AppTokens.light;
      expect(_kontrast(h.forest, h.surf), greaterThan(13.0));
      expect(_kontrast(h.onForest, h.forest), greaterThan(_text));
      expect(_kontrast(h.lime, h.ink2), greaterThan(_text));
    });
  });
}
