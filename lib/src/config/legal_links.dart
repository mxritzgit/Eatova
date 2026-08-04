/// Zentrale, app-weite Rechts-Links (DSGVO Art. 13 / App-Store-Pflicht).
///
/// Single source of truth fuer die Datenschutzerklaerung, damit Auth-Screen,
/// Profil und Settings exakt dieselbe URL verlinken. Aenderungen passieren
/// nur hier — kein hartkodierter Uri mehr verstreut im Code.
library;

/// Datenschutzerklaerung (im oeffentlichen Repo gepflegt, MIT-Lizenz).
const String kPrivacyUrl =
    'https://github.com/mxritzgit/eatova/blob/main/PRIVACY.md';

// Hinweis: Eine separate Nutzungsbedingungen-URL existiert noch nicht.
// Sobald `TERMS.md` o.ae. veroeffentlicht ist, hier `kTermsUrl` ergaenzen
// und in Auth/Profil/Settings analog zu `kPrivacyUrl` verlinken.
