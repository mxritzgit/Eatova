import 'dart:convert';

import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/sync_session_fixture.dart';
import 'sync_operation_sync_test.dart' show client, mutation, owner, recipe;

const operationId = '76000000-0000-4000-8000-000000000001';

Map<String, dynamic> receipt({bool deleted = false}) => {
  'operation_id': operationId,
  'kind': 'recipeUpsert',
  'entity_id': recipe.slug,
  'result': {'recipe_mutation': mutation()},
  'current_state': {
    for (final name in ['recipe', 'saved_recipe'])
      name: {
        'slug': recipe.slug,
        'revision': deleted ? 10 : 9,
        'deleted': deleted,
        'recipe': deleted ? null : recipe.copyWith(serverRevision: 9).toRow(),
      },
  },
};

http.Response respond(http.Request request, Object? data) => http.Response(
  jsonEncode(data),
  200,
  request: request,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'receipt lookup pins owner and reads current tombstone without replay',
    () async {
      var calls = 0;
      final connection = client((request) async {
        calls++;
        expect(request.url.path, endsWith('/rpc/load_sync_operation_receipt'));
        expect(jsonDecode(request.body), {'p_operation_id': operationId});
        expect(
          request.headers['Authorization'],
          'Bearer ${syncFixtureToken(owner)}',
        );
        return respond(request, receipt(deleted: true));
      });
      await signInSyncFixture(connection, owner);
      final result = await SyncOperationSync(
        connection,
        owner,
      ).loadReceipt(operationId);
      expect(result!.recipeMutation!.savedRecipe, isNotNull);
      expect(result.currentSavedRecipeState!.deleted, isTrue);
      expect(calls, 1);
    },
  );

  test('missing receipt is unresolved', () async {
    final service = SyncOperationSync(
      client((request) async => respond(request, null)),
      owner,
    );
    expect(await service.loadReceipt(operationId), isNull);
  });

  test('mismatched operation or canonical recipe fails closed', () async {
    for (final malformed in [
      {...receipt(), 'operation_id': '76000000-0000-4000-8000-000000000099'},
      {...receipt(), 'entity_id': 'user_different'},
    ]) {
      final service = SyncOperationSync(
        client((request) async => respond(request, malformed)),
        owner,
      );
      await expectLater(
        service.loadReceipt(operationId),
        throwsFormatException,
      );
    }
  });

  test('invalid operation and changed account issue no HTTP request', () async {
    var calls = 0;
    final connection = client((request) async {
      calls++;
      return respond(request, receipt());
    });
    final service = SyncOperationSync(connection, owner);
    await expectLater(service.loadReceipt('invalid'), throwsFormatException);
    await signInSyncFixture(connection, 'other-owner');
    await expectLater(
      service.loadReceipt(operationId),
      throwsA(isA<Exception>()),
    );
    expect(calls, 0);
  });
}
