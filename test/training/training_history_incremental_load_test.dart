import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/training_history_sync.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import 'training_timer_fixtures.dart';

// Cold start: with this account's cached history only a manifest
// (id, finished_at) is downloaded; full rows only for ids the cache lacks.

final _finished = DateTime.utc(2026, 9, 25, 12);

final Map<String, dynamic> _template = withClock(Clock.fixed(_finished), () {
  final controller = TrainingSessionController(
    plan: timerPlan(),
    workoutIndex: 1,
    autoTick: false,
  );
  controller.start();
  controller.completeCurrentSet();
  final row = controller
      .completion(finishedAt: _finished.add(const Duration(minutes: 1)))
      .toRow();
  controller.dispose();
  return row;
});

String _id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// A valid server row with identity [n], finished [n] minutes after the base.
Map<String, dynamic> _row(int n, {int? minutes}) {
  final row = jsonDecode(jsonEncode(_template)) as Map<String, dynamic>;
  row['id'] = _id(n);
  row['finished_at'] = _finished
      .add(Duration(minutes: minutes ?? n + 1))
      .toIso8601String();
  (row['session'] as Map)['snapshot']['session_id'] = _id(n);
  return row;
}

TrainingHistoryEntry _entry(int n, {int? minutes}) =>
    TrainingHistoryEntry.fromRow(_row(n, minutes: minutes));

/// PostgREST subset for `training_history`: owner, `id=in`, keyset cursor,
/// order, limit and column projection. Other tables answer empty.
class _HistoryServer {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  final historyReads = <({String select, int bytes, List<String>? ids})>[];
  bool offlineWrites = true;

  /// Runs between the manifest and the row fetch (concurrent deletion).
  void Function()? afterManifest;

  void put(String owner, Map<String, dynamic> row) =>
      (rows[owner] ??= {})[row['id'] as String] = row;

