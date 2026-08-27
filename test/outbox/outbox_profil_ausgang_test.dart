import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart' show SyncDelivery;
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'outbox_test_helpers.dart';

// Two families that hang on the same question — what does the store CLAIM?
//
// Gap E: the recipes screen showed a success toast unconditionally, so the
// store now returns what happened and leaves the ONE message to the caller.
// Gap D: `applySettings`/`completeOnboarding` wrote cache and Supabase WITHOUT
// an outbox, so the next online start overwrote the offline change silently —
// and told the user to save again later, which is no longer true.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- What the USER is told about a queued write ---------------------------

  test(
      'Offline-Log: KEIN Rollback, Op persistiert in der Outbox, '
      'dezenter Hinweis statt rotem Sync-Fehler', () async {
    final s = setup();
    s.server.offline = true;
    await boot(s.store);

    final id = s.store.addResultToDailyTotal(mealResult('Offline-Bowl'));
    await settle();

    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.dailyConsumedKcal, 300);

    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));
    final persisted = await s.cache.readOutbox();
    expect(persisted!.map((o) => o.kind), contains(SyncOpKind.mealInsert));

    // A quiet hint, not a red toast, and only ONE per episode.
    expect(s.snacks.messages.where((m) => m.startsWith('Sync (')), isEmpty);
    expect(s.snacks.offlineHints, hasLength(1));
    expect(s.snacks.offlineHints.single,
        'Offline — wird synchronisiert, sobald du wieder online bist.');
    final ton = s.snacks.tones[
        s.snacks.messages.indexWhere((m) => m.startsWith('Offline'))];
    expect(ton, isNot(SnackTone.error), reason: 'kein Rot-Alarm');
  });

  test(
      'Server-Fehler (500) statt Netz weg: Op queued wie gehabt, aber der '
      'Hinweis ist die neutrale Retry-Meldung — kein "Offline", keine '
      'Roh-Details', () async {
    final s = setup();
    await boot(s.store);
    // Server reachable, writes rejected: a PostgrestException, not a net error.
    s.server.rejectMealWrites = true;

    final id = s.store.addResultToDailyTotal(mealResult('Constraint-Bowl'));
    await settle();

    // Same as offline: no rollback, the op sits in the outbox.
    expect(s.store.loggedMeals.map((m) => m.id), contains(id));
    expect(s.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.mealInsert));

    // The server answered, so it is the retry message, once per episode.
    expect(s.snacks.offlineHints, isEmpty);
    expect(
      s.snacks.messages.where((m) =>
          m ==
          'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.'),
      hasLength(1),
    );

    // Schema-leak guard: no raw error text, no table names.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('PostgrestException')));
      expect(m, isNot(contains('logged_meals')));
      expect(m, isNot(contains('kaputt')));
      expect(m, isNot(startsWith('Sync (')));
    }
  });

  // --- Gap E: the store REPORTS the outcome instead of letting it be claimed -

  test('Luecke E: ein zugestelltes Rezept meldet delivered', () async {
    final s = setup();
    await boot(s.store);

    expect(await s.store.createUserRecipe(userRecipe('user_ok')),
        SyncDelivery.delivered);
    expect(s.server.recipeRows.keys, contains('user_ok'));
  });

  test(
      'Luecke E: offline eingereiht meldet queuedOffline — und der Store '
      'toastet NICHT mehr selbst', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;

    expect(await s.store.createUserRecipe(userRecipe('user_offline')),
        SyncDelivery.queuedOffline);
    await settle();

    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_offline'));
    expect(s.snacks.messages, isEmpty,
        reason: 'zwei Meldungen hintereinander („gespeichert." und gleich '
            'darauf „Offline — …") waren der Bug; der Aufrufer sagt jetzt '
            'beides in einem Satz');
  });

  test('Luecke E: eine Server-Ablehnung meldet queuedRetry, nicht Offline',
      () async {
    final s = setup();
    await boot(s.store);
    // 500 on user_recipes writes: the server ANSWERS, so "offline" would lie.
    s.server.rejectRecipeWrites = true;

    expect(await s.store.createUserRecipe(userRecipe('user_500')),
        SyncDelivery.queuedRetry);
    expect(s.snacks.messages, isEmpty);
  });

  test('Luecke E: die Loeschung meldet ihren Ausgang genauso', () async {
    final s = setup();
    s.server.recipeRows['user_weg'] = serverRecipeRow('user_weg');
    await boot(s.store);
    s.server.offline = true;

    expect(await s.store.deleteUserRecipe('user_weg'),
        SyncDelivery.queuedOffline);
    expect(s.snacks.messages, isEmpty);
  });

  test(
      'Luecke E: ein haengender Write blockiert die Rueckmeldung nicht ewig — '
      'nach dem Feedback-Fenster gilt „liegt in der Warteschlange"', () async {
    // PostgREST has no timeout (gap B): the test waits a real window.
    final s = setup();
    await boot(s.store);
    s.server.hangRecipeWrites = true;

    final ausgang = await s.store.createUserRecipe(userRecipe('user_haenger'));

    expect(ausgang, SyncDelivery.queuedRetry);
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die Meldung darf nur behaupten, was auch stimmt: die Op liegt '
            'in der persistierten Queue');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // --- Gap D: profile changes survive offline -------------------------------

  test(
      'Luecke D: offline geaendertes Gewicht steht nach dem naechsten '
      'ONLINE-Start noch da — und ist zugestellt', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(a.store);
    expect(a.store.profile.weightKg, 80,
        reason: 'Vorbedingung: der Boot hat den Server-Stand hydriert');

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84, dailyKcalGoal: 1900, manualEnergy: true),
      notificationsEnabled: false,
    );
    await settle();
    expect(a.store.profile.weightKg, 84,
        reason: 'Vorbedingung: offline sieht der Nutzer seinen neuen Wert');
    a.store.flushPendingWrites(); // app shutdown
    await settle();

    // Restart WITH network; the server still knows only the old state.
    final b = setup(kv: kv);
    b.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(b.store);

    expect(b.store.profile.weightKg, 84,
        reason: 'die Serverzeile darf eine pendende Profil-Aenderung nicht '
            'ueberschreiben');
    expect(b.store.profile.dailyKcalGoal, 1900);
    expect(b.server.profileRow!['weight_kg'], 84,
        reason: 'und sie muss zugestellt werden, nicht nur lokal ueberleben');
    expect((await b.cache.readProfile())!.weightKg, 84,
        reason: 'der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  test(
      'Luecke D: offline aendern, OFFLINE neu starten — der neue Wert steht',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await settle();
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.profile.weightKg, 84);
    expect(b.store.pendingOutbox.map((o) => o.kind),
        contains(SyncOpKind.profileUpsert),
        reason: 'die Zustellung steht weiterhin aus und muss die Sitzung '
            'ueberleben');
  });

  test(
      'Luecke D: zwei Offline-Aenderungen erzeugen EINE Op — das Profil ist '
      'eine einzelne Zeile, die letzte Aenderung gewinnt', () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await settle();
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 86, dailyKcalGoal: 2000),
      notificationsEnabled: false,
    );
    await settle();

    final profilOps = a.store.pendingOutbox
        .where((o) => o.kind == SyncOpKind.profileUpsert)
        .toList();
    expect(profilOps, hasLength(1),
        reason: 'zwei Ops wuerden sich beim Replay gegenseitig ueberholen');
    expect(profilOps.single.profile!.weightKg, 86);
    expect(profilOps.single.profile!.dailyKcalGoal, 2000);

    // Only the replay counts: the hand-set 2200 kcal of the fixture is a
    // stale live row, so the boot itself already wrote the healed goals back
    // (F7-01 write-back on `ProfileSync.lastLoadHealed`).
    int profilPosts() => a.server.requests
        .where((r) => r.method == 'POST' && r.url.path.contains('/profiles'))
        .length;
    final vorReplay = profilPosts();

    a.server.offline = false;
    a.store.flushPendingWrites();
    await settle();

    expect(a.server.profileRow!['weight_kg'], 86);
    expect(a.server.profileRow!['daily_kcal_goal'], 2000);
    expect(profilPosts() - vorReplay, 1,
        reason: 'genau ein Zustellversuch fuer beide Aenderungen');
    expect(a.store.pendingOutbox, isEmpty);
  });

  test(
      'Luecke D: der Profil-Save meldet die WARTESCHLANGE, nicht mehr '
      '„bitte speichere es später erneut" — es gibt jetzt einen Auto-Retry',
      () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(testProfile(weightKg: 80));
    await boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(weightKg: 84),
      notificationsEnabled: false,
    );
    await settle();

    expect(a.snacks.offlineHints.single,
        'Offline — wird synchronisiert, sobald du wieder online bist.',
        reason: 'die alte Meldung bat den Nutzer, spaeter selbst erneut zu '
            'speichern — das waere jetzt gelogen');
    expect(a.snacks.tones, isNot(contains(SnackTone.error)),
        reason: 'eine Warteschlange ist kein Fehler');
  });

  test(
      'Luecke D: ein offline abgeschlossenes Onboarding ueberlebt den '
      'naechsten ONLINE-Start — sonst wirft die Bootstrap-Zeile den Nutzer '
      'zurueck und seine Koerperdaten sind weg', () async {
    final kv = InMemoryKeyValueStore();
    // The row the signup trigger creates: defaults, onboarding open.
    Map<String, dynamic> bootstrapZeile() =>
        serverProfileRow(const UserProfile());

    final a = setup(kv: kv);
    a.server.profileRow = bootstrapZeile();
    await boot(a.store);
    expect(a.store.needsOnboarding, isTrue, reason: 'Vorbedingung');

    a.server.offline = true;
    await a.store.completeOnboarding(
        const UserProfile(weightKg: 91, heightCm: 186, onboardingCompleted: true));
    await settle();
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.profileRow = bootstrapZeile();
    await boot(b.store);

    expect(b.store.profile.weightKg, 91);
    expect(b.store.needsOnboarding, isFalse,
        reason: 'die alte Bootstrap-Zeile schickte den Nutzer erneut durchs '
            'Onboarding — mit den Defaults statt seinen Angaben');
    expect(b.server.profileRow!['weight_kg'], 91);
    expect(b.server.profileRow!['onboarding_completed'], isTrue);
  });

  test(
      'Luecke D: eine pendende Profil-Op IST eine echte Quelle — sonst '
      'verschluckt der Clobber-Schutz die naechste Aenderung', () async {
    final kv = InMemoryKeyValueStore();
    // Only the outbox is on storage, so the state comes from the op alone.
    await seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.profileUpsert(testProfile(weightKg: 91, dailyKcalGoal: 1800))
          .toJson(),
    ]);

    final s = setup(kv: kv);
    s.server.offline = true;
    await boot(s.store);

    expect(s.store.profile.weightKg, 91);

    // The point: the next change must land, not be blocked by the A1 guard.
    await s.store.applySettings(
      newProfile: s.store.profile.copyWith(weightKg: 92),
      notificationsEnabled: false,
    );
    await settle();

    final imCache = await s.cache.readProfile();
    expect(imCache, isNotNull,
        reason: 'ohne diese Zuordnung schrieb applySettings gar nichts mehr — '
            'weder Cache noch Op, und ohne jeden Hinweis');
    expect(imCache!.weightKg, 92);
    expect(
        s.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.profileUpsert)
            .single
            .profile!
            .weightKg,
        92);
  });

  test(
      'Luecke D: auch die Diaet-Praeferenz ueberlebt — sie ist Teil derselben '
      'Profilzeile', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(testProfile());
    await boot(a.store);

    a.server.offline = true;
    await a.store.applySettings(
      newProfile: a.store.profile.copyWith(diet: DietPreference.vegan),
      notificationsEnabled: false,
    );
    await settle();
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.profileRow = serverProfileRow(testProfile());
    await boot(b.store);

    expect(b.store.profile.diet, DietPreference.vegan);
    expect(b.server.profileRow!['diet_preference'], 'vegan');
  });
}
