import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_operation_sync.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const owner = '71000000-0000-4000-8000-000000000001';

TrainingPlan plan(int incarnation) => TrainingPlan(
  id: 'coach_proposal',
  sourceId: 'proposal',
  incarnation: incarnation,
  proposal: CoachTrainingProposal(
    title: 'Draft',
    workouts: [
      TrainingWorkout(
        title: 'Workout',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 2, reps: 8, restSeconds: 30),
        ],
      ),
    ],
  ),
);

Map<String, dynamic> head(int incarnation, {bool deleted = false}) => {
  'source_id': 'proposal',
  'plan_id': 'coach_proposal',
  'incarnation': incarnation,
  'deleted': deleted,
  'plan': deleted ? null : plan(incarnation).toRow(),
};

SyncOperationSync service(
  Future<http.Response> Function(http.Request) handler,
) {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response(
        response.body,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }),
  );
  addTearDown(client.dispose);
  return SyncOperationSync(client, owner);
}

http.Response reply(Object? data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> receipt(
  Map body, {
  int requested = 0,
  int current = 1,
  String outcome = 'deleted',
}) => {
  'operation_id': body['p_operation_id'],
  'entity_id': body['p_entity_id'],
  'kind': body['p_kind'],
  'result': {
    'training_mutation': {'outcome': outcome, 'incarnation': requested},
  },
  'current_state': <String, dynamic>{
    'entity_deleted': current != requested,
    'training_head': head(current),
    'training_plan': plan(current).toRow(),
  },
};

void main() {
  test('source-head capacity is a typed retained storage failure', () async {
    final transport = service(
      (request) async => http.Response(
        jsonEncode({'code': 'PT507', 'message': 'EX_TRAINING_HEAD_CAPACITY'}),
        507,
        headers: {'content-type': 'application/json'},
      ),
    );
    await expectLater(
      transport.apply(SyncOp.trainingPlanUpsert(plan(0), adoption: true)),
      throwsA(
        isA<SyncCapacityException>().having(
          (error) => error.kind,
          'kind',
          SyncCapacityKind.trainingHeads,
        ),
      ),
    );
  });
  test(
    'adoption pins metadata and uses a top-level server feature fence',
    () async {
      final operation = SyncOp.trainingPlanUpsert(plan(1), adoption: true);
      final transport = service((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(request.url.path, '/rest/v1/rpc/apply_sync_operation');
        expect(body['p_training_protocol'], 2);
        expect(body['p_payload'], {'row': plan(1).toRow(), 'adoption': true});
        expect(body['p_payload']['row'], isNot(contains('user_id')));
        return reply(receipt(body, requested: 1, outcome: 'applied'));
      });
      final result = await transport.apply(operation);
      expect(result.trainingHead!.incarnation, 1);
      expect(result.trainingPlan!.id, 'coach_proposal');
      expect(result.trainingMutation!.outcome, TrainingMutationOutcome.applied);
    },
  );

  test(
    'old frozen payload is unchanged while current head remains separate',
    () async {
      final original = SyncOp.trainingPlanUpsert(plan(0));
      final wire = encodeSyncOperationPayload(original);
      final frozen = SyncOp.tryFromJson({
        ...original.toJson(),
        'wire_schema': 1,
        'wire_payload': wire,
        'delivery_started': true,
      })!;
      final transport = service((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['p_payload'], wire);
        expect(body['p_payload']['row'], isNot(contains('incarnation')));
        expect(body['p_training_protocol'], 2);
        return reply(receipt(body));
      });
      final result = await transport.apply(frozen);
      expect(result.entityDeleted, isTrue);
      expect(result.trainingMutation!.incarnation, 0);
      expect(result.trainingHead!.incarnation, 1);
      expect(result.trainingPlan!.incarnation, 1);
    },
  );

  test('delete wire pins the requested incarnation', () async {
    final transport = service((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body['p_payload'], {'incarnation': 1});
      return reply(receipt(body, requested: 1, current: 2));
    });
    expect(
      (await transport.apply(
        SyncOp.trainingPlanDelete('coach_proposal', incarnation: 1),
      )).trainingHead!.incarnation,
      2,
    );
  });

  test('missing new RPC cannot fall back to a legacy write', () async {
    final paths = <String>[];
    final transport = service((request) async {
      paths.add(request.url.path);
      return http.Response(
        jsonEncode({'code': 'PGRST202', 'message': 'Function missing'}),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    await expectLater(
      transport.apply(SyncOp.trainingPlanUpsert(plan(1), adoption: true)),
      throwsA(isA<PostgrestException>()),
    );
    expect(paths, ['/rest/v1/rpc/apply_sync_operation']);
  });

  test(
    'owner-bound head read distinguishes never existed from deleted',
    () async {
      var count = 0;
      final transport = service((request) async {
        expect(request.url.path, '/rest/v1/rpc/load_training_plan_head');
        expect(jsonDecode(request.body), {'p_source_id': 'proposal'});
        return reply(count++ == 0 ? null : head(2, deleted: true));
      });
      expect(await transport.loadTrainingPlanHead('proposal'), isNull);
      final value = await transport.loadTrainingPlanHead('proposal');
      expect(value!.deleted, isTrue);
      expect(value.incarnation, 2);
      expect(value.plan, isNull);
    },
  );

  test(
    'head read rejects wrong source or incomplete active projection',
    () async {
      for (final invalid in [
        {...head(1), 'source_id': 'another'},
        {...head(1), 'plan_id': 'coach_another'},
        {...head(1), 'plan': null},
        {...head(1), 'incarnation': -1},
        {...head(1), 'incarnation': 1.5},
      ]) {
        await expectLater(
          service((_) async => reply(invalid)).loadTrainingPlanHead('proposal'),
          throwsFormatException,
        );
      }
      final local = TrainingPlanHead.fromJson({...head(1), 'plan': null});
      expect(local.toJson()['plan'], isNull);
    },
  );

  test('receipt rejects missing or mismatched training generation', () async {
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (value) => (value['result'] as Map).remove('training_mutation'),
      (value) => value['result']['training_mutation']['incarnation'] = 2,
      (value) => (value['current_state'] as Map).remove('training_head'),
      (value) => value['current_state']['training_plan'] = null,
      (value) => value['current_state']['training_head'] = head(2),
    ]) {
      final transport = service((request) async {
        final value = receipt(
          jsonDecode(request.body) as Map,
          requested: 1,
          outcome: 'applied',
        );
        mutation(value);
        return reply(value);
      });
      await expectLater(
        transport.apply(SyncOp.trainingPlanUpsert(plan(1), adoption: true)),
        throwsFormatException,
      );
    }
  });
}
