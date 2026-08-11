import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// Zugriff im build(): `context.l10n.settingsLanguageTitle` — dasselbe
/// Muster wie `context.t` fuer die Design-Tokens.
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Deutsches Sprachpaket OHNE BuildContext — Default fuer Stellen, die l10n
/// brauchen, aber keinen Context haben oder als Test-API kontextfrei
/// aufgerufen werden (DESIGN_REFACTOR §6): pure Funktionen wie
/// `targetBmiHintText`/`accountChangeErrorMessage`/`queuedSyncHint`, und
/// context-freie Store-Schichten wie [HomeStore] (ARCH-4: haelt nie einen
/// BuildContext) oder [CoachChatService]. Solange niemand ausdruecklich ein
/// anderes [AppLocalizations] uebergibt (`context.l10n` an der Stelle, wo ein
/// Context existiert), bleibt jeder Bestandstext byte-identisch zu vorher —
/// deshalb bleiben bestehende Tests, die diese Funktionen kontextfrei rufen,
/// unveraendert gruen.
final AppLocalizations deL10n = lookupAppLocalizations(const Locale('de'));
