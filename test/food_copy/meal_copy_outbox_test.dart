// Copying meals through the real outbox (DATA-7): one mealInsert per copy,
// committed before the UI publishes, delivered later when offline, and an
// undo that deletes exactly the copies. After the session ended neither a
// copy nor its undo writes anything.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import '../outbox/outbox_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 14, 12, 30);
final DateTime _today = DateTime(2026, 10, 14);
final DateTime _yesterday = DateTime(2026, 10, 13);

Future<void> _at(Future<void> Function() body) =>
    withClock(Clock.fixed(_now), body);

/// Captures the toast actions, which [SnackCapture] drops.
class _Undo {
  SnackBarAction? last;

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    if (action != null) last = action;
  }
}

/// The outbox suites' [setup], with a toast emitter that keeps the undo.
({HomeStore store, FakeServer server, LocalCache cache, _Undo undo})
_setupWithUndo() {
  final server = FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache = LocalCache(InMemoryKeyValueStore(), 'user-outbox');
  final undo = _Undo();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-outbox'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: undo.call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, server: server, cache: cache, undo: undo);
}

Set<String> _entityIds(List<SyncOp> ops, SyncOpKind kind) => {
  for (final op in ops)
    if (op.kind == kind) op.entityId,
};

Set<String> _wireIds(FakeServer server, String kind) => {
  for (final request in server.operations(kind))
    (jsonDecode(request.body) as Map)['p_entity_id'] as String,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'online: eine mealInsert-Op pro Kopie, neue Server-Zeilen, die Zeile des '
    'Originals bleibt',
    () => _at(() async {
      final s = _setupWithUndo();
      await boot(s.store);
      await s.store.addResultToDailyTotal(
        mealResult('Muesli'),
        slot: MealSlot.breakfast,
        foodDate: _yesterday,
      );
      await s.store.addResultToDailyTotal(
        mealResult('Kaffee', kcal: 20),
        slot: MealSlot.breakfast,
        foodDate: _yesterday,
      );
      await settle();
      final originals = Map.of(s.server.mealRows);
      final favoriteWrites = s.server.operations('favoriteUpsert').length;
      final counted = s.server.mealsCounted;

      final copies = await s.store.repeatPreviousDaySlot(
        MealSlot.breakfast,
        _today,
      );
      await settle();

      expect(copies, hasLength(2));
      expect(_wireIds(s.server, 'mealInsert'), containsAll(copies));
      expect(
        s.server.operations('mealInsert'),
        hasLength(4),
        reason: 'zwei Eintraege plus genau eine Op pro Kopie',
      );
      for (final id in copies) {
        expect(s.server.mealRows[id]?['local_day'], '2026-10-14');
      }
      for (final entry in originals.entries) {
        expect(
          s.server.mealRows[entry.key],
          entry.value,
          reason: 'die Server-Zeile des Originals bleibt unberuehrt',
        );
      }
      expect(s.server.mealsCounted, counted + 2);
      expect(s.server.trackedDay, '2026-10-14');
      expect(
        s.server.operations('favoriteUpsert'),
        hasLength(favoriteWrites),
        reason: 'Kopieren aendert keine Recents',
      );
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'offline: die Kopien liegen kill-sicher in der Outbox und gehen spaeter '
    'raus',
    () => _at(() async {
      final s = _setupWithUndo();
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Bowl'),
        slot: MealSlot.lunch,
        foodDate: _yesterday,
      );
      await settle();

      s.server.offline = true;
      final copies = await s.store.copyLoggedMeals(
        [id],
        day: _today,
        slot: MealSlot.dinner,
      );

      expect(
        s.store.mealsForFoodDate(_today).map((m) => m.id),
        copies,
        reason: 'offline sofort im Tagebuch',
      );
      expect(_entityIds(s.store.pendingOutbox, SyncOpKind.mealInsert), {
        ...copies,
      });
      await settle();
      final persisted = (await s.cache.readOutbox())!;
      expect(_entityIds(persisted, SyncOpKind.mealInsert), {...copies});
      expect(s.server.mealRows.containsKey(copies.single), isFalse);

      s.server.offline = false;
      s.store.flushPendingWrites();
      await settle();

      expect(s.server.mealRows[copies.single]?['forced_slot'], 'dinner');
      expect(s.server.mealRows.containsKey(id), isTrue);
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'offline Rueckgaengig: genau die Kopien werden geloescht, auch auf dem '
    'Server',
    () => _at(() async {
      final s = _setupWithUndo();
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Bowl'),
        slot: MealSlot.lunch,
        foodDate: _yesterday,
      );
      await settle();

      s.server.offline = true;
      final copies = await s.store.repeatPreviousDaySlot(
        MealSlot.lunch,
        _today,
      );
      s.undo.last!.onPressed();
      await settle();

      expect(_entityIds(s.store.pendingOutbox, SyncOpKind.mealDelete), {
        ...copies,
      });
      expect(s.store.loggedMeals.map((m) => m.id), [id]);

      s.server.offline = false;
      s.store.flushPendingWrites();
      await settle();

      expect(s.server.mealRows.keys, [id]);
      expect(_wireIds(s.server, 'mealDelete'), {...copies});
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'nach dem Abmelden schreiben weder Kopieren noch Rueckgaengig etwas',
    () => _at(() async {
      final s = _setupWithUndo();
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Bowl'),
        slot: MealSlot.lunch,
        foodDate: _yesterday,
      );
      await settle();
      final copies = await s.store.copyLoggedMeals([id], day: _today);
      await settle();
      final undo = s.undo.last!;
      final requests = s.server.requests.length;

      await s.store.signOutCleanup();

      await expectLater(
        s.store.copyLoggedMeals([id], day: _today),
        throwsStateError,
      );
      undo.onPressed();
      await settle();

      expect(
        s.server.requests.length,
        requests,
        reason: 'nichts erreicht nach dem Abmelden den Server',
      );
      expect(s.server.mealRows.containsKey(copies.single), isTrue);
      final outbox = await s.cache.readOutbox() ?? const <SyncOp>[];
      expect(
        outbox,
        isEmpty,
        reason: 'nichts landet in der Outbox des beendeten Kontos',
      );
    }),
  );
}
