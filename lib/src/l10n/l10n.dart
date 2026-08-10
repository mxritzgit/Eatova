import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// Zugriff im build(): `context.l10n.settingsLanguageTitle` — dasselbe
/// Muster wie `context.t` fuer die Design-Tokens.
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
