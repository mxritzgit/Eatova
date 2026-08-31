import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthException, AuthRetryableFetchException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/account_change_messages.dart';
import 'package:eatova/src/screens/settings/account_change_sheets.dart';

import '../support/harness.dart';

// H2 (Review 2026-08-31) — EIN Klassifizierer statt zweier.
//
// `auth_code_screen.dart` bekam mit P4-02/P4-03 die typisierte Neufassung
// (GoTrue-Codes zuerst, kein blankes `invalid`, Mail-Kontingent getrennt von
// der Drossel pro Anfrage). Das Duplikat in `account_change_messages.dart`, an
// dem die fuenf Aufrufstellen der Passwort- und E-Mail-Wechsel haengen, fuhr
// weiter die alten reinen Textregeln:
//
//  * `raw.contains('invalid') || raw.contains('otp')` machte aus
//    „Invalid API key" und „Signups not allowed for otp" ein „Der Code stimmt
//    nicht oder ist abgelaufen" — eine Diagnose ueber etwas, das der Server
//    nie geprueft hat.
//  * `over_email_send_rate_limit` (echte Wartezeit ~30 Minuten) las sich als
//    „Bitte warte einen Moment".
//
// Die Regeln stehen jetzt EINMAL in [classifyAuthError]; jede Oberflaeche
// waehlt ihre eigenen Saetze zur [AuthErrorKind].

const String _alteAdresse = 'alt@eatova.de';
const String _neueAdresse = 'neu@eatova.de';
const String _code = '12345678';

/// GoTrues Antwort, wenn der Anon-Key nicht stimmt — ueber den eingegebenen
/// Code sagt sie nichts.
AuthApiException _kaputterAnonKey() =>
    const AuthApiException('Invalid API key', statusCode: '401');

/// GoTrues Antwort, wenn das PROJEKT die OTP-Anmeldung aus hat.
AuthApiException _otpAbgeschaltet() => const AuthApiException(
      'Signups not allowed for otp',
      code: 'otp_disabled',
    );

/// Das stuendliche Mail-Kontingent (`rate_limit_email_sent` = 2/h) ist leer.
AuthApiException _kontingentErschoepft() => const AuthApiException(
      'Email rate limit exceeded',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );

/// Ein echter GoTrue-5xx (siehe h_auth_server_fault_test.dart).
AuthRetryableFetchException _gotrue502() => AuthRetryableFetchException(
      message: '{"code":502,"message":"Bad Gateway"}',
      statusCode: '502',
    );

/// Ein Repository, dessen vier Aenderungs-Aufrufe einzeln scheitern koennen.
class _StellbaresRepo extends InMemoryAuthRepository {
  _StellbaresRepo({super.initialUser});

  Object? startEmailFehler;
  Object? confirmEmailFehler;
  Object? startPasswordFehler;
  Object? confirmPasswordFehler;

  @override
  Future<void> startEmailChange(String newEmail) async {
    final fehler = startEmailFehler;
    if (fehler != null) throw fehler;
    await super.startEmailChange(newEmail);
  }

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    final fehler = confirmEmailFehler;
    if (fehler != null) throw fehler;
    await super.confirmEmailChange(email: email, code: code);
  }

  @override
  Future<void> startPasswordChange() async {
    final fehler = startPasswordFehler;
    if (fehler != null) throw fehler;
    await super.startPasswordChange();
  }

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {
    final fehler = confirmPasswordFehler;
    if (fehler != null) throw fehler;
    await super.confirmPasswordChange(code: code, newPassword: newPassword);
  }
}

Future<_StellbaresRepo> _oeffneMailSheet(WidgetTester tester) async {
  pinPhoneViewport(tester);
  final repo = _StellbaresRepo(
    initialUser: const EatovaUser(id: 'u1', email: _alteAdresse),
  );
  addTearDown(repo.dispose);
  final context = await pumpLocalizedContext(tester, const SizedBox.shrink());
  unawaited(showEmailChangeSheet(
    context,
    authRepository: repo,
    currentEmail: _alteAdresse,
  ));
  await tester.pumpAndSettle();
  return repo;
}

