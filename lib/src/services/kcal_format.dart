import 'package:intl/intl.dart';

/// Calories with the active language's thousands separator: `de` `2200` ->
/// `2.200`, `en` `2200` -> `2,200` (i18n-design.md §5).
///
/// [localeName] is the ACTIVE app language (`AppLocalizations.localeName`), not
/// the device default — callers pass it through, no locale lookup here.
String formatThousands(int n, String localeName) =>
    NumberFormat.decimalPattern(localeName).format(n);
