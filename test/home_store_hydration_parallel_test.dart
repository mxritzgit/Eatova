import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox/outbox_test_helpers.dart';

// Perf round 2026-08-31, finding 4: `_hydrateFromCache` read its nine slots
// strictly sequentially, so the boot gate waited for the SUM of nine decrypt
// latencies instead of the maximum (measured ~91.5 ms per big slot on desktop
// JIT, 2-4x on mobile AOT). The reads have no ordering dependency; they now
// run concurrently — capped, because every read hops through its own
// `compute()` isolate and an unbounded spawn burst is exactly the memory
// pressure the slot-repair paths anticipate failing under.

/// Cache whose slot reads take real time and record how many run at once.
class _LangsameLeseCache extends LocalCache {
  _LangsameLeseCache(super.store, super.userId);

  int _aktiv = 0;
  int maxAktiv = 0;

  Future<T> _mitProbe<T>(Future<T> Function() inner) async {
    _aktiv++;
    if (_aktiv > maxAktiv) maxAktiv = _aktiv;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return await inner();
    } finally {
      _aktiv--;
    }
  }

  @override
  Future<UserProfile?> readProfile() => _mitProbe(super.readProfile);
  @override
  Future<LifetimeStats?> readLifetimeStats() =>
      _mitProbe(super.readLifetimeStats);
  @override
  Future<List<LoggedMeal>?> readLoggedMeals() =>
      _mitProbe(super.readLoggedMeals);
  @override
  Future<List<FavoriteMeal>?> readFavorites() => _mitProbe(super.readFavorites);
  @override
  Future<WeightLog?> readWeightLog() => _mitProbe(super.readWeightLog);
  @override
  Future<List<SyncOp>?> readOutbox() => _mitProbe(super.readOutbox);
  @override
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltas() => _mitProbe(super.readPendingStatsDeltas);
  @override
  Future<List<FitnessRecipe>?> readUserRecipes() =>
      _mitProbe(super.readUserRecipes);
  @override
  Future<Map<String, ({int steps, int kcal})>?> readDailyActivity() =>
      _mitProbe(super.readDailyActivity);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Boot-Hydration liest die Slots nebenlaeufig, aber gedeckelt', () async {
    final cache =
        _LangsameLeseCache(InMemoryKeyValueStore(), 'user-outbox');
    final env = setup(injizierterCache: cache);

    env.store.start();
    await env.store.profileReady;
    await pumpEventQueue(times: 60);

    expect(cache.maxAktiv, greaterThanOrEqualTo(2),
        reason: 'Neun sequenzielle Slot-Reads summieren ihre Latenzen — der '
            'Kaltstart wartet dann auf die Summe statt auf das Maximum.');
    expect(cache.maxAktiv, lessThanOrEqualTo(3),
        reason: 'Jeder Read entschluesselt in einem eigenen compute()-Isolate;'
            ' mehr als 3 gleichzeitig ist der Spawn-Burst, den die '
            'Slot-Reparaturpfade als OOM-Risiko behandeln.');
  });
}
