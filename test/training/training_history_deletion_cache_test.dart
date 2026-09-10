import 'dart:convert';

import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = '11111111-1111-4111-8111-111111111111';
const _second = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deletion receipts merge concurrent writes and survive logout with retained outbox',
    () async {
      final storage = InMemoryKeyValueStore();
      final cache = LocalCache(storage, 'A');
      final other = LocalCache(storage, 'B');
      expect(
        await Future.wait([
          cache.rememberTrainingHistoryDeletion(_first),
          cache.rememberTrainingHistoryDeletion(_second),
          cache.rememberTrainingHistoryDeletion(_first),
        ]),
        everyElement(isTrue),
      );
      expect(await cache.readTrainingHistoryDeletions(), {_first, _second});
      expect(await other.readTrainingHistoryDeletions(), isEmpty);
      expect(await other.rememberTrainingHistoryDeletion(_first), isTrue);
      expect(
        jsonDecode(
              (await storage.getString(
                'eatova.v1.training_history_deletions.A',
              ))!,
            )
            as Map,
        {
          'ids': [_first, _second],
        },
      );
      await cache.clear(preserveOutbox: true);
      expect(await cache.rememberTrainingHistoryDeletion(_first), isFalse);
      final relogin = LocalCache(storage, 'A');
      expect(await relogin.readTrainingHistoryDeletions(), {_first, _second});
      await relogin.clear();
      expect(
        await storage.getString('eatova.v1.training_history_deletions.A'),
        isNull,
      );
      expect(await other.readTrainingHistoryDeletions(), {_first});
      other.close();
    },
  );

  test('invalid deletion receipt blobs cannot be overwritten', () async {
    final storage = InMemoryKeyValueStore();
    final cache = LocalCache(storage, 'A');
    addTearDown(cache.close);
    for (final value in [
      {
        'ids': ['not-an-id'],
      },
      {
        'ids': [_first, _first],
      },
      {
        'ids': [_first],
        'note': 'unexpected',
      },
    ]) {
      final blob = jsonEncode(value);
      await storage.setString('eatova.v1.training_history_deletions.A', blob);
      await expectLater(
        cache.rememberTrainingHistoryDeletion(_second),
        throwsFormatException,
      );
      expect(
        await storage.getString('eatova.v1.training_history_deletions.A'),
        blob,
      );
    }
  });

  test(
    'receipt budget refuses new identifiers while accepting existing ones',
    () async {
      final storage = InMemoryKeyValueStore();
      final cache = LocalCache(storage, 'A');
      addTearDown(cache.close);
      final ids = List.generate(
        100000,
        (index) =>
            '11111111-1111-4111-8111-${index.toString().padLeft(12, '0')}',
      );
      await storage.setString(
        'eatova.v1.training_history_deletions.A',
        jsonEncode({'ids': ids}),
      );
      expect(await cache.rememberTrainingHistoryDeletion(ids.first), isTrue);
      await expectLater(
        cache.rememberTrainingHistoryDeletion(_second),
        throwsStateError,
      );
      expect((await cache.readTrainingHistoryDeletions()).length, 100000);
    },
  );
}
