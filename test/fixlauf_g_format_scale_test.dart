import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/settings_plan_hero.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

// F7-09: hand-built "dd.MM." captions and "×1.45" showed the German dot
// under `de` and the German order under `en`. Both go through intl now.
//
// F8-09: the plan hero's macro tiles shrank their 11-px labels via
// FittedBox.scaleDown, so a 1.3× system font left them at 11 px. The tiles
// now reserve width from the text scaler and wrap instead.

Future<void> _pumpHero(WidgetTester tester, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final targets = const KcalCalculator().calculate(const UserProfile());

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.light),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: SettingsPlanHero(
              kcal: targets.kcal,
              protein: targets.proteinG,
              carbs: targets.carbsG,
              fat: targets.fatG,
              targets: targets,
              manual: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('F7-09 Locale-Formate', () {
    final en = lookupAppLocalizations(const Locale('en'));

    test('PAL-Faktor: de mit Komma, en mit Punkt', () {
      expect(formatPalFactor(ActivityLevel.light, deL10n), '1,45');
      expect(formatPalFactor(ActivityLevel.light, en), '1.45');
      expect(formatPalFactor(ActivityLevel.sedentary, deL10n), '1,3');
      expect(formatPalFactor(ActivityLevel.athlete, en), '1.9');
    });

    test('Kurzdatum: de "1.8.", en "8/1"', () {
      final tag = DateTime(2026, 8, 1);
      expect(formatShortDate(tag, deL10n), '1.8.');
      expect(formatShortDate(tag, en), '8/1');
    });
  });

  group('F8-09 Plan-Hero skaliert Text statt ihn zu schrumpfen', () {
    testWidgets('kein FittedBox mehr um die Makro-Kacheln', (tester) async {
      await _pumpHero(tester);
      expect(
        find.descendant(
          of: find.byType(SettingsPlanHero),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
    });

    testWidgets('bei 2,0× bleiben die Kacheln lesbar und laufen nicht ueber',
        (tester) async {
      await _pumpHero(tester, scale: 2.0);
      expect(tester.takeException(), isNull);

      final label = tester.widget<Text>(find.text('Protein'));
      expect(label.style!.fontSize, 11,
          reason: 'der Stil bleibt 11 — der Scaler rendert ihn 22 px gross');
      // The rendered label really is twice as tall as at 1.0×.
      final hoehe = tester.getSize(find.text('Protein')).height;
      expect(hoehe, greaterThan(20));
    });

    testWidgets('bei 1,0× stehen die drei Kacheln nebeneinander',
        (tester) async {
      await _pumpHero(tester);
      final protein = tester.getTopLeft(find.text('Protein'));
      final fett = tester.getTopLeft(find.text('Fett'));
      expect(protein.dy, fett.dy, reason: 'gleiche Zeile');
      expect(fett.dx, greaterThan(protein.dx));
    });
  });
}
