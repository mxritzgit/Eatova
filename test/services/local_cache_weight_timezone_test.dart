import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

// Weigh-ins are instants. Builds before this fix cached them as local wall
// clocks without an offset, so travel or the repeated fall-back hour changed
// which instant a cached row meant. A test cannot change its process zone:
// legacy fixtures are the exact strings an older build wrote on a device at
// another UTC offset.

const _owner = 'weight-zone-user';
const _key = 'eatova.v1.weight_log.$_owner';
const _queuedId = '7b000000-0000-4000-8000-000000000001';
const _otherQueuedId = '7b000000-0000-4000-8000-000000000002';
final _now = DateTime.utc(2026, 10, 26, 9);

/// Microsecond precision, like `clock.now()` on a device.
final _instant = DateTime.utc(2026, 9, 16, 5, 30, 12, 345, 678);

// The repeated fall-back hour in central Europe: 02:30 local twice.
final _summerHalfPastTwo = DateTime.utc(2026, 10, 25, 0, 30, 0, 0, 111);
final _winterHalfPastTwo = DateTime.utc(2026, 10, 25, 1, 30, 0, 0, 222);

/// What a build before this fix cached for [instant] on a device at UTC
/// [offset]: the local wall clock without a zone designator.
String _legacyWallClock(DateTime instant, Duration offset) {
  final wall = instant.toUtc().add(offset).toIso8601String();
  return wall.substring(0, wall.length - 1);
}

/// A real UTC offset six hours away from this process's offset at
/// [instant]: where the device was when an older build cached it.
Duration _formerZone(DateTime instant) {
  final here = instant.toLocal().timeZoneOffset;
  return here.isNegative
      ? here + const Duration(hours: 6)
      : here - const Duration(hours: 6);
}

SyncOp _weighIn(String id, double kg, DateTime instant) =>
    SyncOp.weightInsert(id: id, weightKg: kg, recordedAt: instant.toLocal());

Future<void> _seedRows(
  InMemoryKeyValueStore kv,
  List<Map<String, dynamic>> rows,
) => kv.setString(_key, jsonEncode(<String, dynamic>{'items': rows}));

Future<List<Map<String, dynamic>>> _storedRows(InMemoryKeyValueStore kv) async {
  final slot = jsonDecode((await kv.getString(_key))!) as Map<String, dynamic>;
  return (slot['items'] as List<dynamic>).cast<Map<String, dynamic>>();
}

/// The cache side of a cold start: hydrate the log, write it back as the boot
/// snapshot (which re-projects every queued operation) and return what the
/// next cold start reads.
Future<WeightLog> _coldStart(LocalCache cache) async {
  final hydrated = (await cache.readWeightLog())!;
  final before = await cache.readMutationSnapshot();
  await cache.commitStoreSnapshot(
    expectedVersions: before.snapshot.versions,
    weightLog: hydrated,
  );
  return (await cache.readWeightLog())!;
}

