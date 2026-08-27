import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'fixlauf_a_helpers.dart';

// F7-01 boot hook (package G's live-goal self-healing, package A's boot
// path): `ProfileSync.load` heals a live profile to the current calculator
// but stays a read. The store writes the healed goals back ONCE when the row
// looks stale, and never for a current or a manual profile.

/// Calculator output for [completedProfile].
KcalTargets get _targets => const KcalCalculator().calculate(completedProfile);

/// Live profile whose stored goals match the current calculator.
UserProfile get _current => completedProfile.copyWith(
      dailyKcalGoal: _targets.kcal,
      proteinGoalG: _targets.proteinG,
      carbsGoalG: _targets.carbsG,
      fatGoalG: _targets.fatG,
    );

/// Same profile with goals from an older calculator.
UserProfile get _stale => _current.copyWith(
      dailyKcalGoal: _targets.kcal + 137,
      proteinGoalG: _targets.proteinG + 9,
    );

int _profileWrites(FixlaufServer server) =>
    server.requestsTo('/profiles', method: 'POST').length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('veraltetes Live-Profil: genau EIN Profil-Write mit den Rechnerwerten, '
      'der naechste Boot schreibt nichts mehr', () async {
    final kv = InMemoryKeyValueStore();
    final a = fixlaufSetup(kv: kv);
    // Cache and server both carry the old goals (state before the update).
    await a.cache!.writeProfile(_stale);
    a.server.profileRow = serverProfileRow(_stale);

    await bootStore(a.store);

    expect(_profileWrites(a.server), 1,
        reason: 'die geheilte Zeile muss den Server erreichen — sonst heilt '
            'jeder Load erneut und die Zeile bleibt fuer immer alt');
    expect(a.server.profileRow!['daily_kcal_goal'], _targets.kcal);
    expect(a.server.profileRow!['protein_goal_g'], _targets.proteinG);
    expect(a.server.profileRow!['manual_energy'], isFalse);
    expect(a.store.profile.dailyKcalGoal, _targets.kcal);
    expect(a.store.pendingOutbox, isEmpty);

    // Second boot: cache (snapshot) and server are current now.
    final b = fixlaufSetup(kv: kv, server: a.server);
    await bootStore(b.store);
    expect(_profileWrites(b.server), 1, reason: 'kein Doppel-Save');
  });

  test('aktuelles Live-Profil: kein Write', () async {
    final s = fixlaufSetup();
    await s.cache!.writeProfile(_current);
    s.server.profileRow = serverProfileRow(_current);

    await bootStore(s.store);

    expect(_profileWrites(s.server), 0);
    expect(s.store.profile.dailyKcalGoal, _targets.kcal);
  });

  test('Manuell-Profil: kein Write, die eigenen Ziele bleiben', () async {
    final s = fixlaufSetup();
    final manuell = _stale.copyWith(manualEnergy: true);
    await s.cache!.writeProfile(manuell);
    s.server.profileRow = serverProfileRow(manuell);

    await bootStore(s.store);

    expect(_profileWrites(s.server), 0);
    expect(s.store.profile.dailyKcalGoal, _targets.kcal + 137);
  });

  test('ohne Cache-Referenz (frisches Geraet): das exakte Signal '
      'lastLoadHealed reicht — genau EIN Write', () async {
    final s = fixlaufSetup();
    s.server.profileRow = serverProfileRow(_stale);

    await bootStore(s.store);

    expect(_profileWrites(s.server), 1,
        reason: 'ProfileSync.lastLoadHealed ersetzt den Cache-Proxy; ohne '
            'Heilung (naechster Test) bleibt ein Login write-frei');
    expect(s.server.profileRow!['daily_kcal_goal'], _targets.kcal);
    expect(s.store.profile.dailyKcalGoal, _targets.kcal);
  });

  test('ohne Cache-Referenz und aktueller Zeile: kein Write', () async {
    final s = fixlaufSetup();
    s.server.profileRow = serverProfileRow(_current);

    await bootStore(s.store);

    expect(_profileWrites(s.server), 0,
        reason: 'ein Login ohne Heilung darf nicht schreiben (Clobber-Tests '
            'zaehlen die)');
  });

  test('Onboarding offen: kein Write', () async {
    final s = fixlaufSetup();
    const bootstrap = UserProfile();
    await s.cache!.writeProfile(bootstrap.copyWith(dailyKcalGoal: 1234));
    s.server.profileRow = serverProfileRow(bootstrap);

    await bootStore(s.store);

    expect(_profileWrites(s.server), 0);
  });
}
