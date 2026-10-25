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
  'reminder_time',
  'reminder_prompt',
  'weekly_result_seen',
  'weigh_in_reminder',
  'ai_consent',
  'coach_quota',
  'plan_status',
  'paywall_prompt',
  'legacy_notice',
  'upsell_shown',
  'health_connect_enabled',
  'health_prompt',
  'health_weight_import',
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

/// A store without the atomic batch, so [LocalCache.clear] takes its
/// per-key path.
class _PlainStore implements KeyValueStore {
  _PlainStore(this._inner);

  final KeyValueStore _inner;

  @override
  Future<String?> getString(String key) => _inner.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _inner.setString(key, value);

  @override
  Future<void> remove(String key) => _inner.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both purge paths: the atomic batch of the production stores and the
  // per-key list of a plain store.
  _purgeTests(atomic: true);
  _purgeTests(atomic: false);
}

void _purgeTests({required bool atomic}) {
  final path = atomic ? 'atomic' : 'per-key';

  test(
    'account deletion clears every A slot and preserves B byte for byte '
    '($path)',
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

      await LocalCache(atomic ? storage : _PlainStore(storage), 'A').clear();

      expect(storage.snapshot, beforeB);
      expect(beforeB, hasLength(30), reason: 'Every B domain has seeded data.');
    },
  );

  test(
    'logout preserves only durable recovery slots for A and all B data '
    '($path)',
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

      await LocalCache(
        atomic ? storage : _PlainStore(storage),
        'A',
      ).clear(preserveOutbox: true);

      expect(storage.snapshot, expected);
      expect(expected, hasLength(33));
    },
  );
}
