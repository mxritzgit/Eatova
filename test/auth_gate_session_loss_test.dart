// D8: a pushed route must not survive an auth change.
//
// AuthGate is MaterialApp.home, so swapping its content for the AuthScreen
// leaves anything pushed above it (profile, dialog, sheet) visible and usable
// with data from a session that no longer exists. The gate therefore clears on
// EVERY identity change, including a deliberate sign-out (whose button lives
// in settings, i.e. on a pushed route). Whether the "session expired" notice
// appears is decided by [IntentionalSignOut], not by whether routes were
// dropped.
//
// Pinned here:
//   1. session loss clears the navigator stack down to the root route;
//   2. an open dialog goes with it and its future completes with null;
//   3. a direct A -> B switch clears it too, WITHOUT the expiry notice;
//   4. a token refresh (same user again) clears NOTHING;
//   5. the user learns why they suddenly face the login.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Auth repository whose events the test drives directly, so a server-side
/// revocation (null), a token refresh (same user) and an account switch
/// (different id) can be told apart.
class _ScriptedAuthRepository implements AuthRepository {
  _ScriptedAuthRepository(this._user);

  EatovaUser? _user;
  final _controller = StreamController<EatovaUser?>.broadcast();

  void emit(EatovaUser? user) {
    _user = user;
    _controller.add(user);
  }

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

const _user = EatovaUser(
  id: 'user-1',
  email: 'moritz@example.com',
  displayName: 'Moritz',
);

const _andererUser = EatovaUser(
  id: 'user-2',
  email: 'zweitkonto@example.com',
  displayName: 'Zweitkonto',
);

/// Photo store double that only records the identity bindings.
///
/// No real IO: `testWidgets` runs under FakeAsync, where a file operation
/// would never finish. What the purge does is covered by
/// test/services/recipe_image_store_test.dart; here only that the gate
/// REPORTS every transition to the store (Finding 5, 2026-08-11).
class _BindungsRekorder extends RecipeImageStore {
  final List<String?> bindungen = <String?>[];

