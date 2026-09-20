import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/background_sync.dart';
import 'package:eatova/src/services/background_sync_scheduler.dart';
import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'background_sync_client_test.dart' show encodedSession;

class _NativeScheduler extends WorkmanagerPlatform {
  final attempts = <int>[];

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {
    attempts.add(inputData!['attempt'] as int);
  }
}

Future<bool> _invokeNativeTask() async {
  final response = Completer<ByteData?>();
  ServicesBinding.instance.channelBuffers.push(
    'dev.flutter.pigeon.workmanager_platform_interface.WorkmanagerFlutterApi.executeTask',
    WorkmanagerFlutterApi.pigeonChannelCodec.encodeMessage([
      backgroundSyncTask,
      <String, Object?>{'attempt': 0},
    ]),
    response.complete,
  );
  final result =
      WorkmanagerFlutterApi.pigeonChannelCodec.decodeMessage(
            await response.future,
          )
          as List;
  expect(result, [true], reason: 'OS must not independently retry this task');
  return result.single as bool;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime.utc(2026, 9, 20, 12);
  final native = _NativeScheduler();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const outboxKey = 'eatova.v1.outbox.A';
  final key = base64Encode(List.generate(32, (i) => i));
  late Directory directory;
  late String databasePath;
  late SyncOp op;
  String? lockedKey;
  var secureWrites = 0;
  Future<http.Response> Function(http.Request) respond = (_) async =>
      throw StateError('Unexpected network request');

  setUpAll(() async {
    // Initialize before overriding the platform so Linux CI cannot replace it.
    Workmanager();
    WorkmanagerPlatform.instance = native;
    const ready = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.workmanager_platform_interface.WorkmanagerHostApi.notifyBackgroundChannelInitialized',
      WorkmanagerHostApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler(ready, (_) async => [null]);
    withClock(Clock.fixed(now), () {
      http.runWithClient(
        backgroundSyncDispatcher,
        () => MockClient((request) => respond(request)),
      );
    });
    await pumpEventQueue();
    addTearDown(() => messenger.setMockDecodedMessageHandler(ready, null));
  });

  setUp(() async {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues({});
    native.attempts.clear();
    lockedKey = null;
    secureWrites = 0;
    respond = (_) async => throw StateError('Unexpected network request');
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method != 'read') {
        secureWrites++;
        throw StateError('Background must not mutate credentials');
      }
      final requested = call.arguments['key'];
      if (requested == lockedKey) {
        throw PlatformException(code: 'keychain_locked');
      }
      return requested == CacheKeyProvider.dekStorageKey
          ? key
          : encodedSession();
    });
    directory = await Directory.systemTemp.createTemp(
      'eatova-background-prerequisites-',
    );
    databasePath = '${directory.path}/cache.sqlite';
    LocalCache.debugDatabasePath = databasePath;
    await withClock(Clock.fixed(now), () async {
      final cache = (await LocalCache.create('A'))!;
      await SyncExecutionGuard(cache.atomicStore!).activate('A', 'session-A');
      op = SyncOp.mealDelete('11111111-1111-4111-8111-111111111111');
      await cache.commitSyncOperations([op]);
      await cache.releaseStorage();
    });
  });

  tearDown(() async {
    await DurableCacheStore.closeAll();
    CacheKeyProvider.debugReset();
    LocalCache.debugDatabasePath = null;
    messenger.setMockMethodCallHandler(secureChannel, null);
    await directory.delete(recursive: true);
  });

  for (final failure in ['session', 'key', 'database']) {
    test(
      'production callback: unavailable $failure schedules no follow-up and recovers',
      () async {
        await withClock(Clock.fixed(now), () async {
          final before = await File(databasePath).readAsBytes();
          switch (failure) {
            case 'session':
              lockedKey = EatovaSupabaseConfig.sessionPersistKey;
            case 'key':
              lockedKey = CacheKeyProvider.dekStorageKey;
            case 'database':
              // A directory cannot be opened as a SQLite file.
              LocalCache.debugDatabasePath = directory.path;
          }
          expect(await _invokeNativeTask(), isTrue);
          expect(native.attempts, isEmpty);
          expect(await File(databasePath).readAsBytes(), before);
          expect(secureWrites, 0);

          lockedKey = null;
          LocalCache.debugDatabasePath = databasePath;
          // App-open initialization can read the same encrypted queue again.
          final reopened = (await LocalCache.create('A'))!;
          final queued = await reopened.readSyncOperations();
          expect(queued.single.toJson(), op.toJson());
          expect(await reopened.atomicStore!.getString(outboxKey), isNotNull);
          await reopened.releaseStorage();
          var delivered = 0;
          expect(
            await BackgroundSyncRunner(
              dispatch: (_, pending) async {
                delivered++;
                expect(pending.operationId, op.operationId);
                return const LocalSyncResult();
              },
            ).run(),
            BackgroundSyncOutcome.complete,
          );
          expect(delivered, 1);
          final after = (await LocalCache.create('A'))!;
          expect(await after.readSyncOperations(), isEmpty);
          await after.releaseStorage();
          expect(await _invokeNativeTask(), isTrue);
          expect(native.attempts, isEmpty);
        });
      },
    );
  }

  for (final failure in ['network', 'server']) {
    test(
      'production callback: transient $failure retains intent and schedules retry',
      () async {
        await withClock(Clock.fixed(now), () async {
          final sent = <Map<String, dynamic>>[];
          var unavailable = true;
          respond = (request) async {
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (unavailable) {
              if (failure == 'network') throw http.ClientException('offline');
              return http.Response(
                '{"message":"temporary outage"}',
                503,
                request: request,
              );
            }
            return http.Response(
              jsonEncode({
                'operation_id': sent.last['p_operation_id'],
                'kind': sent.last['p_kind'],
                'entity_id': sent.last['p_entity_id'],
                'result': {},
                'current_state': {'entity_deleted': true},
              }),
              200,
              request: request,
            );
          };
          await _invokeNativeTask();
          expect(native.attempts, [1]);
          expect(sent, hasLength(1));
          final cache = (await LocalCache.create('A'))!;
          final pending = (await cache.readSyncOperations()).single;
          expect(pending.operationId, op.operationId);
          expect(pending.attempts, failure == 'network' ? 0 : 1);
          expect(pending.blockedReason, isNull);
          await cache.releaseStorage();
          unavailable = false;
          await _invokeNativeTask();
          expect(native.attempts, [1]);
          expect(
            sent[1],
            sent[0],
            reason: 'retry must use the exact frozen request',
          );
          final recovered = (await LocalCache.create('A'))!;
          expect(await recovered.readSyncOperations(), isEmpty);
          await recovered.releaseStorage();
        });
      },
    );
  }
}
