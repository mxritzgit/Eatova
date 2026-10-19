// The onboarding weight becomes the first weigh-in (review 2026-10-19), so
// the trend and the weekly check start on day one: once, in the onboarding's
// commit, and only while the server answered an empty weight log.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart';

import 'outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 19, 9);

const UserProfile _fresh = UserProfile(weightKg: 70);

const UserProfile _finished = UserProfile(
  weightKg: 82,
  heightCm: 180,
  onboardingCompleted: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the onboarding weight is logged once, counted once', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_fresh);
    await boot(a.store);

    await Future.wait([
      a.store.completeOnboarding(_finished),
      a.store.completeOnboarding(_finished),
    ]);
    await settle();
    await a.store.completeOnboarding(_finished);
    await settle();

    final entry = a.store.weightLog.entries.single;
    expect((entry.weightKg, entry.timestamp), (82.0, _now));
    expect(entry.id, isNotNull);
    expect(a.server.weightRows.keys, [entry.id]);
    expect(a.server.weightRows[entry.id]!['weight_kg'], 82.0);
    expect(a.server.weightLogsCounted, 1);
    expect(a.server.operations('weightInsert'), hasLength(1));
    expect(a.store.weightLog.planWeightKg(_now), 82.0,
        reason: 'the trend starts on day one');
    expect(a.store.profile.weightKg, 82, reason: 'no re-anchor needed');
    expect(a.store.pendingOutbox, isEmpty);
  }));

  test('offline, the weigh-in is one commit with the profile', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_fresh);
    await boot(a.store);
    a.server.offline = true;

    await a.store.completeOnboarding(_finished);
    await settle();

    expect(a.store.pendingOutbox.map((op) => op.kind), [
      SyncOpKind.profileUpsert,
      SyncOpKind.weightInsert,
    ]);
    expect(a.store.pendingOutbox.last.weightKg, 82.0);
  }));

  test('an account with weigh-ins gets none', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_fresh);
    final id = uuidV4();
    a.server.weightRows[id] = <String, dynamic>{
      'id': id,
      'recorded_at': _now.subtract(const Duration(days: 3)).toUtc().toIso8601String(),
      'weight_kg': 75.0,
    };
    await boot(a.store);

    await a.store.completeOnboarding(_finished);
    await settle();

    expect(a.store.weightLog.entries.map((e) => e.id), [id]);
    expect(a.server.operations('weightInsert'), isEmpty);
  }));

  test('an unknown weight log gets none', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server
      ..profileRow = serverProfileRow(_fresh)
      ..rejectWeightLogReads = true;
    await boot(a.store);

    await a.store.completeOnboarding(_finished);
    await settle();

    expect(a.store.profile.onboardingCompleted, isTrue);
    expect(a.store.weightLog.entries, isEmpty);
    expect(a.server.operations('weightInsert'), isEmpty);
  }));
}