  Future<http.Response> handle(http.Request request) async {
    http.Response ok(Object? body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
    final path = request.url.path;
    if (path.endsWith('/rpc/apply_sync_operation') && offlineWrites) {
      throw http.ClientException('fixture offline');
    }
    if (!path.endsWith('/training_history')) {
      if (path.endsWith('/profiles')) return ok(null);
      if (path.endsWith('/lifetime_stats')) return ok({});
      return ok(const []);
    }
    final query = request.url.queryParameters;
    final owner = query['user_id']!.substring(3);
    Iterable<Map<String, dynamic>> result = (rows[owner] ?? {}).values;
    final rawIds = query['id'];
    final ids = rawIds
        ?.substring('in.('.length, rawIds.length - 1)
        .split(',')
        .map((id) => id.replaceAll('"', ''))
        .toList();
    if (ids != null) {
      result = result.where((row) => ids.contains(row['id']));
    }
    final cursor = query['or'];
    if (cursor != null) {
      final match = RegExp(
        r'^\(finished_at\.lt\.([^,]+),and\(finished_at\.eq\.([^,]+),id\.lt\.([^\)]+)\)\)$',
      ).firstMatch(cursor)!;
      final at = DateTime.parse(match.group(1)!);
      final id = match.group(3)!;
      result = result.where((row) {
        final time = DateTime.parse(row['finished_at'] as String);
        return time.isBefore(at) ||
            (time == at && (row['id'] as String).compareTo(id) < 0);
      });
    }
    final sorted = result.toList()
      ..sort((a, b) {
        final byTime = DateTime.parse(
          b['finished_at'] as String,
        ).compareTo(DateTime.parse(a['finished_at'] as String));
        return byTime != 0
            ? byTime
            : (b['id'] as String).compareTo(a['id'] as String);
      });
    final limit = int.tryParse(query['limit'] ?? '');
    final columns = query['select']!.split(',');
    final page = [
      for (final row in limit == null ? sorted : sorted.take(limit))
        {for (final column in columns) column: row[column]},
    ];
    final body = jsonEncode(page);
    historyReads.add((
      select: query['select']!,
      bytes: utf8.encode(body).length,
      ids: ids,
    ));
    if (ids == null && !columns.contains('session')) afterManifest?.call();
    return ok(page);
  }

  Iterable<({String select, int bytes, List<String>? ids})> get fullRowReads =>
      historyReads.where((read) => read.select.contains('session'));
}

SupabaseClient _client(_HistoryServer server) {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient(server.handle),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

HomeStore _store(_HistoryServer server, LocalCache cache, String owner) {
  final store = HomeStore(
    sync: EatovaSync.forUser(_client(server), owner),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

Future<LocalCache> _cacheWithHistory(
  KeyValueStore kv,
  String owner,
  List<TrainingHistoryEntry> history,
) async {
  final cache = LocalCache(kv, owner);
  await cache.writeProfile(const UserProfile(onboardingCompleted: true));
  await cache.commitStoreSnapshot(
    expectedVersions: const {},
    trainingHistory: history,
  );
  return cache;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrainingHistorySync.load(known:)', () {
    late _HistoryServer server;
    late TrainingHistorySync sync;
    setUp(() {
      server = _HistoryServer();
      for (var n = 1; n <= 40; n++) {
        server.put('A', _row(n));
      }
      sync = TrainingHistorySync(_client(server), 'A');
    });

    test('unveränderte Zeilen werden nicht erneut geladen', () async {
      final known = [for (var n = 1; n <= 40; n++) _entry(n)];
      final history = await sync.load(known: known);
      expect(server.fullRowReads, isEmpty);
      expect(server.historyReads.single.select, 'id,finished_at');
      expect(history.map((e) => e.id), [for (var n = 40; n >= 1; n--) _id(n)]);
      expect(history.map((e) => jsonEncode(e.toRow())), [
        for (var n = 40; n >= 1; n--) jsonEncode(_entry(n).toRow()),
      ]);
    });

    test('nur neue Zeilen kommen voll, in Server-Reihenfolge', () async {
      final known = [for (var n = 1; n <= 38; n++) _entry(n)];
      final history = await sync.load(known: known);
      final fetch = server.fullRowReads.single;
      expect(fetch.ids, [_id(40), _id(39)]);
      expect(history, hasLength(40));
      expect(history.first.id, _id(40));
    });

    test('geänderte Zeile (anderes finished_at) wird neu geladen', () async {
      final known = [
        for (var n = 1; n <= 40; n++)
          n == 7 ? _entry(7, minutes: 999) : _entry(n),
      ];
      final history = await sync.load(known: known);
      expect(server.fullRowReads.single.ids, [_id(7)]);
      expect(
        history.singleWhere((e) => e.id == _id(7)).finishedAt,
        _entry(7).finishedAt,
      );
    });

    test('auf anderem Gerät gelöschte Zeile verschwindet', () async {
      server.rows['A']!.remove(_id(5));
      final known = [for (var n = 1; n <= 40; n++) _entry(n)];
      final history = await sync.load(known: known);
      expect(history.map((e) => e.id), isNot(contains(_id(5))));
      expect(history, hasLength(39));
      expect(server.fullRowReads, isEmpty);
    });

    test('zwischen Manifest und Abruf gelöschte Zeile fehlt einfach', () async {
      server.afterManifest = () => server.rows['A']!.remove(_id(40));
      final known = [for (var n = 1; n <= 39; n++) _entry(n)];
      final history = await sync.load(known: known);
      expect(server.fullRowReads.single.ids, [_id(40)]);
      expect(history.map((e) => e.id), isNot(contains(_id(40))));
      expect(history, hasLength(39));
    });

    test('ohne Cache bleibt es der volle, gepagte Load', () async {
      final history = await sync.load();
      expect(server.historyReads.single.select, 'id,finished_at,session');
      expect(server.historyReads.single.ids, isNull);
      expect(history, hasLength(40));
    });

    test('viele fehlende Zeilen: voller Load statt vieler id-Abrufe', () async {
      for (var n = 41; n <= 41 + TrainingHistorySync.maxIncrementalFetch; n++) {
        server.put('A', _row(n));
      }
      final history = await sync.load(known: [_entry(1)]);
      expect(server.historyReads.where((read) => read.ids != null), isEmpty);
      expect(server.fullRowReads, isNotEmpty);
      expect(history, hasLength(41 + TrainingHistorySync.maxIncrementalFetch));
    });

    test(
      'Manifest-Zeilen ohne id/finished_at lassen den Load scheitern',
      () async {
        final broken = SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode([
                {'id': _id(1)},
              ]),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            ),
          ),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(broken.dispose);
        await expectLater(
          TrainingHistorySync(broken, 'A').load(known: [_entry(1)]),
          throwsFormatException,
        );
      },
    );

    test('Payload: 300 bekannte Workouts kosten nur das Manifest', () async {
      for (var n = 41; n <= 300; n++) {
        server.put('A', _row(n));
      }
      await sync.load();
      final full = server.historyReads.fold<int>(0, (s, r) => s + r.bytes);
      server.historyReads.clear();
      await sync.load(known: [for (var n = 1; n <= 300; n++) _entry(n)]);
      final manifest = server.historyReads.fold<int>(0, (s, r) => s + r.bytes);
      // Fixture plan: ~1.3 kB per row vs ~87 B per manifest row.
      expect(server.fullRowReads, isEmpty);
      expect(manifest * 10, lessThan(full));
    });
  });

