import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

import 'outbox/outbox_test_helpers.dart' as h;
import 'recipe_edit_store_test.dart' show draft;
import 'support/atomic_store_faults.dart';

void remoteEdit(h.FakeServer server, FitnessRecipe recipe) {
  server.syncOperations.apply({
    'p_operation_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'p_kind': 'recipeUpsert',
    'p_entity_id': recipe.slug,
    'p_payload': {
      'expected_revision': recipe.serverRevision,
      'recipe': recipe.copyWith(title: 'Other device').toRow(),
    },
  });
}

class _HeldReceiptServer extends h.FakeServer {
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  http.Client client() {
    final upstream = super.client();
    return MockClient((request) async {
      final forwarded = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      final response = await http.Response.fromStream(
        await upstream.send(forwarded),
      );
      if (gate != null &&
          request.url.path.endsWith('/rpc/load_sync_operation_receipt')) {
        final waiting = gate!;
        gate = null;
        if (!started.isCompleted) started.complete();
        await waiting.future;
      }
      return response;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'old receipt cannot overwrite a successor ACKed while the read was held',
    () async {
      final server = _HeldReceiptServer();
      final env = h.setup(geteilterServer: server);
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final first = await env.store.editUserRecipe(
        env.store.userRecipes.single.copyWith(title: 'First'),
      );
      addTearDown(first.handle.dispose);
      final gate = server.gate = Completer<void>();
      final refreshing = first.handle.refresh();
      await server.started.future;
      final second = await env.store.editUserRecipe(
        first.handle.value.recipe!.copyWith(title: 'Latest'),
      );
      addTearDown(second.handle.dispose);
      final latestRevision = second.handle.value.recipe!.serverRevision;
      gate.complete();
      await refreshing;
      expect(first.handle.value.recipe!.title, 'Latest');
      expect(first.handle.value.recipe!.serverRevision, latestRevision);
      expect(first.handle.value.resolving, isFalse);
      expect(env.server.recipeRows, hasLength(1));
    },
  );

  test(
    'successive confirmed edits use the current revision without a copy',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      expect(env.store.activeRecipeEditWatches, 0);
      final original = env.store.userRecipes.single;
      final first = await env.store.editUserRecipe(
        original.copyWith(title: 'First'),
      );
      addTearDown(first.handle.dispose);
      expect(first.delivery, SyncDelivery.delivered);
      expect(
        first.handle.value.recipe!.serverRevision,
        original.serverRevision! + 1,
      );
      final second = await env.store.editUserRecipe(
        first.handle.value.recipe!.copyWith(title: 'Second'),
      );
      addTearDown(second.handle.dispose);
      expect(
        second.handle.value.recipe!.serverRevision,
        original.serverRevision! + 2,
      );
      expect(second.handle.value.conflictSaved, isFalse);
      expect(env.server.recipeRows, hasLength(1));
      expect(first.handle.value.recipe!.title, 'Second');
      first.handle.dispose();
      second.handle.dispose();
      expect(env.store.activeRecipeEditWatches, 0);
    },
  );

  test(
    'conflict result follows the exact copy and edits its current base',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      remoteEdit(env.server, original);
      final result = await env.store.editUserRecipe(
        original.copyWith(title: 'Mine'),
      );
      addTearDown(result.handle.dispose);
      final copy = result.handle.value.recipe!;
      expect(result.handle.value.conflictSaved, isTrue);
      expect(copy.slug, isNot(original.slug));
      expect(copy.conflictOf, original.slug);
      expect(copy.title, 'Mine');
      final next = await env.store.editUserRecipe(
        copy.copyWith(title: 'Mine again'),
      );
      addTearDown(next.handle.dispose);
      expect(next.handle.value.recipe!.slug, copy.slug);
      expect(next.handle.value.conflictSaved, isFalse);
      expect(env.server.recipeRows, hasLength(2));
      expect(env.server.recipeRows[original.slug]!['title'], 'Other device');
    },
  );

