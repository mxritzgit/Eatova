import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// The weigh-in sheet takes decimals ("72,5"). "1.000" read as 1 kg and only the
// range check caught it, with a message about 20–400 kg that did not say why.

Future<List<double>> _oeffne(WidgetTester tester, Locale locale) async {
  final gewogen = <double>[];
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    WeightCard(
      profile: const UserProfile(),
      log: WeightLog(
        entries: <WeightLogEntry>[
          WeightLogEntry(timestamp: DateTime(2026, 1, 1), weightKg: 80),
        ],
      ),
      onLogWeight: gewogen.add,
    ),
    locale: locale,
    padding: const EdgeInsets.all(20),
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('profile-log-weight')));
  await tester.pumpAndSettle();
  return gewogen;
}

Future<void> _tippe(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('profile-weight-input')),
    text,
  );
  await tester.pump();
}

VoidCallback? _speichern(WidgetTester tester) => tester
    .widget<PrimaryActionButton>(
      find.byKey(const ValueKey('profile-weight-save')),
    )
    .onTap;

String? _fehler(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('profile-weight-error'));
  return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);

    testWidgets('Wiegen [${locale.languageCode}]: 1.000 wird nicht geraten',
        (tester) async {
      final gewogen = await _oeffne(tester, locale);

      for (final eingabe in const <String>['3,5', '3.5']) {
        await _tippe(tester, eingabe);
        expect(_fehler(tester), l10n.profileWeightInputRangeError(20, 400),
            reason: '$eingabe kg liest sich als 3,5 und liegt unter 20 kg');
      }

      await _tippe(tester, '1.000');
      expect(_fehler(tester), mehrdeutigHinweis(l10n));
      expect(_speichern(tester), isNull);

      await _tippe(tester, '1.000,5');
      expect(_fehler(tester), l10n.profileWeightInputRangeError(20, 400),
          reason: 'eindeutig 1000,5 kg');

      await _tippe(tester, '100,500');
      expect(_fehler(tester), l10n.numberInputAmbiguous(
        locale.languageCode == 'de' ? '100,5' : '100.5',
        '100500',
      ));

      await _tippe(tester, '72,5');
      expect(_fehler(tester), isNull);
      await tester.tap(find.byKey(const ValueKey('profile-weight-save')));
      await tester.pumpAndSettle();
      expect(gewogen, <double>[72.5]);
    });
  }
}
