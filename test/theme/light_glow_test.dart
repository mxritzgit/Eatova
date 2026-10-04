// The decorative violet glows per display mode (light pass, 2026-10-04). In
// dark they read as light behind the auth header and the heroes; on the light
// page the same alphas painted a lavender cloud, so their alpha is scaled by
// `AppTokens.glowStrength` — 1 in dark (unchanged), lower in light.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/auth_controls.dart';

import '../support/harness.dart';
import '../support/today_summary.dart';

/// Alpha of the brightest stop of every radial glow on screen.
List<double> _glowAlphas(WidgetTester tester) => <double>[
  for (final box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)))
    if (box.decoration case BoxDecoration(gradient: final RadialGradient g))
      g.colors.first.a,
];

void main() {
  const faelle = <Brightness, AppTokens>{
    Brightness.dark: AppTokens.dark,
    Brightness.light: AppTokens.light,
  };

  for (final MapEntry(key: helligkeit, value: t) in faelle.entries) {
    testWidgets('${helligkeit.name}: der Auth-Kopf-Glow folgt glowStrength', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        const AuthPageLayout(child: SizedBox(height: 200)),
        brightness: helligkeit,
      );
      expect(_glowAlphas(tester), <Matcher>[
        closeTo(0.30 * t.glowStrength, 0.002),
      ]);
    });

    testWidgets('${helligkeit.name}: der Glow hinter dem Kalorienbogen', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        SizedBox(
          width: 360,
          child: TodayCalorieCard(
            summary: todaySummary(
              profile: const UserProfile(dailyKcalGoal: 2000),
              consumedKcal: 1200,
            ),
          ),
        ),
        brightness: helligkeit,
        scrollable: true,
      );
      expect(_glowAlphas(tester), <Matcher>[
        closeTo(0.22 * t.glowStrength, 0.002),
      ]);
    });
  }

  test('hell ist der Auth-Glow hoechstens halb so stark wie dunkel', () {
    // 0.30 of the iris fill painted a cloud behind the wordmark.
    expect(AppTokens.light.glowStrength, lessThanOrEqualTo(0.5));
  });
}
