import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';

// The AuthGate as the ONLY place every auth transition passes through:
//
//   Finding 1: `HomeStore.signOutCleanup` clears the PII cache but hangs off
//              the sign-out button, so an involuntary session end and a direct
//              A -> B switch never saw it. The outbox must survive: it holds
//              undelivered writes.
//   Finding 2: the subscriptions had no `onError`. gotrue pushes errors into
//              the stream, so without a handler it is an unhandled zone error,
//              triggerable from outside via the deeplink intent.
//   Finding 3: the session-expired message hung off "something was above the
//              root route", which since the sign-out button moved into the
//              settings hit the INTENTIONAL logout.

const _userA = EatovaUser(
  id: 'user-a',
  email: 'a@example.com',
  displayName: 'Anna',
);

const _userB = EatovaUser(
  id: 'user-b',
  email: 'b@example.com',
  displayName: 'Ben',
);

/// Auth repository whose events AND errors the test drives directly.
class _ScriptedAuthRepository implements AuthRepository {
  _ScriptedAuthRepository(this._user);

  EatovaUser? _user;
  final _controller = StreamController<EatovaUser?>.broadcast();

  void emit(EatovaUser? user) {
    _user = user;
    _controller.add(user);
  }

  /// Exactly what gotrue does: an error on the same stream that otherwise
  /// delivers users.
  void emitError(Object error) => _controller.addError(error);

  void dispose() => _controller.close();

  @override
  EatovaUser? get currentUser => _user;

  @override
  Stream<EatovaUser?> get authStateChanges => _controller.stream;

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> verifyRecoveryCode(
      {required String email, required String code}) async {}

  @override
  Future<void> verifySignupCode(
      {required String email, required String code}) async {}

  @override
  Future<void> resendSignupCode(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> startPasswordChange() async {}

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {}

  @override
  Future<void> startEmailChange(String newEmail) async {}

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {}

  @override
  Future<void> signIn({required String email, required String password}) async {}

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async =>
      SignUpOutcome.created;

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {}

  @override
  Future<void> signOut() async => emit(null);
}

/// Photo store double without IO; the real purge is covered by
/// test/services/recipe_image_store_test.dart.
class _StummerFotoStore extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId) => Future<void>.value();
}

