// Die BMI-Zonenlabels standen doppelt kodiert im Quelltext: irgendwann hat
// ein Editor profile_charts.dart als Latin-1 gelesen und als UTF-8
// zurueckgeschrieben, aus dem „Ü" wurde eine zweistellige Zeichenfolge. Der
// Nutzer sah das auf der Karte UND im Screenreader-Wert. Dieser Test haelt
// die Korrektur fest — faellt jemand beim Speichern in dieselbe Falle, wird er
// hier rot, nicht erst beim Nutzer. (Die kaputte Form steht bewusst NICHT in
// diesem Kommentar, sonst waere die Testdatei selbst ein Fundort.)

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/profile/profile_charts.dart';

void main() {
  test('BMI-Zonenlabels sind korrekt kodiert', () {
    expect(BMIGaugePainter.labelFor(17.0), 'Untergewicht');
    expect(BMIGaugePainter.labelFor(22.0), 'Normal');
    expect(BMIGaugePainter.labelFor(27.0), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(31.0), 'Adipös');
  });

  test('die Zonengrenzen liegen auf den WHO-Schwellen', () {
    expect(BMIGaugePainter.labelFor(18.49), 'Untergewicht');
    expect(BMIGaugePainter.labelFor(18.5), 'Normal');
    expect(BMIGaugePainter.labelFor(24.99), 'Normal');
    expect(BMIGaugePainter.labelFor(25.0), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(29.99), 'Übergewicht');
    expect(BMIGaugePainter.labelFor(30.0), 'Adipös');
  });
}
