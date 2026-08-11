// Die BMI-Zonenlabels standen doppelt kodiert im Quelltext: irgendwann hat
// ein Editor profile_charts.dart als Latin-1 gelesen und als UTF-8
// zurueckgeschrieben, aus dem „Ü" wurde eine zweistellige Zeichenfolge. Der
// Nutzer sah das auf der Karte UND im Screenreader-Wert. Dieser Test haelt
// die Korrektur fest — faellt jemand beim Speichern in dieselbe Falle, wird er
// hier rot, nicht erst beim Nutzer. (Die kaputte Form steht bewusst NICHT in
// diesem Kommentar, sonst waere die Testdatei selbst ein Fundort.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/widgets/profile/profile_charts.dart';

// Seit der i18n-Migration (Paket 5, 2026-08-10) braucht `labelFor` ein
// [AppLocalizations] — hier fest `de` (die Erwartungswerte bleiben wortgleich
// zum Bestand, Regel 1 aus docs/I18N_PAKETE.md).
final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

void main() {
  test('BMI-Zonenlabels sind korrekt kodiert', () {
    expect(BMIGaugePainter.labelFor(17.0, _de), 'Untergewicht');
    expect(BMIGaugePainter.labelFor(22.0, _de), 'Normal');
    expect(BMIGaugePainter.labelFor(27.0, _de), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(31.0, _de), 'Adipös');
  });

  test('die Zonengrenzen liegen auf den WHO-Schwellen', () {
    expect(BMIGaugePainter.labelFor(18.49, _de), 'Untergewicht');
    expect(BMIGaugePainter.labelFor(18.5, _de), 'Normal');
    expect(BMIGaugePainter.labelFor(24.99, _de), 'Normal');
    expect(BMIGaugePainter.labelFor(25.0, _de), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(29.99, _de), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(30.0, _de), 'Adipös');
  });
}
