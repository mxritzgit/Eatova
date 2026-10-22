// Correcting weigh-ins (review 2026-10-19): value and time can be edited and
// a weigh-in deleted with an undo, through durable sync operations
// (weightUpsert / weightDelete, 20261019110000). An edit or a delete
// re-anchors the plan through the same path as a new weigh-in, and only
// Eatova's own Apple Health sample follows.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart';

import 'outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 19, 9);

/// Live mode, male, 182 cm, light, −0.5 kg/week: 2100 kcal at 84 kg.
UserProfile _live() => const KcalCalculator().applyLiveGoals(
  const UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 76,
    weightGoal: WeightGoal.lose05kg,
    diet: DietPreference.none,
    onboardingCompleted: true,
  ),
);

Map<String, dynamic> _row(String id, DateTime at, double kg) =>
    <String, dynamic>{
      'id': id,
      'recorded_at': at.toUtc().toIso8601String(),
      'weight_kg': kg,
    };

Iterable<SyncOp> _weightOps(Iterable<SyncOp> ops) => ops.where(
  (op) =>
      op.kind == SyncOpKind.weightInsert ||
      op.kind == SyncOpKind.weightUpsert ||
      op.kind == SyncOpKind.weightDelete,
);

String _sentOperationId(dynamic request) =>
    (jsonDecode(request.body as String) as Map)['p_operation_id'] as String;

