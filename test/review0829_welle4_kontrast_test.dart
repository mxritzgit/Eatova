import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// Wave 4 of the 2026-08-29 fix run — the two colour findings the reviewers
// raised against waves 2 and 3.
//
// P9-01b  MacroTile (MealResultCard, the AI scan result) is the FOURTH macro
//         tile and the worst of them: unlike the three fixed in wave 2 it sits
//         on `surf2`, one step darker than `surf`. There the raw tone carries
//         neither the number (4.5:1) nor even a dot (3:1, WCAG 1.4.11).
// P9-02b  _FoodQuickChip emphasised the AI scan with `forest` on a `surf`
//         neighbour — 1.34:1 in dark mode, i.e. no emphasis at all. The app
//         has ONE emphasis language, [SelectionTone].
//
// Everything here is measured on colours read BACK OUT of the built tree, not
// on what the source claims to paint.
// ---------------------------------------------------------------------------

/// WCAG 2.1 contrast ratio of two OPAQUE colours (1.0 … 21.0).
double _kontrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

const MealAnalysisResult _scanErgebnis = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '24 g',
  carbs: '48 g',
  fat: '9 g',
  confidence: 'Hoch',
  portionNotes: 'Ein tiefer Teller.',
  sourceLabel: 'Foto-KI',
);

/// The three macro tones of [t] under their names.
Map<String, Color> _makros(AppTokens t) => <String, Color>{
      'protein': t.protein,
      'carbs': t.carbs,
      'fat': t.fat,
    };

/// Fill of the first circular [Container] inside [kachel].
Color _punktFarbe(Finder kachel) {
  for (final element in find
      .descendant(of: kachel, matching: find.byType(Container))
      .evaluate()) {
    final deko = (element.widget as Container).decoration;
    if (deko is BoxDecoration && deko.shape == BoxShape.circle) {
      return deko.color!;
    }
  }
  fail('Keine runde Markierung in der Makro-Kachel gefunden.');
}

/// Fill of the tile itself (the rounded, non-circular [Container]).
Color _kachelFlaeche(Finder kachel) {
  for (final element in find
      .descendant(of: kachel, matching: find.byType(Container))
      .evaluate()) {
    final deko = (element.widget as Container).decoration;
    if (deko is BoxDecoration && deko.shape != BoxShape.circle) {
      return deko.color!;
    }
  }
  fail('Keine Flaeche in der Makro-Kachel gefunden.');
}

/// Builds the food tab in the shell the home page gives it — the two quick
/// chips only exist there.
Future<BuildContext> _pumpFoodTab(
  WidgetTester tester,
  Brightness helligkeit,
) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // The headless test font has other metrics than the shipped one, so a tree
  // with slack on device reports an overflow here. This suite measures
  // colours, never geometry.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  return pumpLocalizedContext(
    tester,
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: MealAnalysisScreen(dailyConsumedKcal: 0),
    ),
    brightness: helligkeit,
    reducedMotion: false,
    settle: true,
  );
}

/// [Material] fill of the chip carrying [schluessel].
Color _chipFlaeche(WidgetTester tester, String schluessel) {
  return tester
      .widget<Material>(
        find
            .descendant(
              of: find.byKey(ValueKey<String>(schluessel)),
              matching: find.byType(Material),
            )
            .first,
      )
      .color!;
}

Color _chipTextFarbe(WidgetTester tester, String schluessel) {
  return tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey<String>(schluessel)),
          matching: find.byType(Text),
        ),
      )
      .style!
      .color!;
}

Color _chipIkonFarbe(WidgetTester tester, String schluessel) {
  return tester
      .widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey<String>(schluessel)),
          matching: find.byType(Icon),
        ),
      )
      .color!;
}

