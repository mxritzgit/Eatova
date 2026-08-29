import 'dart:io' show HandshakeException, SocketException;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthRetryableFetchException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore, KeyValueStore;

import 'support/harness.dart';

// Error classification of the code screen (Review 2026-08-29, P4-02 + P4-03).
//
// P4-02: the screen classified purely by SERVER TEXT FRAGMENTS. Offline there
// is no server text at all, so a dead radio cell produced "Das hat gerade nicht
// geklappt. Bitte nochmal versuchen." — the user blamed their code. A boot
// failure of the auth layer (AuthUnavailableException) got the same sentence,
// although only a restart helps and the login screen says exactly that. And
// "invalid certificate" fell into the `invalid` branch: "Der Code ist
// abgelaufen oder falsch".
//
// P4-03: GoTrue throttles the mail TWICE — per request ("you can only request
// this after 51 seconds") and per hour (rate_limit_email_sent = 2,
// supabase/AUTH_EMAIL_OTP.md). Both landed in the same bucket, the server's
// second count was thrown away, and the text always claimed "etwa eine
// Minute". With the hourly quota spent that is off by a factor of 60 and
// produced a knock loop: wait a minute, tap, same sentence, one real mail
// request each time, for up to an hour.
//
// The exceptions here are the REAL objects (SocketException, ClientException,
// AuthRetryableFetchException, AuthUnavailableException) — none of them
// appeared in any auth UI suite before.

const String _adresse = 'opfer@example.com';
const String _code = '12345678';
final DateTime _jetzt = DateTime(2026, 8, 29, 9, 30);

/// Throws [fehler] on every send AND every verify — one repository for both
/// paths of the screen.
class _WerfendesAuthRepository extends InMemoryAuthRepository {
  _WerfendesAuthRepository(this.fehler);

  final Object fehler;
  int sendeVersuche = 0;

  @override
  Future<void> resendSignupCode(String email) async {
    sendeVersuche++;
    throw fehler;
  }

  @override
  Future<void> verifySignupCode({
    required String email,
    required String code,
  }) async {
    throw fehler;
  }
}