  @override
  Future<void> setActiveUser(String? userId) {
    bindungen.add(userId);
    return Future<void>.value();
  }
}

/// Builds the same shell as EatovaApp: AuthGate as MaterialApp.home, with a
/// placeholder home whose button pushes a route.
Future<void> _pumpGate(
  WidgetTester tester,
  _ScriptedAuthRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // The signed-out branch renders AuthScreen, which reads `context.l10n`.
      locale: const Locale('de'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AuthGate(
        authRepository: repository,
        builder: (context, user, freshLogin) => Scaffold(
          key: const ValueKey('screen-fake-home'),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('push-profile'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(
                        key: ValueKey('screen-fake-profile'),
                        body: Center(child: Text('Gewichtsverlauf')),
                      ),
                    ),
                  ),
                  child: const Text('Profil'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The auth events the parametrised identity-binding block drives. Named
// functions, not inline closures, so each case reads as what it models.
void _keinEreignis(_ScriptedAuthRepository repository) {}
void _meldeSessionVerlust(_ScriptedAuthRepository repository) =>
    repository.emit(null);
void _wechsleKonto(_ScriptedAuthRepository repository) =>
    repository.emit(_andererUser);
void _meldeTokenRefresh(_ScriptedAuthRepository repository) =>
    repository.emit(_user);

void main() {
  testWidgets(
      'Extern ausgeloester Session-Verlust raeumt die gepushte Route ab',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    expect(find.byKey(const ValueKey('screen-fake-home')), findsOneWidget);

    // The user opens their profile.
    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget);

    // Meanwhile the refresh token is invalidated server-side.
    repository.emit(null);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget,
        reason: 'Root-Route muss der Auth-Screen sein');
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsNothing,
        reason: 'Die gepushte Profil-Route darf den Session-Verlust nicht '
            'ueberleben — sie zeigt Daten einer Session, die es nicht gibt');
    expect(find.text('Gewichtsverlauf'), findsNothing);
  });

  testWidgets(
      'Ein offener Dialog verschwindet mit und schliesst sauber (null)',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    // Push a route and open a dialog above it.
    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();

    Object? dialogResult = 'noch offen';
    var dialogClosed = false;
    final context = tester.element(
      find.byKey(const ValueKey('screen-fake-profile')),
    );
    unawaited(
      showDialog<String>(
        context: context,
        builder: (_) => const AlertDialog(
          key: ValueKey('fake-dialog'),
          content: Text('Konto wirklich loeschen?'),
        ),
      ).then((value) {
        dialogResult = value;
        dialogClosed = true;
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-dialog')), findsOneWidget);

    repository.emit(null);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fake-dialog')), findsNothing,
        reason: 'Auch ein Dialog ist eine Route und muss weg sein');
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsNothing);
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(dialogClosed, isTrue,
        reason: 'Der Dialog-Future muss abgeschlossen sein, nicht haengen');
    expect(dialogResult, isNull,
        reason: 'Regulaerer Pop -> Ergebnis null, kein halber Zustand');
  });

  testWidgets(
      'Ein direkter Kontowechsel A -> B raeumt die gepushte Route ebenfalls ab',
      (tester) async {
    // The counterpart to the null case above. Both are identity changes, but
    // only this one ends with someone ELSE logged in, so the teardown may not
    // hang off "nobody is signed in any more": B would keep looking at As
    // open view. On a shared device that is the whole point of the switch.
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget);

    // No sign-out in between: Bs session simply replaces As.
    repository.emit(_andererUser);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-fake-profile')), findsNothing,
        reason: 'die offene Route zeigt As Daten — B darf sie nicht sehen');
    expect(find.text('Gewichtsverlauf'), findsNothing);
    expect(find.byKey(const ValueKey('screen-fake-home')), findsOneWidget,
        reason: 'B ist angemeldet, also die Startseite und nicht der Login');
    expect(find.textContaining('Sitzung ist abgelaufen'), findsNothing,
        reason: 'nichts ist abgelaufen — B sitzt in einer frischen Sitzung');
  });

  testWidgets('Ein Token-Refresh raeumt die gepushte Route NICHT ab',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget);

    // tokenRefreshed delivers the same user again: an auth event, but no
    // session loss, so the open route must stay.
    repository.emit(_user);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget,
        reason: 'Ein Token-Refresh darf die offene Ansicht nicht wegraeumen');
    expect(find.byKey(const ValueKey('screen-auth')), findsNothing);
  });

  testWidgets('Der Nutzer erfaehrt, dass die Sitzung abgelaufen ist',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();

    repository.emit(null);
    // Settle first: during the pop transition two scaffolds are briefly
    // registered with the ScaffoldMessenger and both render the snackbar.
    await tester.pumpAndSettle();

    expect(find.textContaining('Sitzung ist abgelaufen'), findsOneWidget,
        reason: 'Wortlos auf den Login geworfen zu werden ist verwirrend');
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

    // The snackbar must not leave a pending timer.
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets(
      'Die gewollte In-App-Abmeldung bleibt still (kein „abgelaufen"-Hinweis)',
      (tester) async {
    // Production order: pop first, then signOut. InMemoryAuthRepository is
    // used because its async* stream has the same delivery asynchrony as the
    // Supabase stream.
    final repository = InMemoryAuthRepository(initialUser: _user);
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AuthGate(
          authRepository: repository,
          builder: (context, user, freshLogin) => Scaffold(
            key: const ValueKey('screen-fake-home'),
            body: Center(
              child: TextButton(
                key: const ValueKey('push-profile'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (routeContext) => Scaffold(
                      key: const ValueKey('screen-fake-profile'),
                      body: Center(
                        child: TextButton(
                          key: const ValueKey('sign-out'),
                          onPressed: () async {
                            // This marker, not "nothing was above the root
                            // route", separates a deliberate sign-out from an
                            // expired session — the button itself sits on a
                            // pushed route. Production sets it in
                            // `_EatovaHomePageState._signOut`.
                            IntentionalSignOut.mark();
                            Navigator.maybePop(routeContext);
                            await repository.signOut();
                          },
                          child: const Text('Abmelden'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Profil'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sign-out')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsNothing);
    expect(find.textContaining('Sitzung ist abgelaufen'), findsNothing,
        reason: 'Wer sich selbst abmeldet, hat keine abgelaufene Sitzung');
  });

  group('Finding 5 — der Gate bindet den Rezept-Foto-Store an die Identitaet',
      () {
    // The store purges on identity change itself (setActiveUser, own unit
    // tests); the gate is the ONE place every transition passes through,
    // including those signOutCleanup never sees: involuntary session loss and
    // a direct A -> B switch.

    // Same shell every time: only the auth event and the expected binding
    // sequence differ, so the four transitions run as one parametrised block.
    for (final (name, ereignis, erwartet, grund) in <(
      String,
      void Function(_ScriptedAuthRepository),
      List<String?>,
      String
    )>[
      (
        'Kaltstart bindet den restaurierten Nutzer',
        _keinEreignis,
        <String?>['user-1'],
        'Schon der initState muss binden — sonst rendert der erste Frame '
            'gegen einen ungebundenen Store.'
      ),
      (
        'Session-Verlust meldet null an den Store',
        _meldeSessionVerlust,
        <String?>['user-1', null],
        'Der externe Widerruf laeuft NICHT ueber signOutCleanup — ohne diese '
            'Meldung bliebe der Bestand des Nutzers liegen.'
      ),
      (
        'direkter Wechsel A -> B meldet die neue Identitaet',
        _wechsleKonto,
        <String?>['user-1', 'user-2'],
        'Beim Kontowechsel ohne explizites Abmelden muss der Store den '
            'Wechsel erfahren, BEVOR das neue Konto rendert.'
      ),
      (
        'ein Token-Refresh meldet denselben Nutzer erneut (No-Op im Store)',
        _meldeTokenRefresh,
        <String?>['user-1', 'user-1'],
        'Dieselbe id darf gemeldet werden — setActiveUser macht daraus ein '
            'No-Op und purgt nichts.'
      ),
    ]) {
      testWidgets(name, (tester) async {
        final rekorder = _BindungsRekorder();
        RecipeImageStore.instance = rekorder;
        addTearDown(RecipeImageStore.resetInstance);
        final repository = _ScriptedAuthRepository(_user);
        addTearDown(repository.dispose);

        await _pumpGate(tester, repository);
        ereignis(repository);
        await tester.pumpAndSettle();

        expect(rekorder.bindungen, erwartet, reason: grund);
      });
    }
  });
}
