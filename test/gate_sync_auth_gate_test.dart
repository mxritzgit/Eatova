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
import 'package:eatova/src/theme/app_theme.dart';

// Komplettreview 2026-08-19, Paket „gate-sync" — der AuthGate als EINZIGE
// Stelle, durch die jeder Auth-Uebergang laeuft:
//
//   Fund 1: `HomeStore.signOutCleanup` raeumt den PII-Cache, haengt aber am
//           Ausloggen-Knopf. Unfreiwilliges Sitzungsende und der direkte
//           Wechsel A -> B sehen ihn nie — Profil, Tagebuch, Favoriten,
//           Gewicht und das Erinnerungs-Flag von A blieben liegen. Die Outbox
//           muss dabei stehen bleiben: sie traegt nicht zugestellte Writes.
//   Fund 2: die Abonnements hatten keinen `onError`. gotrue speist Fehler
//           aktiv in den Strom ein — ohne Handler ein unbehandelter
//           Zonen-Fehler, von aussen ueber den Deeplink-Intent ausloesbar.
//   Fund 3: „Deine Sitzung ist abgelaufen" haing an „lag etwas ueber der
//           Root-Route". Seit der Ausloggen-Knopf in den Einstellungen sitzt
//           (also auf einer gepushten Route), traf das ausgerechnet den
//           GEWOLLTEN Logout.

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

/// Auth-Repository, dessen Ereignisse UND Fehler der Test direkt steuert.
class _ScriptedAuthRepository implements AuthRepository {
  _ScriptedAuthRepository(this._user);

  EatovaUser? _user;
  final _controller = StreamController<EatovaUser?>.broadcast();

  void emit(EatovaUser? user) {
    _user = user;
    _controller.add(user);
  }

  /// Genau das, was gotrue tut: ein Fehler auf demselben Strom, der sonst
  /// Nutzer liefert.
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

/// Foto-Store-Double ohne IO — was der echte Purge tut, prueft
/// test/services/recipe_image_store_test.dart.
class _StummerFotoStore extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId) => Future<void>.value();
}

/// Baut dieselbe Huelle wie EatovaApp: AuthGate als MaterialApp.home, darueber
/// eine pushbare Route (steht fuer „Einstellungen").
Future<void> _pumpGate(
  WidgetTester tester,
  _ScriptedAuthRepository repository, {
  Future<void> Function(String userId)? purge,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
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
                          // Produktionsnahe Reihenfolge: der Knopf sitzt auf
                          // einer GEPUSHTEN Route und poppt NICHT selbst
                          // (settings_screen.dart) — genau die Lage, in der
                          // die alte Abgrenzung kippte.
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
    testWidgets('unfreiwilliger Session-Verlust raeumt', (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      final geraeumt = <String>[];
      await _pumpGate(tester, repository,
          purge: (id) async => geraeumt.add(id));

      repository.emit(null);
      await tester.pumpAndSettle();

      expect(geraeumt, <String>['user-a'],
          reason: 'der serverseitige Widerruf laeuft NICHT ueber '
              'signOutCleanup — ohne diese Raeumung bleiben Profil, Tagebuch '
              'und Gewichtsreihe auf dem Geraet liegen');
    });

    testWidgets('direkter Wechsel A -> B raeumt A', (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      final geraeumt = <String>[];
      await _pumpGate(tester, repository,
          purge: (id) async => geraeumt.add(id));

      repository.emit(_userB);
      await tester.pumpAndSettle();

      expect(geraeumt, <String>['user-a'],
          reason: 'auf dem Familien-Tablet saehe B sonst As Bestand');
    });

    testWidgets('ein Token-Refresh raeumt NICHTS', (tester) async {
      final repository = _ScriptedAuthRepository(_userA);
      addTearDown(repository.dispose);
      final geraeumt = <String>[];
      await _pumpGate(tester, repository,
          purge: (id) async => geraeumt.add(id));

      repository.emit(_userA);
      await tester.pumpAndSettle();

      expect(geraeumt, isEmpty,
          reason: 'derselbe Nutzer erneut ist kein Wechsel — hier faellt sonst '
              'dem eingeloggten Nutzer sein eigener Offline-Bestand weg');
    });

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

      // Ohne onError-Handler ist das ein unbehandelter Zonen-Fehler und der
      // Test faellt hier durch — genau die Eskalation, die von aussen ueber
      // den BROWSABLE-Deeplink-Intent ausloesbar war.
      repository.emitError(StateError('AuthRetryableFetchException'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('screen-fake-home')), findsOneWidget,
          reason: 'ein Strom-Fehler ist kein Session-Verlust');

      // Und der Gate hoert weiter zu: ein Fehler darf das Abonnement nicht
      // beenden, sonst bekaeme er den echten Widerruf nie mit.
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

      // Kein Push, nichts abzuraeumen — nach der alten Regel („nur wenn Routen
      // wegfielen") blieb der Nutzer hier ohne jede Erklaerung auf dem Login.
      repository.emit(null);
      await tester.pumpAndSettle();

      expect(find.textContaining('Sitzung ist abgelaufen'), findsOneWidget);
      // Die Snackbar darf keinen haengenden Timer hinterlassen.
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
  });
}