Future<void> _pumpCode(
  WidgetTester tester,
  AuthRepository repo,
  KeyValueStore speicher,
) async {
  await pumpLocalized(
    tester,
    AuthCodeScreen(
      authRepository: repo,
      flow: AuthCodeFlow.signup,
      initialEmail: _adresse,
      throttleStore: speicher,
    ),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

/// The countdown runs on a `Timer.periodic`; without a teardown flutter_test
/// reports a pending timer.
Future<void> _entsorgeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Finder get _resendLink => find.byKey(const ValueKey('code-resend'));
Finder get _primaerKnopf => find.byKey(const ValueKey('code-primary'));
Finder get _codeFeld => find.byKey(const ValueKey('code-field'));

/// Taps "request a new code" once and settles.
Future<void> _tippeNeuAnfordern(WidgetTester tester) async {
  await tester.tap(_resendLink);
  await tester.pumpAndSettle();
}

void main() {
  group('P4-02 — Netzfehler und tote Auth-Schicht heissen nicht mehr '
      '"nochmal versuchen"', () {
    for (final fall in <({String name, Object fehler})>[
      (
        name: 'SocketException (Funkloch)',
        fehler: const SocketException('Failed host lookup: ci.invalid'),
      ),
      (
        name: 'ClientException (Verbindung abgerissen)',
        fehler: ClientException('Connection closed before full header'),
      ),
      (
        name: 'AuthRetryableFetchException (GoTrue-Wrapper)',
        fehler: AuthRetryableFetchException(
            message: 'ClientException: Failed host lookup'),
      ),
    ]) {
      testWidgets('${fall.name} nennt die Verbindung statt der Generik',
          (tester) async {
        final repo = _WerfendesAuthRepository(fall.fehler);

        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpCode(tester, repo, InMemoryKeyValueStore());
          await _tippeNeuAnfordern(tester);

          expect(find.text(deL10n.authCodeOfflineError), findsOneWidget,
              reason: 'ohne Netz gibt es keinen Servertext — die Klassifikation '
                  'muss am TYP haengen');
          expect(find.text(deL10n.authErrorGeneric), findsNothing,
              reason: 'die Generik laesst den Nutzer seinen Code verdaechtigen');
          await _entsorgeScreen(tester);
        });
      });
    }

    testWidgets(
        'ein Netzfehler beim Code-Pruefen zaehlt keinen Fehlversuch und '
        'sperrt die Eingabe nicht', (tester) async {
      // The server never saw the code, so counting it toward the five-strike
      // lockout would lock a correct code out over a dead radio cell.
      final repo =
          _WerfendesAuthRepository(const SocketException('Failed host lookup'));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());

        for (var versuch = 1; versuch <= 5; versuch++) {
          await tester.enterText(_codeFeld, _code);
          await tester.tap(_primaerKnopf);
          await tester.pumpAndSettle();
        }

        expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
        expect(find.text(deL10n.authCodeTooManyAttempts), findsNothing,
            reason: 'nur ein wirklich ABGELEHNTER Code zaehlt');
        expect(tester.widget<TextField>(_codeFeld).enabled, isTrue);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'ein "invalid certificate" ist kein abgelaufener Code (P4-02)',
        (tester) async {
      // The `invalid` fragment caught the TLS error and claimed the code was
      // wrong — more misleading than the generic sentence it replaced.
      final repo = _WerfendesAuthRepository(
          const HandshakeException('Handshake error: invalid certificate'));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await tester.enterText(_codeFeld, _code);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();

        expect(find.text(deL10n.authCodeErrorRejected), findsNothing,
            reason: 'ein Zertifikatsfehler sagt nichts ueber den Code');
        expect(find.text(deL10n.authCodeOfflineError), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'eine tote Auth-Schicht sagt dasselbe wie der Login-Screen: neu '
        'starten', (tester) async {
      // auth_screen.dart:197 answers AuthUnavailableException with
      // authErrorUnavailable ("Bitte starte die App neu"). Der Code-Screen bot
      // "Bitte nochmal versuchen" an — eine Schleife ohne Ausweg.
      const repo = UnavailableAuthRepository('Supabase.instance warf beim Boot');

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authErrorUnavailable), findsOneWidget,
            reason: 'derselbe Satz wie auf dem Login-Screen');
        expect(find.text(deL10n.authErrorGeneric), findsNothing,
            reason: 'ein Neuversuch kann hier nie klappen');
        await _entsorgeScreen(tester);
      });
    });
  });

  group('P4-03 — die zwei Drosseln sind getrennt', () {
    testWidgets(
        'das Stunden-Kontingent behauptet keine "etwa eine Minute" mehr',
        (tester) async {
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'Email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeQuotaExhausted), findsOneWidget,
            reason: 'das Kontingent fuellt sich stuendlich, nicht minuetlich');
        expect(find.text(deL10n.authCodeRateLimited), findsNothing,
            reason: '"etwa eine Minute" war um Faktor 60 falsch');
        expect(find.text(deL10n.authCodeResendCountdownMinutes(60)),
            findsOneWidget,
            reason: 'der Countdown nennt Minuten statt 3600 s');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'waehrend der Stunden-Sperre erreicht kein weiterer Tap den Server '
        '(Klopfschleife)', (tester) async {
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'Email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);

        // Vorher: 60-s-Countdown -> Link wieder aktiv -> naechste echte
        // Anfrage. Bis zu 60 Mails-Anfragen pro Stunde.
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1,
            reason: 'die Sperre haelt den Tap lokal auf');
        expect(find.text(deL10n.authCodeThrottleWaitMinutes(60)), findsOneWidget,
            reason: 'und sagt dem Nutzer die echte Groessenordnung');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'die vom Server genannte Sekundenzahl wird benutzt statt verworfen',
        (tester) async {
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'For security purposes, you can only request this after 180 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeRateLimitedSeconds(180)), findsOneWidget,
            reason: 'der Server nannte 180 s — die Zahl war da und wurde '
                'weggeworfen');
        expect(find.text(deL10n.authCodeRateLimited), findsNothing);
        expect(
            find.text(deL10n.authCodeResendCountdownMinutes(3)), findsOneWidget,
            reason: 'der eigene Riegel uebernimmt die Server-Dauer');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'eine Server-Sekundenzahl unter dem eigenen Riegel hebt ihn nicht auf',
        (tester) async {
      // 51 s vom Server, 60 s eigener Cooldown: der Missbrauchsriegel bleibt
      // die Untergrenze, und der angezeigte Wert ist der, der wirklich gilt.
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'For security purposes, you can only request this after 51 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeRateLimitedSeconds(60)), findsOneWidget);
        expect(find.text(deL10n.authCodeResendCountdown(60)), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('die Stunden-Sperre ueberlebt den Rebuild des Screens',
        (tester) async {
      // Ohne Persistenz waere die Klopfschleife durch Verlassen und
      // Zurueckkehren wieder offen.
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'Email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));
      final speicher = InMemoryKeyValueStore();

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, speicher);
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        await _entsorgeScreen(tester);

        await _pumpCode(tester, repo, speicher);
        expect(find.text(deL10n.authCodeResendCountdownMinutes(60)),
            findsOneWidget,
            reason: 'die Dauer haengt an der Adresse, nicht an der Instanz');
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        await _entsorgeScreen(tester);
      });
    });
  });
}
