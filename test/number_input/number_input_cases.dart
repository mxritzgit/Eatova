// Shared cases for the numeric-field suites in this folder.
//
// Every fixed field group is typed with the same four inputs in German and
// English: "3,5", "3.5", "1.000" and "1.000,5". A decimal field reads the first
// two as 3.5, refuses "1.000" as ambiguous (1 or 1000) and reads "1.000,5" as
// 1000.5. A whole-number field refuses both decimals with a hint instead of
// turning "3,5" into 35.

import 'package:flutter/widgets.dart';

import 'package:eatova/src/l10n/l10n.dart';

const List<Locale> eingabeSprachen = <Locale>[Locale('de'), Locale('en')];

AppLocalizations l10nFuer(Locale locale) => lookupAppLocalizations(locale);

/// The hint for "1.000" (or "1,000"): both readings, neither guessed.
String mehrdeutigHinweis(AppLocalizations l10n) =>
    l10n.numberInputAmbiguous('1', '1000');

/// The hint for a decimal in a whole-number field.
String ganzzahlHinweis(AppLocalizations l10n) => l10n.numberInputWholeNumber;

/// The four inputs and what a WHOLE-NUMBER field must say about each.
List<(String, String)> ganzzahlFaelle(AppLocalizations l10n) =>
    <(String, String)>[
      ('3,5', ganzzahlHinweis(l10n)),
      ('3.5', ganzzahlHinweis(l10n)),
      ('1.000', mehrdeutigHinweis(l10n)),
      ('1.000,5', ganzzahlHinweis(l10n)),
    ];
