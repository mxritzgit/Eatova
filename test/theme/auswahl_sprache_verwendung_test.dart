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
//   4. _TileCard/_RowCard   onboarding, sex and activity/goal cards (since
//                           2026-10-04 the picker-sheet language, below)
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
import 'package:eatova/src/screens/today/today_day_strip.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/controls.dart';
import 'package:eatova/src/widgets/design/option_card.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/food_glyphs.dart';

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

/// The painted card of a keyed onboarding option. Its [AnimatedContainer]
/// sits ABOVE the keyed InkWell, so the ink can paint over the fill.
BoxDecoration _kartenDeko(WidgetTester tester, Key key) =>
    tester
            .widget<AnimatedContainer>(
              find
                  .ancestor(
                    of: find.byKey(key),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .decoration!
        as BoxDecoration;

Color _kartenFuellung(WidgetTester tester, Key key) =>
    _kartenDeko(tester, key).color!;

Color _kartenRand(WidgetTester tester, Key key) =>
    (_kartenDeko(tester, key).border! as Border).top.color;

/// The radio mark inside a keyed onboarding option.
BoxDecoration _radioDeko(WidgetTester tester, Key key) =>
    tester
            .widget<AnimatedContainer>(
              find
                  .descendant(
                    of: find.descendant(
                      of: find.byKey(key),
                      matching: find.byType(OptionRadio),
                    ),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .decoration!
        as BoxDecoration;

/// The onboarding cards' contract, measured on the colours actually painted:
/// the outline and the radio carry the state (3:1), the text stays readable
/// (4.5:1) on the tinted fill, and the tint itself is the accent's.
void _erwarteKartenSprache(
  WidgetTester tester, {
  required String modus,
  required AppTokens t,
  required String was,
  required Key gewaehlt,
  required Key ungewaehlt,
}) {
  final flaeche = _kartenFuellung(tester, gewaehlt);
  expect(flaeche, Color.alphaBlend(t.accentTint, t.surf),
      reason: '$modus/$was: Fuellung ist der Akzent-Hauch ueber surf');
  expect(_kartenFuellung(tester, ungewaehlt), t.surf);

  // 1. The outline: accent when chosen, against both grounds a card sits on.
  final rand = _kartenRand(tester, gewaehlt);
  expect(rand, t.accent);
  expect(_kartenRand(tester, ungewaehlt), t.line);
  for (final grund in <(String, Color)>[('bg', t.bg), ('surf', t.surf)]) {
    expect(
      _kontrast(rand, grund.$2),
      greaterThanOrEqualTo(_zustand),
      reason: '$modus/$was: Auswahl-Rand gegen ${grund.$1} (WCAG 1.4.11)',
    );
  }

  // 2. The radio: a filled disc against the card, its check on the disc, and
  //    an empty ring that still reads on the unselected card.
  final scheibe = _radioDeko(tester, gewaehlt).color!;
  expect(scheibe, t.selectedFill);
  expect(
    _kontrast(scheibe, flaeche),
    greaterThanOrEqualTo(_zustand),
    reason: '$modus/$was: Radio-Scheibe gegen die Kartenflaeche',
  );
  expect(
    _kontrast(_iconFarbe(tester, gewaehlt, _drin(gewaehlt, Icon).evaluate().length - 1), scheibe),
    greaterThanOrEqualTo(_text),
    reason: '$modus/$was: Haken auf der Scheibe',
  );
  final ring = (_radioDeko(tester, ungewaehlt).border! as Border).top.color;
  expect(
    _kontrast(ring, t.surf),
    greaterThanOrEqualTo(_zustand),
    reason: '$modus/$was: leerer Ring auf der ungewaehlten Karte',
  );

  // 3. Every text on the chosen card stays body-text readable.
  for (final text in tester.widgetList<Text>(_drin(gewaehlt, Text))) {
    final farbe = text.style!.color!;
    expect(
      _kontrast(_ueber(farbe, flaeche), flaeche),
      greaterThanOrEqualTo(_text),
      reason: '$modus/$was: "${text.data}" auf der gewaehlten Flaeche',
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

/// Today, because the edit sheet's strip ends on the real today: a meal pinned
/// to a fixed calendar day would stop being the SELECTED day the day after
/// this file is written, and the assertions below would compare two
/// UNSELECTED days. Pinned to 2026-08-29, this group was green on exactly one
/// day and red from 2026-08-30 on.
final DateTime _heute = DateUtils.dateOnly(DateTime.now());

LoggedMeal _mahlzeit() => LoggedMeal(
      id: 'm1',
      loggedAt: _heute.add(const Duration(hours: 12)),
      localDay: localDayKey(_heute),
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

/// Onboarding up to [schritte] taps on "next" (goal = 0).
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
  group('Food-Datum bleibt auf dem offenen Hintergrund lesbar', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);
      for (final archived in [false, true]) {
        testWidgets('$modus: Datum und Kalender, Archiv=$archived', (tester) async {
          await _pumpFoodTab(tester, brightness: brightness,
            selectedDate: archived ? DateTime(2025, 9, 1) : null);
          final label = tester.widget<Text>(
            find.byKey(const ValueKey('food-date-selected-label')),
          );
          // Dark redesign: the date is the meta line of the day pill (a
          // `surf` capsule), the calendar a round header button whose glyph
          // inherits the button's icon ink.
          final glyph = IconTheme.of(
            tester.element(
              find.descendant(
                of: find.byKey(const ValueKey('food-date-calendar')),
                matching: find.byType(FoodGlyphIcon),
              ),
            ),
          ).color!;
          expect(label.style!.color, t.ink3);
          expect(_kontrast(label.style!.color!, t.surf), greaterThanOrEqualTo(_text));
          expect(_kontrast(glyph, t.surf), greaterThanOrEqualTo(_zustand));
          expect(_kontrast(glyph, t.bg), greaterThanOrEqualTo(_zustand));
          expect(tester.getSize(find.byKey(const ValueKey('food-date-calendar'))).height,
            greaterThanOrEqualTo(44));
          if (archived) expect(label.data, contains('2025'));
        });
      }
    });
  });

  // =========================================================================
  // 3. The edit-meal sheet's day strip (Today's 7-day strip since 2026-10-03)
  // =========================================================================
  group('Bearbeiten-Sheet: der Tages-Streifen traegt dieselbe Sprache', () {
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Flaeche, Wochentag und Tageszahl', (tester) async {
        await _oeffneEditSheet(tester, brightness: brightness);
        final streifen = find.byKey(const ValueKey('edit-meal-day-picker'));
        expect(tester.widget(streifen), isA<TodayDayStrip>());

        Finder tag(DateTime d) =>
            find.byKey(ValueKey<String>('today-day-${localDayKey(d)}'));
        final gewaehlt = tag(_heute);
        final ungewaehlt = tag(
          DateTime(_heute.year, _heute.month, _heute.day - 1),
        );
        Color flaeche(Finder zelle) => (tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(of: zelle, matching: find.byType(DecoratedBox))
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color!;
        List<Color> farben(Finder zelle) => [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: zelle, matching: find.byType(Text)),
          ))
            text.style!.color!,
        ];

        final auswahl = flaeche(gewaehlt);
        expect(auswahl, t.selectedFill, reason: '$modus: Fuellung');
        expect(flaeche(ungewaehlt).a, 0, reason: 'offen auf dem Sheet');
        final [wochentag, zahl] = farben(gewaehlt);
        expect(zahl, t.onSelected);

        _erwarteAuswahlsprache(
          modus: modus,
          t: t,
          was: 'Sheet-Tagesstreifen',
          gewaehlteFlaeche: auswahl,
          ungewaehlteFlaeche: t.bg,
          aufDerFlaeche: <Color>[_ueber(wochentag, auswahl), zahl],
          gegenueber: [for (final c in farben(ungewaehlt)) _ueber(c, t.bg)],
        );
      });
    });
  });

  group('Onboarding: gewaehlte Karten tragen die Picker-Sprache', () {
    // Since 2026-10-04 the onboarding speaks the settings pickers' selection
    // language: the chosen card takes the accent tint, an accent outline and
    // a filled accent radio; the text stays `ink`. The state is carried by
    // the outline and the radio — both measured here — not by the tint.
    _modi.forEach((modus, brightness) {
      final t = _tokens(brightness);

      testWidgets('$modus: Geschlechts-Kachel', (tester) async {
        // Step 2 = about you; UserProfile() defaults to `neutral`.
        await _zumSchritt(tester, 1, brightness: brightness);
        _erwarteKartenSprache(
          tester,
          modus: modus,
          t: t,
          was: 'Geschlechts-Kachel',
          gewaehlt: const ValueKey<String>('onboarding-sex-neutral'),
          ungewaehlt: const ValueKey<String>('onboarding-sex-female'),
        );
      });

      testWidgets('$modus: Aktivitaets-Karte', (tester) async {
        // Step 4 = activity; UserProfile() defaults to `sedentary`.
        await _zumSchritt(tester, 3, brightness: brightness);
        _erwarteKartenSprache(
          tester,
          modus: modus,
          t: t,
          was: 'Aktivitaets-Karte',
          gewaehlt: const ValueKey<String>('onboarding-activity-sedentary'),
          ungewaehlt: const ValueKey<String>('onboarding-activity-moderate'),
        );
      });

      testWidgets('$modus: Ziel-Karte mit fuehrendem Symbol', (tester) async {
        // Step 1 = goal.
        await _zumSchritt(tester, 0, brightness: brightness);
        await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
        await tester.pumpAndSettle();
        const gewaehlt = ValueKey<String>('onboarding-goal-lose');
        _erwarteKartenSprache(
          tester,
          modus: modus,
          t: t,
          was: 'Ziel-Karte',
          gewaehlt: gewaehlt,
          ungewaehlt: const ValueKey<String>('onboarding-goal-maintain'),
        );
        // The leading glyph sits on its tile over the selected fill.
        final flaeche = _kartenFuellung(tester, gewaehlt);
        final kachel = tester
            .widgetList<Container>(_drin(gewaehlt, Container))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.color == t.tile);
        final glyphe = _iconFarbe(tester, gewaehlt);
        expect(
          _kontrast(glyphe, _ueber(kachel.color!, flaeche)),
          greaterThanOrEqualTo(_zustand),
          reason: '$modus: Symbol auf seiner Kachel ueber der Auswahl',
        );
      });
    });
  });

  // =========================================================================
  // The numbers — vorher/nachher, so a revert has to walk past them
  // =========================================================================
  group('Auswahl bleibt nach einem Palettenwechsel erkennbar', () {
    for (final mode in Brightness.values) {
      final t = _tokens(mode);
      test('Kontrastvertrag $mode', () {
        // The pair is SelectionTone's (the accent fill since the dark
        // redesign, 2026-09-28), measured against the unselected label ink2.
        final fill = t.selectedFill;
        final label = t.onSelected;
        expect(_kontrast(fill, t.surf), greaterThanOrEqualTo(_zustand));
        expect(_kontrast(label, fill), greaterThanOrEqualTo(_text));
        expect(_kontrast(label, t.ink2), greaterThanOrEqualTo(_zustand));
        final quiet = _ueber(label.withValues(alpha: 0.78), fill);
        expect(_kontrast(quiet, fill), greaterThanOrEqualTo(_text));
        expect(_kontrast(quiet, t.ink2), greaterThanOrEqualTo(_zustand));
        expect(_kontrast(t.brandSurface, t.surf), lessThan(_zustand));
      });
    }
  });
}
