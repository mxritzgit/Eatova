import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'fixlauf_a_helpers.dart';
import 'support/atomic_store_faults.dart';

class _CountingNotifications implements NotificationService {
  int requests = 0;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async {
    requests++;
    return true;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a rejected profile save never requests reminder permission', () async {
    final client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: MockClient(
        (_) async =>
            throw StateError('A rejected save must not use the network'),
      ),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final notifications = _CountingNotifications();
    final store = HomeStore(
      sync: EatovaSync.forUser(client, 'test-user'),
      health: const NoopHealthService(),
      notificationService: notifications,
      initialUserName: 'Test',
      emitSnack:
          (
            String _, {
            IconData icon = Icons.info_outline,
            SnackTone tone = SnackTone.positive,
            Duration? duration,
            SnackBarAction? action,
          }) {},
    );
    addTearDown(store.dispose);

    await expectLater(
      store.applySettings(
        newProfile: const UserProfile(weightKg: 81),
        notificationsEnabled: true,
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifications.requests, 0);
    expect(store.reminderState, ReminderState.off);
  });

  test(
    'a failed durable profile commit leaves reminder opt-in untouched',
    () async {
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final cache = LocalCache(faults, kFixlaufUser);
      final notifications = _CountingNotifications();
      final initial = completedProfile.copyWith(manualEnergy: true);
      final setup = fixlaufSetup(cache: cache, notifications: notifications);
      await cache.writeProfile(initial);
      setup.server.profileRow = serverProfileRow(initial);
      await bootStore(setup.store);

      final edited = initial.copyWith(weightKg: 82);
      var failedCommit = false;
      faults.beforeWrite = (changes) async {
        if (changes.keys.any((key) => key.contains('.profile.')) &&
            changes.keys.any((key) => key.contains('.outbox.'))) {
          failedCommit = true;
          throw StateError('Injected durable profile commit failure');
        }
      };

      await expectLater(
        setup.store.applySettings(
          newProfile: edited,
          notificationsEnabled: true,
        ),
        throwsStateError,
      );
      expect(failedCommit, isTrue);
      expect(notifications.requests, 0);
      expect(setup.store.reminderState, ReminderState.off);
      expect(setup.store.profile.weightKg, initial.weightKg);
      expect((await cache.readProfile())!.weightKg, initial.weightKg);
      expect(setup.store.pendingOutbox, isEmpty);

      faults.beforeWrite = null;
      await setup.store.applySettings(
        newProfile: edited,
        notificationsEnabled: true,
      );
      await settle();
      expect(setup.store.profile.weightKg, edited.weightKg);
      expect((await cache.readProfile())!.weightKg, edited.weightKg);
      expect(notifications.requests, 1);
      expect(setup.store.reminderState, ReminderState.active);
    },
  );
}
