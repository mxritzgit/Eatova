import '../../l10n/l10n.dart';
import '../../services/sync_error_messages.dart' show isNetworkSyncError;

// ---------------------------------------------------------------------------
// Texte und Pruefungen der beiden Konto-Aenderungs-Flows (2026-08-10).
//
// Bewusst eine EIGENE, widgetfreie Datei: die Fehler-Uebersetzung ist die
// sicherheitsrelevante Haelfte dieser Flows und laesst sich hier ohne
// Widget-Baum pruefen (`test/account_change_flows_test.dart`, Gruppe
// „accountChangeErrorMessage").
//
// GRUNDREGEL, wie in sync_error_messages.dart: NIE `error.toString()` in die
// UI. Ein `AuthException`-Text kann Projekt-URL, Endpunkt oder interne Codes
// tragen; er ist ausserdem englisch und fuer Nutzer unlesbar. Hier wird nur
// KLASSIFIZIERT und dann ein eigener deutscher Satz gezeigt. Die Roh-Exception
// bleibt dem Diagnose-Kanal vorbehalten.
// ---------------------------------------------------------------------------

/// Mindestlaenge fuers Passwort — zeichengleich mit `auth_screen.dart` und
/// `auth_code_screen.dart`. Drei verschiedene Grenzen in einer App waeren nur
/// verwirrend; die Zahl steht deshalb hier einmal und der Text unten wortgleich
/// zu dem, den der Login schon zeigt.
const int kAccountMinPasswordLength = 8;

/// Laenge des E-Mail-Codes (GoTrue `mailer_otp_length` = 8).
///
/// Seit 2026-08-18 acht statt sechs Stellen: /auth/v1/verify ist nur pro IP
/// rate-limitiert und ein falscher Versuch verbraucht den Code nicht — bei
/// sechs Stellen erreichte ein verteilter Angreifer zweistellige Trefferquoten
/// pro 10-Minuten-Fenster, bei acht sinkt das um Faktor 100. Wer den Wert
/// aendert, MUSS die Server-Config nachziehen (supabase/AUTH_EMAIL_OTP.md).
const int kAccountCodeLength = 8;

// Alle sechs Funktionen unten nehmen ein OPTIONALES [AppLocalizations] mit
// Deutsch-Default ([deL10n]) statt eines Pflichtparameters: dieselbe
// Konstanten-Signatur (`kAccountEmailInvalid` -> `kAccountEmailInvalid()`)
// bleibt so als Test-API nutzbar (`test/account_change_flows_test.dart` ruft
// sie weiterhin kontextfrei), waehrend `account_change_sheets.dart` (hat
// `context.l10n`) die aktive Sprache durchreicht.
String kAccountEmailInvalid([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountEmailInvalid;
String kAccountEmailUnchanged([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountEmailUnchanged;
String kAccountCodeInvalid([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountCodeInvalid;
String kAccountPasswordTooShort([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountPasswordTooShort;
String kAccountPasswordMismatch([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountPasswordMismatch;

/// Der haeufigste Serverfehler dieser Flows: Code falsch getippt oder die
/// 10 Minuten (mailer_otp_exp) sind um.
String kAccountCodeRejected([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).settingsAccountCodeRejected;

/// Dieselbe grosszuegige Pruefung wie in `auth_screen.dart`: nur die Form, die
/// Existenz kann ohnehin nur der Server beantworten. Strenger zu sein hiesse,
/// gueltige Adressen abzulehnen (`+`-Aliase, neue TLDs, IDN).
bool isPlausibleAccountEmail(String value) {
  final adresse = value.trim();
  return adresse.contains('@') && adresse.contains('.');
}

/// Genau [kAccountCodeLength] Ziffern. Der Formatter am Feld filtert bereits Nicht-Ziffern —
/// diese Pruefung faengt den zu kurzen Rest ab, bevor er als sicherer
/// Serverfehler zurueckkommt.
bool isAccountCode(String value) =>
    RegExp('^\\d{$kAccountCodeLength}\$').hasMatch(value.trim());

/// Uebersetzt einen Fehler aus [AuthRepository.startPasswordChange] &
/// Geschwistern in einen deutschen Satz ohne technische Details.
///
/// Die Reihenfolge der Zweige ist Absicht — mehrere GoTrue-Meldungen tragen
/// dasselbe Reizwort. „email_address_invalid" enthaelt `invalid` wie der
/// abgelaufene Code, und „Password should be at least 6 characters" enthaelt
/// `password` wie „New password should be different". Spezifisch vor generisch.
String accountChangeErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  // Netz zuerst, und am TYP statt am Text: offline gibt es gar keine
  // Server-Meldung, die man lesen koennte.
  if (isNetworkSyncError(error)) {
    return t.settingsAccountOfflineError;
  }

  final raw = error.toString().toLowerCase();

  // GoTrue drosselt Mailversand und Reauth-Anfragen hart („For security
  // purposes, you can only request this after 51 seconds").
  if (raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes')) {
    return t.settingsAccountRateLimited;
  }

  // Konto-Enumeration (Audit 2026-08-14): Der Server verraet hier, dass die
  // Zieladresse belegt ist. Frueher gab die App das woertlich weiter („Diese
  // E-Mail-Adresse wird bereits verwendet") — damit konnte JEDER angemeldete
  // Nutzer fremde Adressen durchprobieren und bekam die Kontoexistenz
  // bestaetigt. Das widerspricht der Hauslinie, die der Reset-Pfad verteidigt
  // (auth_repository.dart, `sendPasswordReset`). Der Satz behauptet jetzt
  // nichts mehr, sondern nennt nur den Ausweg, den es in BEIDEN Faellen gibt.
  if (raw.contains('already registered') ||
      raw.contains('already been registered') ||
      raw.contains('already in use') ||
      raw.contains('already exists') ||
      raw.contains('email_exists')) {
    return t.settingsAccountEmailNotAvailable;
  }

  if (raw.contains('email') &&
      (raw.contains('invalid') || raw.contains('not valid'))) {
    return t.settingsAccountEmailLooksInvalid;
  }

  if (raw.contains('password')) {
    if (raw.contains('different')) {
      return t.settingsAccountPasswordSameAsOld;
    }
    if (raw.contains('weak') ||
        raw.contains('at least') ||
        raw.contains('short') ||
        raw.contains('characters')) {
      return t.settingsAccountPasswordWeak;
    }
    // „Password update requires reauthentication", „Invalid nonce" o. ae.
    // fallen absichtlich in den Code-Zweig darunter durch: fuer den Nutzer ist
    // das derselbe Sachverhalt — der Code hat nicht gezogen.
  }

  if (raw.contains('expired') ||
      raw.contains('invalid') ||
      raw.contains('nonce') ||
      raw.contains('reauth') ||
      raw.contains('otp')) {
    return kAccountCodeRejected(t);
  }

  return t.commonGenericRetryError;
}
