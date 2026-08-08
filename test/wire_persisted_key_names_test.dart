import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

/// G2, sechster Schalter — von Agent W5-02 gefunden.
///
/// Persistierte Schluesselnamen sind ein **Wire-Format**: sie stehen auf dem
/// Geraet jeder bestehenden Installation. Wer einen umbenennt, findet die
/// alten Daten nie wieder.
///
/// `CacheKeyProvider.dekStorageKey` war der Beleg dafuer, dass genau diese
/// Klasse ungeprueft war: eine Ein-Token-Umbenennung liess **74 Tests gruen**,
/// weil jeder Test die Konstante gegen sich selbst prueft. Der Schwester-
/// Schluessel `dekProvisionedKey` war zufaellig als Literal gepinnt, dieser
/// nicht.
///
/// Folge einer stillen Umbenennung des DEK-Schluessels: `keyStore.read` findet
/// nichts, das Sentinel sagt aber weiter „provisioned" — der A1-Abbruchzweig
/// greift korrekt und die App laeuft **dauerhaft ohne Cache**. Kein
/// Datenverlust (der Ciphertext bleibt liegen), aber jede bestehende
/// Installation waere permanent verschlechtert, ohne dass ein Test es meldet.
///
/// Deshalb steht hier jedes Literal ausgeschrieben. Ein Test, der
/// `expect(X.key, X.key)` prueft, ist wertlos — die Zeichenkette ist der Punkt.
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
      // Die Slot-Getter sind privat; geprueft wird deshalb, was tatsaechlich
      // im Speicher landet. Das ist ohnehin die belastbarere Ebene — sie
      // faengt auch eine geaenderte Zusammensetzung aus Praefix und User-ID.
      late InMemoryKeyValueStore store;
      late LocalCache cache;

      setUp(() {
        store = InMemoryKeyValueStore();
        cache = LocalCache(store, 'user-42');
      });

      /// Schreibt in JEDEN Slot, den `LocalCache` kennt.
      ///
      /// Die erste Fassung dieses Tests hiess „jeder geschriebene Slot traegt
      /// seinen erwarteten Namen" und schrieb genau EINEN — der Doc-Kommentar
      /// oben geisselt Tests, die eine Konstante gegen sich selbst pruefen,
      /// und der Test machte dann die abgeschwaechte Variante desselben
      /// Fehlers (Verifizierer V4). Wer hier einen Slot ergaenzt, muss ihn
      /// unten mitnehmen — sonst faellt der Vollstaendigkeits-Test.
      Future<void> alleSlotsFuellen(LocalCache c) async {
        await c.writeNotificationsEnabled(true);
        await c.writeProfile(const UserProfile());
        await c.writeLifetimeStats(LifetimeStats());
        await c.writeLoggedMeals(const <LoggedMeal>[]);
        await c.writeFavorites(const <FavoriteMeal>[]);
        await c.writeWeightLog(const WeightLog());
        await c.writeOutbox(const <SyncOp>[]);
        await c.writePendingStatsDeltas(meals: 1, weightLogs: 1);
      }

      test('jeder Slot traegt exakt seinen erwarteten Namen', () async {
        await alleSlotsFuellen(cache);

        // Ausgeschrieben, nicht aus den Gettern abgeleitet — die Zeichenkette
        // IST der Vertrag mit jeder bestehenden Installation.
        const erwartet = <String>{
          'eatova.v1.notifications_enabled.user-42',
          'eatova.v1.profile.user-42',
          'eatova.v1.stats.user-42',
          'eatova.v1.logged_meals.user-42',
          'eatova.v1.favorites.user-42',
          'eatova.v1.weight_log.user-42',
          'eatova.v1.outbox.user-42',
          'eatova.v1.pending_stats.user-42',
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
