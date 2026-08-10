part of 'profile_widgets.dart';

/// Der Gedankenstrich, den die Profil-Seite ueberall dort zeigt, wo eine Zahl
/// fehlt oder unbrauchbar ist. Bewusst U+2013 wie im Rest der App.
const String _keineZahl = '–';

/// Kilogramm deutsch: Komma statt Punkt, hoechstens eine Nachkommastelle,
/// und eine glatte Zahl steht ohne „,0" da.
///
/// Eine Quelle fuer alle kg-Zahlen des Profils — vorher stand im Hero
/// „78,4 kg" und in der Delta-Pille daneben „-2.6 kg".
String formatKgDe(double kg) {
  if (!kg.isFinite) return _keineZahl;
  final gerundet = (kg * 10).round() / 10;
  if (gerundet == gerundet.roundToDouble()) return gerundet.toStringAsFixed(0);
  return gerundet.toStringAsFixed(1).replaceAll('.', ',');
}

/// BMI deutsch: immer genau eine Nachkommastelle (ein glattes „22" laese sich
/// wie eine gerundete Schaetzung), Komma statt Punkt.
String formatBmiDe(double bmi) {
  if (!bmi.isFinite) return _keineZahl;
  return bmi.toStringAsFixed(1).replaceAll('.', ',');
}
