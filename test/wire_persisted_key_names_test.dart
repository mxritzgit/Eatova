import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

/// Persisted key names are a WIRE FORMAT: they exist on every installed
/// device, and renaming one loses the old data for good.
///
/// A one-token rename of `CacheKeyProvider.dekStorageKey` once left 74 tests
/// green, because every test compared the constant against itself. The result
/// of such a silent rename: `keyStore.read` finds nothing while the sentinel
/// still says "provisioned", so the app runs permanently without a cache — no
/// data loss, but every existing install is degraded unnoticed.
///
/// Hence every literal is spelled out here. `expect(X.key, X.key)` is
/// worthless; the string itself is the point.
void main() {
  group('persistierte Schluesselnamen sind festgenagelt', () {
    test('Secure Storage: DEK und Sentinel', () {
      expect(CacheKeyProvider.dekStorageKey, 'eatova.v1.cache_dek',
          reason: 'umbenannt = jede bestehende Installation laeuft dauerhaft '
              'ohne Cache, weil das Sentinel weiter "provisioned" sagt');
      expect(CacheKeyProvider.dekProvisionedKey, 'eatova.v1.dek_provisioned',
          reason: 'umbenannt = der A1-Schutz greift nie, ein geloeschter '
              'Keystore-Eintrag praegt wieder still einen frischen DEK');
    });

    test('Strike-Zaehler und Reset-Hinweis (Welle 6)', () {
      expect(
          CacheKeyProvider.dekVanishStrikesKey, 'eatova.v1.dek_vanish_strikes',
          reason: 'umbenannt = ein laufender Strike-Zyklus beginnt still von '
              'vorn, die Cache-Erholung verschiebt sich um bis zu '
              '${CacheKeyProvider.vanishStrikeBudget} weitere Kaltstarts');
      expect(
          CacheKeyProvider.cacheResetNoticeKey, 'eatova.v1.cache_reset_notice',
          reason: 'umbenannt = ein bereits anstehender Nutzerhinweis zum '
              'Cache-Verlust wird nie angezeigt');
    });

    test('Suchzugangsdaten', () {
      expect(SearchCredentialsStore.cacheKey, 'eatova.v1.search_credentials');
    });

    group('Cache-Slots pro Nutzer', () {
      // The slot getters are private, so the assertions look at what actually
      // lands in storage — the stronger level anyway, since it also catches a
      // changed composition of prefix and user id.
      late InMemoryKeyValueStore store;
      late LocalCache cache;

      setUp(() {
        store = InMemoryKeyValueStore();
        cache = LocalCache(store, 'user-42');
      });

      /// Writes to EVERY slot `LocalCache` knows. Adding a slot here means
      /// adding it to the expected list below, or the completeness test fails.
      Future<void> alleSlotsFuellen(LocalCache c) async {
        await c.writeNotificationsEnabled(true);
        await c.writeProfile(const UserProfile());
        await c.writeLifetimeStats(LifetimeStats());
        await c.writeLoggedMeals(const <LoggedMeal>[]);
        await c.writeFavorites(const <FavoriteMeal>[]);
        await c.writeWeightLog(const WeightLog());
        await c.writeOutbox(const <SyncOp>[]);
        await c.writePendingStatsDeltas(meals: 1, weightLogs: 1);
        await c.writeUserRecipes(const <FitnessRecipe>[]);
      }

      test('jeder Slot traegt exakt seinen erwarteten Namen', () async {
        await alleSlotsFuellen(cache);

        // Spelled out, not derived from the getters: the string IS the
        // contract with every existing install.
        const erwartet = <String>{
          'eatova.v1.notifications_enabled.user-42',
          'eatova.v1.profile.user-42',
          'eatova.v1.stats.user-42',
          'eatova.v1.logged_meals.user-42',
          'eatova.v1.favorites.user-42',
          'eatova.v1.weight_log.user-42',
          'eatova.v1.outbox.user-42',
          'eatova.v1.pending_stats.user-42',
          // This list once pinned a gap as the target: user recipes had no
          // slot and hung on the outbox alone, vanishing once it drained.
          // Renaming this key makes every install's recipes disappear on the
          // next offline start.
          'eatova.v1.user_recipes.user-42',
        };

        expect(store.snapshot.keys.toSet(), erwartet,
            reason: 'ein zusaetzlicher Slot gehoert in diese Liste, ein '
                'fehlender bedeutet eine unbeabsichtigte Umbenennung');
      });

      test('die User-ID ist Teil des Namens — sonst teilen sich zwei Konten '
          'auf einem Geraet denselben Slot', () async {
        await cache.writeNotificationsEnabled(true);
        final andere = LocalCache(store, 'user-99');
        await andere.writeNotificationsEnabled(false);

        expect(store.snapshot.keys, contains('eatova.v1.notifications_enabled.user-42'));
        expect(store.snapshot.keys, contains('eatova.v1.notifications_enabled.user-99'));
        expect(await cache.readNotificationsEnabled(), isTrue);
        expect(await andere.readNotificationsEnabled(), isFalse);
      });

      test('das Versions-Praefix ist v1 — eine Erhoehung verwaist alle Slots '
          'und muss eine bewusste Migration sein', () async {
        await cache.writeNotificationsEnabled(true);

        for (final key in store.snapshot.keys) {
          expect(key, startsWith('eatova.v1.'),
              reason: '$key faellt aus dem Namensraum');
        }
      });
    });
  });
}
