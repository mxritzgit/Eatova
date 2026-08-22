part of 'profile_widgets.dart';

/// Dash shown wherever the profile page has no usable number. U+2013, as
/// elsewhere in the app.
const String _keineZahl = '–';

/// Kilograms in the active locale: at most one decimal, dropped when the
/// value is round. Single source for every kg number in the profile.
///
/// Pre-rounds to one decimal (unchanged rounding behavior) and takes the
/// decimal separator from CLDR instead of hardcoding it.
String formatKgDe(double kg, AppLocalizations l10n) {
  if (!kg.isFinite) return _keineZahl;
  final gerundet = (kg * 10).round() / 10;
  return NumberFormat('0.#', l10n.localeName).format(gerundet);
}

/// BMI in the active locale: always exactly one decimal (a bare "22" would
/// read like a rough estimate).
String formatBmiDe(double bmi, AppLocalizations l10n) {
  if (!bmi.isFinite) return _keineZahl;
  return NumberFormat('0.0', l10n.localeName).format(bmi);
}
