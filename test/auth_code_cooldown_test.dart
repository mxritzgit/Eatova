import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore, KeyValueStore;
import 'package:eatova/src/theme/app_theme.dart';

// Versand-Riegel der Code-Seite (Audit 2026-08-14).
//
// Vorher war `if (_busy) return;` der einzige Riegel am Neu-anfordern-Link —
// rund 200 ms. Jeder Tap ist ein echter Mailversand an eine BELIEBIGE
// eingetippte Adresse: Postfach-Flut beim Opfer, leergelaufenes
// GoTrue-Kontingent (danach bekommt KEIN Nutzer mehr Mails) und Zustellkosten
// am eigenen Mailserver. Die 429-Antwort des Servers fiel zudem in den
// Sammelzweig „Bitte nochmal versuchen" — die App forderte woertlich zum
// naechsten Tap auf.
//
// Geprueft wird deshalb VERHALTEN, nicht die Existenz der neuen Methoden:
// wie oft das Repository wirklich gerufen wird, was nach einem Rebuild noch
// gilt, und welcher Satz bei einer Drosselung erscheint.
//
// Die Uhr steht per `withClock` fest (der Screen liest sie ueber
// `clock.now()`), damit der Countdown-Wert deterministisch ist. Der Speicher
// ist ein [InMemoryKeyValueStore] — dieselbe Rolle wie SharedPreferences auf
// dem Geraet, nur ohne Plugin-Channel.

const String _adresse = 'opfer@example.com';
final DateTime _jetzt = DateTime(2026, 8, 14, 9, 30);

/// Drosselt jeden Neuversand so, wie GoTrue es tut („For security purposes,
/// you can only request this after 51 seconds").
class _DrosselndesAuthRepository extends InMemoryAuthRepository {
  @override
  Future<void> resendSignupCode(String email) async {
    throw const AuthException(
        'For security purposes, you can only request this after 51 seconds');
  }
}

/// Speicher, der NIE antwortet — so verhaelt sich SharedPreferences ohne
/// Plugin-Channel, und so kann sich ein blockiertes Geraet verhalten.
class _StummerSpeicher implements KeyValueStore {
  @override
  Future<String?> getString(String key) => Completer<String?>().future;

  @override
  Future<void> setString(String key, String value) => Completer<void>().future;

  @override
  Future<void> remove(String key) => Completer<void>().future;
}

Future<void> _pumpCode(
  WidgetTester tester,
  InMemoryAuthRepository repo,
  KeyValueStore speicher, {
  AuthCodeFlow flow = AuthCodeFlow.signup,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: AuthCodeScreen(
      authRepository: repo,
      flow: flow,
      initialEmail: _adresse,
      throttleStore: speicher,
    ),
  ));
  await tester.pumpAndSettle();
}

/// Baut den Screen ab. Der laufende Countdown haengt an einem
/// `Timer.periodic`; ohne `dispose()` meldet flutter_test am Testende einen
/// offenen Timer.
Future<void> _entsorgeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Finder get _resendLink => find.byKey(const ValueKey('code-resend'));
Finder get _primaerKnopf => find.byKey(const ValueKey('code-primary'));
Finder get _codeFeld => find.byKey(const ValueKey('code-field'));

