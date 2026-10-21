import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// A1 (sweep 2026-08-08): the boot snapshot wrote the profile even when the
// state was not hydrated from a real source, so an offline boot replaced a
// profile blob it could not use with the ctor defaults (78 kg) — and the next
// boot took those defaults for a real hydration source, opening the clobber
// lock towards the server.
//
// Contract: the snapshot writes the profile slot only when the profile was
// hydrated from a real source (cache, server or a pending profile op).

const _profileKey = 'eatova.v1.profile.user-snap';
const _statsKey = 'eatova.v1.stats.user-snap';

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Fully offline server: every request fails with 503.
http.Client _offlineClient() => MockClient(
  (req) async => http.Response(
    jsonEncode({'message': 'offline'}),
    503,
    headers: const {'Content-Type': 'application/json'},
    request: req,
  ),
);

HomeStore _store(LocalCache cache) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _offlineClient(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-snap'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _noopSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

Future<void> _boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await pumpEventQueue(times: 60);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('A1: an offline boot never replaces an unusable profile blob with the '
      'ctor defaults', () async {
    final kv = InMemoryKeyValueStore();
    // A blob an older build left without its numbers: no hydration source.
    const unusable = '{"weight_kg":91,"onboarding_completed":true}';
    await kv.setString(_profileKey, unusable);
    final store = _store(LocalCache(kv, 'user-snap'));

    await _boot(store);

    expect(store.profile.weightKg, const UserProfile().weightKg,
        reason: 'precondition: nothing hydrated the profile');
    expect(kv.snapshot[_statsKey], isNotNull,
        reason: 'precondition: the boot snapshot did run');
    expect(kv.snapshot[_profileKey], unusable,
        reason: 'the defaults would count as a real source on the next boot');
  });
}