/// Records Health writes and deletes; Eatova's own samples are the ones it
/// wrote. [samples] are a scale's weigh-ins for the import.
class _Health
    implements HealthService, HealthWeightCorrection, HealthWeightSource {
  final writes = <(double, DateTime)>[];
  final deletes = <DateTime>[];
  final own = <int>{};
  List<WeightSample> samples = <WeightSample>[];

  @override
  Future<List<WeightSample>?> readWeightSamples(
    DateTime from,
    DateTime to,
  ) async => samples;

  @override
  Future<bool> ensureWeightAccess() async => true;

  @override
  HealthAuthState get authState => HealthAuthState.unsupported;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    writes.add((kg, when));
    own.add(when.microsecondsSinceEpoch);
    return true;
  }

  @override
  Future<bool> deleteOwnWeight(DateTime when) async {
    deletes.add(when);
    return own.remove(when.microsecondsSinceEpoch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an edited typo moves the plan back, as one upsert of the same id', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    await a.store.logWeight(95.0);
    await settle();
    expect(a.store.profile.weightKg, 95, reason: 'precondition: the typo anchors');
    final id = a.store.weightLog.latest!.id!;

    final yesterday = _now.subtract(const Duration(days: 1));
    await a.store.updateWeighIn(id, kg: 84.2, at: yesterday);
    await settle();

    final entry = a.store.weightLog.entries.single;
    expect((entry.id, entry.weightKg), (id, 84.2));
    expect(entry.timestamp.isAtSameMomentAs(yesterday), isTrue);
    expect(a.store.profile.weightKg, 84);
    expect(a.store.profile.dailyKcalGoal, 2100);
    expect(a.server.profileRow!['weight_kg'], 84);
    expect(a.server.weightRows[id]!['weight_kg'], 84.2);
    expect(
      DateTime.parse(a.server.weightRows[id]!['recorded_at'] as String)
          .isAtSameMomentAs(yesterday),
      isTrue,
    );
    final edits = a.server.operations('weightUpsert');
    expect(edits, hasLength(1));
    expect((jsonDecode(edits.single.body) as Map)['p_entity_id'], id);
    expect(a.server.weightLogsCounted, 1, reason: 'an edit counts no weigh-in');
    expect(a.store.pendingOutbox, isEmpty);
  }));

  test('a moment in the future becomes now', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    await a.store.logWeight(84.0, at: _now.subtract(const Duration(days: 3)));
    await settle();
    final id = a.store.weightLog.latest!.id!;
    expect(
      a.store.weightLog.latest!.timestamp,
      _now.subtract(const Duration(days: 3)),
      reason: 'a dated weigh-in keeps its day',
    );

    await a.store.updateWeighIn(id, kg: 84.0, at: _now.add(const Duration(hours: 5)));
    await settle();

    expect(a.store.weightLog.latest!.timestamp, _now);
  }));

  test('delete, then undo: the value returns under a new id, uncounted', () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    a.server.profileRow = serverProfileRow(_live());
    final older = uuidV4(), newer = uuidV4();
    final at = _now.subtract(const Duration(days: 1));
    a.server.weightRows[older] = _row(older, _now.subtract(const Duration(days: 2)), 84.0);
    a.server.weightRows[newer] = _row(newer, at, 84.4);
    await boot(a.store);
    a.snacks.messages.clear();
    a.snacks.actions.clear();

    await a.store.deleteWeighIn(newer);
    await settle();

    expect(a.store.weightLog.entries.map((e) => e.id), [older]);
    expect(a.server.weightRows.keys, [older]);
    expect(a.snacks.messages, ['Wiegung gelöscht']);
    final undo = a.snacks.actions.single!;

    undo.onPressed();
    undo.onPressed();
    await settle();

    expect(a.store.weightLog.entries, hasLength(2));
    final restored = a.store.weightLog.latest!;
    expect(restored.id, isNot(newer), reason: 'a deleted id stays deleted');
    expect((restored.weightKg, restored.timestamp), (84.4, at));
    expect(a.server.weightRows[restored.id]!['weight_kg'], 84.4);
    expect(a.server.operations('weightUpsert'), hasLength(1),
        reason: 'a double tap restores once');
    expect(a.server.weightLogsCounted, 0, reason: 'neither delete nor undo count');
  }));

  test('offline, an edit of an unsent weigh-in survives a restart and replays in order', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, disposeStore: false);
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    a.server.offline = true;
    await a.store.logWeight(80.0);
    final id = a.store.weightLog.latest!.id!;
    final edited = _now.subtract(const Duration(hours: 2));
    await a.store.updateWeighIn(id, kg: 79.4, at: edited);
    await settle();
    final queued = _weightOps(a.store.pendingOutbox).toList();
    expect(queued.map((op) => (op.kind, op.entityId)), [
      (SyncOpKind.weightInsert, id),
      (SyncOpKind.weightUpsert, id),
    ]);
    a.store.dispose();

    final b = setup(kv: kv, geteilterServer: a.server);
    await boot(b.store);
    final shown = b.store.weightLog.entries.single;
    expect((shown.id, shown.weightKg), (id, 79.4));
    expect(shown.timestamp.isAtSameMomentAs(edited), isTrue,
        reason: 'the cached row holds the edit, not the insert');
    expect(
      _weightOps(b.store.pendingOutbox).map((op) => op.operationId),
      queued.map((op) => op.operationId),
      reason: 'operation identities survive the restart',
    );

    a.server.offline = false;
    await b.store.syncPendingWrites();
    await settle();

    expect(a.server.weightRows[id]!['weight_kg'], 79.4);
    expect(a.server.weightLogsCounted, 1);
    expect(
      a.server.operations('weightUpsert').map(_sentOperationId),
      [queued.last.operationId],
    );
    expect(_weightOps(b.store.pendingOutbox), isEmpty);
  }));

  test('a deleted unsent weigh-in stays gone across a restart', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv, disposeStore: false);
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    a.server.offline = true;
    await a.store.logWeight(80.0);
    final id = a.store.weightLog.latest!.id!;
    await a.store.deleteWeighIn(id);
    await settle();
    expect(a.store.weightLog.entries, isEmpty);
    a.store.dispose();

    final b = setup(kv: kv, geteilterServer: a.server);
    await boot(b.store);
    expect(b.store.weightLog.entries, isEmpty);

    a.server.offline = false;
    await b.store.syncPendingWrites();
    await settle();

    expect(a.server.weightRows, isEmpty);
    // The insert reached the server before its delete: logged once.
    expect(a.server.weightLogsCounted, 1);
    expect(b.store.weightLog.entries, isEmpty);
  }));

  test('an edit of a weigh-in another device deleted drops it here too', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    a.server.profileRow = serverProfileRow(_live());
    final id = uuidV4();
    a.server.weightRows[id] = _row(id, _now.subtract(const Duration(days: 1)), 84.0);
    await boot(a.store);
    a.server.syncOperations.apply(<String, dynamic>{
      'p_operation_id': uuidV4(),
      'p_kind': 'weightDelete',
      'p_entity_id': id,
      'p_payload': <String, dynamic>{},
    });

    await a.store.updateWeighIn(id, kg: 83.6, at: _now.subtract(const Duration(days: 1)));
    await settle();

    expect(a.server.weightRows, isEmpty, reason: 'the stale edit revives nothing');
    expect(a.store.weightLog.entries, isEmpty);
    expect(await LocalCache(kv, 'user-outbox').readWeightLog(), isNotNull);
    expect((await LocalCache(kv, 'user-outbox').readWeightLog())!.entries, isEmpty);
  }));

  test('rows an older build cached without ids get them from the next load', () => withClock(Clock.fixed(_now), () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-outbox');
    await cache.writeProfile(_live());
    await kv.setString(
      'eatova.v1.weight_log.user-outbox',
      jsonEncode({
        'items': [
          {'t': _now.subtract(const Duration(days: 1)).toUtc().toIso8601String(), 'kg': 84.0},
        ],
      }),
    );
    final id = uuidV4();
    final a = setup(injizierterCache: cache, disposeStore: false);
    a.server.offline = true;
    await boot(a.store);
    expect(a.store.weightLog.entries.single.id, isNull, reason: 'precondition');
    await expectLater(
      a.store.updateWeighIn('missing', kg: 80, at: _now),
      throwsStateError,
    );
    a.store.dispose();

    final b = setup(kv: kv, geteilterServer: a.server);
    a.server
      ..offline = false
      ..profileRow = serverProfileRow(_live())
      ..weightRows[id] = _row(id, _now.subtract(const Duration(days: 1)), 84.0);
    await bootUntilIdle(b.store);

    expect(b.store.weightLog.entries.single.id, id);
    final cached = await LocalCache(kv, 'user-outbox').readWeightLog();
    expect(cached!.entries.single.id, id, reason: 'store snapshots keep ids');
  }));

  test("Apple Health: Eatova's own sample follows an edit, a delete and its undo", () => withClock(Clock.fixed(_now), () async {
    final health = _Health();
    final a = setup(kv: healthConnectedKv(), health: health);
    a.server.profileRow = serverProfileRow(_live());
    await boot(a.store);
    await a.store.logWeight(84.0);
    final id = a.store.weightLog.latest!.id!;
    final moved = _now.subtract(const Duration(hours: 1));

    await a.store.updateWeighIn(id, kg: 83.8, at: moved);
    await settle();
    expect(health.deletes, [_now]);
    expect(health.writes.last, (83.8, moved));

    await a.store.deleteWeighIn(id);
    await settle();
    expect(health.deletes.last, moved);
    final undo = a.snacks.actions.lastWhere((action) => action != null)!;
    undo.onPressed();
    await settle();
    expect(health.writes.last, (83.8, moved), reason: 'the undo writes it back');
    expect(health.writes, hasLength(3));
  }));

  test('Apple Health: an imported weigh-in leaves the source sample alone', () => withClock(Clock.fixed(_now), () async {
    final measured = _now.subtract(const Duration(hours: 3));
    final health = _Health()
      ..samples = [WeightSample(kg: 84.3, measuredAt: measured)];
    final a = setup(kv: healthConnectedKv(), health: health);
    a.server.profileRow = serverProfileRow(_live());
    await bootUntilIdle(a.store);
    await a.store.enableHealthWeightImport();
    final id = a.store.weightLog.latest!.id!;

    await a.store.updateWeighIn(id, kg: 84.1, at: measured);
    await a.store.deleteWeighIn(id);
    await settle();
    a.snacks.actions.lastWhere((action) => action != null)!.onPressed();
    await settle();

    expect(health.deletes, [measured, measured],
        reason: 'only own samples are deletable; there was none');
    expect(health.writes, isEmpty, reason: 'no copy of the scale reading');
  }));
}
