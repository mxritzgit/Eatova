import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/screens/training/training_actual_fields.dart';
import 'package:eatova/src/widgets/common/decimal_text.dart';

import '../support/harness.dart';
import '../support/onboarding_harness.dart';

// Decimals shown in the UI follow the app language: German readers saw
// "62.5 kg" in the training history, "×1.45" in onboarding and "0.5" in
// recipe fields. Prefills must also parse back through the fields' own
// ',' -> '.' rule, so no digit grouping.

void main() {
  group('formatDecimal', () {
    test('Dezimalzeichen je Sprache, ganze Zahlen ohne Nachkommastelle', () {
      expect(formatDecimal(12.5, deL10n), '12,5');
      expect(formatDecimal(12.5, enL10n), '12.5');
      expect(formatDecimal(60.0, deL10n), '60');
      expect(formatDecimal(0.125, deL10n, maxFractionDigits: 3), '0,125');
      expect(formatDecimal(1.25, enL10n, maxFractionDigits: 1), '1.3');
    });

    test('keine Tausendertrennung, damit Felder den Wert zurueckgeben', () {
      final text = formatDecimal(1234.5, deL10n);
      expect(text, '1234,5');
      expect(double.parse(text.replaceAll(',', '.')), 1234.5);
    });
  });

  test('Trainingsgewicht in Verlauf und Vorbelegung', () {
    expect(formatTrainingWeight(62.5, deL10n), '62,5');
    expect(formatTrainingWeight(62.5, enL10n), '62.5');
    expect(formatTrainingWeight(60, deL10n), '60');
    expect(
      deL10n.trainingHistoryWeightValue(formatTrainingWeight(62.5, deL10n)),
      contains('62,5'),
    );
  });

  for (final (locale, expected) in const [
    (Locale('de'), '×1,45'),
    (Locale('en'), '×1.45'),
  ]) {
    testWidgets('Onboarding-Aktivitaet zeigt den PAL-Faktor lokalisiert '
        '(${locale.languageCode})', (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpLocalized(
        tester,
        OnboardingScreen(
          firstName: 'Alex',
          initialProfile: const UserProfile(),
          onComplete: (_) {},
        ),
        locale: locale,
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
      );
      await tester.pumpAndSettle();
      await goToOnboarding(tester, 'activity');
      final tile = find.byKey(const ValueKey('onboarding-activity-light'));
      await tester.ensureVisible(tile);
      expect(
        find.descendant(of: tile, matching: find.text(expected)),
        findsOneWidget,
      );
    });
  }
}
