/// Kalorien mit deutschem Tausenderpunkt: `2200` -> `2.200`, `-1234` ->
/// `-1.234`.
///
/// Bewusst ohne `intl`: die App bringt kein Locale-Paket mit, und das Format
/// ist zeichengenau von Tests festgenagelt (u. a. `'2.200 kcal'`).
///
/// Diese Funktion hatte nach dem Design-Refactor 2026-08-09 drei
/// zeichengleiche Kopien (Food-Karte, Heute-Texte, die alte
/// Kalorienuebersicht). Zwei Flaechen, die dieselbe Zahl verschieden
/// formatieren, sind ein Fehler, den niemand meldet — deshalb eine Heimat.
String formatThousands(int n) {
  final negativ = n < 0;
  final ziffern = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < ziffern.length; i++) {
    final vonHinten = ziffern.length - i;
    buf.write(ziffern[i]);
    if (vonHinten > 1 && vonHinten % 3 == 1) buf.write('.');
  }
  return negativ ? '-$buf' : buf.toString();
}
