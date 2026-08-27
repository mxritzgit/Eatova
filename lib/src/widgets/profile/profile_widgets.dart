/// Profile widgets — one library assembled from several `part` files.
///
/// Purely mechanical split; imports and library-private `_` visibility are
/// unchanged. Colour comes from `context.t` ([AppTokens]) and type from
/// [AppType]; `app_colors.dart` is fully retired here.
library;

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/model_limits.dart';
import '../../models/user_profile.dart';
import '../../models/weight_log.dart';
import '../../services/health_service.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';
import 'profile_charts.dart';

part 'profile_format.dart';
part 'profile_widgets_hero.dart';
part 'profile_widgets_body.dart';
part 'profile_widgets_goals.dart';
part 'profile_widgets_stats.dart';
part 'profile_widgets_actions.dart';

/// Short locale-aware day.month label (`de` "28.8.", `en` "8/28") for the
/// weight captions and the health timestamp (F7-09). `DateFormat.Md('de')`
/// needs the CLDR symbols loaded once, hence the guarded init — the load is
/// synchronous from a bundled table.
bool _dateSymbolsReady = false;
String formatShortDate(DateTime d, AppLocalizations l10n) {
  if (!_dateSymbolsReady) {
    initializeDateFormatting();
    _dateSymbolsReady = true;
  }
  return DateFormat.Md(l10n.localeName).format(d);
}
