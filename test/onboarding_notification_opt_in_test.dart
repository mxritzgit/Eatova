import 'package:clock/clock.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixlauf_a_helpers.dart';

class _Notifications extends NoopNotificationService {
  int requests = 0;
  int schedules = 0;

  @override
  Future<bool> requestPermission() async {
    requests++;
    return true;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    schedules++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('onboarding completes without opting in to notifications', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 16, 12)), () async {
      final notifications = _Notifications();
      final setup = fixlaufSetup(notifications: notifications);
      await bootStore(setup.store);
      const finished = UserProfile(
        weightKg: 82,
        heightCm: 180,
        onboardingCompleted: true,
      );

      await setup.store.completeOnboarding(finished);
      await settle();

      expect(setup.store.needsOnboarding, isFalse);
      expect(setup.store.profile, finished);
      expect((await setup.cache!.readProfile())!.onboardingCompleted, isTrue);
      expect(setup.server.profileRow!['onboarding_completed'], isTrue);
      expect(notifications.requests, 0);
      expect(notifications.schedules, 0);
      expect(setup.store.notificationsEnabled, isFalse);
      expect(await setup.cache!.readNotificationsEnabled(), isNot(isTrue));

      // The user's later Settings action still asks and activates reminders.
      await setup.store.setNotificationsEnabled(true);
      expect(notifications.requests, 1);
      expect(notifications.schedules, 1);
      expect(setup.store.notificationsEnabled, isTrue);
      expect(await setup.cache!.readNotificationsEnabled(), isTrue);
    });
  });
}
