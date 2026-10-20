// Apple Health after the onboarding (review 2026-10-19): the onboarding's
// commit holds HealthKit back, and Today's intro card asks instead. The
// answer is kept per account, so a restart neither asks unprompted nor
// forgets a "Not now"; an account onboarded before connects as it did.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 19, 9);

/// An iOS-like health store: never asked, counts the permission requests.
class _AppleHealth implements HealthService {
  int requests = 0;

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
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;
}

class _HealthConnect extends _AppleHealth implements HealthConnectAccess {
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

  test('an account onboarded before connects as before', () => withClock(Clock.fixed(_now), () async {
    final a = setup(health: _AppleHealth());
    a.server.profileRow = serverProfileRow(testProfile());

    expect(a.store.healthAutoConnectAllowed, isFalse,
        reason: 'nothing is known before the boot');
    await boot(a.store);

    expect(a.store.healthAutoConnectAllowed, isTrue);
    expect(a.store.healthIntroVisible, isFalse);
  }));

  test('Health Connect keeps its own explicit connect, without a card', () => withClock(Clock.fixed(_now), () async {
    final a = setup(health: _HealthConnect());
    await _onboard(a);

    expect(a.store.healthIntroVisible, isFalse);
  }));

  test('the intro slot is cleared with the account', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-outbox');
    await cache.writeHealthPrompt('dismissed');

    await cache.clear();

    expect(await LocalCache(kv, 'user-outbox').readHealthPrompt(), isNull);
  }));
}
