import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// BMI zones: the one mapping from a BMI to its name and state color, shared
/// by the zone chip on the body card and the legend of the BMI info sheet.
abstract final class BmiZones {
  /// Zone color of [v]. Under- and overweight share `warning`: the token
  /// contract offers only `warning` and `danger` as state colors.
  static Color colorFor(AppTokens t, double v) {
    if (!v.isFinite) return t.ink2;
    if (v < 18.5) return t.warning;
    if (v < 25.0) return t.accent;
    if (v < 30.0) return t.warning;
    return t.danger;
  }

  static String labelFor(double v, AppLocalizations l10n) {
    if (v < 18.5) return l10n.profileBmiZoneUnder;
    if (v < 25.0) return l10n.profileBmiZoneNormal;
    if (v < 30.0) return l10n.profileBmiZoneOver;
    return l10n.profileBmiZoneObese;
  }
}