  group('Kaltstart mit gecachter Historie', () {
    test(
      'lädt nur Neues, entfernt remote Gelöschtes und schreibt den Cache',
      () async {
        final server = _HistoryServer();
        for (var n = 1; n <= 5; n++) {
          if (n != 2) server.put('A', _row(n));
        }
        server.put('A', _row(6));
        final kv = InMemoryKeyValueStore();
        final cache = await _cacheWithHistory(kv, 'A', [
          for (var n = 1; n <= 5; n++) _entry(n),
        ]);
        final store = _store(server, cache, 'A');
        await h.bootUntilIdle(store);

        expect(server.fullRowReads.single.ids, [_id(6)]);
        expect(store.trainingHistoryLoadFailed, isFalse);
        expect(store.trainingHistory.map((e) => e.id).toSet(), {
          _id(1),
          _id(3),
          _id(4),
          _id(5),
          _id(6),
        });
        final cached = await LocalCache(kv, 'A').readTrainingHistory();
        expect(cached!.map((e) => e.id).toSet(), {
          _id(1),
          _id(3),
          _id(4),
          _id(5),
          _id(6),
        });
      },
    );

    test('ausstehender Abschluss im Outbox überlebt den Kaltstart', () async {
      final server = _HistoryServer()..put('A', _row(1));
      final kv = InMemoryKeyValueStore();
      final cache = await _cacheWithHistory(kv, 'A', [_entry(1)]);
      final pending = _entry(9);
      await cache.commitSyncOperations([SyncOp.trainingHistoryInsert(pending)]);
      final store = _store(server, cache, 'A');
      await h.bootUntilIdle(store);

      // The server does not list it yet; the confirmed intent stays.
      expect(store.trainingHistory.map((e) => e.id), contains(pending.id));
      expect(
        store.pendingOutbox.map((op) => op.entityId),
        contains(pending.id),
      );
      final restarted = LocalCache(kv, 'A');
      expect(
        (await restarted.readSyncOperations()).map((op) => op.entityId),
        contains(pending.id),
      );
      expect(
        (await restarted.readTrainingHistory())!.map((e) => e.id),
        containsAll([_id(1), pending.id]),
      );
    });

    test('Kontowechsel nutzt den Cache des anderen Kontos nicht', () async {
      final server = _HistoryServer()
        ..put('B', _row(1, minutes: 500))
        ..put('B', _row(2));
      final kv = InMemoryKeyValueStore();
      // Account A's cache holds identity 1 with different content.
      await _cacheWithHistory(kv, 'A', [_entry(1), _entry(3)]);
      final cacheB = LocalCache(kv, 'B');
      await cacheB.writeProfile(const UserProfile(onboardingCompleted: true));
      final store = _store(server, cacheB, 'B');
      await h.bootUntilIdle(store);

      expect(server.fullRowReads, isNotEmpty);
      expect(server.historyReads.every((read) => read.ids == null), isTrue);
      expect(store.trainingHistory.map((e) => e.id).toSet(), {_id(1), _id(2)});
      expect(
        store.trainingHistory.singleWhere((e) => e.id == _id(1)).finishedAt,
        _entry(1, minutes: 500).finishedAt,
      );
    });

    test('unlesbarer History-Slot fällt auf den vollen Load zurück', () async {
      final server = _HistoryServer()
        ..put('A', _row(1))
        ..put('A', _row(2));
      final kv = InMemoryKeyValueStore();
      final cache = await _cacheWithHistory(kv, 'A', [_entry(1)]);
      await kv.setString('eatova.v1.training_history.A', '{"items": 7}');
      final store = _store(server, cache, 'A');
      await h.bootUntilIdle(store);

      expect(server.historyReads.first.select, 'id,finished_at,session');
      expect(store.trainingHistory.map((e) => e.id).toSet(), {_id(1), _id(2)});
    });
  });
}
