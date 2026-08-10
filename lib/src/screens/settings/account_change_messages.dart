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

/// Laenge des E-Mail-Codes (GoTrue `mailer_otp_length` = 6).
const int kAccountCodeLength = 6;

const String kAccountEmailInvalid = 'Bitte gib eine gültige E-Mail ein.';
const String kAccountEmailUnchanged =
    'Das ist bereits deine Adresse — hier gibt es nichts zu ändern.';
const String kAccountCodeInvalid = 'Der Code hat 6 Ziffern.';
const String kAccountPasswordTooShort =
    'Das Passwort braucht mindestens 8 Zeichen.';
const String kAccountPasswordMismatch =
    'Die beiden Passwörter stimmen nicht überein.';

/// Der haeufigste Serverfehler dieser Flows: Code falsch getippt oder die
/// 10 Minuten (mailer_otp_exp) sind um.
const String kAccountCodeRejected =
    'Der Code stimmt nicht oder ist abgelaufen. Fordere einen neuen an.';

/// Dieselbe grosszuegige Pruefung wie in `auth_screen.dart`: nur die Form, die
/// Existenz kann ohnehin nur der Server beantworten. Strenger zu sein hiesse,
/// gueltige Adressen abzulehnen (`+`-Aliase, neue TLDs, IDN).
bool isPlausibleAccountEmail(String value) {
  final adresse = value.trim();
  return adresse.contains('@') && adresse.contains('.');
}

/// Genau sechs Ziffern. Der Formatter am Feld filtert bereits Nicht-Ziffern —
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
String accountChangeErrorMessage(Object error) {
  // Netz zuerst, und am TYP statt am Text: offline gibt es gar keine
  // Server-Meldung, die man lesen koennte.
  if (isNetworkSyncError(error)) {
    return 'Offline — die Änderung ließ sich nicht abschicken. Bitte versuch '
        'es mit Internetverbindung erneut.';
  }

  final raw = error.toString().toLowerCase();

  // GoTrue drosselt Mailversand und Reauth-Anfragen hart („For security
  // purposes, you can only request this after 51 seconds").
  if (raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes')) {
    return 'Zu viele Versuche in kurzer Zeit. Bitte warte einen Moment und '
        'versuch es dann erneut.';
  }

  if (raw.contains('already registered') ||
      raw.contains('already been registered') ||
      raw.contains('already in use') ||
      raw.contains('already exists') ||
      raw.contains('email_exists')) {
    return 'Diese E-Mail-Adresse wird bereits verwendet.';
  }

  if (raw.contains('email') &&
      (raw.contains('invalid') || raw.contains('not valid'))) {
    return 'Diese E-Mail-Adresse sieht nicht gültig aus.';
  }

  if (raw.contains('password')) {
    if (raw.contains('different')) {
      return 'Das neue Passwort muss sich vom bisherigen unterscheiden.';
    }
    if (raw.contains('weak') ||
        raw.contains('at least') ||
        raw.contains('short') ||
        raw.contains('characters')) {
      return 'Dieses Passwort ist zu schwach. Nimm ein längeres oder '
          'ungewöhnlicheres.';
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
    return kAccountCodeRejected;
  }

  return 'Das hat gerade nicht geklappt. Bitte versuch es später erneut.';
}
