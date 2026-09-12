import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
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
    test('rohe Makro-Toene sind keine Schriftfarben auf surf2', () {
      const t = AppTokens.light;
      expect(_kontrast(t.carbs, t.surf2), lessThan(4.5));
      expect(_kontrast(t.fat, t.surf2), lessThan(4.5));
      expect(_kontrast(t.carbs, t.surf), greaterThanOrEqualTo(3.0));
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
      // The pastel surface is also too subtle to carry emphasis by itself.
      expect(_kontrast(AppTokens.light.forest, AppTokens.light.surf),
          lessThan(3.0));
    });

    for (final helligkeit in Brightness.values) {
      final modus = helligkeit == Brightness.light ? 'HELL' : 'DUNKEL';

      testWidgets('$modus: alle Erfassungswege bleiben auf Lavendel lesbar', (tester) async {
        final c = await _pumpFoodTab(tester, helligkeit);
        final t = c.t;
        final surface = tester.widget<Material>(
          find.byKey(const ValueKey('food-entry-dock')),
        ).color!;
        expect(surface, t.brandSurface);
        for (final key in ['food-action-ai', 'food-action-barcode', 'food-action-manual']) {
          expect(_kontrast(_chipTextFarbe(tester, key), surface), greaterThanOrEqualTo(4.5));
          expect(_kontrast(_chipIkonFarbe(tester, key), surface), greaterThanOrEqualTo(3.0));
        }
      });
    }
  });
}
