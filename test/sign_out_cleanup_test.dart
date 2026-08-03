import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/src/app/home_store.dart';
import 'package:shiftfit/src/models/lifetime_stats.dart';
import 'package:shiftfit/src/models/user_profile.dart';
import 'package:shiftfit/src/services/health_service.dart';
import 'package:shiftfit/src/services/local_cache.dart';
import 'package:shiftfit/src/services/notification_service.dart';

// Audit 2026-06-09, M-1: der lokale Klartext-PII-Cache (Profil, Mood-Notiz,
// Lifetime-Stats, Notification-Flag) wurde bisher NUR bei der Konto-Löschung
// geräumt, nicht beim normalen Sign-Out. Damit blieben Gesundheits-/Profildaten
// nach dem Logout unverschlüsselt in den SharedPreferences liegen.
//
// signOutCleanup() schließt diese Lücke. Der Test treibt den Store ohne Sync
// (kein Supabase nötig) mit einem injizierten In-Memory-Cache und prüft, dass
// nach signOutCleanup() KEINE der gecachten Zeilen mehr lesbar ist.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  Color accent = const Color(0xFFFFFFFF),
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _storeWith(LocalCache cache) => HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signOutCleanup räumt den gesamten PII-Cache', () async {
    final store = InMemoryKeyValueStore();
    final cache = LocalCache(store, 'user-signout');
    await cache.writeProfile(const UserProfile(
      weightKg: 81,
      heightCm: 182,
      onboardingCompleted: true,
    ));
    await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
    await cache.writeNotificationsEnabled(true);

    // Vorbedingung: alles ist da.
    expect(await cache.readProfile(), isNotNull);
    expect(await cache.readLifetimeStats(), isNotNull);
    expect(await cache.readNotificationsEnabled(), isTrue);
    expect(store.snapshot, isNotEmpty);

    await _storeWith(cache).signOutCleanup();

    // Nach dem Logout darf nichts mehr lesbar sein.
    expect(await cache.readProfile(), isNull);
    expect(await cache.readLifetimeStats(), isNull);
    expect(await cache.readNotificationsEnabled(), isNull);
    expect(store.snapshot, isEmpty);
  });

  test('signOutCleanup ist ohne Cache ein gefahrloses No-Op', () async {
    // Kein debugCache, kein Sync -> nichts zu räumen, kein Crash/Channel.
    final store = HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _noopSnack,
    );
    await expectLater(store.signOutCleanup(), completes);
  });
}
