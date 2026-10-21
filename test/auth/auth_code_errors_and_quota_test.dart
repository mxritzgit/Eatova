import 'dart:io' show HandshakeException, SocketException;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthRetryableFetchException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore, KeyValueStore;

import '../support/harness.dart';

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
// this after 51 seconds") and per hour (rate_limit_email_sent, a PROJECT-wide
// bucket, supabase/AUTH_EMAIL_OTP.md). Both landed in the same bucket, the server's
// second count was thrown away, and the text always claimed "etwa eine
// Minute". With the hourly quota spent that is off by a factor of 60 and
// produced a knock loop: wait a minute, tap, same sentence, one real mail
// request each time, for up to an hour.
//
// The exceptions here are the REAL objects (SocketException,
// HandshakeException, AuthRetryableFetchException, AuthUnavailableException).
// The classification itself is unit-tested in
// h_account_change_classifier_test.dart and h_auth_server_fault_test.dart;
// this suite pins what the code SCREEN does with it: attempt counter, lock,
// throttle and its one escape.

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

  /// The recovery flow's send — the ADDRESS step goes through this one, so the
  /// same counter has to see it (P4-03b, Loch 2).
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

/// GoTrue's answer once the project-wide mail quota (`rate_limit_email_sent`)
/// is out.
AuthApiException _kontingentErschoepft() => const AuthApiException(
      'Email rate limit exceeded',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );

