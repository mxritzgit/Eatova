// D8: Eine gepushte Route ueberlebt den Auth-Wechsel.
//
// AuthGate ist das Widget von MaterialApp.home, also der Inhalt der
// Root-Route. Tauscht _onAuthEvent diesen Inhalt gegen den AuthScreen, bleibt
// alles was der Nutzer darueber gepusht hat (Profil, Trends, ein Dialog, ein
// Bottom Sheet) sichtbar und bedienbar — mit Daten einer Session, die es nicht
// mehr gibt. Betroffen ist ausschliesslich der extern ausgeloeste
// Session-Verlust; die In-App-Abmeldung poppt selbst (profile_screen.dart:137).
//
// Die Tests hier pinnen drei Aussagen fest:
//   1. Session-Verlust raeumt den Navigator-Stack bis zur Root-Route ab.
//   2. Ein offener Dialog verschwindet dabei mit und sein Future schliesst
//      sauber (null) — kein halber Zustand.
//   3. Ein Token-Refresh (derselbe Nutzer erneut) raeumt NICHTS ab.
//   4. Der Nutzer erfaehrt, warum er ploetzlich auf dem Login steht.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Auth-Repository, dessen Ereignisse der Test direkt steuert — so laesst sich
/// ein serverseitiger Widerruf (null) von einem Token-Refresh (derselbe
/// Nutzer erneut) und einem Kontowechsel (andere id) unterscheiden.
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

/// Foto-Store-Double, das nur die Identitaets-Bindungen protokolliert.
///
/// Bewusst OHNE echtes IO: `testWidgets` laeuft unter FakeAsync, eine echte
/// Datei-Operation wuerde dort nie fertig. Was der Purge beim Wechsel tut,
/// prueft test/services/recipe_image_store_test.dart — hier steht nur die
/// Zusicherung, dass der Gate JEDEN Uebergang an den Store MELDET (Finding 5,
/// Security-Review 2026-08-11).
class _BindungsRekorder extends RecipeImageStore {
  final List<String?> bindungen = <String?>[];

  @override
  Future<void> setActiveUser(String? userId) {
    bindungen.add(userId);
    return Future<void>.value();
  }
}

/// Baut dieselbe Huelle wie EatovaApp: AuthGate als MaterialApp.home. Der
/// Builder liefert einen Platzhalter-Home mit einem Knopf, der eine Route
/// pusht (steht fuer „Profil oeffnen").
Future<void> _pumpGate(
  WidgetTester tester,
  _ScriptedAuthRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
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

void main() {
  testWidgets(
      'Extern ausgeloester Session-Verlust raeumt die gepushte Route ab',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    expect(find.byKey(const ValueKey('screen-fake-home')), findsOneWidget);

    // Nutzer oeffnet sein Profil.
    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget);

    // Waehrenddessen wird der Refresh-Token serverseitig ungueltig.
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

    // Route pushen und darueber noch einen Dialog oeffnen.
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

  testWidgets('Ein Token-Refresh raeumt die gepushte Route NICHT ab',
      (tester) async {
    final repository = _ScriptedAuthRepository(_user);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository);

    await tester.tap(find.byKey(const ValueKey('push-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-fake-profile')), findsOneWidget);

    // tokenRefreshed liefert denselben Nutzer erneut — ein Auth-Event, aber
    // kein Session-Verlust. Die offene Route muss stehen bleiben.
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
    // Erst settlen: waehrend der Pop-Transition sind kurzzeitig zwei Scaffolds
    // beim ScaffoldMessenger registriert und beide rendern dieselbe Snackbar.
    await tester.pumpAndSettle();

    expect(find.textContaining('Sitzung ist abgelaufen'), findsOneWidget,
        reason: 'Wortlos auf den Login geworfen zu werden ist verwirrend');
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

    // Die Snackbar darf keinen haengenden Timer hinterlassen.
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets(
      'Die gewollte In-App-Abmeldung bleibt still (kein „abgelaufen"-Hinweis)',
      (tester) async {
    // Produktionsnahe Reihenfolge aus profile_screen.dart:137 — erst poppen,
    // dann signOut. Bewusst mit InMemoryAuthRepository, weil dessen async*-
    // Stream dieselbe Zustellungs-Asynchronie hat wie der Supabase-Stream.
    final repository = InMemoryAuthRepository(initialUser: _user);
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
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
    // Der Store purgt beim Identitaetswechsel selbst (setActiveUser, eigene
    // Unit-Tests); der Gate ist die EINE Stelle, durch die JEDER Uebergang
    // laeuft — auch die, die kein signOutCleanup sehen: unfreiwilliger
    // Session-Verlust und der direkte Wechsel A -> B.

    testWidgets('Kaltstart bindet den restaurierten Nutzer', (tester) async {
      final rekorder = _BindungsRekorder();
      RecipeImageStore.instance = rekorder;
      addTearDown(RecipeImageStore.resetInstance);
      final repository = _ScriptedAuthRepository(_user);
      addTearDown(repository.dispose);

      await _pumpGate(tester, repository);

      expect(rekorder.bindungen, <String?>['user-1'],
          reason: 'Schon der initState muss binden — sonst rendert der '
              'erste Frame gegen einen ungebundenen Store.');
    });

    testWidgets('Session-Verlust meldet null an den Store', (tester) async {
      final rekorder = _BindungsRekorder();
      RecipeImageStore.instance = rekorder;
      addTearDown(RecipeImageStore.resetInstance);
      final repository = _ScriptedAuthRepository(_user);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      repository.emit(null);
      await tester.pumpAndSettle();

      expect(rekorder.bindungen, <String?>['user-1', null],
          reason: 'Der externe Widerruf laeuft NICHT ueber signOutCleanup — '
              'ohne diese Meldung bliebe der Bestand des Nutzers liegen.');
    });

    testWidgets('direkter Wechsel A -> B meldet die neue Identitaet',
        (tester) async {
      final rekorder = _BindungsRekorder();
      RecipeImageStore.instance = rekorder;
      addTearDown(RecipeImageStore.resetInstance);
      final repository = _ScriptedAuthRepository(_user);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      repository.emit(_andererUser);
      await tester.pumpAndSettle();

      expect(rekorder.bindungen, <String?>['user-1', 'user-2'],
          reason: 'Beim Kontowechsel ohne explizites Abmelden muss der Store '
              'den Wechsel erfahren, BEVOR das neue Konto rendert.');
    });

    testWidgets('ein Token-Refresh meldet denselben Nutzer erneut (No-Op im '
        'Store)', (tester) async {
      final rekorder = _BindungsRekorder();
      RecipeImageStore.instance = rekorder;
      addTearDown(RecipeImageStore.resetInstance);
      final repository = _ScriptedAuthRepository(_user);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository);

      repository.emit(_user);
      await tester.pumpAndSettle();

      expect(rekorder.bindungen, <String?>['user-1', 'user-1'],
          reason: 'Dieselbe id darf gemeldet werden — setActiveUser macht '
              'daraus ein No-Op und purgt nichts.');
    });
  });
}
