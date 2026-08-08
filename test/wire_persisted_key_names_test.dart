import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
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

      test('jeder geschriebene Slot traegt seinen erwarteten Namen', () async {
        await cache.writeNotificationsEnabled(true);

        expect(store.snapshot.keys,
            contains('eatova.v1.notifications_enabled.user-42'));
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
