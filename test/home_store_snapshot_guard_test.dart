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

// A1 (sweep 2026-08-08): `_writeCacheSnapshot` ran unguarded at boot end, so
// "cache read error + offline boot" wrote pure ctor defaults over an intact
// but momentarily unreadable cache — and the next boot took those defaults for
// a real hydration source, opening the clobber lock towards the server.
//
// New contract: the snapshot runs only when the state was hydrated from a real
// source (cache OR server).

/// The data IS there, but every read fails; writes are recorded, since those
/// are the danger.
class _LesefehlerStore implements KeyValueStore {
  _LesefehlerStore(Map<String, String> initial) : blobs = {...initial};

  final Map<String, String> blobs;
  final List<String> writes = <String>[];

  @override
  Future<String?> getString(String key) async =>
      throw StateError('Lesefehler: $key');

  @override
  Future<void> setString(String key, String value) async {
    writes.add(key);
    blobs[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    blobs.remove(key);
  }
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Fully offline server: every request fails with 503.
http.Client _offlineClient() => MockClient((req) async => http.Response(
      jsonEncode({'message': 'offline'}),
      503,
      headers: const {'Content-Type': 'application/json'},
      request: req,
    ));

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

  test(
      'A1: Lesefehler + Offline-Boot fasst den durablen Bestand NICHT an '
      '(kein Default-Snapshot ueber echte Daten)', () async {
    final kv = _LesefehlerStore(<String, String>{
      // Existing content; that it is unchanged AFTER the boot is the point.
      'eatova.v1.profile.user-snap': '<intakter, aber unlesbarer Blob>',
      'eatova.v1.logged_meals.user-snap': '<tagebuch>',
    });
    final store = _store(LocalCache(kv, 'user-snap'));

    await _boot(store);

    expect(kv.writes, isEmpty,
        reason: 'ohne echte Hydrationsquelle (Cache unlesbar, Server '
            'offline) darf der Boot keinen Default-Snapshot schreiben — '
            'er wuerde den vorhandenen Bestand vernichten und beim '
            'naechsten Boot als echte Quelle gelten (Clobber-Kette)');
    expect(kv.blobs['eatova.v1.profile.user-snap'],
        '<intakter, aber unlesbarer Blob>');
  });

  test('Kontrolle: mit echter Cache-Quelle schreibt der Boot den Snapshot',
      () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-snap');
    await cache.writeProfile(const UserProfile(
      weightKg: 80,
      heightCm: 180,
      onboardingCompleted: true,
    ));
    final store = _store(cache);

    await _boot(store);

    expect(kv.snapshot.keys, contains('eatova.v1.profile.user-snap'),
        reason: 'mit echter Quelle bleibt der Snapshot-Pfad aktiv — der '
            'Guard darf nicht ueberschiessen');
  });
}
