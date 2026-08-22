import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// Access inside build(): `context.l10n.settingsLanguageTitle` — same pattern
/// as `context.t` for the design tokens.
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// German bundle WITHOUT a BuildContext — default for pure functions and
/// context-free store layers such as [HomeStore] (ARCH-4: never holds a
/// BuildContext) or [CoachChatService]. Callers with a context pass
/// `context.l10n` instead.
final AppLocalizations deL10n = lookupAppLocalizations(const Locale('de'));

/// English bundle WITHOUT a BuildContext (mirror of [deL10n]). Needed where
/// both languages must be comparable context-free, e.g.
/// `FitnessRecipe._resolvePlaceholder` matches German and English placeholder
/// values regardless of the active display language.
final AppLocalizations enL10n = lookupAppLocalizations(const Locale('en'));
