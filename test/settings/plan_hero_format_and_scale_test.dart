import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/settings_plan_hero.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

// F7-09: hand-built "dd.MM." captions and "×1.45" showed the German dot
// under `de` and the German order under `en`. Both go through intl now.
//
// F8-09: the plan hero's macro tiles shrank their (then 11-px) labels via
// FittedBox.scaleDown, so a 1.3× system font left them small. The macros
// now reserve width from the text scaler and switch to one line each at
// large sizes instead of shrinking.

Future<void> _pumpHero(WidgetTester tester, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final targets = const KcalCalculator().calculate(const UserProfile());

  await pumpLocalized(
    tester,
    SettingsPlanHero(
      kcal: targets.kcal,
      protein: targets.proteinG,
      carbs: targets.carbsG,
      fat: targets.fatG,
      targets: targets,
      manual: false,
    ),
    brightness: Brightness.light,
    textScale: scale,
    padding: const EdgeInsets.all(20),
    safeArea: false,
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
    testWidgets('bei 2,0× bleiben die Kacheln lesbar, ohne FittedBox und '
        'ohne Ueberlauf', (tester) async {
      await _pumpHero(tester, scale: 2.0);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(SettingsPlanHero),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
        reason: 'FittedBox.scaleDown hob die Systemschrift wieder auf',
      );

      // The rendered label really is about twice as tall as its 13 px style.
      final hoehe = tester.getSize(find.text('Protein')).height;
      expect(hoehe, greaterThan(20));
    });
  });
}
