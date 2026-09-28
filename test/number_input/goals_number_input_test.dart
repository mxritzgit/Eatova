import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The goals page writes integer `profiles` columns. `digitsOnly` dropped the
// comma: "7,5" kg became 75 kg and was saved, "72,5" became 725 and got a range
// error that never mentioned the comma. The profile weigh-in accepts decimals
// because `weight_log.weight_kg` is numeric; `profiles.weight_kg` is not, so
// here a decimal is refused with a hint instead.

const List<String> _felder = <String>[
  'settings-weight',
  'settings-height',
  'settings-age',
  'settings-target-weight',
  'settings-steps-goal',
];

Future<Future<SettingsResult?>> _oeffne(
  WidgetTester tester,
  Locale locale,
) async {
  late Future<SettingsResult?> ergebnis;
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-settings'),
          onPressed: () {
            ergebnis = Navigator.of(context).push<SettingsResult>(
              MaterialPageRoute<SettingsResult>(
                builder: (_) => const GoalsScreen(profile: UserProfile()),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
    locale: locale,
  );
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
  return ergebnis;
}

Future<void> _tippe(WidgetTester tester, String key, String text) async {
  final feld = find.byKey(ValueKey(key));
  await tester.ensureVisible(feld);
  await tester.enterText(feld, text);
  await tester.pump();
}

VoidCallback? _speichern(WidgetTester tester) => tester
    .widget<PrimaryActionButton>(find.byKey(const ValueKey('settings-save')))
    .onTap;

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);

    testWidgetsRobust(
      'Ziele [${locale.languageCode}]: ganze Zahlen, "7,5" wird nicht 75',
      (tester) async {
        final ergebnis = await _oeffne(tester, locale);
        expect(_speichern(tester), isNotNull);

        for (final key in _felder) {
          final vorher =
              tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
          for (final (eingabe, hinweis) in ganzzahlFaelle(l10n)) {
            await _tippe(tester, key, eingabe);
            expect(
              tester.widget<TextField>(find.byKey(ValueKey(key))).controller!
                  .text,
              eingabe,
              reason: '$key: "$eingabe" darf nicht zu Ziffern verkuerzt werden',
            );
            expect(find.text(hinweis), findsOneWidget, reason: '$key $eingabe');
            expect(_speichern(tester), isNull, reason: '$key $eingabe');
          }
          await _tippe(tester, key, vorher);
        }

        // The exact defect: "7,5" used to be saved as 75 kg.
        await _tippe(tester, 'settings-weight', '7,5');
        expect(_speichern(tester), isNull);
        await _tippe(tester, 'settings-weight', '82');
        await _tippe(tester, 'settings-steps-goal', '10.000.000');
        expect(find.text(l10n.numberInputWholeNumber), findsNothing,
            reason: 'zwei Gruppen sind eindeutig — nur der Bereich greift');
        expect(_speichern(tester), isNull);
        await _tippe(tester, 'settings-steps-goal', '9500');

        final speichern = find.byKey(const ValueKey('settings-save'));
        await tester.ensureVisible(speichern);
        await tester.pumpAndSettle();
        await tester.tap(speichern);
        await tester.pumpAndSettle();
        final profil = (await ergebnis)!.profile;
        expect(profil.weightKg, 82);
        expect(profil.dailyStepsGoal, 9500);
      },
    );
  }
}