void expectInstants(Iterable<WeightLogEntry> entries, List<DateTime> want) {
  final got = entries.map((e) => e.timestamp).toList();
  expect(got, hasLength(want.length), reason: '$got');
  for (var i = 0; i < want.length; i++) {
    expect(
      got[i].isAtSameMomentAs(want[i]),
      isTrue,
      reason: 'entry $i is ${got[i].toUtc()}, expected ${want[i].toUtc()}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('weight cache format', () {
    test('every writer stores UTC instants with a zone designator', () async {
      await withClock(Clock.fixed(_now), () async {
        final queued = DateTime.utc(2026, 10, 25, 1, 45, 0, 0, 333);
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        final expected = [_summerHalfPastTwo, _winterHalfPastTwo, queued]
            .map((t) => t.toIso8601String())
            .toList();

        await cache.writeWeightLog(
          WeightLog(
            entries: [
              WeightLogEntry(
                timestamp: _summerHalfPastTwo.toLocal(),
                weightKg: 80,
              ),
              WeightLogEntry(
                timestamp: _winterHalfPastTwo.toLocal(),
                weightKg: 80.4,
              ),
            ],
          ),
        );
        // Projection of a queued weigh-in.
        await cache.commitSyncOperations([_weighIn(_queuedId, 80.2, queued)]);
        expect(
          (await _storedRows(kv)).map((row) => row['t']),
          expected,
          reason: 'the fall-back hour must stay two distinct instants',
        );

        // Store snapshot plus re-projection of the still queued weigh-in.
        await _coldStart(cache);
        expect((await _storedRows(kv)).map((row) => row['t']), expected);
      });
    });

    test('rows read back as local times of the same instant', () async {
      final local = DateTime(2026, 9, 16, 23, 45, 0, 0, 42);
      final cache = LocalCache(InMemoryKeyValueStore(), _owner);
      await cache.writeWeightLog(
        WeightLog(entries: [WeightLogEntry(timestamp: local, weightKg: 80)]),
      );

      final back = (await cache.readWeightLog())!.entries.single.timestamp;
      // The profile compares calendar fields with the local clock.
      expect(back.isUtc, isFalse);
      expect(back, local);
    });

    test('an older build reads the new rows as the same instants', () async {
      await withClock(Clock.fixed(_now), () async {
        final queued = DateTime.utc(2026, 10, 25, 1, 45, 0, 0, 333);
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        final op = _weighIn(_queuedId, 80.2, queued);
        await cache.commitSyncOperations([op]);
        // The store snapshot writes id-less rows.
        final before = await cache.readMutationSnapshot();
        await cache.commitStoreSnapshot(
          expectedVersions: before.snapshot.versions,
          weightLog: WeightLog(
            entries: [
              WeightLogEntry(
                timestamp: _winterHalfPastTwo.toLocal(),
                weightKg: 80.4,
              ),
              WeightLogEntry(timestamp: queued.toLocal(), weightKg: 80.2),
            ],
          ),
        );
        final rows = await _storedRows(kv);
        expect(rows.map((row) => row['id']), [null, null]);

        // Reader, projection match, sort and merge key of the build before
        // this format, verbatim.
        DateTime oldRead(Map<String, dynamic> j) =>
            DateTime.parse(j['t'] as String);
        final old = rows.map(oldRead).toList();
        expectInstants([
          for (final (i, t) in old.indexed)
            WeightLogEntry(
              timestamp: t,
              weightKg: (rows[i]['kg'] as num).toDouble(),
            ),
        ], [_winterHalfPastTwo, queued]);
        final ts = op.recordedAt!;
        expect(
          rows.where(
            (row) =>
                row['id'] == op.entityId ||
                row['id'] == null &&
                    DateTime.parse(row['t'] as String).isAtSameMomentAs(ts),
          ),
          [rows.last],
          reason: 'an older projection must find exactly the queued row',
        );
        final sorted = [...rows.reversed]
          ..sort(
            (a, b) => DateTime.parse(a['t'] as String)
                .compareTo(DateTime.parse(b['t'] as String)),
          );
        expect(sorted.map((row) => row['kg']), [80.4, 80.2]);
        // The older store's merge key of the server load.
        expect(
          old.map((t) => t.toUtc().toIso8601String()),
          [_winterHalfPastTwo, queued].map((t) => t.toIso8601String()),
        );
      });
    });
  });

  group('legacy rows of a queued weigh-in after a zone change', () {
    test('a projected row keeps the instant of its operation', () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, _instant)]);
        await _seedRows(kv, [
          {
            'id': _queuedId,
            't': _legacyWallClock(_instant, _formerZone(_instant)),
            'kg': 80.0,
          },
        ]);

        expectInstants((await cache.readWeightLog())!.entries, [_instant]);
      });
    });

    test('a snapshot row is the queued weigh-in, not a second one', () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, _instant)]);
        // An older build's store snapshot drops the operation id.
        await _seedRows(kv, [
          {'t': _legacyWallClock(_instant, _formerZone(_instant)), 'kg': 80.0},
        ]);

        // The store only adds queued weigh-ins missing at their instant.
        expectInstants((await cache.readWeightLog())!.entries, [_instant]);
        final log = await _coldStart(cache);
        expectInstants(log.entries, [_instant]);
        final rows = await _storedRows(kv);
        expect(rows, hasLength(1), reason: '$rows');
        expect(rows.single['t'], _instant.toIso8601String());
        expect((await cache.readSyncOperations()).single.entityId, _queuedId);
      });
    });

    test('an older build\'s duplicate collapses into the queued weigh-in', () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, _instant)]);
        // Cached in the former zone, then an older build's cold start here
        // misread it and merged the queued weigh-in a second time.
        await _seedRows(kv, [
          {'t': _legacyWallClock(_instant, _formerZone(_instant)), 'kg': 80.0},
          {
            't': _legacyWallClock(_instant, _instant.toLocal().timeZoneOffset),
            'kg': 80.0,
          },
        ]);

        expectInstants((await cache.readWeightLog())!.entries, [_instant]);
        expectInstants((await _coldStart(cache)).entries, [_instant]);
        expect(await _storedRows(kv), hasLength(1));
      });
    });

    test('a queued re-projection repairs a legacy row in place', () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, _instant)]);
        await _seedRows(kv, [
          {'t': _legacyWallClock(_instant, _formerZone(_instant)), 'kg': 80.0},
        ]);
        // A snapshot of other collections re-projects the queue on the
        // untouched weight slot.
        final before = await cache.readMutationSnapshot();
        await cache.commitStoreSnapshot(
          expectedVersions: before.snapshot.versions,
          shoppingChecks: const {},
        );

        final rows = await _storedRows(kv);
        expect(rows, hasLength(1), reason: '$rows');
        expect(rows.single['t'], _instant.toIso8601String());
        expect(rows.single['id'], _queuedId);
      });
    });

    test('two weigh-ins in the repeated fall-back hour stay apart', () async {
      await withClock(Clock.fixed(_now), () async {
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([
          _weighIn(_queuedId, 80, _summerHalfPastTwo),
          _weighIn(_otherQueuedId, 80.4, _winterHalfPastTwo),
        ]);
        // An older build in central Europe wrote 02:30 for both: CEST
        // (+02:00) before the switch, CET (+01:00) after it.
        await _seedRows(kv, [
          {
            't': _legacyWallClock(_summerHalfPastTwo, const Duration(hours: 2)),
            'kg': 80.0,
          },
          {
            't': _legacyWallClock(_winterHalfPastTwo, const Duration(hours: 1)),
            'kg': 80.4,
          },
        ]);

        final log = await _coldStart(cache);
        expectInstants(log.entries, [_summerHalfPastTwo, _winterHalfPastTwo]);
        expect(log.entries.map((e) => e.weightKg), [80, 80.4]);
        expect(
          (await _storedRows(kv)).map((row) => row['t']),
          [_summerHalfPastTwo, _winterHalfPastTwo]
              .map((t) => t.toIso8601String()),
        );
      });
    });

    test('the local calendar day follows the instant, not the old zone', () async {
      await withClock(Clock.fixed(_now), () async {
        // Early or late here, so the wall clock of the former zone falls on
        // another calendar day.
        final noon = DateTime(2026, 9, 16, 12);
        final former = _formerZone(noon);
        final towardsEarlier = former < noon.timeZoneOffset;
        final local = DateTime(2026, 9, 16, towardsEarlier ? 2 : 21, 15, 0, 0, 42);
        final instant = local.toUtc();
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, instant)]);
        await _seedRows(kv, [
          {'t': _legacyWallClock(instant, former), 'kg': 80.0},
        ]);

        final entry = (await cache.readWeightLog())!.entries.single;
        expect(entry.timestamp.isUtc, isFalse);
        expect(
          (entry.timestamp.year, entry.timestamp.month, entry.timestamp.day),
          (2026, 9, 16),
        );
        expect(entry.timestamp.isAtSameMomentAs(instant), isTrue);
      });
    });

    test('an operation queued before 2026-09-20 matches its snapshot row after '
        'travel', () async {
      await withClock(Clock.fixed(_now), () async {
        // Builds before the SQLite release queued the wall clock too, so the
        // operation itself reads in the current zone.
        final wall = _legacyWallClock(_instant, _formerZone(_instant));
        final kv = InMemoryKeyValueStore();
        await kv.setString(
          'eatova.v1.outbox.$_owner',
          jsonEncode(<String, dynamic>{
            'items': [
              {
                'kind': 'weightInsert',
                'entity_id': _queuedId,
                'payload': {'weight_kg': 80.0, 'recorded_at': wall},
                'queued_at': wall,
                'attempts': 0,
              },
            ],
          }),
        );
        final cache = LocalCache(kv, _owner);
        final queued = (await cache.readSyncOperations()).single.recordedAt!;
        // This build's snapshot in the former zone stored that reading.
        await _seedRows(kv, [
          {
            't': DateTime.parse('${wall}Z')
                .subtract(_formerZone(_instant))
                .toIso8601String(),
            'kg': 80.0,
          },
        ]);

        expectInstants((await cache.readWeightLog())!.entries, [queued]);
        expectInstants((await _coldStart(cache)).entries, [queued]);
        expect(
          (await _storedRows(kv)).map((row) => row['t']),
          [queued.toUtc().toIso8601String()],
        );
      });
    });
  });

  group('legacy rows without a queued weigh-in', () {
    test('read as wall clocks of the current zone', () async {
      final kv = InMemoryKeyValueStore();
      final cache = LocalCache(kv, _owner);
      await _seedRows(kv, [
        {'t': '2026-09-15T07:30:00.000', 'kg': 81.0},
      ]);

      final entry = (await cache.readWeightLog())!.entries.single;
      expect(entry.timestamp, DateTime(2026, 9, 15, 7, 30));
      expect(entry.weightKg, 81);
    });

    test('an equal weight at another time is not the queued weigh-in', () async {
      await withClock(Clock.fixed(_now), () async {
        final here = _instant.toLocal().timeZoneOffset;
        final dayBefore = _instant.subtract(const Duration(days: 1));
        final secondsOff = _instant.subtract(const Duration(hours: 3, seconds: 7));
        final kv = InMemoryKeyValueStore();
        final cache = LocalCache(kv, _owner);
        await cache.commitSyncOperations([_weighIn(_queuedId, 80, _instant)]);
        // Delivered weigh-ins: a full day earlier with the same clock
        // reading (beyond any UTC offset), and one not a whole number of
        // quarter hours away.
        await _seedRows(kv, [
          {'t': _legacyWallClock(dayBefore, here), 'kg': 80.0},
          {'t': _legacyWallClock(secondsOff, here), 'kg': 80.0},
        ]);

        final log = await _coldStart(cache);
        expectInstants(log.entries, [dayBefore, secondsOff, _instant]);
        expect(await _storedRows(kv), hasLength(3));
      });
    });
  });
}