  test(
    'offline successors keep their draft through conflict rebase and ACK',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      remoteEdit(env.server, original);
      env.server.offline = true;
      final first = await env.store.editUserRecipe(
        original.copyWith(title: 'First'),
      );
      final second = await env.store.editUserRecipe(
        first.handle.value.recipe!.copyWith(title: 'Latest draft'),
      );
      addTearDown(first.handle.dispose);
      addTearDown(second.handle.dispose);
      expect(second.delivery, SyncDelivery.queuedOffline);
      final shown = <String>[];
      second.handle.addListener(() {
        if (second.handle.value.recipe case final recipe?) {
          shown.add(recipe.title);
        }
      });
      env.server.offline = false;
      await env.store.syncPendingWrites();
      expect(shown, isNotEmpty);
      expect(shown.every((title) => title == 'Latest draft'), isTrue);
      expect(second.handle.value.recipe!.slug, isNot(original.slug));
      expect(second.handle.value.recipe!.title, 'Latest draft');
      expect(second.handle.value.pending, isFalse);
      expect(env.server.recipeRows, hasLength(2));
    },
  );

  test(
    'headless ACK resolves copy with stale RAM queue and permits next edit',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      remoteEdit(env.server, original);
      env.server.offline = true;
      final result = await env.store.editUserRecipe(
        original.copyWith(title: 'Mine'),
      );
      addTearDown(result.handle.dispose);
      env.server.offline = false;
      final op = (await env.cache.startSyncOperation(
        result.handle.operationId,
      ))!;
      final ack = await dispatchSyncOp(env.store.sync!, op);
      await env.cache.acknowledgeSyncOperation(op.operationId, ack);
      expect(
        env.store.pendingOutbox,
        isNotEmpty,
        reason: 'No foreground notification',
      );
      expect(env.store.userRecipes.single.slug, original.slug);
      await result.handle.refresh();
      final copy = result.handle.value.recipe!;
      expect(copy.slug, isNot(original.slug));
      expect(result.handle.value.conflictSaved, isTrue);
      expect(result.handle.value.resolving, isFalse);
      expect(env.store.pendingOutbox, isEmpty);
      expect(
        env.store.userRecipes.any((recipe) => recipe.slug == copy.slug),
        isTrue,
      );
      final next = await env.store.editUserRecipe(
        copy.copyWith(title: 'Next edit'),
      );
      addTearDown(next.handle.dispose);
      expect(next.handle.value.recipe!.slug, copy.slug);
      expect(env.server.recipeRows, hasLength(2));
    },
  );

  test(
    'headless queued successor follows rebased identity before its own ACK',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      remoteEdit(env.server, original);
      env.server.offline = true;
      final first = await env.store.editUserRecipe(
        original.copyWith(title: 'First'),
      );
      final second = await env.store.editUserRecipe(
        first.handle.value.recipe!.copyWith(title: 'Second'),
      );
      addTearDown(first.handle.dispose);
      addTearDown(second.handle.dispose);
      env.server.offline = false;
      final op = (await env.cache.startSyncOperation(
        first.handle.operationId,
      ))!;
      await env.cache.acknowledgeSyncOperation(
        op.operationId,
        await dispatchSyncOp(env.store.sync!, op),
      );
      await second.handle.refresh();
      expect(second.handle.value.recipe!.slug, isNot(original.slug));
      expect(second.handle.value.recipe!.title, 'Second');
      expect(second.handle.value.pending, isTrue);
      await env.store.syncPendingWrites();
      expect(second.handle.value.recipe!.title, 'Second');
      expect(env.server.recipeRows, hasLength(2));
    },
  );

  test(
    'receipt outage preserves exact draft then current tombstone blocks editing',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      remoteEdit(env.server, original);
      env.server.offline = true;
      final result = await env.store.editUserRecipe(
        original.copyWith(title: 'Mine'),
      );
      addTearDown(result.handle.dispose);
      env.server.offline = false;
      final op = (await env.cache.startSyncOperation(
        result.handle.operationId,
      ))!;
      final ack = await dispatchSyncOp(env.store.sync!, op);
      await env.cache.acknowledgeSyncOperation(op.operationId, ack);
      env.server.offline = true;
      await result.handle.refresh();
      expect(result.handle.value.recipe!.title, 'Mine');
      expect(result.handle.value.resolving, isTrue);
      expect(result.handle.value.canEdit, isFalse);
      env.server.offline = false;
      await env.store.sync!.userRecipes.delete(
        ack.recipe!.slug,
        expectedRevision: ack.recipe!.serverRevision,
      );
      await result.handle.refresh();
      expect(result.handle.value.recipe, isNull);
      expect(result.handle.value.targetSlug, ack.recipe!.slug);
      expect(result.handle.value.targetSlug, isNot(original.slug));
      expect(result.handle.value.resolving, isFalse);
      expect(result.handle.value.canEdit, isFalse);
    },
  );

  test(
    'failed commit and disposed owner release every edit observer',
    () async {
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final env = h.setup(
        injizierterCache: LocalCache(faults, 'user-outbox'),
        disposeStore: false,
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) env.store.dispose();
      });
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      faults.beforeWrite = (_) async => throw StateError('Disk unavailable');
      await expectLater(
        env.store.editUserRecipe(
          env.store.userRecipes.single.copyWith(title: 'Rejected'),
        ),
        throwsStateError,
      );
      expect(env.store.activeRecipeEditWatches, 0);
      faults.beforeWrite = null;
      final result = await env.store.editUserRecipe(
        env.store.userRecipes.single.copyWith(title: 'Saved'),
      );
      expect(env.store.activeRecipeEditWatches, 1);
      env.store.dispose();
      disposed = true;
      expect(result.handle.isDisposed, isTrue);
      expect(env.store.activeRecipeEditWatches, 0);
      await result.handle.refresh();
    },
  );
}
