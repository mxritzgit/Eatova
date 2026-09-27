import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';

/// Locale-aware decimal for labels and field prefills: "12,5" under `de`,
/// "12.5" under `en`. Whole numbers drop the fraction ("2", not "2.0").
///
/// No digit grouping on purpose: every numeric field in the app parses by
/// swapping ',' for '.', so a prefilled "1.000" would read back as 1.
String formatDecimal(
  num value,
  AppLocalizations l10n, {
  int maxFractionDigits = 2,
}) {
  final pattern = maxFractionDigits <= 0
      ? '0'
      : '0.${'#' * maxFractionDigits}';
  return NumberFormat(pattern, l10n.localeName).format(value);
}