void main() {
  // =========================================================================
  // P9-01b — die Makro-Kachel des KI-Ergebnisses
  // =========================================================================
  group('P9-01b: die Makro-Kachel im Scan-Ergebnis', () {
    test('der rohe Ton traegt auf surf2 weder Text noch Punkt', () {
      // The reason this instance is worse than the three fixed in wave 2: they
      // sit on `surf`, this one on `surf2`. In the LIGHT palette that costs
      // roughly half a point and drops carbs and fat under the 3:1 a graphical
      // object needs — so even the dot may not take the raw tone here.
      const hell = AppTokens.light;
      expect(_kontrast(hell.carbs, hell.surf2), lessThan(3.0),
          reason: 'carbs auf surf2 (2,77:1) — unter der Grafik-Schwelle');
      expect(_kontrast(hell.fat, hell.surf2), lessThan(4.5),
          reason: 'fat auf surf2 (3,04:1) — unter der Text-Schwelle');
      expect(_kontrast(hell.protein, hell.surf2), lessThan(5.0));
      // Counter-check: on `surf` the same tones would still make the 3:1 the
      // wave-2 tiles rely on. The ground is the whole finding.
      expect(_kontrast(hell.carbs, hell.surf), greaterThanOrEqualTo(3.0));
    });

    test('readableOnTint traegt den Punkt auf surf2 in beiden Modi', () {
      for (final paar in <(String, AppTokens)>[
        ('hell', AppTokens.light),
        ('dunkel', AppTokens.dark),
      ]) {
        final t = paar.$2;
        for (final makro in _makros(t).entries) {
          expect(
            _kontrast(t.readableOnTint(makro.value), t.surf2),
            greaterThanOrEqualTo(3.0),
            reason: '${paar.$1}: ${makro.key}-Punkt auf surf2',
          );
        }
        expect(_kontrast(t.ink, t.surf2), greaterThanOrEqualTo(4.5),
            reason: '${paar.$1}: die Zahl in ink auf surf2');
      }
    });

    for (final helligkeit in Brightness.values) {
      final modus = helligkeit == Brightness.light ? 'HELL' : 'DUNKEL';

      testWidgets('$modus: die Kachel zeichnet Punkt + Zahl in ink',
          (tester) async {
        final c = await pumpLocalizedContext(
          tester,
          MealResultCard(
            result: _scanErgebnis,
            addedToDailyTotal: false,
            onAdjustRequested: () {},
            onAddToDailyRequested: () {},
          ),
          brightness: helligkeit,
          settle: true,
        );
        final t = c.t;

        final kacheln = find.byType(MacroTile);
        expect(kacheln, findsNWidgets(3));

        final erwartetePunkte = _makros(t)
            .values
            .map(t.readableOnTint)
            .toList(growable: false);

        for (var i = 0; i < 3; i++) {
          final kachel = kacheln.at(i);
          final flaeche = _kachelFlaeche(kachel);
          expect(flaeche, t.surf2,
              reason: 'die Kachel liegt auf surf2 — die Praemisse des Fundes');

          // The number: text token, never a macro tone.
          final zahl = tester.widget<Text>(
            find.descendant(of: kachel, matching: find.byType(Text)).at(1),
          );
          expect(zahl.style!.color, t.ink,
              reason: '$modus: die Makrozahl steht in ink');
          expect(
            _kontrast(zahl.style!.color!, flaeche),
            greaterThanOrEqualTo(4.5),
            reason: '$modus: 13-px-w700-Zahl ist Normaltext (AA-Large beginnt '
                'erst bei 14 pt fett = 18,67 px)',
          );

          // The dot: corrected macro tone, measured against the tile it sits
          // on, not against the card behind it.
          final punkt = _punktFarbe(kachel);
          expect(punkt, erwartetePunkte[i],
              reason: '$modus: der Punkt traegt den korrigierten Makroton');
          expect(_kontrast(punkt, flaeche), greaterThanOrEqualTo(3.0),
              reason: '$modus: Punkt auf surf2 (WCAG 1.4.11)');
        }
      });
    }
  });

  // =========================================================================
  // P9-02b — die Betonung der beiden Schnell-Chips
  // =========================================================================
  group('P9-02b: die Betonung des KI-Scan-Chips', () {
    test('forest auf surf ist im Dunkelmodus keine Betonung', () {
      // The number that made this a finding. No 1.4.11 violation — `filled` is
      // a static emphasis, not a selection state, and both chips are labelled
      // — but 1.34:1 simply is not visible.
      expect(_kontrast(AppTokens.dark.forest, AppTokens.dark.surf),
          lessThan(1.5));
      // In light mode the same pair carries 13.57:1 — mode-asymmetric, exactly
      // the bug SelectionTone was introduced for in wave 3.
      expect(_kontrast(AppTokens.light.forest, AppTokens.light.surf),
          greaterThan(10.0));
    });

    for (final helligkeit in Brightness.values) {
      final modus = helligkeit == Brightness.light ? 'HELL' : 'DUNKEL';

      testWidgets('$modus: der KI-Chip spricht die Auswahl-Sprache der App',
          (tester) async {
        final c = await _pumpFoodTab(tester, helligkeit);
        final t = c.t;

        final betont = _chipFlaeche(tester, 'food-action-ai');
        final schlicht = _chipFlaeche(tester, 'food-action-barcode');

        expect(betont, t.selectedFill,
            reason: '$modus: gefuellt = selectedFill, wie Pille und Filter-Chip');
        expect(schlicht, t.surf, reason: '$modus: ungefuellt bleibt surf');
        expect(_chipTextFarbe(tester, 'food-action-ai'), t.onSelected);
        expect(_chipIkonFarbe(tester, 'food-action-ai'), t.onSelected,
            reason: '$modus: lime auf ink waere im Dunkelmodus unlesbar');
        expect(_chipTextFarbe(tester, 'food-action-barcode'), t.ink2);

        // The emphasis is a boundary between two adjacent controls, i.e. a
        // graphical object: 3:1.
        expect(_kontrast(betont, schlicht), greaterThanOrEqualTo(3.0),
            reason: '$modus: betonter Chip gegen seinen Nachbarn');
        expect(_kontrast(betont, t.bg), greaterThanOrEqualTo(3.0),
            reason: '$modus: betonter Chip gegen den Seitengrund');
        // And the label on it stays normal text.
        expect(
          _kontrast(_chipTextFarbe(tester, 'food-action-ai'), betont),
          greaterThanOrEqualTo(4.5),
          reason: '$modus: 13-px-Label auf der Fuellung',
        );
        expect(
          _kontrast(_chipTextFarbe(tester, 'food-action-barcode'), schlicht),
          greaterThanOrEqualTo(4.5),
          reason: '$modus: 13-px-Label des schlichten Chips',
        );
      });
    }
  });
}
