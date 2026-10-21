// The health intro per account (reviews 2026-10-19 and 2026-10-22): the
// onboarding's commit holds the health source back, and Today's intro card
// asks instead. The answer is kept per account, so a restart neither asks
// unprompted nor forgets a "Not now". HealthKit's grant belongs to the
// device: a second account on the same iPhone neither reads nor writes
// Apple Health before it connects itself; an account cached here before the
// rule keeps its connection.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 19, 9);

/// An iOS-like health store: never asked in this session, but the device's
/// grant (another person's) would answer every read. Counts what the store
/// asks of it.
class _AppleHealth implements HealthService {
  int requests = 0, reads = 0, writes = 0;

  @override
  HealthAuthState authState = HealthAuthState.unknown;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async {
    requests++;
    return authState = HealthAuthState.unverified;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    reads++;
    return null;
  }

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    reads++;
    return 9000;
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    writes++;
    return true;
  }
}

class _HealthConnect extends _AppleHealth implements HealthConnectAccess {
  @override
  Future<HealthAuthState> requestAuthorization() async {
    requests++;
    return authState = HealthAuthState.granted;
  }

  @override
  Future<bool> openSettings() async => true;

  @override
  void restoreConnection() {}
}

Future<void> _onboard(
  ({HomeStore store, FakeServer server, LocalCache cache, SnackCapture snacks})
  a,
) async {
  a.server.profileRow = serverProfileRow(const UserProfile(weightKg: 70));
  await boot(a.store);
  expect(a.store.needsOnboarding, isTrue, reason: 'precondition');
  await a.store.completeOnboarding(
    const UserProfile(weightKg: 82, heightCm: 180, onboardingCompleted: true),
  );
  await settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('after the onboarding, HealthKit waits for the card', () => withClock(Clock.fixed(_now), () async {
    final health = _AppleHealth();
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, health: health, disposeStore: false);
    await _onboard(a);

    expect(a.store.healthIntroVisible, isTrue);
    expect(a.store.healthAutoConnectAllowed, isFalse);
    expect(health.requests, 0);
    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), 'pending');

    // A restart before any answer keeps waiting.
    a.store.dispose();
    final b = setup(kv: kv, geteilterServer: a.server, health: health);
    await boot(b.store);
    expect(b.store.healthIntroVisible, isTrue);
    expect(b.store.healthAutoConnectAllowed, isFalse);

    await b.store.acceptHealthIntro();
    await settle();

    expect(health.requests, 1);
    expect(b.store.healthIntroVisible, isFalse);
    expect(b.store.healthAutoConnectAllowed, isTrue);
    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), 'connected');
  }));

  test('"Not now" hides the card and asks nobody, also after a restart', () => withClock(Clock.fixed(_now), () async {
    final health = _AppleHealth();
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, health: health, disposeStore: false);
    await _onboard(a);

    await a.store.dismissHealthIntro();
    expect(a.store.healthIntroVisible, isFalse);
    expect(a.store.healthAutoConnectAllowed, isFalse);
    a.store.dispose();

    final b = setup(kv: kv, geteilterServer: a.server, health: health);
    await boot(b.store);
    expect(b.store.healthIntroVisible, isFalse);
    expect(b.store.healthAutoConnectAllowed, isFalse);
    expect(health.requests, 0);

    // The profile's connect is the user's own: from then on as before.
    await b.store.connectHealth();
    expect(health.requests, 1);
    expect(b.store.healthAutoConnectAllowed, isTrue);
    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), 'connected');
  }));

  test('a second account on this iPhone neither reads nor writes Apple '
      'Health before it connects', () => withClock(Clock.fixed(_now), () async {
    // Onboarded on another device; this device's grant is someone else's.
    final health = _AppleHealth();
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, health: health, disposeStore: false);
    a.server.profileRow = serverProfileRow(testProfile());
    await boot(a.store);

    expect(a.store.healthAutoConnectAllowed, isFalse);
    expect(a.store.healthIntroVisible, isTrue);
    await a.store.refreshHealthSteps();
    await a.store.backfillStepsForTrends(30);
    await a.store.logWeight(80);
    await settle();
    expect((health.requests, health.reads, health.writes), (0, 0, 0),
        reason: 'no ask, no read of the other person\'s steps, no write');
    expect(a.store.dailyActivity, isEmpty);

    // The next cold start (its profile is cached now) still waits.
    a.store.dispose();
    final b = setup(kv: kv, geteilterServer: a.server, health: health);
    await boot(b.store);
    expect(b.store.healthIntroVisible, isTrue);
    expect(b.store.healthAutoConnectAllowed, isFalse);

    await b.store.acceptHealthIntro();
    await b.store.logWeight(79.5);
    await settle();
    expect(health.requests, 1);
    expect(health.writes, 1, reason: 'its own connect opens the write-back');
  }));

  test('an account cached here before the per-account rule keeps its '
      'connection', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    await LocalCache(kv, 'user-outbox').writeProfile(testProfile());
    final a = setup(kv: kv, health: _AppleHealth());
    a.server.profileRow = serverProfileRow(testProfile());

    expect(a.store.healthAutoConnectAllowed, isFalse,
        reason: 'nothing is known before the boot');
    await boot(a.store);

    expect(a.store.healthAutoConnectAllowed, isTrue);
    expect(a.store.healthIntroVisible, isFalse);
    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), 'connected');
  }));

  test('Health Connect gets the same card; "Not now" keeps it and the '
      'missing-steps row away', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, health: _HealthConnect(), disposeStore: false);
    await _onboard(a);

    expect(a.store.healthIntroVisible, isTrue);
    expect(a.store.healthConnectLinked, isFalse);
    await a.store.dismissHealthIntro();
    a.store.dispose();

    final b = setup(kv: kv, geteilterServer: a.server, health: _HealthConnect());
    await boot(b.store);
    expect(b.store.healthIntroVisible, isFalse);
    expect(b.store.healthConnectLinked, isFalse);

    // The profile's connect still works, and links this account.
    await b.store.connectHealth();
    expect(b.store.healthConnectLinked, isTrue);
  }));

  test('the intro slot is cleared with the account', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-outbox');
    await cache.writeHealthPrompt('dismissed');

    await cache.clear();

    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), isNull);
  }));
}
