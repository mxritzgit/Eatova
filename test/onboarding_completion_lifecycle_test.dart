import 'package:clock/clock.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixlauf_a_helpers.dart';

const _finished = UserProfile(
  weightKg: 82,
  heightCm: 180,
  onboardingCompleted: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('duplicate completion queues the profile once', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 16, 12)), () async {
      final setup = fixlaufSetup();
      await bootStore(setup.store);
      setup.server.requests.clear();

      await Future.wait([
        setup.store.completeOnboarding(_finished),
        setup.store.completeOnboarding(_finished),
      ]);
      await settle();

      expect(setup.store.profile, _finished);
      expect(setup.store.needsOnboarding, isFalse);
      expect(setup.server.requestsTo('/profiles', method: 'POST'), hasLength(1));
      expect(setup.store.pendingOutbox, isEmpty);
    });
  });

  test('a disposed onboarding callback cannot save a profile', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 16, 12)), () async {
      final setup = fixlaufSetup(autoDispose: false);
      await bootStore(setup.store);
      final previous = setup.store.profile;
      setup.store.dispose();
      setup.server.requests.clear();

      await setup.store.completeOnboarding(_finished);
      await settle();

      expect(setup.store.profile, previous);
      expect(setup.server.requestsTo('/profiles', method: 'POST'), isEmpty);
      expect(setup.store.pendingOutbox, isEmpty);
    });
  });
}