/// Same shell as EatovaApp: AuthGate as MaterialApp.home with a pushable route
/// above it (standing in for the settings).
Future<void> _pumpGate(
  WidgetTester tester,
  _ScriptedAuthRepository repository, {
  Future<void> Function(String userId)? purge,
  Locale locale = const Locale('de'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // The signed-out branch renders AuthScreen, which reads `context.l10n`.
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AuthGate(
        authRepository: repository,
        debugPurgeCache: purge,
        builder: (context, user, freshLogin) => Scaffold(
          key: const ValueKey('screen-fake-home'),
          body: Center(
            child: TextButton(
              key: const ValueKey('push-settings'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (routeContext) => Scaffold(
                    key: const ValueKey('screen-fake-settings'),
                    body: Center(
                      child: TextButton(
                        key: const ValueKey('sign-out'),
                        onPressed: () async {
                          // Production order: the button sits on a PUSHED
                          // route and does not pop itself — exactly the case
                          // the old heuristic got wrong.
                          IntentionalSignOut.mark();
                          await repository.signOut();
                        },
                        child: const Text('Abmelden'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Einstellungen'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The three auth events the parametrised purge block drives. Named functions,
// not inline closures, so each case reads as what it models.
void _emitVerlust(_ScriptedAuthRepository repository) => repository.emit(null);
void _emitWechsel(_ScriptedAuthRepository repository) => repository.emit(_userB);
void _emitRefresh(_ScriptedAuthRepository repository) => repository.emit(_userA);

void main() {
  setUp(() {
    IntentionalSignOut.clear();
    RecipeImageStore.instance = _StummerFotoStore();
  });
  tearDown(() {
    RecipeImageStore.resetInstance();
    IntentionalSignOut.clear();
  });

  group('Fund 1 — jeder Identitaetswechsel raeumt den Cache des Vorgaengers',
      () {
    // One shell, three auth events: the emitted event and the expected purge
    // list are the only difference.
    for (final (name, ereignis, erwartet, grund) in <(
      String,
      void Function(_ScriptedAuthRepository),
      List<String>,
      String
    )>[
      (
        'unfreiwilliger Session-Verlust raeumt',
        _emitVerlust,
        <String>['user-a'],
        'der serverseitige Widerruf laeuft NICHT ueber signOutCleanup — ohne '
            'diese Raeumung bleiben Profil, Tagebuch und Gewichtsreihe auf '
            'dem Geraet liegen'
      ),
      (
        'direkter Wechsel A -> B raeumt A',
        _emitWechsel,
        <String>['user-a'],
        'auf dem Familien-Tablet saehe B sonst As Bestand'
      ),
      (
        'ein Token-Refresh raeumt NICHTS',
        _emitRefresh,
        <String>[],
        'derselbe Nutzer erneut ist kein Wechsel — hier faellt sonst dem '
            'eingeloggten Nutzer sein eigener Offline-Bestand weg'
      ),
    ]) {
      testWidgets(name, (tester) async {
        final repository = _ScriptedAuthRepository(_userA);
        addTearDown(repository.dispose);
        final geraeumt = <String>[];
        await _pumpGate(tester, repository,
            purge: (id) async => geraeumt.add(id));

        ereignis(repository);
        await tester.pumpAndSettle();

        expect(geraeumt, erwartet, reason: grund);
      });
    }

    test('die Raeumung nimmt die PII mit und laesst die Outbox stehen',
        () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, 'user-a');
      await cache.writeProfile(
          const UserProfile(weightKg: 80, onboardingCompleted: true));
      await cache.writeLoggedMeals(<LoggedMeal>[
        LoggedMeal(
          id: 'm-1',
          result: const MealAnalysisResult(
            mealName: 'Bowl',
            caloriesKcal: 300,
            estimatedGrams: 350,
            kcalPer100G: 85,
            protein: '30 g',
            carbs: '40 g',
            fat: '10 g',
            confidence: 'Hoch',
            portionNotes: 'Test.',
            sourceLabel: 'Foto-KI',
          ),
          loggedAt: DateTime(2026, 8, 19, 12),
        ),
      ]);
      await cache.writeNotificationsEnabled(true);
      await cache.writeOutbox(<SyncOp>[SyncOp.trackingDay('2026-08-19')]);

      await purgePersonalCache(cache);

      expect(await cache.readProfile(), isNull);
      expect(await cache.readLoggedMeals(), isNull);
      expect(await cache.readNotificationsEnabled(), isNull);
      expect(
        (await cache.readOutbox())?.map((o) => o.kind),
        contains(SyncOpKind.trackingDay),
        reason: 'die Outbox ist kein Anzeige-Cache, sondern nicht zugestellte '
            'Schreibvorgaenge (A2) — sie zu vernichten hiesse, dem Nutzer die '
            'offline geloggten Mahlzeiten zu nehmen',
      );
    });
  });

  group('Fund 2 — ein Fehler auf dem Auth-Strom eskaliert nicht', () {
    testWidgets('addError laesst den Gate stehen und weiterarbeiten',
        (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      // Without an onError handler this is an unhandled zone error and the
      // test fails here — the escalation reachable from outside via the
      // BROWSABLE deeplink intent.
      repository.emitError(StateError('AuthRetryableFetchException'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('screen-fake-home')), findsOneWidget,
          reason: 'ein Strom-Fehler ist kein Session-Verlust');

      // The gate keeps listening: an error must not end the subscription, or
      // it would miss the real revocation.
      repository.emit(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    });
  });

  group('Fund 3 — gewollt abgemeldet ist nicht abgelaufen', () {
    testWidgets(
        'Abmelden aus einer gepushten Route bleibt still, raeumt sie aber ab',
        (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      await tester.tap(find.byKey(const ValueKey('push-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-fake-settings')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sign-out')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-fake-settings')), findsNothing,
          reason: 'die Einstellungen zeigen Daten einer Session, die es nicht '
              'mehr gibt');
      expect(find.textContaining('Sitzung ist abgelaufen'), findsNothing,
          reason: 'genau hier log die alte Abgrenzung: der Logout raeumt seit '
              'dem Umzug des Knopfes selbst Routen ab');
    });

    testWidgets(
        'Sitzungsverlust auf der Root-Route erklaert sich trotzdem',
        (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      // No push, nothing to tear down — under the old rule the user landed on
      // the login without any explanation.
      repository.emit(null);
      await tester.pumpAndSettle();

      expect(find.textContaining('Sitzung ist abgelaufen'), findsOneWidget);
      // The snackbar must not leave a pending timer.
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    // P1-04: the only text on this path was hardcoded German — a rendered
    // sentence in a file that has been listed as migrated for two rounds.
    testWidgets('der Hinweis folgt der App-Sprache', (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, locale: const Locale('en'));

      repository.emit(null);
      await tester.pumpAndSettle();

      expect(find.text(enL10n.authSessionExpired), findsOneWidget);
      expect(find.textContaining('Sitzung ist abgelaufen'), findsNothing,
          reason: 'die englische App darf den Satz nicht auf Deutsch zeigen');
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    test('die Absicht gilt fuer GENAU einen Uebergang', () {
      IntentionalSignOut.mark();
      expect(IntentionalSignOut.consume(), isTrue);
      expect(IntentionalSignOut.consume(), isFalse,
          reason: 'sonst schaltete ein Logout jeden spaeteren Verlust stumm');
    });

    test(
        'eine steckengebliebene Absicht verfaellt und schaltet einen echten '
        'Verlust nicht stumm', () {
      final start = DateTime(2026, 8, 19, 10);
      var jetzt = start;
      withClock(Clock(() => jetzt), () {
        IntentionalSignOut.mark();
        jetzt = start
            .add(IntentionalSignOut.gueltigkeit + const Duration(seconds: 1));
        expect(IntentionalSignOut.consume(), isFalse);
      });
    });

    // P1-03: the cleanup before `signOut` may take longer than the window, so
    // the intent hangs off the END of that work instead of off the button
    // press. Wiring and reason: test/sign_out_cleanup_test.dart.
    test('refresh() setzt die Frist neu, erfindet aber keine Absicht', () {
      final start = DateTime(2026, 8, 19, 10);
      var jetzt = start;
      withClock(Clock(() => jetzt), () {
        // Nothing declared: the same cleanup runs on an INVOLUNTARY session
        // end, and an intent invented here would silence its message.
        IntentionalSignOut.refresh();
        expect(IntentionalSignOut.consume(), isFalse);

        // Declared, then a long cleanup: the window starts at its end.
        IntentionalSignOut.mark();
        jetzt = start.add(IntentionalSignOut.gueltigkeit * 3);
        IntentionalSignOut.refresh();
        jetzt = jetzt.add(const Duration(seconds: 1));
        expect(IntentionalSignOut.consume(), isTrue);

        // And the refreshed window still expires — the guarantee the deadline
        // exists for stays intact.
        IntentionalSignOut.mark();
        IntentionalSignOut.refresh();
        jetzt = jetzt
            .add(IntentionalSignOut.gueltigkeit + const Duration(seconds: 1));
        expect(IntentionalSignOut.consume(), isFalse);
      });
    });
  });
}
