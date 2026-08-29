import 'dart:io' show HandshakeException, SocketException;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthException, AuthRetryableFetchException;

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
/// paths of the screen. Setting [fehler] to null lets the next call through,
/// which is how the "try anyway" escape gets a success to report.
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
  Future<void> verifySignupCode({
    required String email,
    required String code,
  }) async {
    final aktuell = fehler;
    if (aktuell != null) throw aktuell;
  }
}

/// GoTrue's answer once the mail quota (`rate_limit_email_sent` = 2/h) is out.
AuthApiException _kontingentErschoepft() => const AuthApiException(
      'Email rate limit exceeded',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );

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
Finder get _ausweichLink => find.byKey(const ValueKey('code-send-anyway'));

/// Taps "request a new code" once and settles.
Future<void> _tippeNeuAnfordern(WidgetTester tester) async {
  await tester.tap(_resendLink);
  await tester.pumpAndSettle();
}

/// Taps the "try anyway" escape once and settles.
Future<void> _tippeTrotzdem(WidgetTester tester) async {
  await tester.tap(_ausweichLink);
  await tester.pumpAndSettle();
}

/// Enters [code] and taps "check code".
Future<void> _pruefeCode(WidgetTester tester, [String code = _code]) async {
  await tester.enterText(_codeFeld, code);
  await tester.tap(_primaerKnopf);
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
        'das Mail-Kontingent behauptet keine "etwa eine Minute" mehr',
        (tester) async {
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeQuotaExhausted), findsOneWidget,
            reason: 'das Kontingent fuellt sich in Halbstunden, nicht in '
                'Minuten');
        expect(find.text(deL10n.authCodeRateLimited), findsNothing,
            reason: '"etwa eine Minute" war um Faktor 30 falsch');
        expect(find.text(deL10n.authCodeResendCountdownMinutes(30)),
            findsOneWidget,
            reason: 'der Countdown nennt Minuten statt 1800 s');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'waehrend der Kontingent-Sperre erreicht kein BLINDER Tap den Server '
        '(Klopfschleife)', (tester) async {
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);

        // Vorher: 60-s-Countdown -> Link wieder aktiv -> naechste echte
        // Anfrage. Bis zu 60 Mail-Anfragen pro Stunde.
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1,
            reason: 'die Sperre haelt den Tap lokal auf');
        expect(find.text(deL10n.authCodeThrottleWaitMinutes(30)), findsOneWidget,
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

        // P4-03c: dieselbe Minuten-Schwelle wie der Link darunter. Vorher
        // stand "noch 180 s gesperrt" ueber "Neuen Code in 3 min anfordern".
        expect(find.text(deL10n.authCodeRateLimitedMinutes(3)), findsOneWidget,
            reason: 'der Server nannte 180 s — die Zahl war da und wurde '
                'weggeworfen');
        expect(find.text(deL10n.authCodeRateLimitedSeconds(180)), findsNothing,
            reason: 'ab 120 s spricht der Link Minuten, die Meldung muss '
                'mitziehen');
        expect(find.text(deL10n.authCodeRateLimited), findsNothing);
        expect(
            find.text(deL10n.authCodeResendCountdownMinutes(3)), findsOneWidget,
            reason: 'der eigene Riegel uebernimmt die Server-Dauer');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'unter der Minuten-Schwelle bleibt es bei Sekunden (P4-03c kippt '
        'nicht ins Gegenteil)', (tester) async {
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'For security purposes, you can only request this after 90 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeRateLimitedSeconds(90)), findsOneWidget);
        expect(find.text(deL10n.authCodeResendCountdown(90)), findsOneWidget);
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

    testWidgets('die Kontingent-Sperre ueberlebt den Rebuild des Screens',
        (tester) async {
      // Ohne Persistenz waere die Klopfschleife durch Verlassen und
      // Zurueckkehren wieder offen.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());
      final speicher = InMemoryKeyValueStore();

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, speicher);
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        await _entsorgeScreen(tester);

        await _pumpCode(tester, repo, speicher);
        expect(find.text(deL10n.authCodeResendCountdownMinutes(30)),
            findsOneWidget,
            reason: 'die Dauer haengt an der Adresse, nicht an der Instanz');
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        await _entsorgeScreen(tester);
      });
    });
  });

  group('P4-03b — die Kontingent-Sperre hat einen Ausweg', () {
    testWidgets(
        'der Riegel dauert eine halbe Stunde, nicht eine ganze (Token-Bucket)',
        (tester) async {
      // rate_limit_email_sent = 2/h ist ein Bucket mit Burst 2 und Nachfuellen
      // 2/h: der ERSTE Token ist nach ~1800 s zurueck. Eine volle Stunde
      // sperrte doppelt so lange wie noetig.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeResendCountdownMinutes(30)),
            findsOneWidget);
        expect(find.text(deL10n.authCodeResendCountdownMinutes(60)),
            findsNothing,
            reason: 'eine volle Stunde war der Bucket-VOLL-Zeitpunkt, nicht '
                'der naechste Token');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('„Trotzdem versuchen" erreicht den Server wirklich',
        (tester) async {
      // Der eine Pfad, auf dem der P4-03-Fix die Lage verschlechtert hatte:
      // wer die ersten zwei Mails real nicht bekommt (Spam-Filter,
      // Zustellverzoegerung), sass ohne Handlungsmoeglichkeit fest.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        expect(_ausweichLink, findsOneWidget,
            reason: 'die halbe Stunde ist unsere SCHAETZUNG — der Server ist '
                'die einzige Instanz, die es wirklich weiss');

        await _tippeTrotzdem(tester);

        expect(repo.sendeVersuche, 2,
            reason: 'der Ausweg geht wirklich raus, sonst waere er Theater');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('ein geglueckter Ausweg-Versuch loest die Sperre auf',
        (tester) async {
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        // Der Bucket hat wieder einen Token: der naechste Versand klappt.
        repo.fehler = null;
        await _tippeTrotzdem(tester);

        expect(find.text(deL10n.authCodeResent), findsOneWidget);
        expect(find.text(deL10n.authCodeResendCountdown(60)), findsOneWidget,
            reason: 'nach einer echten Mail gilt wieder der normale Riegel');
        expect(_ausweichLink, findsNothing);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'der Ausweg gilt einmal pro Sperre — auch nach Verlassen und '
        'Zurueckkehren', (tester) async {
      // Sonst waere die Klopfschleife ueber die Navigation wieder offen: raus,
      // rein, neuer Ausweg, echte Mail-Anfrage.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());
      final speicher = InMemoryKeyValueStore();

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, speicher);
        await _tippeNeuAnfordern(tester);
        await _tippeTrotzdem(tester);
        expect(repo.sendeVersuche, 2);
        expect(_ausweichLink, findsNothing,
            reason: 'verbraucht');
        expect(find.text(deL10n.authCodeSendAnywayUsed), findsOneWidget,
            reason: 'statt eines toten Links steht da, warum');
        await _entsorgeScreen(tester);

        await _pumpCode(tester, repo, speicher);
        expect(_ausweichLink, findsNothing,
            reason: 'der verbrauchte Ausweg haengt an der Adresse, nicht an '
                'der Screen-Instanz');
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 2);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'eine vom Server GENANNTE Wartezeit bekommt keinen Ausweg',
        (tester) async {
      // 180 s hat der Server selbst gesagt — dagegen anzuklopfen bringt nichts
      // und kostet nur eine Anfrage.
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'For security purposes, you can only request this after 180 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(_ausweichLink, findsNothing);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('ohne laufende Sperre gibt es keinen Ausweg-Link',
        (tester) async {
      final repo = _WerfendesAuthRepository(null);

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());

        expect(_ausweichLink, findsNothing);
        await _entsorgeScreen(tester);
      });
    });
  });

  group('P4-02c — „Der Code stimmt nicht" nur, wenn es um den Code geht', () {
    testWidgets(
        'ein falsch konfigurierter Anon-Key ist kein falscher Code und zaehlt '
        'keinen Fehlversuch', (tester) async {
      // `AuthApiException('Invalid API key')` fiel ueber das blosse Textstueck
      // `invalid` in den Code-Zweig: der Nutzer las "Der Code stimmt nicht",
      // und jeder Versuch zaehlte gegen die 5er-Sperre, die nur ein NEUER Code
      // wieder loest — bei kaputtem Key also nie.
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'Invalid API key',
        statusCode: '401',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());

        for (var versuch = 1; versuch <= 5; versuch++) {
          await _pruefeCode(tester);
        }

        expect(find.text(deL10n.authCodeErrorRejected), findsNothing,
            reason: 'ueber den Code sagt dieser Fehler nichts');
        expect(find.text(deL10n.authCodeTooManyAttempts), findsNothing);
        expect(tester.widget<TextField>(_codeFeld).enabled, isTrue,
            reason: 'die Eingabe darf durch einen Server-Konfigfehler nicht '
                'zugehen');
        expect(find.text(deL10n.authErrorGeneric), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('GoTrues eigener Code otp_expired zaehlt sehr wohl',
        (tester) async {
      // Der Gegenbeweis zur Zeile darueber: derselbe Weg, den
      // auth_screen.dart fuer invalid_credentials schon geht.
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'Token has expired or is invalid',
        statusCode: '403',
        code: 'otp_expired',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _pruefeCode(tester);

        expect(find.text(deL10n.authCodeErrorRejected), findsOneWidget);

        for (var versuch = 2; versuch <= 5; versuch++) {
          await _pruefeCode(tester);
        }
        expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget,
            reason: 'fuenf wirklich abgelehnte Codes sperren weiterhin');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('eine Antwort ohne Code faellt weiter auf den Text zurueck',
        (tester) async {
      // Aeltere GoTrue-Antworten tragen keinen `code`; der Textzweig bleibt,
      // nur ohne das blosse `invalid`.
      final repo = _WerfendesAuthRepository(
          const AuthException('Token has expired or is invalid'));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _pruefeCode(tester);

        expect(find.text(deL10n.authCodeErrorRejected), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });
  });
}
