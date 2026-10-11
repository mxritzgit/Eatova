import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';

import 'outbox_test_helpers.dart';

// REC-3 (2026-10-11): recipe import (user_import_<sha>) and Coach adoption
// (user_coach_<msgId>) reuse a fixed slug. Re-saving it after a delete sends
// expected_revision 0 against the server tombstone; since migration
// 20261011100000 that is `applied` under the same slug instead of a
// user_conflict_ copy. These tests pin the client side of that contract: the
// store, cache and outbox take the recreated identity without a stale copy.

Map<String, dynamic> _payload(dynamic request) =>
    ((jsonDecode(request.body as String) as Map)['p_payload'] as Map)
        .cast<String, dynamic>();

Iterable<String> _outcomes(FakeServer server) => server
    .syncOperations
    .receipts
    .values
    .map((r) => (r['result'] as Map)['recipe_mutation'])
    .whereType<Map<dynamic, dynamic>>()
    .map((m) => m['outcome'] as String);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Re-Import nach Loeschung: gleicher Slug, keine Konfliktkopie, auch '
      'nach dem Kaltstart', () async {
    const slug = 'user_import_0123abcd';
    final kv = InMemoryKeyValueStore();
    final a = setup(kv: kv);
    await boot(a.store);

    await a.store.createUserRecipe(userRecipe(slug, title: 'TikTok-Bowl'));
    await settle();
    await a.store.deleteUserRecipe(slug);
    await settle();
    expect(a.server.recipeRows.keys, isNot(contains(slug)));
    expect(a.store.pendingOutbox, isEmpty);

    for (final title in ['TikTok-Bowl erneut', 'TikTok-Bowl dritter Import']) {
      await a.store.createUserRecipe(userRecipe(slug, title: title));
      await settle();
      expect(
        _payload(a.server.operations('recipeUpsert').last)['expected_revision'],
        0,
        reason: 'Vorbedingung: der Client kennt den Slug nicht mehr',
      );
      expect(a.store.pendingOutbox, isEmpty);
      expect(a.server.recipeRows.keys, [
        slug,
      ], reason: 'jeder Re-Import legte eine weitere user_conflict_-Kopie an');
      expect(a.store.visibleUserRecipes.map((r) => (r.slug, r.title)), [
        (slug, title),
      ]);
      await a.store.deleteUserRecipe(slug);
      await settle();
    }
    expect(_outcomes(a.server), isNot(contains('conflictSaved')));

    await a.store.createUserRecipe(userRecipe(slug, title: 'Bleibt'));
    await settle();
    a.store.flushPendingWrites();
    await settle();

    final b = setup(kv: kv);
    b.server.offline = true;
    await boot(b.store);
    expect(b.store.userRecipes.map((r) => (r.slug, r.title)), [
      (slug, 'Bleibt'),
    ]);
    final cached = (await b.cache.readUserRecipes())!;
    expect(cached.map((r) => r.slug), [slug]);
    expect(
      cached.single.serverRevision,
      a.server.syncOperations.recipeHeads[slug],
      reason: 'der Cache traegt die neue Server-Revision, nicht den Grabstein',
    );
  });

  test('Re-Import, waehrend die Loeschung noch in der Outbox liegt: die '
      'Kette stellt beides zu, ohne Kopie', () async {
    const slug = 'user_coach_msg-42';
    final a = setup(kv: InMemoryKeyValueStore());
    await boot(a.store);
    await a.store.createUserRecipe(userRecipe(slug, title: 'Coach-Rezept'));
    await settle();

    a.server.offline = true;
    await a.store.deleteUserRecipe(slug);
    await a.store.createUserRecipe(
      userRecipe(slug, title: 'Wieder uebernommen'),
    );
    await settle();
    expect(a.store.pendingOutbox.map((o) => o.kind.name), [
      'recipeDelete',
      'recipeUpsert',
    ]);

    a.server.offline = false;
    a.store.flushPendingWrites();
    await settle();

    expect(a.store.pendingOutbox, isEmpty);
    expect(a.server.recipeRows.keys, [slug]);
    expect(a.server.recipeRows[slug]!['title'], 'Wieder uebernommen');
    expect(_outcomes(a.server), isNot(contains('conflictSaved')));
    expect(a.store.visibleUserRecipes.map((r) => r.slug), [slug]);
  });
}
