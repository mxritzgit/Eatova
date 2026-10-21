import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' show FakeServer;
import '../training_qa/fixtures.dart';

// The fake's training-head rules must match apply_sync_operation, which
// test/migrations/training_incarnations.sql checks against Postgres; the
// store tests that run on this fake rely on them.

Map<String, dynamic> row(int generation, {String title = 'Original'}) => {
  'id': 'coach_message',
  'source_id': 'message',
  'incarnation': generation,
  'plan': {...trainingDraft(), 'title': title},
};

Map<String, dynamic> request(
  int identity,
  String kind,
  Map<String, dynamic> body, {
  int? protocol = 2,
}) => {
  'p_operation_id':
      '${identity.toString().padLeft(8, '0')}-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'p_kind': kind,
  'p_entity_id': 'coach_message',
  'p_payload': body,
  if (protocol != null) 'p_training_protocol': protocol,
};

Map<dynamic, dynamic> mutation(Map<dynamic, dynamic> response) =>
    (response['result'] as Map)['training_mutation'] as Map;
Map<dynamic, dynamic> current(Map<dynamic, dynamic> response) => response['current_state'] as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit re-adoption advances stable source, stale writes cannot touch it',
    () {
      final fake = FakeServer().syncOperations;
      final adopted = request(1, 'trainingPlanUpsert', {
        'row': row(0),
        'adoption': true,
      });
      final initial = fake.apply(adopted);
      fake.apply(request(2, 'trainingPlanDelete', {}));
      final readopted = fake.apply(
        request(3, 'trainingPlanUpsert', {
          'row': row(1, title: 'New adoption'),
          'adoption': true,
        }),
      );
      expect(mutation(readopted)['outcome'], 'applied');
      expect(current(readopted)['entity_deleted'], isFalse);
      expect(fake.readTrainingHead('message')!['incarnation'], 1);
      fake.apply(request(4, 'trainingPlanDelete', {}));
      final stale = fake.apply(
        request(5, 'trainingPlanUpsert', {'row': row(0, title: 'Old edit')}),
      );
      expect(mutation(stale), {'outcome': 'deleted', 'incarnation': 0});
      expect(current(stale)['entity_deleted'], isTrue);
      expect((current(stale)['training_plan'] as Map)['incarnation'], 1);
      expect(
        (fake.trainingPlans['coach_message']!['plan'] as Map)['title'],
        'New adoption',
      );
      final replay = fake.apply(adopted);
      expect(replay['result'], initial['result']);
      expect(current(replay)['entity_deleted'], isTrue);
      expect((current(replay)['training_head'] as Map)['incarnation'], 1);
      expect(
        fake.receipts[adopted['p_operation_id']]!.containsKey('current_state'),
        isFalse,
      );
    },
  );

  test(
    'head conflict preserves server plan and explicit current generation resolves it',
    () {
      final fake = FakeServer().syncOperations;
      fake.apply(
        request(1, 'trainingPlanUpsert', {'row': row(0), 'adoption': true}),
      );
      fake.apply(request(2, 'trainingPlanDelete', {}));
      fake.apply(
        request(3, 'trainingPlanUpsert', {'row': row(1), 'adoption': true}),
      );
      final stale = request(4, 'trainingPlanUpsert', {
        'row': row(0, title: 'Draft'),
        'adoption': true,
      });
      final conflict = fake.apply(stale);
      expect(mutation(conflict)['outcome'], 'headConflict');
      expect(
        (current(conflict)['training_plan'] as Map)['plan']['title'],
        'Original',
      );
      final resolved = fake.apply(
        request(5, 'trainingPlanUpsert', {
          'row': row(1, title: 'Explicitly resolved'),
          'adoption': true,
        }),
      );
      expect(mutation(resolved)['outcome'], 'applied');
      final replay = fake.apply(stale);
      expect(replay['result'], conflict['result']);
      expect(
        (current(replay)['training_plan'] as Map)['plan']['title'],
        'Explicitly resolved',
      );
    },
  );

  test(
    'delete can tombstone a not-yet-delivered next adoption but not skip generations',
    () {
      final fake = FakeServer().syncOperations;
      fake.apply(request(1, 'trainingPlanDelete', {}));
      fake.apply(request(2, 'trainingPlanDelete', {'incarnation': 1}));
      expect(fake.readTrainingHead('message')!['incarnation'], 1);
      expect(fake.readTrainingHead('message')!['deleted'], isTrue);
      final arrival = fake.apply(
        request(3, 'trainingPlanUpsert', {'row': row(1), 'adoption': true}),
      );
      expect(mutation(arrival)['outcome'], 'headConflict');
      expect(fake.trainingPlans, isEmpty);
      expect(
        () => fake.apply(request(4, 'trainingPlanDelete', {'incarnation': 3})),
        throwsA(isA<PostgrestException>()),
      );
      expect(fake.readTrainingHead('message')!['incarnation'], 1);
    },
  );

  test(
    'future adoption without observed deleted predecessor is a conflict',
    () {
      final fake = FakeServer().syncOperations;
      expect(
        mutation(
          fake.apply(
            request(1, 'trainingPlanUpsert', {'row': row(1), 'adoption': true}),
          ),
        )['outcome'],
        'headConflict',
      );
      expect(fake.trainingHeads, isEmpty);
      fake.apply(request(2, 'trainingPlanUpsert', {'row': row(0)}));
      expect(
        mutation(
          fake.apply(
            request(3, 'trainingPlanUpsert', {'row': row(1), 'adoption': true}),
          ),
        )['outcome'],
        'headConflict',
      );
      expect(fake.trainingHeads['message']!['incarnation'], 0);
    },
  );

  test(
    'protocol negotiation permits exact legacy receipt replay but fences modern fields',
    () {
      final fake = FakeServer().syncOperations;
      final legacyRow = row(0)..remove('incarnation');
      final legacy = request(1, 'trainingPlanUpsert', {
        'row': legacyRow,
      }, protocol: null);
      final initial = fake.apply(legacy);
      expect(
        fake.apply({...legacy, 'p_training_protocol': 2})['result'],
        initial['result'],
      );
      final modern = request(2, 'trainingPlanUpsert', {
        'row': row(0),
        'adoption': true,
      });
      fake.apply(modern);
      expect(
        () => fake.apply({...modern, 'p_training_protocol': 1}),
        throwsA(
          isA<PostgrestException>().having(
            (error) => error.message,
            'error',
            'EX_TRAINING_PROTOCOL_REQUIRED',
          ),
        ),
      );
      expect(
        () => fake.apply(request(3, 'profileUpsert', {'row': <dynamic, dynamic>{}})),
        throwsA(isA<PostgrestException>()),
      );
    },
  );

  test(
    'source mismatch and malformed generations fail before accepting a receipt',
    () {
      final fake = FakeServer().syncOperations;
      for (final invalid in [
        {...row(0), 'source_id': 'different'},
        {...row(0), 'incarnation': -1},
        {...row(0), 'incarnation': null},
        {...row(0), 'incarnation': 2147483648},
      ]) {
        expect(
          () => fake.apply(request(1, 'trainingPlanUpsert', {'row': invalid})),
          throwsA(isA<PostgrestException>()),
        );
        expect(fake.receipts, isEmpty);
        expect(fake.trainingPlans, isEmpty);
      }
    },
  );
}