Future<_StellbaresRepo> _oeffnePasswortSheet(WidgetTester tester) async {
  pinPhoneViewport(tester);
  final repo = _StellbaresRepo(
    initialUser: const EatovaUser(id: 'u1', email: _alteAdresse),
  );
  addTearDown(repo.dispose);
  final context = await pumpLocalizedContext(tester, const SizedBox.shrink());
  unawaited(showPasswordChangeSheet(
    context,
    authRepository: repo,
    email: _alteAdresse,
  ));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _schreibe(
  WidgetTester tester,
  String schluessel,
  String text,
) async {
  await tester.enterText(find.byKey(ValueKey<String>(schluessel)), text);
  await tester.pumpAndSettle();
}

Future<void> _tippe(WidgetTester tester, String beschriftung) async {
  final ziel = find.text(beschriftung);
  await tester.ensureVisible(ziel);
  await tester.pumpAndSettle();
  await tester.tap(ziel);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('H2 — „Der Code stimmt nicht" nur, wenn es um den Code geht', () {
    test('ein kaputter Anon-Key ist kein abgelaufener Code', () {
      // Das blosse `invalid` im Textzweig fing „Invalid API key" mit ab: der
      // Nutzer las, sein Code sei falsch, und tippte einen richtigen Code
      // beliebig oft gegen einen Konfigurationsfehler.
      final meldung = accountChangeErrorMessage(_kaputterAnonKey());

      expect(meldung, isNot(kAccountCodeRejected()),
          reason: 'ueber den eingegebenen Code sagt diese Antwort nichts');
      expect(meldung, deL10n.commonGenericRetryError,
          reason: 'unknown ist die ehrliche Einstufung');
      expect(classifyAuthError(_kaputterAnonKey()).kind, AuthErrorKind.unknown);
    });

    test('ein abgeschaltetes OTP ist kein abgelaufener Code', () {
      // `raw.contains('otp')` traf „Signups not allowed for otp" — ein
      // Server-Konfigurationsfehler, den kein neuer Code heilt.
      final meldung = accountChangeErrorMessage(_otpAbgeschaltet());

      expect(meldung, isNot(kAccountCodeRejected()));
      expect(meldung, deL10n.commonGenericRetryError);
    });

    test('REGRESSION: ein wirklich abgelehnter Code bleibt abgelehnt', () {
      // Die Gegenprobe: der Textfallback greift weiter fuer Antworten OHNE
      // Code, und GoTrues eigene Codes zaehlen typisiert.
      expect(
        accountChangeErrorMessage(
            const AuthException('Token has expired or is invalid')),
        kAccountCodeRejected(),
      );
      expect(
        accountChangeErrorMessage(const AuthApiException(
          'Token has expired or is invalid',
          statusCode: '403',
          code: 'otp_expired',
        )),
        kAccountCodeRejected(),
      );
      expect(
        accountChangeErrorMessage(const AuthApiException(
          'Reauthentication token is invalid',
          statusCode: '403',
          code: 'reauthentication_not_valid',
        )),
        kAccountCodeRejected(),
        reason: 'der Nonce IST der Code dieses Flows',
      );
      expect(
        accountChangeErrorMessage(
            const AuthException('Reauthentication token is invalid')),
        kAccountCodeRejected(),
        reason: 'auch ohne Code-Feld, ueber den Textfallback',
      );
    });
  });

  group('H2 — das Mail-Kontingent nennt die richtige Groessenordnung', () {
    test('over_email_send_rate_limit ist kein „Moment"', () {
      final meldung = accountChangeErrorMessage(_kontingentErschoepft());

      expect(meldung, deL10n.settingsAccountQuotaExhausted);
      expect(meldung, isNot(deL10n.settingsAccountRateLimited),
          reason: '„Bitte warte einen Moment" war um Faktor 30 daneben');
      expect(classifyAuthError(_kontingentErschoepft()).kind,
          AuthErrorKind.quotaExhausted);
    });

    test('der Text nennt die halbe Stunde in beiden Sprachen', () {
      // Dekliniert: "in einer guten halben Stunde". Die Grundform kommt im
      // Satz nicht vor - der Punkt ist die Groessenordnung, nicht der Kasus.
      expect(deL10n.settingsAccountQuotaExhausted, contains('halben Stunde'));
      expect(enL10n.settingsAccountQuotaExhausted, contains('half an hour'));
    });

    test('auch die Textform ohne GoTrue-Code landet im Kontingent', () {
      expect(
        accountChangeErrorMessage(
            const AuthException('email rate limit exceeded')),
        deL10n.settingsAccountQuotaExhausted,
      );
    });

    test(
        'REGRESSION: die Drossel PRO ANFRAGE bleibt beim „Moment"',
        () {
      // Sie nennt Sekunden, nicht Halbstunden — der alte Satz stimmt hier.
      final meldung = accountChangeErrorMessage(const AuthException(
          'For security purposes, you can only request this after 51 seconds'));

      expect(meldung, deL10n.settingsAccountRateLimited);
      expect(meldung, startsWith('Zu viele Versuche'));
      expect(
        classifyAuthError(const AuthException(
                'For security purposes, you can only request this after 51 '
                'seconds'))
            .retryAfter,
        const Duration(seconds: 51),
        reason: 'die Sekundenzahl geht nicht mehr verloren',
      );
    });
  });

  group('H2 — der 5xx erreicht auch die Einstellungen', () {
    test('ein GoTrue-502 heisst nicht mehr „Offline"', () {
      final meldung = accountChangeErrorMessage(_gotrue502());

      expect(meldung, deL10n.authErrorServerFault);
      expect(meldung, isNot(deL10n.settingsAccountOfflineError));
    });

    test('REGRESSION: echte Netzlosigkeit bleibt „Offline"', () {
      expect(
        accountChangeErrorMessage(const SocketException('no route to host')),
        deL10n.settingsAccountOfflineError,
      );
    });
  });

  group('H2 — die typisierten GoTrue-Codes werden gelesen', () {
    test('same_password kommt ohne Textraten an', () {
      expect(
        accountChangeErrorMessage(const AuthApiException(
          'Neues Passwort abgelehnt',
          statusCode: '422',
          code: 'same_password',
        )),
        deL10n.settingsAccountPasswordSameAsOld,
        reason: 'die alte Regel brauchte das englische Wort „different"',
      );
    });

    test('weak_password kommt ohne Textraten an', () {
      expect(
        accountChangeErrorMessage(const AuthApiException(
          'Passwort abgelehnt',
          statusCode: '422',
          code: 'weak_password',
        )),
        deL10n.settingsAccountPasswordWeak,
      );
    });

    test('email_exists als CODE bestaetigt keine fremde Kontoexistenz', () {
      expect(
        accountChangeErrorMessage(const AuthApiException(
          'Something went wrong',
          statusCode: '422',
          code: 'email_exists',
        )),
        deL10n.settingsAccountEmailNotAvailable,
      );
    });

    test('REGRESSION: die Textformen der Enumeration greifen weiter', () {
      for (final roh in const <String>[
        'A user with this email address has already been registered',
        'User already registered',
        'Email address already in use',
      ]) {
        expect(accountChangeErrorMessage(AuthException(roh)),
            deL10n.settingsAccountEmailNotAvailable,
            reason: roh);
      }
    });

    test('REGRESSION: die uebrigen Textregeln stehen unveraendert', () {
      expect(
        accountChangeErrorMessage(
            const AuthException('Password should be at least 6 characters')),
        deL10n.settingsAccountPasswordWeak,
      );
      expect(
        accountChangeErrorMessage(const AuthException(
            'Unable to validate email address: invalid format')),
        deL10n.settingsAccountEmailLooksInvalid,
      );
      // Kein Roh-Text in der Oberflaeche.
      const roh = 'unexpected_failure at https://xyz.supabase.co/auth/v1/user';
      final meldung = accountChangeErrorMessage(const AuthException(roh));
      expect(meldung, deL10n.commonGenericRetryError);
      expect(meldung.contains('supabase'), isFalse);
    });
  });

  group('H2 — die Aufrufstellen der Sheets bekommen die Neufassung', () {
    testWidgets('E-Mail anfordern: ein kaputter Anon-Key ist kein Code-Fehler',
        (tester) async {
      final repo = await _oeffneMailSheet(tester);
      repo.startEmailFehler = _kaputterAnonKey();

      await _schreibe(tester, 'email-change-new-address', _neueAdresse);
      await _tippe(tester, deL10n.settingsEmailChangeRequestCta);

      expect(find.text(deL10n.settingsAccountCodeRejected), findsNothing,
          reason: 'der Server hat hier noch gar keinen Code geprueft');
      expect(find.text(deL10n.commonGenericRetryError), findsOneWidget);
    });

    testWidgets('E-Mail bestaetigen: ebenso auf dem Code-Schritt',
        (tester) async {
      final repo = await _oeffneMailSheet(tester);

      await _schreibe(tester, 'email-change-new-address', _neueAdresse);
      await _tippe(tester, deL10n.settingsEmailChangeRequestCta);
      expect(find.byKey(const ValueKey('email-change-code-old')),
          findsOneWidget);

      repo.confirmEmailFehler = _kaputterAnonKey();
      await _schreibe(tester, 'email-change-code-old', _code);
      await _schreibe(tester, 'email-change-code-new', _code);
      await _tippe(tester, deL10n.settingsEmailChangeSubmitCta);

      expect(find.text(deL10n.settingsAccountCodeRejected), findsNothing);
      expect(find.text(deL10n.commonGenericRetryError), findsOneWidget);
    });

    testWidgets('Passwort anfordern: das Kontingent nennt die halbe Stunde',
        (tester) async {
      final repo = await _oeffnePasswortSheet(tester);
      repo.startPasswordFehler = _kontingentErschoepft();

      await _tippe(tester, deL10n.settingsPasswordChangeRequestCta);

      expect(find.byKey(const ValueKey('password-change-error')),
          findsOneWidget);
      expect(find.text(deL10n.settingsAccountQuotaExhausted), findsOneWidget);
      expect(find.text(deL10n.settingsAccountRateLimited), findsNothing,
          reason: '„einen Moment" schickt den Nutzer in eine Klopfschleife');
    });

    testWidgets('Passwort setzen: ein 502 ist kein Offline-Hinweis',
        (tester) async {
      final repo = await _oeffnePasswortSheet(tester);

      await _tippe(tester, deL10n.settingsPasswordChangeRequestCta);
      repo.confirmPasswordFehler = _gotrue502();

      await _schreibe(tester, 'password-change-code', _code);
      await _schreibe(tester, 'password-change-new', 'geheim99');
      await _schreibe(tester, 'password-change-repeat', 'geheim99');
      await _tippe(tester, deL10n.settingsPasswordChangeSubmitCta);

      expect(find.text(deL10n.authErrorServerFault), findsOneWidget);
      expect(find.text(deL10n.settingsAccountOfflineError), findsNothing,
          reason: 'die Verbindung hat die 502 gerade transportiert');
    });
  });
}
