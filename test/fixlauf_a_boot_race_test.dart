import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-01: the welcome gate opens on the cached profile while
// the six boot loads are still in flight. A live write delivered in that
// window leaves the outbox, and the server answer (a snapshot from BEFORE the
// write) then REPLACED the whole list — the meal vanished, a deleted entry
// came back, and the cache snapshot persisted the wrong state.
//
// Contract pinned here: a load result is a full replacement only if the
// collection was not mutated during the load; otherwise it is merged (local
// wins, missing server ids are added, locally deleted ids stay deleted).

/// The cached meals count towards TODAY, so their timestamp must not be able
/// to slip over midnight: `DateTime.now() - 1 h` put them on the PREVIOUS day
/// between 00:00 and 01:00 local, `dailyConsumedKcal` then saw only the live
/// meal, and the test was red every night in that hour (CI hit it on
/// 2026-08-31 at 00:41 UTC: expected 800, got 300). [heuteUm] anchors to today
/// instead of to a fixed date, which would only rot differently.
LoggedMeal _cachedMeal(String id, String name) => LoggedMeal(
      id: id,
      result: mealResult(name, kcal: 250),
      loggedAt: heuteUm(),
    );

/// Cache + server both know m1 and m2; the gate opens on the cached profile
/// while every boot GET is held.
Future<FixlaufSetup> _bootMitAngehaltenenReads({String? extraServerRow}) async {
  final s = fixlaufSetup();
  await s.cache!.writeProfile(completedProfile);
  await s.cache!.writeLoggedMeals(
      [_cachedMeal('m1', 'Eins'), _cachedMeal('m2', 'Zwei')]);
  s.server.profileRow = serverProfileRow(completedProfile);
  s.server.mealRows['m1'] = serverMealRow('m1', name: 'Eins');
  s.server.mealRows['m2'] = serverMealRow('m2', name: 'Zwei');
  if (extraServerRow != null) {
    s.server.mealRows[extraServerRow] =
        serverMealRow(extraServerRow, name: 'Fremdgeraet');
  }
  s.server.holdReads = true;
  s.store.start();
  await s.store.profileReady;
  await settle();
  expect(s.server.heldReads, greaterThanOrEqualTo(6),
      reason: 'Vorbedingung: die Boot-Loads haengen im Ladefenster');
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Live-Insert im Ladefenster ueberlebt die Server-Antwort von VOR dem '
      'Write', () async {
    final s = await _bootMitAngehaltenenReads();

    final liveId = s.store.addResultToDailyTotal(mealResult('Live-Bowl'));
    await settle();
    expect(s.store.pendingOutbox, isEmpty,
        reason: 'Vorbedingung: der Live-Write wurde zugestellt, die Op hat '
            'die Outbox verlassen — _applyPendingOpsToState kann sie nicht '
            'mehr retten');

    s.server.releaseReads();
    await settle();

    expect(s.store.loggedMeals.map((m) => m.id), contains(liveId),
        reason: 'der Snapshot von vor dem Write darf die frisch geloggte '
            'Mahlzeit nicht aus dem Tagebuch werfen');
    expect(s.store.loggedMeals.map((m) => m.id), containsAll(['m1', 'm2']));
    expect(s.store.dailyConsumedKcal, 300 + 250 + 250);
    final cached = await s.cache!.readLoggedMeals();
    expect(cached!.map((m) => m.id), contains(liveId),
        reason: 'der Cache-Snapshot nach dem Boot traegt den gemergten Stand');
  });

  test('Live-Delete im Ladefenster wird von der Server-Antwort nicht '
      'wiederbelebt', () async {
    final s = await _bootMitAngehaltenenReads();

    s.store.removeLoggedMeal('m2');
    await settle();
    expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung');

    s.server.releaseReads();
    await settle();

    expect(s.store.loggedMeals.map((m) => m.id), isNot(contains('m2')),
        reason: 'lokal geloescht bleibt geloescht — der Server-Snapshot kannte '
            'die Loeschung noch nicht');
    expect(s.store.loggedMeals.map((m) => m.id), contains('m1'));
    final cached = await s.cache!.readLoggedMeals();
    expect(cached!.map((m) => m.id), isNot(contains('m2')));
  });

  test('Server-Zeilen, die lokal fehlen und nicht geloescht wurden, kommen '
      'beim Merge dazu (anderes Geraet)', () async {
    // The server snapshot carries m9 (logged on another device); the cache
    // never saw it. Must be there BEFORE the hold, the snapshot is captured at
    // request time.
    final s = await _bootMitAngehaltenenReads(extraServerRow: 'm9');

    final liveId = s.store.addResultToDailyTotal(mealResult('Live'));
    await settle();

    s.server.releaseReads();
    await settle();

    expect(s.store.loggedMeals.map((m) => m.id),
        containsAll([liveId, 'm1', 'm2', 'm9']),
        reason: 'lokal gewinnt, aber fehlende Server-Ids werden ergaenzt');
  });

  test('Kontrolle: ohne Mutation im Ladefenster ersetzt der Server-Load die '
      'Liste weiterhin komplett', () async {
    final s = fixlaufSetup();
    await s.cache!.writeProfile(completedProfile);
    // The cache still knows m3; the server does not (deleted elsewhere).
    await s.cache!.writeLoggedMeals([
      _cachedMeal('m1', 'Eins'),
      _cachedMeal('m2', 'Zwei'),
      _cachedMeal('m3', 'Drei'),
    ]);
    s.server.profileRow = serverProfileRow(completedProfile);
    s.server.mealRows['m1'] = serverMealRow('m1');
    s.server.mealRows['m2'] = serverMealRow('m2');

    await bootStore(s.store);

    expect(s.store.loggedMeals.map((m) => m.id).toSet(), {'m1', 'm2'},
        reason: 'ohne Rennen bleibt der Server die Wahrheit — der Merge '
            'greift nur, wenn lokal etwas passiert ist');
  });

  test('Favorit und Gewicht aus dem Ladefenster ueberleben ebenfalls',
      () async {
    final s = await _bootMitAngehaltenenReads();

    s.store.toggleFavorite(mealResult('Pin-Bowl'));
    s.store.logWeight(83.5);
    await settle();
    expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung');

    s.server.releaseReads();
    await settle();

    expect(s.store.isFavorite(mealResult('Pin-Bowl')), isTrue,
        reason: 'die leere Favoriten-Antwort von vor dem Pin darf ihn nicht '
            'entfernen');
    expect(s.store.weightLog.latest?.weightKg, 83.5,
        reason: 'die leere Gewichts-Antwort von vor dem Eintrag darf ihn '
            'nicht entfernen');
  });

  test('Onboarding-Variante: ein im Ladefenster abgeschlossenes Onboarding '
      'wird von der Bootstrap-Zeile nicht zurueckgedreht', () async {
    final s = fixlaufSetup();
    // Cached bootstrap row: the gate opens straight into onboarding while the
    // server (same row) is still loading.
    const bootstrap = UserProfile();
    await s.cache!.writeProfile(bootstrap);
    s.server.profileRow = serverProfileRow(bootstrap);
    s.server.holdReads = true;
    s.store.start();
    await s.store.profileReady;
    await settle();
    expect(s.store.needsOnboarding, isTrue, reason: 'Vorbedingung');

    await s.store.completeOnboarding(
        const UserProfile(weightKg: 91, heightCm: 186, onboardingCompleted: true));
    await settle();
    expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung: zugestellt');

    s.server.releaseReads();
    await settle();

    expect(s.store.profile.weightKg, 91,
        reason: 'die alte Bootstrap-Zeile darf die eingegebenen Koerperdaten '
            'nicht ueberschreiben');
    expect(s.store.needsOnboarding, isFalse);
    expect((await s.cache!.readProfile())!.weightKg, 91);
  });

  test('ohne Cache-Instanz bootet der Store weiterhin ueber den Server',
      () async {
    final s = fixlaufSetup(ohneCache: true);
    s.server.profileRow = serverProfileRow(completedProfile);
    s.server.mealRows['m1'] = serverMealRow('m1');
    await bootStore(s.store);
    expect(s.store.loggedMeals.map((m) => m.id), ['m1']);
    expect(s.cache, isNull);
  });
}
