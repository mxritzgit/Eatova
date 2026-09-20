import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';
import 'package:eatova/main.dart' show buildEatovaApp;
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/background_sync_scheduler.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_connectivity.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'support/harness.dart';

class _Connectivity implements SyncConnectivity {
  final events = StreamController<bool>.broadcast(sync: true);
  bool available = false;
  @override
  Future<bool> hasNetworkInterface() async => available;
  @override
  Stream<bool> get networkInterfaceChanges => events.stream;
  void reconnect() {
    available = true;
    events.add(true);
  }
}

class _Scheduler implements BackgroundSyncScheduler {
  int requests = 0;
  @override
  Future<void> request() async {
    requests++;
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  testWidgets('offene echte Shell liefert offline Intent beim Netzwerkereignis', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12)), () async {
      SharedPreferences.setMockInitialValues({});
      pinPhoneViewport(tester);
      final connectivity = _Connectivity();
      final scheduler = _Scheduler();
      var offline = true;
      final delivered = <String>[];
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.invalid',
          'dummy',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            if (offline) throw http.ClientException('offline');
            if (request.url.path.endsWith('/rpc/apply_sync_operation')) {
              final body = jsonDecode(request.body) as Map;
              delivered.add(body['p_operation_id'] as String);
              return http.Response(
                jsonEncode({
                  'operation_id': body['p_operation_id'],
                  'kind': body['p_kind'],
                  'entity_id': body['p_entity_id'],
                  'result': {},
                  'current_state': {'entity_deleted': true},
                }),
                200,
                request: request,
              );
            }
            return http.Response('[]', 200, request: request);
          }),
        ),
      ))!;
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      await cache.writeProfile(const UserProfile(onboardingCompleted: true));
      await cache.flush();
      final op = SyncOp.mealDelete('11111111-1111-4111-8111-111111111111');
      await cache.commitSyncOperations([op]);
      await pumpLocalized(
        tester,
        EatovaHomePage(
          sync: EatovaSync.forUser(client, 'A'),
          debugCache: cache,
          syncConnectivity: connectivity,
          backgroundSyncScheduler: scheduler,
        ),
        scaffold: false,
        safeArea: false,
      );
      await tester.runAsync(() => pumpEventQueue(times: 50));
      await tester.pump(const Duration(seconds: 1));
      final access =
          tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess;
      expect(access.debugStore.pendingOutbox, hasLength(1));
      expect(delivered, isEmpty);
      offline = false;
      connectivity.reconnect();
      await tester.pump(const Duration(milliseconds: 501));
      await tester.runAsync(() => pumpEventQueue(times: 50));
      await tester.pump();
      expect(delivered, [
        op.operationId,
      ], reason: 'Reconnect must beat the 30s timer');
      expect(access.debugStore.pendingOutbox, isEmpty);
      expect(scheduler.requests, greaterThan(0));
      // Initial offline GETs have SDK retry timers separate from outbox replay.
      // Drain that boot load before disposing its HTTP client in fake time.
      for (var i = 0; i < 10 && access.debugStore.bootLoadInFlight; i++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => pumpEventQueue(times: 20));
      }
      expect(access.debugStore.bootLoadInFlight, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(connectivity.events.hasListener, isFalse);
      await tester.runAsync(client.dispose);
      await connectivity.events.close();
    });
  });

  testWidgets('Preview ohne Sync registriert weder Connectivity noch OS-Job', (
    tester,
  ) async {
    final connectivity = _Connectivity();
    final scheduler = _Scheduler();
    await pumpLocalized(
      tester,
      EatovaHomePage(
        syncConnectivity: connectivity,
        backgroundSyncScheduler: scheduler,
      ),
      scaffold: false,
      safeArea: false,
    );
    connectivity.reconnect();
    await tester.pump(const Duration(seconds: 1));
    expect(connectivity.events.hasListener, isFalse);
    expect(scheduler.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await connectivity.events.close();
  });

  test('Produktionscomposition injiziert den echten Netzwerkadapter', () {
    expect(buildEatovaApp().syncConnectivity, isA<PlatformSyncConnectivity>());
  });
}
