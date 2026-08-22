// The profile screen mixed two number notations: the hero used the localized
// form while the delta pill came straight from toStringAsFixed. formatKgDe and
// formatBmiDe are now the only source for kg and BMI numbers on that page.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

// formatKgDe/formatBmiDe need an [AppLocalizations]; pinned to `de` here so the
// expectations stay verbatim (rule 1 in docs/I18N_PAKETE.md).
final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));
final AppLocalizations _en = lookupAppLocalizations(const Locale('en'));

void main() {
  group('formatKgDe', () {
    test('ganze Kilogramm stehen ohne Nachkommastelle', () {
      expect(formatKgDe(78, _de), '78');
      expect(formatKgDe(78.0, _de), '78');
      expect(formatKgDe(0, _de), '0');
    });

    test('Zehntel bekommen ein Komma, keinen Punkt', () {
      expect(formatKgDe(78.4, _de), '78,4');
      expect(formatKgDe(78.42, _de), '78,4');
      expect(formatKgDe(78.45, _de), '78,5');
    });

    test('das Vorzeichen bleibt erhalten', () {
      expect(formatKgDe(-2.6, _de), '-2,6');
      expect(formatKgDe(-2.0, _de), '-2');
    });

    test('Nicht-Zahlen ergeben keinen „NaN"-Text', () {
      expect(formatKgDe(double.nan, _de), '–');
      expect(formatKgDe(double.infinity, _de), '–');
    });

    test('unter en steht ein Punkt statt des Kommas', () {
      expect(formatKgDe(78.4, _en), '78.4');
      expect(formatKgDe(-2.6, _en), '-2.6');
    });
  });

  group('formatBmiDe', () {
    test('BMI behaelt immer genau eine Nachkommastelle', () {
      expect(formatBmiDe(22.44, _de), '22,4');
      expect(formatBmiDe(22.0, _de), '22,0');
      expect(formatBmiDe(30.55, _de), '30,6');
    });

    test('Nicht-Zahlen ergeben keinen „NaN"-Text', () {
      expect(formatBmiDe(double.nan, _de), '–');
    });

    test('unter en steht ein Punkt statt des Kommas', () {
      expect(formatBmiDe(22.44, _en), '22.4');
    });
  });
}
