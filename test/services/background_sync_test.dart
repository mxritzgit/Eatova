import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/session_revocations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eatova/src/services/background_sync.dart';
import 'package:eatova/src/services/background_sync_client.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/sync_operation_sync.dart';

import 'background_sync_client_test.dart' show encodedSession;

const _mealA = '11111111-1111-4111-8111-111111111111';
const _mealB = '22222222-2222-4222-8222-222222222222';

Future<InMemoryKeyValueStore> _seed(List<SyncOp> ops) async {
  final database = InMemoryKeyValueStore();
  await SyncExecutionGuard(database).activate('A', 'session-A');
  final cache = LocalCache(database, 'A');
  await cache.commitSyncOperations(ops);
  cache.close();
  return database;
}

Future<List<SyncOp>> _pending(InMemoryKeyValueStore database) async {
  final cache = LocalCache(database, 'A');
  try {
    return await cache.readSyncOperations();
  } finally {
    cache.close();
  }
}

BackgroundSyncRunner _runner(
  InMemoryKeyValueStore database, {
  BackgroundSyncDispatch? dispatch,
  Future<String?> Function()? readSession,
  http.Client? transport,
  Duration budget = const Duration(seconds: 20),
  int maxOperations = 20,
}) => BackgroundSyncRunner(
  readSession: readSession ?? () async => encodedSession(),
  openCache: (userId) async => LocalCache(database, userId),
  dispatch: dispatch,
  budget: budget,
  maxOperations: maxOperations,
  clientBuilder: (session, allowed) => BackgroundSyncClient(
    url: 'https://example.invalid',
    anonKey: 'dummy',
    session: session,
    permitted: allowed,
    transport:
        transport ??
        MockClient((_) async => throw StateError('unexpected HTTP')),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 9, 20, 12);

  test(
    'echter Dispatcher liefert feste opUUID und atomarer Ack leert Queue',
    () async {
      await withClock(Clock.fixed(now), () async {
        final op = SyncOp.mealDelete(_mealA);
        final db = await _seed([op]);
        final requests = <http.Request>[];
        final result = await _runner(
          db,
          transport: MockClient((request) async {
            requests.add(request);
            final body = jsonDecode(request.body) as Map;
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
          }),
        ).run();
        expect(result, BackgroundSyncOutcome.complete);
        expect(await _pending(db), isEmpty);
        expect(requests, hasLength(1));
        final body = jsonDecode(requests.single.body) as Map;
        expect(body['p_operation_id'], op.operationId);
        expect(requests.single.url.path, '/rest/v1/rpc/apply_sync_operation');
      });
    },
  );

  test(
    'Fehler blockiert nur seine Entity und verbraucht kein Retrybudget',
    () async {
      await withClock(Clock.fixed(now), () async {
        final first = SyncOp.mealDelete(_mealA);
        final next = SyncOp.mealDelete(_mealA);
        final other = SyncOp.mealDelete(_mealB);
        final db = await _seed([first, next, other]);
        final dispatched = <String>[];
        final result = await _runner(
          db,
          dispatch: (_, op) async {
            dispatched.add(op.operationId);
            if (op.operationId == first.operationId) {
              throw http.ClientException('offline');
            }
            return const LocalSyncResult();
          },
        ).run();
        expect(result, BackgroundSyncOutcome.retry);
        expect(dispatched, [first.operationId, other.operationId]);
        final left = await _pending(db);
        expect(left.map((op) => op.operationId), [
          first.operationId,
          next.operationId,
        ]);
        expect(left.map((op) => op.attempts), [0, 0]);
      });
    },
  );

  test('Logout waehrend HTTP verhindert Ack und jeden Folgerequest', () async {
    await withClock(Clock.fixed(now), () async {
      final first = SyncOp.mealDelete(_mealA);
      final next = SyncOp.mealDelete(_mealB);
      final db = await _seed([first, next]);
      var calls = 0;
      final result = await _runner(
        db,
        dispatch: (_, op) async {
          calls++;
          await SyncExecutionGuard(db).invalidate('A');
          return const LocalSyncResult();
        },
      ).run();
      expect(result, BackgroundSyncOutcome.unavailable);
      expect(calls, 1);
      expect(await _pending(db), hasLength(2));
    });
  });

  test('Secure-Session-Ende ohne DB-Ereignis verhindert spaeten Ack', () async {
    await withClock(Clock.fixed(now), () async {
      final db = await _seed([SyncOp.mealDelete(_mealA)]);
      String? current = encodedSession();
      final outcome = await _runner(
        db,
        readSession: () async => current,
        dispatch: (_, _) async {
          current = null;
          return const LocalSyncResult();
        },
      ).run();
      expect(outcome, BackgroundSyncOutcome.unavailable);
      expect(await _pending(db), hasLength(1));
    });
  });

  test(
    'gesperrtes Logout-Journal sperrt verbleibenden Secure-Token read-only',
    () async {
      await withClock(Clock.fixed(now), () async {
        final key = EatovaSupabaseConfig.sessionPersistKey;
        final journalStore = InMemoryKeyValueStore();
        await SessionRevocations(
          '$key.logout-v1',
          () async => journalStore,
        ).revoke([encodedSession()]);
        SharedPreferences.setMockInitialValues(journalStore.snapshot);
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              methods.add(call.method);
              if (call.method != 'read') {
                throw StateError('Background wrote Auth storage');
              }
              return encodedSession();
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        var opens = 0;
        final result = await BackgroundSyncRunner(
          openCache: (_) async {
            opens++;
            return null;
          },
        ).run();
        expect(result, BackgroundSyncOutcome.unavailable);
        expect(opens, 0);
        expect(methods, ['read']);
      });
    },
  );

  test(
    'Foregroundclaim sperrt parallelen Worker ohne Queueaenderung',
    () async {
      await withClock(Clock.fixed(now), () async {
        final db = await _seed([SyncOp.mealDelete(_mealA)]);
        final foreground = (await SyncExecutionGuard(db).tryClaim('A'))!;
        var calls = 0;
        final result = await _runner(
          db,
          dispatch: (_, __) async {
            calls++;
            return const LocalSyncResult();
          },
        ).run();
        expect(result, BackgroundSyncOutcome.retry);
        expect(calls, 0);
        expect(await foreground.isCurrent(), isTrue);
        expect(await _pending(db), hasLength(1));
        await foreground.release();
      });
    },
  );

  test(
    'Capacity bleibt erhalten und blockierte Nachfolger hungern andere Entity nicht aus',
    () async {
      await withClock(Clock.fixed(now), () async {
        final first = SyncOp.mealDelete(_mealA);
        final successors = List.generate(25, (_) => SyncOp.mealDelete(_mealA));
        final other = SyncOp.mealDelete(_mealB);
        final db = await _seed([first, ...successors, other]);
        final dispatched = <String>[];
        Future<LocalSyncResult> dispatch(EatovaSync _, SyncOp op) async {
          dispatched.add(op.operationId);
          if (op.operationId == first.operationId) {
            throw const SyncCapacityException(
              SyncCapacityKind.operationReceipts,
            );
          }
          return const LocalSyncResult();
        }

        expect(
          await _runner(db, dispatch: dispatch).run(),
          BackgroundSyncOutcome.unavailable,
        );
        expect(dispatched, [first.operationId, other.operationId]);
        final pending = await _pending(db);
        expect(pending, hasLength(26));
        expect(pending.first.blockedReason, SyncBlockedReason.capacity);
        expect(
          await _runner(db, dispatch: dispatch).run(),
          BackgroundSyncOutcome.unavailable,
        );
        expect(
          dispatched,
          hasLength(2),
          reason: 'automatic retry never unlocks blocked intents',
        );
      });
    },
  );

  test(
    'Operationslimit laesst Rest dauerhaft fuer naechsten Pass stehen',
    () async {
      await withClock(Clock.fixed(now), () async {
        final db = await _seed([
          SyncOp.mealDelete(_mealA),
          SyncOp.mealDelete(_mealB),
        ]);
        var calls = 0;
        final result = await _runner(
          db,
          maxOperations: 1,
          dispatch: (_, __) async {
            calls++;
            return const LocalSyncResult();
          },
        ).run();
        expect(result, BackgroundSyncOutcome.retry);
        expect(calls, 1);
        expect(await _pending(db), hasLength(1));
      });
    },
  );

  test(
    'haengender Request endet am Budget und spaeter Receipt darf nicht ackn',
    () async {
      await withClock(Clock.fixed(now), () async {
        final db = await _seed([SyncOp.mealDelete(_mealA)]);
        final gate = Completer<LocalSyncResult>();
        final entered = Completer<void>();
        final pending = _runner(
          db,
          budget: const Duration(seconds: 1),
          dispatch: (_, __) {
            entered.complete();
            return gate.future;
          },
        ).run();
        await entered.future;
        expect(await pending, BackgroundSyncOutcome.retry);
        gate.complete(const LocalSyncResult());
        await pumpEventQueue(times: 20);
        expect(await _pending(db), hasLength(1));
        expect(await SyncExecutionGuard(db).tryClaim('A'), isNotNull);
      });
    },
  );

  test(
    'fehlende abgelaufene und gesperrte Session beruehrt keine Queue',
    () async {
      await withClock(Clock.fixed(now), () async {
        var opens = 0;
        for (final session in [null, encodedSession(expiry: 1)]) {
          final result = await BackgroundSyncRunner(
            readSession: () async => session,
            openCache: (_) async {
              opens++;
              return null;
            },
          ).run();
          expect(result, BackgroundSyncOutcome.unavailable);
        }
        final result = await BackgroundSyncRunner(
          readSession: () async => throw StateError('keystore locked'),
          openCache: (_) async {
            opens++;
            return null;
          },
        ).run();
        expect(result, BackgroundSyncOutcome.retry);
        expect(opens, 0);
      });
    },
  );

  test('nicht verfuegbare Cacheverschluesselung wird nicht umgangen', () async {
    await withClock(Clock.fixed(now), () async {
      final result = await BackgroundSyncRunner(
        readSession: () async => encodedSession(),
        openCache: (_) async => null,
      ).run();
      expect(result, BackgroundSyncOutcome.unavailable);
    });
  });
}
