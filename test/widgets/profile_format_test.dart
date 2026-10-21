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
  test('formatKgDe: hoechstens eine Nachkommastelle, Komma nach Sprache', () {
    for (final (kg, l10n, text) in <(double, AppLocalizations, String)>[
      // Whole kilograms carry no decimal.
      (78, _de, '78'),
      (0, _de, '0'),
      // Tenths get a comma, not a point, rounded half up.
      (78.4, _de, '78,4'),
      (78.42, _de, '78,4'),
      (78.45, _de, '78,5'),
      // The sign survives.
      (-2.6, _de, '-2,6'),
      (-2.0, _de, '-2'),
      // English uses a point.
      (78.4, _en, '78.4'),
      (-2.6, _en, '-2.6'),
      // No "NaN" on screen.
      (double.nan, _de, '–'),
      (double.infinity, _de, '–'),
    ]) {
      expect(formatKgDe(kg, l10n), text, reason: '$kg ${l10n.localeName}');
    }
  });

  test('formatBmiDe: immer genau eine Nachkommastelle', () {
    for (final (bmi, l10n, text) in <(double, AppLocalizations, String)>[
      (22.44, _de, '22,4'),
      (22.0, _de, '22,0'),
      (30.55, _de, '30,6'),
      (22.44, _en, '22.4'),
      (double.nan, _de, '–'),
    ]) {
      expect(formatBmiDe(bmi, l10n), text, reason: '$bmi ${l10n.localeName}');
    }
  });
}
