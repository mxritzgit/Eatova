part of 'profile_widgets.dart';

/// Der Gedankenstrich, den die Profil-Seite ueberall dort zeigt, wo eine Zahl
/// fehlt oder unbrauchbar ist. Bewusst U+2013 wie im Rest der App.
const String _keineZahl = '–';

/// Kilogramm mit der Locale der aktiven Sprache: hoechstens eine
/// Nachkommastelle, eine glatte Zahl steht ohne Nachkommastelle da.
///
/// Eine Quelle fuer alle kg-Zahlen des Profils — vorher stand im Hero
/// „78,4 kg" und in der Delta-Pille daneben „-2.6 kg".
///
/// Seit der i18n-Migration (Paket 5, 2026-08-10) ueber `package:intl`s
/// `NumberFormat('0.#', ...)`: die Vorrundung auf eine Nachkommastelle
/// bleibt (byte-identisches Rundungsverhalten zum Bestand), nur der
/// Dezimaltrenner kommt jetzt aus den CLDR-Daten der aktiven Sprache
/// (`de`: Komma, `en`: Punkt) statt fest verdrahtet zu sein.
String formatKgDe(double kg, AppLocalizations l10n) {
  if (!kg.isFinite) return _keineZahl;
  final gerundet = (kg * 10).round() / 10;
  return NumberFormat('0.#', l10n.localeName).format(gerundet);
}

/// BMI mit der Locale der aktiven Sprache: immer genau eine
/// Nachkommastelle (ein glattes „22" laese sich wie eine gerundete
/// Schaetzung).
String formatBmiDe(double bmi, AppLocalizations l10n) {
  if (!bmi.isFinite) return _keineZahl;
  return NumberFormat('0.0', l10n.localeName).format(bmi);
}