/// The signup flow starts at the CODE step; [flow] + [initialEmail] open the
/// recovery flow at the ADDRESS step instead.
Future<void> _pumpCode(
  WidgetTester tester,
  AuthRepository repo,
  KeyValueStore speicher, {
  AuthCodeFlow flow = AuthCodeFlow.signup,
  String initialEmail = _adresse,
}) async {
  await pumpLocalized(
    tester,
    AuthCodeScreen(
      authRepository: repo,
      flow: flow,
      initialEmail: initialEmail,
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
Finder get _emailFeld => find.byKey(const ValueKey('code-email-field'));
Finder get _ausweichLink => find.byKey(const ValueKey('code-send-anyway'));

/// GoTrue's answer when the project has OTP sign-in switched off — a SERVER
/// configuration fault, not a wrong code (P4-02d).
AuthApiException _otpAbgeschaltet() => const AuthApiException(
      'Signups not allowed for otp',
      code: 'otp_disabled',
    );

/// A plain server fault: no wait named, nothing to classify as a throttle.
///
/// The REAL shape (H1, 2026-08-31): gotrue 2.27.2 turns EVERY response with
/// status >= 500 into an `AuthRetryableFetchException` in `fetch.dart`
/// (`_handleError`) and never reaches the `AuthApiException` branch — the
/// `AuthApiException(statusCode: '500')` that stood here is a form gotrue
/// cannot produce, so the real 5xx path was untested. What the SENTENCE for it
/// has to be is pinned in `test/auth/h_auth_server_fault_test.dart`.
AuthRetryableFetchException _serverfehler500() => AuthRetryableFetchException(
      message: '{"code":500,"message":"Unexpected failure"}',
      statusCode: '500',
    );

/// Taps "request a new code" once and settles.
Future<void> _tippeNeuAnfordern(WidgetTester tester) async {
  await tester.tap(_resendLink);
  await tester.pumpAndSettle();
}

/// Taps the "try anyway" escape once and settles.
Future<void> _tippeTrotzdem(WidgetTester tester) async {
  await tester.ensureVisible(_ausweichLink);
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
  group('P4-02 — was nichts ueber den Code sagt, zaehlt nicht als Fehlversuch',
      () {
    testWidgets(
        'Netz-, Zertifikats- und Konfigurationsfehler zaehlen keinen '
        'Fehlversuch und sperren die Eingabe nicht', (tester) async {
      // The server never judged the code, so counting these toward the
      // five-strike lockout would lock a correct code out — and that lockout
      // only lifts with a NEW code, which a config fault never hands out.
      final faelle = <({String name, Object fehler, String meldung})>[
        // A dead radio cell: there is no server text at all.
        (
          name: 'Funkloch',
          fehler: const SocketException('Failed host lookup'),
          meldung: deL10n.authCodeOfflineError,
        ),
        // The bare `invalid` fragment used to read a TLS error as a wrong code.
        (
          name: 'invalid certificate',
          fehler:
              const HandshakeException('Handshake error: invalid certificate'),
          meldung: deL10n.authCodeOfflineError,
        ),
        // A misconfigured anon key fell into the code branch the same way
        // (P4-02c).
        (
          name: 'Invalid API key',
          fehler: const AuthApiException('Invalid API key', statusCode: '401'),
          meldung: deL10n.authErrorGeneric,
        ),
        // OTP sign-in switched off for the project (P4-02d): `unknown` is the
        // honest verdict, the code was never the problem.
        (
          name: 'otp_disabled',
          fehler: _otpAbgeschaltet(),
          meldung: deL10n.authErrorGeneric,
        ),
      ];

      for (final fall in faelle) {
        final repo = _WerfendesAuthRepository(fall.fehler);
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpCode(tester, repo, InMemoryKeyValueStore());

          for (var versuch = 1; versuch <= 5; versuch++) {
            await _pruefeCode(tester);
          }

          expect(find.text(fall.meldung), findsOneWidget, reason: fall.name);
          expect(find.text(deL10n.authCodeErrorRejected), findsNothing,
              reason: '${fall.name} sagt nichts ueber den Code');
          expect(find.text(deL10n.authCodeTooManyAttempts), findsNothing,
              reason: '${fall.name}: nur ein ABGELEHNTER Code zaehlt');
          expect(tester.widget<TextField>(_codeFeld).enabled, isTrue,
              reason: fall.name);
          await _entsorgeScreen(tester);
        });
      }
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
      // rate_limit_email_sent = 60/h is a PROJECT-wide bucket with burst 60
      // and a refill of 60/h: the first token is back after ~60 s, other
      // users compete for it. Three minutes is the conservative guess; the
      // half hour was the maths for the 2/h misconfiguration (review
      // 2026-09-01) and must not come back.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);

        expect(find.text(deL10n.authCodeQuotaExhausted), findsOneWidget,
            reason: 'das Kontingent ist projektweit und fuellt sich '
                'minutenweise — kein "Moment"');
        expect(find.text(deL10n.authCodeRateLimited), findsNothing,
            reason: '"etwa eine Minute" verschwieg die geteilte Warteschlange');
        expect(find.text(deL10n.authCodeResendCountdownMinutes(3)),
            findsOneWidget,
            reason: 'der Countdown nennt Minuten statt 180 s');
        expect(find.text(deL10n.authCodeResendCountdownMinutes(30)),
            findsNothing,
            reason: 'die halbe Stunde galt fuer 2 Mails/h projektweit');
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
        expect(find.text(deL10n.authCodeThrottleWaitMinutes(3)), findsOneWidget,
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
        // A wait the server NAMED is authoritative: knocking against it only
        // costs a request, so there is no "try anyway" (P4-03b).
        expect(_ausweichLink, findsNothing);
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

    // A server wait BELOW our own 60 s floor (51 s) keeps the floor:
    // auth_code_cooldown_test.dart, 'ein Rate-Limit-Fehler nennt die
    // Drosselung statt zum naechsten Versuch aufzufordern'.

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
        expect(find.text(deL10n.authCodeResendCountdownMinutes(3)),
            findsOneWidget,
            reason: 'die Dauer haengt an der Adresse, nicht an der Instanz');
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 1);
        await _entsorgeScreen(tester);
      });
    });
  });

  group('P4-03b — die Kontingent-Sperre hat einen Ausweg', () {
    // The few minutes are our ESTIMATE; only the server really knows. Whoever
    // did not get the first mails (spam filter, delivery delay) needs one way
    // out of the lock, or the P4-03 fix left them stuck.

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
  });

  group('P4-02c — „Der Code stimmt nicht" nur, wenn es um den Code geht', () {
    testWidgets('GoTrues eigener Code otp_expired zaehlt sehr wohl',
        (tester) async {
      // Der Gegenbeweis zu P4-02 oben: derselbe Weg, den auth_screen.dart fuer
      // invalid_credentials schon geht. Ohne ihn waere "zaehlt nie" auch
      // gruen.
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
  });

  group('P4-03b/Loch 1 — der Ausweg ist ein VERSUCH, kein Erfolgsversprechen',
      () {
    testWidgets(
        'PROBE-500 nachgestellt: waehrend der ganzen Sperre bleibt es bei ZWEI '
        'echten Sendeversuchen', (tester) async {
      // Gestempelt wurde bisher NUR bei drossel- oder kontingentfoermigen
      // Fehlern (_sperrDauer > 0). Ein 500er (oder ein Funkloch, derselbe
      // Zweig) liess `bypassUsed` auf false — der Link kam zurueck und jeder
      // Tap war eine echte Anfrage waehrend der laufenden Sperre. Die Messung
      // des Pruefers: sendeVersuche=6, linkNochDa=true.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        repo.fehler = _serverfehler500();

        // Der Pruefer hat einfach getippt, was da war — fuenf Runden lang.
        for (var runde = 1; runde <= 5; runde++) {
          if (_ausweichLink.evaluate().isNotEmpty) {
            await _tippeTrotzdem(tester);
          }
          await _tippeNeuAnfordern(tester);
        }

        expect(repo.sendeVersuche, 2,
            reason: 'die erste Anfrage plus der EINE Ausweg — gemessen waren '
                'sechs');
        expect(_ausweichLink, findsNothing, reason: 'gemessen: linkNochDa=true');
        expect(find.text(deL10n.authCodeSendAnywayUsed), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('ein gescheiterter Ausweg verlaengert die Sperre NICHT',
        (tester) async {
      // Deshalb setzt der Fix nur das Verbraucht-Flag statt neu zu stempeln:
      // ein Serverfehler ist nicht die Schuld des Nutzers, die Wartezeit bleibt
      // wo sie war.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());
      var jetzt = _jetzt;

      await withClock(Clock(() => jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        expect(find.text(deL10n.authCodeResendCountdownMinutes(3)),
            findsOneWidget);

        // 61 Sekunden spaeter: der Countdown steht bei 119 s (unter der
        // Minuten-Schwelle, deshalb wieder in Sekunden).
        jetzt = _jetzt.add(const Duration(seconds: 61));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.text(deL10n.authCodeResendCountdown(119)), findsOneWidget);

        repo.fehler = _serverfehler500();
        await _tippeTrotzdem(tester);

        expect(find.text(deL10n.authCodeResendCountdown(119)), findsOneWidget,
            reason: 'der Riegel endet weiter zum urspruenglichen Zeitpunkt');
        expect(find.text(deL10n.authCodeResendCountdownMinutes(3)), findsNothing,
            reason: 'neu zu stempeln haette den Nutzer fuer den Serverfehler '
                'bestraft');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'der Verbrauch haengt an der SPERRE — die naechste bringt einen neuen '
        'Ausweg mit', (tester) async {
      // Gegenprobe zu den Zeilen darueber: das Flag darf nicht einfach kleben
      // bleiben, sonst gaebe es pro Adresse genau einen Ausweg ueberhaupt.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());
      var jetzt = _jetzt;

      await withClock(Clock(() => jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore());
        await _tippeNeuAnfordern(tester);
        repo.fehler = _serverfehler500();
        await _tippeTrotzdem(tester);
        expect(repo.sendeVersuche, 2);
        expect(_ausweichLink, findsNothing);

        // Die paar Minuten sind um: der Riegel faellt.
        jetzt = _jetzt.add(const Duration(minutes: 4));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.text(deL10n.authCodeResendCta), findsOneWidget);

        // Die naechste Kontingent-Sperre bringt einen frischen Ausweg mit.
        repo.fehler = _kontingentErschoepft();
        await _tippeNeuAnfordern(tester);
        expect(repo.sendeVersuche, 3);
        expect(_ausweichLink, findsOneWidget,
            reason: 'eine neue Sperre ist eine neue Schaetzung — sonst gaebe '
                'es pro Adresse genau einen Ausweg ueberhaupt');
        await _entsorgeScreen(tester);
      });
    });
  });

  group('P4-03b/Loch 2 — auch der Adress-Schritt hat einen Ausweg', () {
    testWidgets(
        'laeuft der ERSTE Versand ins Kontingent, steht der Nutzer nicht ohne '
        'Handlungsmoeglichkeit da', (tester) async {
      // Gemessen: ausweichLink=0, resendLink=0. Der Screen bleibt im
      // Adress-Schritt, und der Ausweg hing an `_step == _Step.code`.
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore(),
            flow: AuthCodeFlow.recovery, initialEmail: '');
        await tester.enterText(_emailFeld, _adresse);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();

        expect(repo.sendeVersuche, 1);
        expect(_emailFeld, findsOneWidget,
            reason: 'der Screen bleibt im Adress-Schritt — der Code-Schritt '
                'wird nie erreicht');
        expect(find.text(deL10n.authCodeQuotaExhausted), findsOneWidget);
        expect(_ausweichLink, findsOneWidget,
            reason: 'sonst sitzt der Nutzer minutenlang fest — genau der '
                'Zustand, den P4-03b beseitigen sollte, nur einen Schritt '
                'frueher');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'der Ausweg im Adress-Schritt erreicht den Server und traegt weiter in '
        'den Code-Schritt', (tester) async {
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore(),
            flow: AuthCodeFlow.recovery, initialEmail: '');
        await tester.enterText(_emailFeld, _adresse);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();

        // Der Bucket hat wieder einen Token.
        repo.fehler = null;
        await _tippeTrotzdem(tester);

        expect(repo.sendeVersuche, 2,
            reason: 'der Ausweg geht wirklich raus, sonst waere er Theater');
        expect(repo.passwordResets, <String>[_adresse]);
        expect(_codeFeld, findsOneWidget,
            reason: 'ein geglueckter Versand fuehrt weiter — nicht bloss eine '
                'Meldung im Adress-Schritt');
        await _entsorgeScreen(tester);
      });
    });

    testWidgets('auch im Adress-Schritt gilt der Ausweg genau einmal',
        (tester) async {
      final repo = _WerfendesAuthRepository(_kontingentErschoepft());
      final speicher = InMemoryKeyValueStore();

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, speicher,
            flow: AuthCodeFlow.recovery, initialEmail: '');
        await tester.enterText(_emailFeld, _adresse);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();

        await _tippeTrotzdem(tester);
        expect(repo.sendeVersuche, 2);
        expect(_ausweichLink, findsNothing);
        expect(find.text(deL10n.authCodeSendAnywayUsed), findsOneWidget);

        // Der Hauptknopf bleibt der normalen Sperre unterworfen.
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
        expect(repo.sendeVersuche, 2,
            reason: 'die Sperre haelt den blinden Tap weiterhin lokal auf');
        expect(find.text(deL10n.authCodeThrottleWaitMinutes(3)), findsOneWidget);
        await _entsorgeScreen(tester);
      });
    });

    testWidgets(
        'eine vom Server GENANNTE Wartezeit bekommt auch im Adress-Schritt '
        'keinen Ausweg', (tester) async {
      final repo = _WerfendesAuthRepository(const AuthApiException(
        'For security purposes, you can only request this after 180 seconds.',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ));

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpCode(tester, repo, InMemoryKeyValueStore(),
            flow: AuthCodeFlow.recovery, initialEmail: '');
        await tester.enterText(_emailFeld, _adresse);
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();

        expect(_emailFeld, findsOneWidget);
        expect(_ausweichLink, findsNothing,
            reason: 'gegen eine Zahl, die der Server selbst genannt hat, '
                'anzuklopfen kostet nur eine Anfrage');
        await _entsorgeScreen(tester);
      });
    });
  });
}
