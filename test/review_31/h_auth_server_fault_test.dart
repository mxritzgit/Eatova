import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthRetryableFetchException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore;
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/harness.dart';

// H1 (Review 2026-08-31) — ein Serverfehler ist keine fehlende Verbindung.
//
// gotrue 2.27.2 verpackt in `fetch.dart` JEDE Antwort mit Status >= 500 in eine
// `AuthRetryableFetchException` — genau den Typ, den es auch wirft, wenn die
// Anfrage das Gerät nie verlassen hat. Weil `isNetworkSyncError` diesen Typ
// (für die Sync-Pfade richtig) als Netzfehler zählt, lasen Nutzer bei einem
// 502/503 von GoTrue „Offline — der Server war nicht erreichbar. Bitte prüf
// deine Internetverbindung" — obwohl der Server geantwortet hatte und die
// Verbindung dieselbe Antwort transportiert hat.
//
// Unterschieden wird am `statusCode`: nur der Antwort-Pfad füllt ihn
// (`response.statusCode.toString()`), die beiden Transport-Pfade lassen ihn
// null. Die Altsuite modellierte einen 500er als
// `AuthApiException(statusCode: '500')` — eine Form, die gotrue für 5xx NIE
// erzeugt; der echte Pfad war damit ungetestet.

const String _adresse = 'opfer@example.com';
const String _code = '12345678';

/// Ein echter GoTrue-5xx, so wie `fetch.dart:_handleError` ihn wirft: Body als
/// Message, Status gesetzt.
AuthRetryableFetchException _gotrue502() => AuthRetryableFetchException(
      message: '{"code":502,"message":"Bad Gateway"}',
      statusCode: '502',
    );

/// Und der Transport-Pfad desselben Typs: kein Status, weil es keine Antwort
/// gab (Funkloch, CORS, abgebrochener Socket).
AuthRetryableFetchException _gotrueTransport() => AuthRetryableFetchException(
      message: 'ClientException: Failed host lookup: ci.invalid',
    );

/// Wirft [fehler] auf jedem Versand UND jedem Verify.
class _WerfendesAuthRepository extends InMemoryAuthRepository {
  _WerfendesAuthRepository(this.fehler);

  Object? fehler;
  int sendeVersuche = 0;

  @override
  Future<void> resendSignupCode(String email) async {
    sendeVersuche++;
    final aktuell = fehler;
    if (aktuell != null) throw aktuell;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    sendeVersuche++;
    final aktuell = fehler;
    if (aktuell != null) throw aktuell;
    await super.sendPasswordReset(email);
  }

  @override
  Future<void> verifySignupCode({
    required String email,
    required String code,
  }) async {
    final aktuell = fehler;
    if (aktuell != null) throw aktuell;
  }
}

/// Wirft [fehler] auf dem E-Mail-Login — der Pfad, den `_friendlyError` des
/// Login-Screens einstuft.
class _WerfendesLoginRepository extends InMemoryAuthRepository {
  _WerfendesLoginRepository(this.fehler);

  final Object fehler;

  @override
  Future<void> signIn({required String email, required String password}) async {
    throw fehler;
  }
}

Finder get _resendLink => find.byKey(const ValueKey('code-resend'));
Finder get _primaerKnopf => find.byKey(const ValueKey('code-primary'));
Finder get _codeFeld => find.byKey(const ValueKey('code-field'));

