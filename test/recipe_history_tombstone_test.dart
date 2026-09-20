import 'dart:convert';

import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'support/harness.dart';

// Exact journal shape from delete-before-first-create in apply_recipe_mutation.
const deletion = {
  'revision': 1,
  'deleted': true,
  'recorded_at': '2026-09-20T10:00:00Z',
  'source': 'cas',
  'recipe': {'slug': 'user_deleted_before_create', 'server_revision': 1},
};

({UserRecipeReads reads, SupabaseClient client}) fixture({
  bool disposeClient = true,
}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final Object body;
      if (request.url.path.endsWith('/rpc/load_recipe_history')) {
        final slug = (jsonDecode(request.body) as Map)['p_slug'];
        body = {
          'current_revision': slug == null ? null : 1,
          'current_deleted': slug == null ? null : true,
          'versions': [deletion],
          'next_before': null,
        };
      } else if (request.url.path.endsWith('/rpc/load_recipe_page')) {
        body = {
          'watermark': 1,
          'rows': [],
          'next_after': null,
          'complete': true,
        };
      } else {
        body = [];
      }
      return http.Response(
        jsonEncode(body),
        200,
        request: request,
        headers: {'content-type': 'application/json', 'content-range': '*/0'},
      );
    }),
  );
  if (disposeClient) addTearDown(client.dispose);
  return (reads: UserRecipeReads(client, 'user-a'), client: client);
}

void main() {
  test('structural deletion preserves its exact exported event', () async {
    final env = fixture();
    final page = await env.reads.loadHistory();
    expect(page.versions.single.hasRecipeContent, isFalse);
    expect(page.versions.single.toJson(), deletion);
    final exported =
        jsonDecode(
              await DataExportService(env.client, 'user-a').buildExportJson(),
            )
            as Map;
    expect(exported['user_recipe_history'], [deletion]);
    expect(exported.containsKey('unvollstaendig'), isFalse);
  });

  for (final language in ['de', 'en']) {
    testWidgets(
      'deletion without prior content has no invented restore ($language)',
      (tester) async {
        final page = RecipeHistoryPage(
          versions: [
            RecipeVersion(
              recipe: FitnessRecipe.fromRow(
                (deletion['recipe'] as Map).cast<String, dynamic>(),
              ),
              revision: 1,
              deleted: true,
              recordedAt: DateTime.utc(2026, 9, 20, 10),
              record: deletion,
              hasRecipeContent: false,
            ),
          ],
          currentRevision: null,
          currentDeleted: null,
          nextBefore: null,
        );
        var restores = 0;
        await pumpLocalized(
          tester,
          RecipeHistoryScreen(
            loadHistory: ({slug, beforeRevision}) async => page,
            restoreVersion: (recipe, {required expectedRevision}) async {
              restores++;
              return SyncDelivery.delivered;
            },
            isSessionCurrent: () => true,
          ),
          locale: Locale(language),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recipe-history-version-1')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('recipe-history-restore-1')),
          findsNothing,
        );
        expect(find.text('Eigenes Rezept'), findsNothing);
        expect(
          find.text(
            language == 'de'
                ? 'Löschung ohne frühere Version'
                : 'Deletion without an earlier version',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            language == 'de'
                ? 'keine Version zum Wiederherstellen'
                : 'no version to restore',
          ),
          findsOneWidget,
        );
        expect(restores, 0);
      },
    );
  }
}
