import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import 'outbox_test_helpers.dart';

// A weigh-in logged offline stays queued until delivery. A cold start in
// another time zone must show it once, at its instant.

const _uid = 'user-outbox';
const _weightKey = 'eatova.v1.weight_log.$_uid';
const _queuedId = '7c000000-0000-4000-8000-000000000001';

/// Microsecond precision, like `clock.now()` on a device.
final _instant = DateTime.utc(2026, 9, 16, 5, 30, 12, 345, 678);

/// A real UTC offset six hours away from this process's offset at
/// [instant].
Duration _otherZone(DateTime instant) {
  final here = instant.toLocal().timeZoneOffset;
  return here.isNegative
      ? here + const Duration(hours: 6)
      : here - const Duration(hours: 6);
}

Future<List<Map<String, dynamic>>> _storedRows(InMemoryKeyValueStore kv) async {
  final slot =
      jsonDecode((await kv.getString(_weightKey))!) as Map<String, dynamic>;
  return (slot['items'] as List<dynamic>).cast<Map<String, dynamic>>();
}

/// Moves the device from this process's zone to [zone] after the weight slot
/// was written. A row without a zone designator is a wall clock, which the
/// new zone reads at another instant; rewriting it emulates that reading
/// here. A row with a designator is an instant and keeps its meaning.
Future<void> _travel(InMemoryKeyValueStore kv, Duration zone) async {
  final rows = [
    for (final row in await _storedRows(kv))
      if (DateTime.parse(row['t'] as String) case final wall when !wall.isUtc)
        {
          ...row,
          't': wall
              .subtract(zone - wall.timeZoneOffset)
              .toIso8601String(),
        }
      else
        row,
  ];
  await kv.setString(_weightKey, jsonEncode(<String, dynamic>{'items': rows}));
}

void expectOnlyTheQueuedWeighIn(Iterable<DateTime> timestamps) {
  final got = timestamps.toList();
  expect(got, hasLength(1), reason: '${got.map((t) => t.toUtc())}');
  expect(
    got.single.isAtSameMomentAs(_instant),
    isTrue,
    reason: '${got.single.toUtc()}',
  );
  expect(got.single.isUtc, isFalse, reason: 'shown in local time');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a weigh-in logged by this build survives a zone change offline', () async {
    await withClock(Clock.fixed(_instant.toLocal()), () async {
      final kv = InMemoryKeyValueStore();
      final logging = setup(kv: kv)..server.offline = true;
      await bootUntilIdle(logging.store);
      await logging.store.logWeight(80);

      await _travel(kv, _otherZone(_instant));
      final abroad = setup(kv: kv)..server.offline = true;
      await bootUntilIdle(abroad.store);

      expectOnlyTheQueuedWeighIn(
        abroad.store.weightLog.entries.map((e) => e.timestamp),
      );
      expect(
        abroad.store.pendingOutbox
            .where((op) => op.kind == SyncOpKind.weightInsert),
        hasLength(1),
      );
    });
  });

  test('a queued weigh-in cached by an older build in another zone is shown '
      'once', () async {
    await withClock(Clock.fixed(_instant.toLocal()), () async {
      final kv = InMemoryKeyValueStore();
      await LocalCache(kv, _uid).commitSyncOperations([
        SyncOp.weightInsert(
          id: _queuedId,
          weightKg: 80,
          recordedAt: _instant.toLocal(),
        ),
      ]);
      // What an older build's offline boot snapshot left in the other
      // zone: the wall clock without offset and without operation id.
      final wall = _instant.toUtc().add(_otherZone(_instant)).toIso8601String();
      await kv.setString(
        _weightKey,
        jsonEncode(<String, dynamic>{
          'items': [
            {'t': wall.substring(0, wall.length - 1), 'kg': 80.0},
          ],
        }),
      );

      final first = setup(kv: kv)..server.offline = true;
      await bootUntilIdle(first.store);
      expectOnlyTheQueuedWeighIn(
        first.store.weightLog.entries.map((e) => e.timestamp),
      );

      final second = setup(kv: kv)..server.offline = true;
      await bootUntilIdle(second.store);
      expectOnlyTheQueuedWeighIn(
        second.store.weightLog.entries.map((e) => e.timestamp),
      );

      // Delivery and the server load keep the one exact instant.
      final online = setup(kv: kv);
      await bootUntilIdle(online.store);
      await pumpUntil(() => online.store.pendingOutbox.isEmpty);
      expect(online.store.pendingOutbox, isEmpty);
      expect(
        online.server.weightRows.values.single['recorded_at'],
        _instant.toIso8601String(),
      );
      expectOnlyTheQueuedWeighIn(
        online.store.weightLog.entries.map((e) => e.timestamp),
      );
    });
  });
}