void main() {
  testWidgets('der zweite Neu-anfordern-Tap loest KEINE zweite Mail aus',
      (tester) async {
    final repo = InMemoryAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1));

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();

      expect(repo.signupResends, hasLength(1),
          reason: 'der Cooldown haelt den zweiten Versand auf — vorher ging '
              'jeder Tap als Mail raus');
      expect(find.text(deL10n.authCodeThrottleWait(60)), findsOneWidget,
          reason: 'der Nutzer erfaehrt, WANN es weitergeht');
      await _entsorgeScreen(tester);
    });
  });

  testWidgets('ein Speicher, der nie antwortet, haelt den Versand NICHT auf',
      (tester) async {
    // Regression: der Riegel las und schrieb den Geraetespeicher MIT `await`
    // auf dem Weg zum Versand. Bleibt dessen Future offen, ging danach gar
    // keine Mail mehr raus — „Passwort vergessen" war tot, der Knopf drehte
    // endlos. Der Speicher traegt nur die HALTBARKEIT des Riegels ueber
    // Neustarts, er ist nicht seine Bedingung: fail-open.
    final repo = InMemoryAuthRepository();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, _StummerSpeicher());

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1),
          reason: 'der erste Versand haengt an keiner Ablage');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'der Knopf ist wieder frei statt ewig zu drehen');

      // Der Riegel gilt trotzdem — innerhalb der Sitzung braucht er den
      // Speicher nicht.
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1));
      expect(find.text(deL10n.authCodeThrottleWait(60)), findsOneWidget);
      await _entsorgeScreen(tester);
    });
  });

  testWidgets('der Countdown ueberlebt den Rebuild des Screens',
      (tester) async {
    final repo = InMemoryAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(find.text(deL10n.authCodeResendCountdown(60)), findsOneWidget);

      // Wegnavigieren und zurueck: neue Screen-Instanz, derselbe
      // Geraetespeicher.
      await _entsorgeScreen(tester);
      await _pumpCode(tester, repo, speicher);

      expect(find.text(deL10n.authCodeResendCountdown(60)), findsOneWidget,
          reason: 'der Stempel haengt an der Adresse, nicht an der '
              'Screen-Instanz');

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1),
          reason: 'sonst waere der Riegel durch Navigation zu umgehen');
      await _entsorgeScreen(tester);
    });
  });

  testWidgets('nach fuenf abgelehnten Codes ist die Eingabe gesperrt',
      (tester) async {
    final repo = InMemoryAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      for (var versuch = 1; versuch <= 5; versuch++) {
        repo.verifyFails = true;
        await tester.enterText(_codeFeld, '00000$versuch');
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
      }

      expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget);
      expect(tester.widget<TextField>(_codeFeld).enabled, isFalse);
      expect(tester.widget<FilledButton>(_primaerKnopf).onPressed, isNull);

      // Der sechste Versuch erreicht den Server nicht mehr — ohne Zaehler
      // liefe er durch (verifyFails ist verbraucht) und landete in
      // verifiedCodes.
      await tester.tap(_primaerKnopf, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(repo.verifiedCodes, isEmpty);

      await _entsorgeScreen(tester);
      await _pumpCode(tester, repo, speicher);
      expect(tester.widget<TextField>(_codeFeld).enabled, isFalse,
          reason: 'auch die Sperre haengt an der Adresse — ein Neuaufbau der '
              'Seite hebt sie nicht auf');
      await _entsorgeScreen(tester);
    });
  });

  testWidgets('ein Rate-Limit-Fehler nennt die Drosselung statt zum naechsten '
      'Versuch aufzufordern', (tester) async {
    final repo = _DrosselndesAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();

      expect(find.text(deL10n.authCodeRateLimited), findsOneWidget);
      expect(find.textContaining('Bitte nochmal versuchen'), findsNothing,
          reason: 'die generische Meldung forderte woertlich zum naechsten '
              'Tap auf — genau der Schleife, die das Kontingent leerraeumt');
      expect(find.text(deL10n.authCodeResendCountdown(60)), findsOneWidget,
          reason: 'die Server-Drosselung stempelt den eigenen Riegel mit');
      await _entsorgeScreen(tester);
    });
  });

  testWidgets(
      'nach der Sperre zeigt ein NEUER Fehler beim Neuanfordern sich selbst '
      'statt nur den Dauerhinweis der Sperre (W3)', (tester) async {
    // Regression: `gesperrt ? tooManyAttempts : _error` verschluckte JEDEN
    // weiteren Fehler, sobald die Sperre einmal griff. Der Nutzer tippt
    // "Neuen Code anfordern", der Versand scheitert serverseitig (hier: die
    // Drossel aus `_DrosselndesAuthRepository`) — es erschien NICHTS, der
    // Link wirkte tot.
    final repo = _DrosselndesAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      for (var versuch = 1; versuch <= 5; versuch++) {
        repo.verifyFails = true;
        await tester.enterText(_codeFeld, '00000$versuch');
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
      }
      expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget,
          reason: 'der Dauerhinweis der Sperre bleibt ohne neuen Fehler '
              'sichtbar');

      // Der Resend-Link bleibt waehrend der Sperre absichtlich antippbar
      // (s. Kommentar am Link in auth_code_screen.dart) und scheitert hier.
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();

      expect(find.text(deL10n.authCodeRateLimited), findsOneWidget,
          reason: 'ein aktueller Fehler hat Vorrang vor dem Dauerhinweis der '
              'Sperre');
      await _entsorgeScreen(tester);
    });
  });

  testWidgets(
      'eine zurueckgestellte Geraeteuhr fuehrt zu keinem Rest groesser als '
      'die Cooldown-Dauer (W3b)', (tester) async {
    // Regression: `_remainingSeconds` klemmte nur nach unten. Stellt der
    // Nutzer die Uhr zurueck (oder wechselt die Zeitzone), entsteht sonst ein
    // persistenter Selbstblock ("naechster Code in 86400 s"), aus dem er
    // nicht mehr herauskommt.
    final repo = InMemoryAuthRepository();
    final speicher = InMemoryKeyValueStore();
    final inDerZukunft = _jetzt.add(const Duration(days: 1));

    // Phase 1: Versand wird gestempelt, waehrend die Geraeteuhr (irrtuemlich)
    // einen Tag voraus geht.
    await withClock(Clock.fixed(inDerZukunft), () async {
      await _pumpCode(tester, repo, speicher);
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1));
      await _entsorgeScreen(tester);
    });

    // Phase 2: Die Uhr steht wieder auf dem urspruenglichen (frueheren) Wert —
    // deutlich VOR dem gespeicherten Stempel. Ohne die obere Klemme laege der
    // Rest bei ueber einem Tag; die Seite muss das stattdessen als abgelaufen
    // behandeln.
    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      expect(find.text('Keinen Code bekommen? Neuen anfordern'),
          findsOneWidget,
          reason: 'ein Rest > Cooldown-Dauer gilt als abgelaufen, kein '
              'absurd hoher Countdown');
      expect(find.textContaining('86'), findsNothing,
          reason: 'kein Countdown-Rest im Tagesbereich durch die '
              'verstellte Uhr');

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(2),
          reason: 'die verstellte Uhr darf keinen dauerhaften Selbst-DoS '
              'erzeugen');
      await _entsorgeScreen(tester);
    });
  });
}
