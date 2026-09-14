import 'dart:convert';

import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

// Independent inventory, including legacy data and all new planning/training
// domains. It must not be derived from clear() or an omitted slot would pass.
const _personalSlots = [
  'profile',
  'daily',
  'stats',
  'notifications_enabled',
  'health_connect_enabled',
  'logged_meals',
  'favorites',
  'weight_log',
  'outbox',
  'pending_stats',
  'user_recipes',
  'meal_plans',
  'training_history',
  'training_history_deletions',
  'training_plans',
  'training_selection',
  'training_session',
  'daily_activity',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account deletion clears every A slot and preserves B byte for byte',
    () async {
      final storage = InMemoryKeyValueStore();
      for (final user in ['A', 'B']) {
        for (final slot in _personalSlots) {
          await storage.setString(
            'eatova.v1.$slot.$user',
            jsonEncode({'synthetic': '$user:$slot'}),
          );
        }
      }
      final beforeB = Map<String, String>.fromEntries(
        storage.snapshot.entries.where((entry) => entry.key.endsWith('.B')),
      );

      await LocalCache(storage, 'A').clear();

      expect(storage.snapshot, beforeB);
      expect(beforeB, hasLength(18), reason: 'Every B domain has seeded data.');
    },
  );

  test(
    'logout preserves only durable recovery slots for A and all B data',
    () async {
      final storage = InMemoryKeyValueStore();
      for (final user in ['A', 'B']) {
        for (final slot in _personalSlots) {
          await storage.setString(
            'eatova.v1.$slot.$user',
            jsonEncode({'synthetic': '$user:$slot'}),
          );
        }
      }
      final before = storage.snapshot;
      final expected = Map<String, String>.fromEntries(
        before.entries.where(
          (entry) =>
              entry.key.endsWith('.B') ||
              const {
                'eatova.v1.outbox.A',
                'eatova.v1.pending_stats.A',
                'eatova.v1.training_history_deletions.A',
              }.contains(entry.key),
        ),
      );

      await LocalCache(storage, 'A').clear(preserveOutbox: true);

      expect(storage.snapshot, expected);
      expect(expected, hasLength(21));
    },
  );
}
