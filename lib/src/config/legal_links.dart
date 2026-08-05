/// Zentrale, app-weite Rechts-Links (DSGVO Art. 13 / § 5 DDG / App-Store-Pflicht).
///
/// Single source of truth fuer alle Rechtsseiten, damit Auth-Screen, Profil
/// und Settings exakt dieselben URLs verlinken. Aenderungen passieren nur
/// hier — kein hartkodierter Uri mehr verstreut im Code.
///
/// Die Seiten liegen seit 2026-08 auf der eigenen Domain (deutsch, gepflegt
/// in FitPilotTestSite bzw. /var/www/eatova.de); eatova.de/privacy leitet
/// fuer die Store-Formulare per 301 auf /datenschutz um.
library;

/// Datenschutzerklaerung (deutsch, deckt Website + App ab).
const String kPrivacyUrl = 'https://eatova.de/datenschutz';

/// Allgemeine Geschaeftsbedingungen / Nutzungsbedingungen.
const String kTermsUrl = 'https://eatova.de/agb';

/// Impressum (Anbieterkennzeichnung nach § 5 DDG).
const String kImprintUrl = 'https://eatova.de/impressum';