Future<void> _pumpCode(WidgetTester tester, AuthRepository repo) async {
  await pumpLocalized(
    tester,
    AuthCodeScreen(
      authRepository: repo,
      flow: AuthCodeFlow.signup,
      initialEmail: _adresse,
      throttleStore: InMemoryKeyValueStore(),
    ),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

/// Der Countdown läuft auf einem `Timer.periodic`; ohne Abbau meldet
/// flutter_test einen offenen Timer.
Future<void> _entsorgeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _pumpLogin(WidgetTester tester, Object fehler) async {
  pinIphone14Pro(tester);
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: _WerfendesLoginRepository(fehler)),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')), 'du@eatova.de');
  await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')), 'geheim99');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  group('H1 — die Praedikate trennen 5xx von echter Netzlosigkeit', () {
    test('ein GoTrue-5xx ist ein SERVER-Fehler, kein Netzfehler', () {
      expect(isAuthServerFaultError(_gotrue502()), isTrue,
          reason: 'gotrue setzt bei >= 500 den statusCode aus der Antwort');
      expect(isAuthNetworkError(_gotrue502()), isFalse,
          reason: 'die Verbindung hat die Antwort gerade transportiert');
    });

    test('derselbe Typ OHNE Status bleibt ein Netzfehler', () {
      // Der Transport-Pfad in fetch.dart: `AuthRetryableFetchException(message:
      // e.toString())` — ohne statusCode, weil es keine Antwort gab.
      expect(isAuthServerFaultError(_gotrueTransport()), isFalse);
      expect(isAuthNetworkError(_gotrueTransport()), isTrue);
    });

    test('die uebrigen Netzfehlertypen bleiben unangetastet', () {
      for (final fehler in <Object>[
        const SocketException('Failed host lookup: ci.invalid'),
        ClientException('Connection closed before full header'),
        TimeoutException('timeout', const Duration(seconds: 8)),
      ]) {
        expect(isAuthNetworkError(fehler), isTrue, reason: '$fehler');
        expect(isAuthServerFaultError(fehler), isFalse, reason: '$fehler');
      }
    });

    test('eine Drossel (429) ist kein Serverfehler', () {
      // Sonst würde der 5xx-Zweig die Drossel-Einstufung schlucken, samt der
      // Sekundenzahl, die der Server nennt.
      expect(
        isAuthServerFaultError(const AuthApiException(
          'Email rate limit exceeded',
          statusCode: '429',
          code: 'over_email_send_rate_limit',
        )),
        isFalse,
      );
    });

    test('ein Nicht-Auth-Fehler laeuft nicht in den 5xx-Zweig', () {
      expect(isAuthServerFaultError(StateError('bug')), isFalse);
      expect(isAuthServerFaultError('nur ein String'), isFalse);
    });
  });

  group('H1 — der Code-Screen nennt den Server, nicht die Leitung', () {
    testWidgets('ein echter GoTrue-502 sagt nicht mehr „Offline"',
        (tester) async {
      final repo = _WerfendesAuthRepository(_gotrue502());

      await _pumpCode(tester, repo);
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();

      expect(find.text(deL10n.authErrorServerFault), findsOneWidget,
          reason: 'der Server hat geantwortet — nur schlecht');
      expect(find.text(deL10n.authCodeOfflineError), findsNothing,
          reason: 'die Schuld lag scheinbar beim Nutzer, obwohl seine '
              'Verbindung die 502 gerade transportiert hat');
      await _entsorgeScreen(tester);
    });

    testWidgets('ein 503 beim Code-Pruefen verbrennt keinen Fehlversuch',
        (tester) async {
      // Der Server hat den Code nie geprüft, also darf er nicht gegen die
      // 5er-Sperre zählen — und der Text muss den Serverfehler nennen.
      final repo = _WerfendesAuthRepository(AuthRetryableFetchException(
        message: 'upstream connect error',
        statusCode: '503',
      ));

      await _pumpCode(tester, repo);
      for (var versuch = 1; versuch <= 5; versuch++) {
        await tester.enterText(_codeFeld, _code);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
      }

      expect(find.text(deL10n.authErrorServerFault), findsOneWidget);
      expect(find.text(deL10n.authCodeTooManyAttempts), findsNothing);
      expect(tester.widget<TextField>(_codeFeld).enabled, isTrue);
      await _entsorgeScreen(tester);
    });

    testWidgets('ein 5xx sperrt den Versand nicht', (tester) async {
      // `_sperrDauer` gibt für serverFault Duration.zero: ein Ausfall auf der
      // Serverseite darf keinen Countdown auf dem Gerät auslösen.
      final repo = _WerfendesAuthRepository(_gotrue502());

      await _pumpCode(tester, repo);
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.sendeVersuche, 1);

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.sendeVersuche, 2,
          reason: 'kein lokaler Riegel — der naechste Versuch darf sofort raus');
      expect(find.text(deL10n.authCodeResendCta), findsOneWidget,
          reason: 'kein Countdown-Label');
      await _entsorgeScreen(tester);
    });

    for (final fall in <({String name, Object fehler})>[
      (
        name: 'SocketException (Funkloch)',
        fehler: const SocketException('Failed host lookup: ci.invalid'),
      ),
      (
        name: 'AuthRetryableFetchException ohne Status (Transport)',
        fehler: _gotrueTransport(),
      ),
    ]) {
      testWidgets('REGRESSION: ${fall.name} bleibt „Offline"', (tester) async {
        // Die Gegenprobe zum Fix: der 5xx-Zweig darf die echte Netzlosigkeit
        // nicht mitnehmen.
        final repo = _WerfendesAuthRepository(fall.fehler);

        await _pumpCode(tester, repo);
        await tester.tap(_resendLink);
        await tester.pumpAndSettle();

        expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
        expect(find.text(deL10n.authErrorServerFault), findsNothing);
        await _entsorgeScreen(tester);
      });
    }
  });

  group('H1 — derselbe Satz auf dem Login-Screen', () {
    testWidgets('ein echter GoTrue-502 beim Login nennt den Server',
        (tester) async {
      await _pumpLogin(tester, _gotrue502());

      expect(find.text(deL10n.authErrorServerFault), findsOneWidget);
      expect(find.text(deL10n.authCodeOfflineError), findsNothing);
      expect(find.text(deL10n.authErrorGeneric), findsNothing);
    });

    testWidgets('REGRESSION: ein Funkloch beim Login bleibt „Offline"',
        (tester) async {
      await _pumpLogin(tester, const SocketException('Failed host lookup'));

      expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
      expect(find.text(deL10n.authErrorServerFault), findsNothing);
    });

    testWidgets(
        'REGRESSION: der Transport-Wrapper beim Login bleibt „Offline"',
        (tester) async {
      await _pumpLogin(tester, _gotrueTransport());

      expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
      expect(find.text(deL10n.authErrorServerFault), findsNothing);
    });
  });

  group('H1 — die SYNC-Pfade stufen unveraendert ein', () {
    // Der Fix darf `isNetworkSyncError` nicht anfassen: dort kostet ein falsch
    // als Netzfehler eingestufter 5xx Wiederholungen, keine Daten, und genau
    // das ist gewollt (ein 5xx will wiederholt werden). Wer H1 stattdessen
    // durch Streichen von `AuthRetryableFetchException` in Zeile 28 "loest",
    // faellt hier durch.
    test('ein GoTrue-5xx bleibt fuer die Outbox ein Netzfehler', () {
      expect(isNetworkSyncError(_gotrue502()), isTrue);
      expect(classifyOutboxFailure(_gotrue502(), 0), OutboxVerdict.retryFree);
      expect(classifyOutboxFailure(_gotrue502(), 999), OutboxVerdict.retryFree,
          reason: 'ein Netzfehler darf das Budget nie verbrennen');
    });

    test('die Warteschlangen-Hinweise sagen weiter „offline"', () {
      expect(queuedSyncHint(_gotrue502()), deL10n.commonQueuedOfflineHint);
      expect(queuedDelivery(_gotrue502()), SyncDelivery.queuedOffline);
      expect(directSyncErrorMessage(_gotrue502()),
          deL10n.commonSyncErrorOffline);
    });

    test('und der Transport-Wrapper natuerlich auch', () {
      expect(isNetworkSyncError(_gotrueTransport()), isTrue);
      expect(
          classifyOutboxFailure(_gotrueTransport(), 999),
          OutboxVerdict.retryFree);
      expect(queuedSyncHint(_gotrueTransport()), deL10n.commonQueuedOfflineHint);
    });
  });
}
