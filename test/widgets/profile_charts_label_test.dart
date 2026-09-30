// Guards against double-encoded BMI zone labels (an editor once read
// profile_charts.dart as Latin-1 and wrote it back as UTF-8). The broken form
// is deliberately not spelled out here, or this file would be a source of it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/widgets/profile/profile_charts.dart';

// `labelFor` needs an [AppLocalizations] since the i18n migration; pinned to
// `de` so the expectations stay verbatim (docs/I18N_PAKETE.md, rule 1).
final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

void main() {
  test('BMI-Zonenlabels sind korrekt kodiert', () {
    expect(BmiZones.labelFor(17.0, _de), 'Untergewicht');
    expect(BmiZones.labelFor(22.0, _de), 'Normal');
    expect(BmiZones.labelFor(27.0, _de), 'Übergewicht');
    expect(BmiZones.labelFor(31.0, _de), 'Adipös');
  });

  test('die Zonengrenzen liegen auf den WHO-Schwellen', () {
    expect(BmiZones.labelFor(18.49, _de), 'Untergewicht');
    expect(BmiZones.labelFor(18.5, _de), 'Normal');
    expect(BmiZones.labelFor(24.99, _de), 'Normal');
    expect(BmiZones.labelFor(25.0, _de), 'Übergewicht');
    expect(BmiZones.labelFor(29.99, _de), 'Übergewicht');
    expect(BmiZones.labelFor(30.0, _de), 'Adipös');
  });
}
