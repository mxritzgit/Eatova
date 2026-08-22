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

// Send guard of the code screen (Audit 2026-08-14).
//
// `if (_busy) return;` was the only bar on the resend link (~200 ms), and every
// tap is a real mail to ANY typed address: inbox flooding, a drained GoTrue
// quota (after which NO user gets mail) and delivery cost. The server's 429 also
// fell into the generic "try again" branch, literally inviting the next tap.
//
// So this checks BEHAVIOUR, not the existence of the new methods: how often the
// repository is really called, what survives a rebuild, and which sentence
// appears on throttling.
//
// The clock is pinned via `withClock` so the countdown is deterministic; the
// store is an [InMemoryKeyValueStore], SharedPreferences' role without the
// plugin channel.

const String _adresse = 'opfer@example.com';
final DateTime _jetzt = DateTime(2026, 8, 14, 9, 30);

/// Throttles every resend the way GoTrue does.
class _DrosselndesAuthRepository extends InMemoryAuthRepository {
  @override
  Future<void> resendSignupCode(String email) async {
    throw const AuthException(
        'For security purposes, you can only request this after 51 seconds');
  }
}

/// Store that NEVER answers — SharedPreferences without a plugin channel, and
/// how a blocked device can behave.
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

/// Tears the screen down. The countdown runs on a `Timer.periodic`; without
/// dispose flutter_test reports a pending timer at the end of the test.
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
    // Regression: the guard awaited the device store on the way to sending, so
    // a never-resolving future killed sending entirely. The store only carries
    // the guard's DURABILITY across restarts, it is not its condition:
    // fail-open.
    final repo = InMemoryAuthRepository();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, _StummerSpeicher());

      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1),
          reason: 'der erste Versand haengt an keiner Ablage');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'der Knopf ist wieder frei statt ewig zu drehen');

      // The guard still holds — within a session it does not need the store.
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

      // Navigate away and back: new screen instance, same device store.
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
        await tester.enterText(_codeFeld, '0000000$versuch');
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
      }

      expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget);
      expect(tester.widget<TextField>(_codeFeld).enabled, isFalse);
      expect(tester.widget<FilledButton>(_primaerKnopf).onPressed, isNull);

      // The sixth attempt no longer reaches the server — without the counter it
      // would pass (verifyFails is spent) and land in verifiedCodes.
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
    // Regression: `gesperrt ? tooManyAttempts : _error` swallowed EVERY further
    // error once the lock engaged, so a failing resend showed NOTHING and the
    // link looked dead.
    final repo = _DrosselndesAuthRepository();
    final speicher = InMemoryKeyValueStore();

    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpCode(tester, repo, speicher);

      for (var versuch = 1; versuch <= 5; versuch++) {
        repo.verifyFails = true;
        await tester.enterText(_codeFeld, '0000000$versuch');
        await tester.tap(_primaerKnopf);
        await tester.pumpAndSettle();
      }
      expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget,
          reason: 'der Dauerhinweis der Sperre bleibt ohne neuen Fehler '
              'sichtbar');

      // The resend link stays tappable during the lock on purpose (see the link
      // in auth_code_screen.dart) and fails here.
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
    // Regression: `_remainingSeconds` clamped only downwards, so turning the
    // clock back (or switching time zone) created a permanent self-block.
    final repo = InMemoryAuthRepository();
    final speicher = InMemoryKeyValueStore();
    final inDerZukunft = _jetzt.add(const Duration(days: 1));

    // Phase 1: the send is stamped while the device clock is a day ahead.
    await withClock(Clock.fixed(inDerZukunft), () async {
      await _pumpCode(tester, repo, speicher);
      await tester.tap(_resendLink);
      await tester.pumpAndSettle();
      expect(repo.signupResends, hasLength(1));
      await _entsorgeScreen(tester);
    });

    // Phase 2: the clock is back to the earlier value, well BEFORE the stored
    // stamp. Without the upper clamp the remainder would exceed a day; the
    // screen must treat it as expired.
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
