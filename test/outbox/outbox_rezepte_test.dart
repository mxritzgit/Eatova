import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart'
    show SyncDelivery, outboxLossHint;
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Gap A/C plus the counter-verification round for user recipes.
//
// Meals, favorites, weight and stats always had TWO nets: the write-through
// cache AND the outbox. `user_recipes` only had the outbox, and
// `_bootFromSupabase` set `_userRecipes = loadedRecipes` unconditionally, so
// with no pending op the first online start overwrote the cache slot.
//
// The counter-verification tests start from the REPORTED ACTION and attack the
// neighbours: delete, the combination, two starts, an answering server, no
// cache, a user switch.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Luecke A: ein im Flugmodus angelegtes Rezept ueberlebt den Kaltstart — '
      'auch nachdem die Outbox es zugestellt hat und damit leer ist', () async {
    final kv = InMemoryKeyValueStore();

    final a = setup(kv: kv);
    await boot(a.store);
    a.server.offline = true;
    a.store.createUserRecipe(userRecipe('user_flug', title: 'Flugmodus-Bowl'));
    await settle();
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_flug'),
        reason: 'Vorbedingung: im Flugmodus ist das Rezept sichtbar');

    // The outbox delivers and empties: only the cache still holds the recipe.
    a.server.offline = false;
    a.store.flushPendingWrites();
    await settle();
    expect(a.store.pendingOutbox, isEmpty);
    // App shutdown forces the debounced cache writes.
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_flug'),
        reason: 'ohne Cache-Slot war das Rezept nach dem Kaltstart weg: die '
            'Outbox war das EINZIGE Netz und hatte ihre Schuldigkeit getan');
  });

  test(
      'Luecke A+B: haengt der Rezept-Write (Supabase-Aufrufe tragen kein '
      'Timeout), tragen BEIDE Netze — die Op liegt vor dem Write in der '
      'Outbox, das Rezept im Cache', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await boot(a.store);
    a.server.hangRecipeWrites = true;

    a.store.createUserRecipe(userRecipe('user_haenger'));
    await settle();
    // Gap B: with no answer neither callback fires, so the op must pre-exist.
    expect(a.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_haenger'),
        reason: 'die Op darf nicht erst im Fehler-Callback entstehen — der '
            'kommt hier nie');
    a.store.flushPendingWrites();
    await settle();
    // Gap A: independently of the outbox, the cache slot holds the recipe.
    expect((await a.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_haenger'),
        reason: 'zwei unabhaengige Netze — der Cache haelt auch ohne Op');

    // Cold start deliberately WITHOUT network; gap C has its own test.
    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_haenger'),
        reason: 'zwischen Tap und (ausbleibendem) Fehler existierte das '
            'Rezept nur im RAM');
  });

  test(
      'Luecke A: der Kaltstart ohne Netz zeigt die BESTEHENDEN Eigen-Rezepte '
      '— frueher waren dabei ALLE weg, nicht nur das neue', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    // Real profile in the cache: the A1 guard needs a hydration source.
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_alt_1'] = serverRecipeRow('user_alt_1');
    a.server.recipeRows['user_alt_2'] = serverRecipeRow('user_alt_2');
    await boot(a.store);
    expect(a.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_alt_1', 'user_alt_2']),
        reason: 'Vorbedingung: der Boot hat sie vom Server geladen');
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_alt_1', 'user_alt_2']),
        reason: 'der Boot-Snapshot muss die Rezepte mitnehmen — sonst zeigt '
            'jeder Start im Flugmodus eine leere Eigen-Rezept-Liste');
  });

  test(
      'Luecke A: eine Offline-Loeschung ueberlebt den Kaltstart und reisst '
      'die uebrigen Eigen-Rezepte nicht mit', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_bleibt'] = serverRecipeRow('user_bleibt');
    a.server.recipeRows['user_weg'] = serverRecipeRow('user_weg');
    await boot(a.store);

    a.server.offline = true;
    a.store.deleteUserRecipe('user_weg');
    await settle();
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(
        b.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')));
  });

  test(
      'Luecke C: ein nur lokal bekanntes Rezept ueberlebt den Boot MIT Netz — '
      'die Serverliste ERGAENZT den lokalen Stand, sie ersetzt ihn nicht',
      () async {
    final kv = InMemoryKeyValueStore();
    final seed = LocalCache(kv, 'user-outbox');
    await seed.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // A recipe only the cache knows: no server row, no outbox op.
    await seed.writeUserRecipes(<FitnessRecipe>[userRecipe('user_nur_lokal')]);

    final s = setup(kv: kv);
    s.server.recipeRows['user_server'] = serverRecipeRow('user_server');
    await boot(s.store);

    expect(s.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_nur_lokal', 'user_server']),
        reason: 'der Server-Load hat den lokalen Stand frueher restlos '
            'ueberschrieben');
    expect((await s.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_nur_lokal'),
        reason: 'der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  test(
      'Luecke C: ein lokal geloeschtes Rezept kommt NICHT zurueck, obwohl der '
      'Cache-Blob es noch fuehrt und der Server es kannte', () async {
    final kv = InMemoryKeyValueStore();
    final seed = LocalCache(kv, 'user-outbox');
    await seed.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // The blob is STALE: the delete died in the debounce window, the op did not.
    await seed.writeUserRecipes(
        <FitnessRecipe>[userRecipe('user_bleibt'), userRecipe('user_weg')]);
    await seedRawOutbox(kv, [SyncOp.recipeDelete('user_weg').toJson()]);

    final s = setup(kv: kv);
    s.server.recipeRows['user_bleibt'] = serverRecipeRow('user_bleibt');
    s.server.recipeRows['user_weg'] = serverRecipeRow('user_weg');
    await boot(s.store);

    expect(s.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(s.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')),
        reason: 'der Merge muss vom LEBENDEN Stand ausgehen (Cache + bereits '
            'angewandte Ops), nicht vom rohen Cache-Blob — der kennt die '
            'Loeschung noch nicht');
    expect(s.server.recipeRows.keys, isNot(contains('user_weg')),
        reason: 'Vorbedingung: der Boot-Replay hat die Loeschung zugestellt');
    expect((await s.cache.readUserRecipes())!.map((r) => r.slug),
        isNot(contains('user_weg')));
  });

  test(
      'Fehlerbild des Nutzers: Flugmodus -> Rezept angelegt -> App zu -> '
      'Flugmodus aus -> App auf. Das Rezept ist noch da', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);
    // Airplane mode at its nastiest: the request never fails, it NEVER ANSWERS.
    a.server.hangRecipeWrites = true;
    a.store.createUserRecipe(userRecipe('user_flugmodus', title: 'Flug-Bowl'));
    await settle();
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'Vorbedingung: im Flugmodus war das Rezept sichtbar');
    a.store.flushPendingWrites(); // app shutdown
    await settle();

    final b = setup(kv: kv);
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_flugmodus'),
        reason: 'genau hier war das Rezept weg: der erfolgreiche Server-Load '
            'ersetzte die Liste, und der Boot-Snapshot schrieb das fest');
  });

  // =========================================================================
  // COUNTER-VERIFICATION
  // =========================================================================

  test(
      'Gegenprobe 1 — der gemeldete Fall wortgetreu: Flugmodus AN, Rezept '
      'angelegt, Store weggeworfen, Flugmodus AUS, Boot. Das Rezept ist da '
      'UND beim Server angekommen', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);

    // Airplane mode on: the request FAILS; the hanging case has its own test.
    a.server.offline = true;
    final ausgang =
        await a.store.createUserRecipe(userRecipe('user_gemeldet', title: 'Bowl'));
    expect(ausgang, SyncDelivery.queuedOffline);
    expect(a.store.userRecipes.map((r) => r.slug), contains('user_gemeldet'),
        reason: 'Vorbedingung des Berichts: „war sichtbar"');

    a.store.flushPendingWrites();
    await settle();

    // Airplane mode off, app up: NEW store, NEW server, SAME cache.
    final b = setup(kv: kv);
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_gemeldet'),
        reason: 'genau hier war das Rezept weg');
    expect(b.server.recipeRows.keys, contains('user_gemeldet'),
        reason: 'sichtbar reicht nicht — es muss auch ankommen, sonst haengt '
            'der Bestand fuer immer an diesem einen Geraet');
    expect(b.store.pendingOutbox, isEmpty);
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_gemeldet'));
  });

  test(
      'Gegenprobe 2 — die Gegenrichtung: offline GELOESCHT, dann online neu '
      'gestartet. Das Rezept aufersteht nicht, und die Loeschung kommt an',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    a.server.recipeRows['user_bleibt'] = serverRecipeRow('user_bleibt');
    a.server.recipeRows['user_weg'] = serverRecipeRow('user_weg');
    await boot(a.store);
    expect(a.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_bleibt', 'user_weg']),
        reason: 'Vorbedingung: beide sind da');

    a.server.offline = true;
    expect(await a.store.deleteUserRecipe('user_weg'),
        SyncDelivery.queuedOffline);
    a.store.flushPendingWrites();
    await settle();

    // Restart WITH network: without replay-before-boot the recipe would be back.
    final b = setup(kv: kv);
    b.server.recipeRows['user_bleibt'] = serverRecipeRow('user_bleibt');
    b.server.recipeRows['user_weg'] = serverRecipeRow('user_weg');
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_bleibt'));
    expect(b.store.userRecipes.map((r) => r.slug), isNot(contains('user_weg')),
        reason: 'eine Loeschung, die wiederkommt, ist derselbe Vertrauens'
            'bruch wie ein Rezept, das verschwindet');
    expect(b.server.recipeRows.keys, isNot(contains('user_weg')),
        reason: 'lokal weg reicht nicht — sonst kommt es auf dem naechsten '
            'Geraet zurueck');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        isNot(contains('user_weg')));
  });

  test(
      'Gegenprobe 3 — offline ANGELEGT und offline wieder GELOESCHT: nach der '
      'Landung existiert es weder lokal noch beim Server', () async {
    final kv = InMemoryKeyValueStore();
    final s = setup(kv: kv);
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(s.store);

    s.server.offline = true;
    await s.store.createUserRecipe(userRecipe('user_kurz'));
    await settle();
    await s.store.deleteUserRecipe('user_kurz');
    await settle();

    // The delete must NOT coalesce away the upsert; the reverse resurrects it.
    expect(
        s.store.pendingOutbox
            .where((o) => o.entityKey == 'recipe:user_kurz')
            .map((o) => o.kind)
            .toList(),
        <SyncOpKind>[SyncOpKind.recipeUpsert, SyncOpKind.recipeDelete]);

    s.server.offline = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.recipeRows.keys, isNot(contains('user_kurz')),
        reason: 'insert -> delete muss den Replay in dieser Reihenfolge '
            'ueberleben, sonst bleibt eine Leiche auf dem Server');
    expect(
        s.store.userRecipes.map((r) => r.slug), isNot(contains('user_kurz')));

    final b = setup(kv: kv);
    await boot(b.store);
    expect(
        b.store.userRecipes.map((r) => r.slug), isNot(contains('user_kurz')),
        reason: 'auch der naechste Kaltstart darf es nicht zurueckholen');
  });

  test(
      'Gegenprobe 4 — offline angelegt, OFFLINE neu gestartet, DANN online: '
      'genau EINE Zustellung. Zwei Netze duerfen nicht zweimal liefern',
      () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(userRecipe('user_zweimal'));
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_zweimal'),
        reason: 'Vorbedingung: der zweite Start ohne Netz zeigt es');
    expect(b.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_zweimal'),
        reason: 'Vorbedingung: die Zustellung steht weiterhin aus');

    b.server.offline = false;
    b.store.flushPendingWrites();
    await settle();

    expect(
        b.server.requests.where((r) =>
            r.method == 'POST' && r.url.path.contains('/user_recipes')),
        hasLength(1),
        reason: 'der Cache-Stand darf keine zweite Zustellung ausloesen — '
            'der Upsert waere zwar idempotent, aber ein doppelter Write ist '
            'der erste Schritt zu einem doppelten Zaehler');
    expect(b.server.recipeRows.keys, contains('user_zweimal'));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 5 — ZWEI Rezepte offline: beide ueberleben den Kaltstart, '
      'beide kommen an, die Reihenfolge bleibt stabil', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);

    a.server.offline = true;
    await a.store.createUserRecipe(userRecipe('user_eins', title: 'Eins'));
    await settle();
    await a.store.createUserRecipe(userRecipe('user_zwei', title: 'Zwei'));
    await settle();
    expect(a.store.userRecipes.map((r) => r.slug).toList(),
        <String>['user_zwei', 'user_eins'],
        reason: 'zuletzt angelegt steht oben — darauf schaut der Nutzer');
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.userRecipes.map((r) => r.slug).toList(),
        <String>['user_zwei', 'user_eins'],
        reason: 'Cache-Blob und Op-Ueberlagerung duerfen die Liste nicht '
            'durcheinanderbringen');

    b.server.offline = false;
    b.store.flushPendingWrites();
    await settle();

    expect(b.server.recipeRows.keys,
        containsAll(<String>['user_eins', 'user_zwei']));
    expect(b.store.userRecipes.map((r) => r.slug),
        containsAll(<String>['user_eins', 'user_zwei']));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 6 — der Server ANTWORTET beim Replay mit 500: das Rezept '
      'bleibt sichtbar, die Op bleibt liegen, nichts wird als Verlust '
      'gemeldet', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(userRecipe('user_500'));
    a.store.flushPendingWrites();
    await settle();

    // Restart: recipe writes rejected, the READING boot load returns EMPTY.
    final b = setup(kv: kv);
    b.server.rejectRecipeWrites = true;
    await boot(b.store);

    expect(b.store.userRecipes.map((r) => r.slug), contains('user_500'));
    final op = b.store.pendingOutbox
        .where((o) => o.entityKey == 'recipe:user_500')
        .single;
    expect(op.attempts, 1, reason: 'ein 500 verbrennt genau einen Versuch');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_500'),
        reason: 'der Boot-Snapshot darf den Stand nicht wegschreiben');
    expect(b.snacks.messages, isNot(contains(outboxLossHint())),
        reason: 'ein retrybarer 500 ist kein Verlust');

    b.server.rejectRecipeWrites = false;
    b.store.flushPendingWrites();
    await settle();
    expect(b.server.recipeRows.keys, contains('user_500'));
    expect(b.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 7 — KEIN Cache (DEK weg): der Store taeuscht keinen Erfolg '
      'vor. Das Rezept bleibt sichtbar, gilt als eingereiht (nicht als '
      'zugestellt) und geht raus, sobald das Netz wieder da ist', () async {
    final s = setupOhneCache();
    await boot(s.store);
    s.server.offline = true;

    final ausgang = await s.store.createUserRecipe(userRecipe('user_ohne_cache'));

    expect(ausgang, SyncDelivery.queuedOffline,
        reason: 'ohne Cache waere ein blankes „gespeichert." die Luege — der '
            'Aufrufer muss den Warteschlangen-Zusatz bekommen');
    expect(s.store.userRecipes.map((r) => r.slug), contains('user_ohne_cache'));
    expect(s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_ohne_cache'),
        reason: 'die Op existiert — nur persistieren kann sie sich nirgends');

    s.server.offline = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.server.recipeRows.keys, contains('user_ohne_cache'),
        reason: 'innerhalb der Sitzung traegt die Outbox auch ohne Platte');
    expect(s.store.pendingOutbox, isEmpty);
  });

  test(
      'Gegenprobe 8 — Nutzerwechsel: die Eigen-Rezepte von A tauchen bei B '
      'nicht auf, und A bekommt sie beim naechsten Login zurueck', () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(injizierterCache: LocalCache(kv, 'user-a'));
    await boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(userRecipe('user_a_geheim'));
    a.store.flushPendingWrites();
    await settle();
    expect(kv.snapshot.keys, contains('eatova.v1.user_recipes.user-a'),
        reason: 'Vorbedingung: A hat wirklich etwas auf der Platte');

    await a.store.signOutCleanup();
    expect(kv.snapshot.keys, isNot(contains('eatova.v1.user_recipes.user-a')),
        reason: 'Zutaten und Mengen sind Nutzerinhalt — der Slot faellt beim '
            'Logout auch dann, wenn die Outbox erhalten bleibt (M-1)');

    final b = setup(injizierterCache: LocalCache(kv, 'user-b'));
    b.server.offline = true;
    await boot(b.store);

    expect(b.store.userRecipes, isEmpty,
        reason: 'jeder Slot-Name traegt die User-ID — B liest seinen eigenen, '
            'leeren Namensraum');
    expect(b.store.pendingOutbox, isEmpty,
        reason: 'auch die beim Logout ERHALTENE Outbox gehoert A, nicht B');

    // A is back: the preserved outbox is why the slot may be dropped on logout.
    final a2 = setup(injizierterCache: LocalCache(kv, 'user-a'));
    a2.server.offline = true;
    await boot(a2.store);
    expect(a2.store.userRecipes.map((r) => r.slug), contains('user_a_geheim'));
  });

  test(
      'Gegenprobe 9 — EIN Netz faellt aus: der Outbox-Slot ist beim Lesen '
      'kaputt, der Cache traegt allein. Ein Boot MIT Netz darf das Rezept '
      'trotzdem nicht wegwerfen', () async {
    // The core of the repair without a pre-seeded blob: real user action, then
    // ONE of the two nets fails. If it survives, there were two.
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await a.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    await boot(a.store);
    a.server.offline = true;
    await a.store.createUserRecipe(userRecipe('user_nur_cache'));
    a.store.flushPendingWrites();
    await settle();

    // Cold start WITH network and a throwing outbox slot (gap F): op invisible,
    // server does not know the recipe.
    final b =
        setup(injizierterCache: OutboxLesefehlerCache(kv, 'user-outbox'));
    await boot(b.store);

    expect(b.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: das Outbox-Netz ist fuer diesen Start weg');
    expect(b.store.userRecipes.map((r) => r.slug), contains('user_nur_cache'),
        reason: 'EIN Netz muss reichen — sonst waren es nie zwei');
    expect((await b.cache.readUserRecipes())!.map((r) => r.slug),
        contains('user_nur_cache'),
        reason: 'und der Boot-Snapshot darf den Verlust nicht auch noch '
            'festschreiben');
  });

  // P3-04b: `userRecipes` sieht in zwei voellig verschiedenen Lagen gleich aus
  // — „der Nutzer hat keine Rezepte" und „wir wissen es noch nicht". Wer aus
  // einem FEHLENDEN Eintrag etwas ableitet (die Foto-Aufraeumung loescht
  // darauf hin Dateien), braucht die Unterscheidung; nur die Server-Antwort
  // liefert sie. Deshalb haengt das Flag am Rezept-Load, nicht am Ende der
  // Boot-Kette: die sechs Loads antworten unabhaengig voneinander.
  test(
      'P3-04b: userRecipesAuthoritative erst nach BEANTWORTETEM Rezept-Load — '
      'ein veraltet-leerer Cache-Slot bleibt vorlaeufig', () async {
    final kv = InMemoryKeyValueStore();
    final s = setup(kv: kv);
    await s.cache.writeProfile(
        const UserProfile(weightKg: 80, onboardingCompleted: true));
    // Genau die Lage nach dem Kill im 400-ms-Entprellfenster: der Slot steht
    // auf leer, das Rezept liegt beim Server.
    await s.cache.writeUserRecipes(const <FitnessRecipe>[]);
    s.server.recipeRows['user_da'] = serverRecipeRow('user_da');

    // NUR der Rezept-Load faellt aus; die anderen fuenf antworten. Genau
    // deshalb haengt das Flag am Rezept-Load und nicht am Boot-Ende.
    s.server.rejectRecipeReads = true;
    await boot(s.store);

    expect(s.store.userRecipes, isEmpty,
        reason: 'Vorbedingung: die Liste ist leer, obwohl es ein Rezept gibt');
    expect(s.store.userRecipesAuthoritative, isFalse,
        reason: 'Der Rezept-Load hat nicht geantwortet — diese leere Liste ist '
            'keine Aussage darueber, welche Rezepte es gibt.');
    expect(s.server.requests.map((r) => r.url.path),
        contains('/rest/v1/profiles'),
        reason: 'und der Boot als ganzes lief durch: das Flag steht fuer die '
            'EINE Sammlung, nicht fuer das Ende der Boot-Kette');

    s.server.rejectRecipeReads = false;
    await s.store.retryBoot();
    await settle();

    expect(s.store.userRecipes.map((r) => r.slug), contains('user_da'));
    expect(s.store.userRecipesAuthoritative, isTrue,
        reason: 'Nach der Antwort ist die Liste vollstaendig — ab hier darf '
            'aus einem fehlenden Eintrag geschlossen werden.');
  });
}
