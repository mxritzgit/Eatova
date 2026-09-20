import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'outbox/outbox_test_helpers.dart' as h;
import 'support/atomic_store_faults.dart';

FitnessRecipe draft(String title, {String slug = 'user_saved'}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: '',
      portion: 'One plate',
      ingredients: 'Rice',
      preparation: 'Boil rice.',
      professionalHint: '',
      imageAsset: 'local:kept.jpg',
      caloriesKcal: 400,
      proteinG: 20,
      carbsG: 60,
      fatG: 10,
      estimatedGrams: 300,
      categories: const ['Eigene'],
      userCreated: true,
    );

class _HeldRecipeServer extends h.FakeServer {
  Completer<void>? gate;
  Completer<void> started = Completer<void>();

  @override
  http.Client client() {
    final upstream = super.client();
    return MockClient((request) async {
      if (gate != null &&
          request.method == 'POST' &&
          request.url.path.endsWith('/rpc/apply_sync_operation') &&
          jsonDecode(request.body)['p_kind'] == 'recipeUpsert') {
        if (!started.isCompleted) started.complete();
        await gate!.future;
      }
      final forwarded = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return http.Response.fromStream(await upstream.send(forwarded));
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline edit has exact durable op and restores one recipe after restart',
    () async {
      final kv = InMemoryKeyValueStore();
      final env = h.setup(kv: kv);
      await h.bootUntilIdle(env.store);
      await env.store.saveUserRecipe(draft('Original'));
      env.server.offline = true;
      final delivery = await env.store.updateUserRecipe(
        env.store.userRecipes.single.copyWith(title: 'Edited'),
      );
      expect(delivery, SyncDelivery.queuedOffline);
      expect(env.store.userRecipes.single.title, 'Edited');
      final outbox = await env.cache.readOutbox();
      expect(
        outbox!
            .where((op) => op.kind == SyncOpKind.recipeUpsert)
            .single
            .recipe!
            .title,
        'Edited',
      );
      // Independent cache/store instances exercise cold-start outbox restoration.
      final restart = h.setup(kv: kv, geteilterServer: env.server);
      await h.bootUntilIdle(restart.store);
      expect(restart.store.userRecipes, hasLength(1));
      expect(restart.store.userRecipes.single.title, 'Edited');
      expect(restart.store.userRecipes.single.slug, 'user_saved');
      expect(restart.store.userRecipes.single.imageAsset, 'local:kept.jpg');
    },
  );

  test(
    'failed durability rejects edit and leaves previous recipe visible',
    () async {
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final env = h.setup(injizierterCache: LocalCache(faults, 'user-outbox'));
      await h.bootUntilIdle(env.store);
      await env.store.saveUserRecipe(draft('Original'));
      env.server.offline = true;
      faults.beforeWrite = (changes) async {
        if (changes.keys.any((key) => key.contains('outbox'))) {
          throw StateError('Synthetic transaction failure');
        }
      };
      await expectLater(
        env.store.updateUserRecipe(
          env.store.userRecipes.single.copyWith(title: 'Rejected'),
        ),
        throwsStateError,
      );
      expect(env.store.userRecipes.single.title, 'Original');
      expect((await env.cache.readOutbox()) ?? [], isEmpty);
    },
  );

  test('deleted and foreign slugs cannot be edited into the account', () async {
    final env = h.setup();
    await h.bootUntilIdle(env.store);
    await expectLater(
      env.store.updateUserRecipe(draft('Foreign')),
      throwsStateError,
    );
    await env.store.saveUserRecipe(draft('Original'));
    await env.store.deleteUserRecipe('user_saved');
    await expectLater(
      env.store.updateUserRecipe(draft('Resurrected')),
      throwsStateError,
    );
    expect(env.store.userRecipes, isEmpty);
    expect(env.server.recipeRows, isEmpty);
  });

  test(
    'retired store refuses recipe edit before network or cache write',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.saveUserRecipe(draft('Original'));
      await env.store.signOutCleanup();
      final requests = env.server.requests.length;
      await expectLater(
        env.store.updateUserRecipe(draft('Private')),
        throwsStateError,
      );
      expect(env.server.requests.length, requests);
      expect(env.store.userRecipes.single.title, 'Original');
    },
  );

  test('invalid recipe input is rejected before write', () async {
    final env = h.setup();
    await h.bootUntilIdle(env.store);
    await expectLater(
      env.store.saveUserRecipe(draft('', slug: 'user_empty')),
      throwsStateError,
    );
    await expectLater(
      env.store.saveUserRecipe(draft('Injected', slug: 'catalog_slug')),
      throwsStateError,
    );
    expect(env.server.recipeRows, isEmpty);
  });

  test(
    'failed re-add leaves uncommitted delete marker and old revision intact',
    () async {
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final env = h.setup(injizierterCache: LocalCache(faults, 'user-outbox'));
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final original = env.store.userRecipes.single;
      env.store.setRecipeDeletePending('user_saved', pending: true);
      faults.beforeWrite = (changes) async {
        if (changes.keys.any((key) => key.contains('outbox'))) {
          throw StateError('Synthetic transaction failure');
        }
      };
      await expectLater(
        env.store.createUserRecipe(draft('Confirmed again')),
        throwsStateError,
      );
      expect(env.store.pendingRecipeDeletes, contains('user_saved'));
      expect(env.store.userRecipes.single.title, original.title);
      expect(
        env.store.userRecipes.single.serverRevision,
        original.serverRevision,
      );
      expect(env.server.recipeRows.values.single['title'], original.title);
    },
  );

  test(
    'failed newer intent cannot suppress an earlier acknowledged edit',
    () async {
      final server = _HeldRecipeServer();
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final env = h.setup(
        injizierterCache: LocalCache(faults, 'user-outbox'),
        geteilterServer: server,
      );
      await h.bootUntilIdle(env.store);
      await env.store.saveUserRecipe(draft('Original'));
      server.gate = Completer<void>();
      final first = env.store.updateUserRecipe(
        env.store.userRecipes.single.copyWith(title: 'Acknowledged edit'),
      );
      await server.started.future;
      faults.beforeWrite = (changes) async {
        if (changes.values.any(
          (value) => value?.contains('Rejected edit') == true,
        )) {
          throw StateError('Synthetic transaction failure');
        }
      };
      await expectLater(
        env.store.updateUserRecipe(
          env.store.userRecipes.single.copyWith(title: 'Rejected edit'),
        ),
        throwsStateError,
      );
      expect(
        env.store.userRecipes.single.title,
        'Acknowledged edit',
        reason:
            'The first edit was already committed locally before its held request.',
      );
      server.gate!.complete();
      expect(await first, SyncDelivery.delivered);
      expect(env.store.userRecipes.single.title, 'Acknowledged edit');
      expect(server.recipeRows.values.single['title'], 'Acknowledged edit');
    },
  );

  test(
    're-add during undo preserves a concurrent remote edit as a conflict',
    () async {
      final env = h.setup();
      await h.bootUntilIdle(env.store);
      await env.store.createUserRecipe(draft('Original'));
      final observed = env.store.userRecipes.single;
      env.store.setRecipeDeletePending(observed.slug, pending: true);
      env.server.syncOperations.apply({
        'p_operation_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        'p_kind': 'recipeUpsert',
        'p_entity_id': observed.slug,
        'p_payload': {
          'expected_revision': observed.serverRevision,
          'recipe': observed.copyWith(title: 'Other device').toRow(),
        },
      });

      await env.store.createUserRecipe(draft('Confirmed again'));
      expect(env.store.pendingRecipeDeletes, isEmpty);
      expect(env.server.recipeRows[observed.slug]?['title'], 'Other device');
      expect(
        env.store.userRecipes.map((recipe) => recipe.title),
        unorderedEquals(['Other device', 'Confirmed again']),
      );
      expect(
        env.store.userRecipes
            .singleWhere((recipe) => recipe.title == 'Confirmed again')
            .conflictOf,
        observed.slug,
      );
      expect(env.server.operations('recipeDelete'), isEmpty);
    },
  );

  test(
    'newer durable edit wins when older live acknowledgement arrives later',
    () async {
      final server = _HeldRecipeServer();
      final env = h.setup(geteilterServer: server);
      await h.bootUntilIdle(env.store);
      await env.store.saveUserRecipe(draft('Original'));
      server.gate = Completer<void>();
      final first = env.store.updateUserRecipe(
        env.store.userRecipes.single.copyWith(title: 'Older edit'),
      );
      await server.started.future;
      expect(
        await env.store.updateUserRecipe(
          env.store.userRecipes.single.copyWith(title: 'Newer edit'),
        ),
        SyncDelivery.queuedRetry,
      );
      server.gate!.complete();
      await first;
      expect(env.store.userRecipes.single.title, 'Newer edit');
    },
  );
}
