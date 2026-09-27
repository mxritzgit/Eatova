import 'dart:convert';

import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _owner = '71000000-0000-4000-8000-000000000001';

void main() {
  test('non-capacity failures keep the original stack trace', () {
    final original = StackTrace.fromString('#0 postgrest origin frame');
    const error = PostgrestException(message: 'denied', code: '42501');
    Object? caught;
    StackTrace? caughtStack;
    try {
      rethrowSyncFailure(error, original);
    } catch (e, stack) {
      caught = e;
      caughtStack = stack;
    }
    expect(caught, same(error));
    expect(caughtStack.toString(), original.toString());
  });

  test('capacity failures stay typed and sanitized', () {
    expect(
      () => rethrowSyncFailure(
        const PostgrestException(
          message: 'EX_TRAINING_HEAD_CAPACITY',
          code: 'PT507',
        ),
        StackTrace.empty,
      ),
      throwsA(
        isA<SyncCapacityException>().having(
          (error) => error.kind,
          'kind',
          SyncCapacityKind.trainingHeads,
        ),
      ),
    );
  });

  test('a rejected operation surfaces the stack of the PostgREST client', () async {
    final client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({'code': '42501', 'message': 'denied'}),
          403,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
    addTearDown(client.dispose);
    StackTrace? caughtStack;
    try {
      await SyncOperationSync(
        client,
        _owner,
      ).apply(SyncOp.trackingDay('2026-09-20'));
    } on PostgrestException catch (_, stack) {
      caughtStack = stack;
    }
    expect(caughtStack, isNotNull);
    expect(caughtStack.toString(), contains('package:postgrest/'));
  });
}
