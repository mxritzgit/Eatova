import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/meters.dart';

import 'design_harness.dart';

void main() {
  group('TickGauge', () {
    testWidgets('haelt die Grenzwerte aus', (tester) async {
      for (final progress in <double>[0, 0.5, 1, 1.8, -0.4, double.nan]) {
        await tester.pumpWidget(
          designHarness(TickGauge(progress: progress)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'progress $progress hat geworfen',
        );
      }
    });

    testWidgets('nimmt die uebergebene Hoehe', (tester) async {
      await tester.pumpWidget(
        designHarness(const TickGauge(progress: 0.5, height: 40)),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(TickGauge)).height, 40);
    });

    testWidgets('malt ueber einen CustomPainter', (tester) async {
      await tester.pumpWidget(designHarness(const TickGauge(progress: 0.5)));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(TickGauge),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });
  });

  group('MacroBar', () {
    Future<double?> pumpBar(
      WidgetTester tester, {
      required int value,
      required int goal,
    }) async {
      await tester.pumpWidget(
        designHarness(
          MacroBar(
            label: 'Protein',
            value: value,
            goal: goal,
            unit: 'g',
            color: AppTokens.light.protein,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value;
    }

    testWidgets('zeigt Beschriftung und Fuellstand', (tester) async {
      final filled = await pumpBar(tester, value: 96, goal: 150);

      expect(find.text('Protein'), findsOneWidget);
      expect(filled, closeTo(0.64, 0.001));
    });

    testWidgets('goal 0 fuehrt nicht zu NaN', (tester) async {
      final filled = await pumpBar(tester, value: 20, goal: 0);

      expect(filled, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ueberschreitung wird auf 1 gedeckelt', (tester) async {
      expect(await pumpBar(tester, value: 400, goal: 150), 1.0);
    });

    testWidgets('negative Werte fallen auf 0', (tester) async {
      expect(await pumpBar(tester, value: -30, goal: 150), 0.0);
    });
  });

  group('MealAvatar', () {
    testWidgets('zeigt den Buchstaben in der Slot-Farbe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          MealAvatar(letter: 'F', color: AppTokens.light.carbs),
        ),
      );

      expect(find.text('F'), findsOneWidget);
      expect(
        tester.getSize(find.byType(MealAvatar)),
        const Size(40, 40),
      );
      expect(
        decorationOf(tester, find.byType(MealAvatar)).color,
        AppTokens.light.carbs.withValues(alpha: 0.16),
      );
    });

    // The letter sits on the avatar's OWN 16 % tint, so the tone that paints
    // the tile may not paint the glyph: the raw carb amber reaches 2.15:1
    // there in light mode. `hell_modus_audit_test` computes what
    // `readableOnTint` WOULD give — it never looks at what the widget picks,
    // and neither did this file, so the whole suite stayed green with the
    // correction dropped. Measured on the rendered tree, in both palettes and
    // for all four slot tones.
    testWidgets('der Buchstabe bleibt auf seiner eigenen Tint lesbar',
        (tester) async {
      final zuSchwach = <String>[];
      for (final palette in <(String, AppTokens, Brightness)>[
        ('hell', AppTokens.light, Brightness.light),
        ('dunkel', AppTokens.dark, Brightness.dark),
      ]) {
        final t = palette.$2;
        for (final ton in <(String, Color)>[
          ('protein', t.protein),
          ('carbs', t.carbs),
          ('fat', t.fat),
          ('snack', t.snack),
        ]) {
          await tester.pumpWidget(
            designHarness(
              MealAvatar(letter: 'F', color: ton.$2),
              brightness: palette.$3,
            ),
          );
          // MaterialApp LERPS the theme over kThemeAnimationDuration, so a
          // single frame still hands out the previous palette — the case would
          // measure a dark tone against a light ground.
          await tester.pumpAndSettle();
          final tint = Color.alphaBlend(
            decorationOf(tester, find.byType(MealAvatar)).color!,
            groundBehind(tester.element(find.byType(MealAvatar))),
          );
          final glyphe = tester.widget<Text>(find.text('F')).style!.color!;
          final ratio = contrastRatio(Color.alphaBlend(glyphe, tint), tint);
          if (ratio < 4.5) {
            zuSchwach.add(
              '${palette.$1}/${ton.$1}: ${ratio.toStringAsFixed(2)}:1 '
              '(Glyphe $glyphe auf Tint $tint)',
            );
          }
        }
      }
      expect(zuSchwach, isEmpty,
          reason: 'Buchstabe auf seinem eigenen 16-%-Tint unter AA:\n'
              '${zuSchwach.join('\n')}');
    });

    testWidgets('der rohe Slot-Ton waere dort NICHT lesbar', (tester) async {
      // Counter-check, so the case above cannot pass by accident: what the
      // widget must not use.
      const t = AppTokens.light;
      await tester.pumpWidget(
        designHarness(MealAvatar(letter: 'F', color: t.carbs)),
      );
      final tint = Color.alphaBlend(
        decorationOf(tester, find.byType(MealAvatar)).color!,
        groundBehind(tester.element(find.byType(MealAvatar))),
      );
      expect(contrastRatio(t.carbs, tint), lessThan(3.0));
    });

    testWidgets('size skaliert die Kachel', (tester) async {
      await tester.pumpWidget(
        designHarness(
          MealAvatar(letter: 'M', color: AppTokens.light.protein, size: 56),
        ),
      );

      expect(tester.getSize(find.byType(MealAvatar)), const Size(56, 56));
    });
  });

  group('Sparkline', () {
    testWidgets('haelt leere, einelementige und konstante Reihen aus',
        (tester) async {
      const series = <List<double>>[
        <double>[],
        <double>[80],
        <double>[80, 80, 80],
        <double>[78.6, 79.2, 78.9, 81.4],
      ];

      for (final values in series) {
        await tester.pumpWidget(designHarness(Sparkline(values: values)));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Reihe $values hat geworfen',
        );
      }
    });

    testWidgets('nimmt die uebergebene Hoehe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const Sparkline(values: <double>[1, 2, 3], height: 100),
        ),
      );

      expect(tester.getSize(find.byType(Sparkline)).height, 100);
    });
  });

  group('DotGridBackground', () {
    testWidgets('fuellt einen Stack ohne Ausnahme', (tester) async {
      await tester.pumpWidget(
        designHarness(
          SizedBox(
            height: 120,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: DotGridBackground(color: AppTokens.light.lime),
                ),
                const Center(child: Text('Hero')),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Hero'), findsOneWidget);
      expect(tester.getSize(find.byType(DotGridBackground)).height, 120);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('alle Messgeraete rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => Column(
        children: <Widget>[
          const TickGauge(progress: 0.6),
          MacroBar(
            label: 'Protein',
            value: 96,
            goal: 150,
            unit: 'g',
            color: AppTokens.light.protein,
          ),
          MealAvatar(letter: 'F', color: AppTokens.light.carbs),
          const Sparkline(values: <double>[78.6, 79.2, 78.9, 81.4]),
          SizedBox(
            height: 60,
            child: DotGridBackground(color: AppTokens.light.lime),
          ),
        ],
      ),
      scrollable: true,
    );
  });

  testWidgets('alle Messgeraete ueberstehen textScaler 2.0', (tester) async {
    pinPhoneViewport(tester);
    await expectSurvivesTextScale(
      tester,
      Column(
        children: <Widget>[
          const TickGauge(progress: 0.6),
          MacroBar(
            label: 'Kohlenhydrate',
            value: 142,
            goal: 250,
            unit: 'g',
            color: AppTokens.light.carbs,
          ),
          MealAvatar(letter: 'F', color: AppTokens.light.carbs),
          const Sparkline(values: <double>[78.6, 79.2, 78.9, 81.4]),
        ],
      ),
    );
  });
}
