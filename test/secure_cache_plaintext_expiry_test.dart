import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// SEC/W7a: der Klartext-Migrationspfad ist befristet — aber erst, wenn nichts
// mehr zu erben ist.
//
// `EncryptedKeyValueStore.getString` nimmt einen Slot OHNE EATOVA1-Magic als
// migrierbaren Legacy-Wert an. Unbefristet bliebe dieser Uebergangszustand fuer
// immer offen, obwohl es echten Legacy-Klartext nur aus Installationen von VOR
// der Verschluesselung geben kann. Der Marker
// (`CacheKeyProvider.plaintextMigrationClosedKey`) beendet ihn.
//
// DER FUND, DEN DIESE DATEI ABSICHERT: der Marker ist GLOBAL, die Slots liegen
// PRO UID. Solange er beim DEK-Sentinel mitgesetzt wurde, schloss der erste
// Start nach dem Update den Pfad fuer alle uebrigen Konten mit — die nie
// zugestellten Writes eines zweiten Nutzers fielen beim naechsten Start in
// `ExpiredPlaintextCacheSlot`, ohne je die Chance auf eine Migration gehabt zu
// haben. Deshalb migriert der migrierende Start jetzt AKTIV alle geerbten
// Slots (`EncryptedKeyValueStore.migrateAllLegacySlots`) und setzt den Marker
// erst danach.
//
// Diese Datei treibt beide Zustaende durch `EncryptedKeyValueStore.create`,
// also ueber denselben Weg wie `LocalCache.create` in Production: nur der
// Keystore ist ein Fake, Marker, Sentinel und (im Sweep-Teil) die Slots selbst
// liegen im echten SharedPreferences-Mock.
//
// GRENZE DER ZUSAGE (und deshalb der letzte Test): der Marker liegt in
// derselben Prefs-Datei wie die Klartext-Slots. Wer den einen schreiben kann,
// loescht den anderen — die Befristung haelt keinen Angreifer mit
// Schreibzugriff auf, sie macht den Vorgang nur sichtbar. Also muss die
// Sichtbarkeit auch dann halten, wenn im selben Prozess schon ein kaputter
// Ciphertext gemeldet wurde.

/// Keystore, der den DEK ueber einen simulierten Neustart hinweg behaelt —
/// der Normalfall auf einem gesunden Geraet.
class _MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = <String, String>{};
  int writes = 0;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Probe, deren Blick auf SharedPreferences scheitert (Plugin-Fehler).
class _FailingLegacyProbe implements LegacyPlaintextProbe {
  @override
  Future<List<String>> plaintextCacheKeys() async =>
      throw StateError('prefs kaputt');
}

const String _slot = 'eatova.v1.outbox.user-1';

/// Zwei Konten auf demselben Geraet — der Kern von W7a.
const String _slotA = 'eatova.v1.outbox.user-a';
const String _slotB = 'eatova.v1.outbox.user-b';

const String _plaintextA =
    '{"items":[{"op":"add_meal","kcal":410,"note":"Porridge"}]}';

/// Der Payload, um den es geht: eine Outbox mit unquittierten Schreiboperationen
/// — im Angriffsfall untergeschoben, im Bestandsfall echte Nutzerdaten.
const String _plaintext =
    '{"items":[{"op":"add_meal","kcal":820,"note":"Kebab"}]}';

/// Zwei Slots MIT Magic, deren Tag nicht passt — der Alltagsfall nach einem
/// Keystore-Reset, bei dem reihum jeder Slot scheitert. Lang genug fuer
/// nonce+tag, damit die Pruefung an der GCM-Authentifizierung scheitert und
/// nicht schon am Rahmen.
final String _toterCiphertext =
    '$cacheCipherMagic${base64.encode(List<int>.filled(48, 7))}';

const String _toterSlot = 'eatova.v1.profile.user-1';
const String _zweiterToterSlot = 'eatova.v1.weights.user-1';

/// Ein neuer App-Start: die Memoisierung ist weg, SharedPreferences (Sentinel,
/// Marker) und der OS-Keystore (DEK) ueberleben.
void _restartApp() => CacheKeyProvider.debugReset();

Future<EncryptedKeyValueStore> _boot(
  KeyValueStore inner,
  SecureKeyStore keyStore, {
  LegacyPlaintextProbe? legacyProbe,
}) async {
  final store = await EncryptedKeyValueStore.create(inner,
      keyStore: keyStore, legacyProbe: legacyProbe);
  expect(store, isNotNull,
      reason: 'Der Fake-Keystore liefert immer einen DEK.');
  return store!;
}

/// Der Produktions-Store: SharedPreferences. Der Sweep zaehlt dort auf, also
/// muss der Dekorator im Sweep-Teil auf DEMSELBEN Speicher sitzen — sonst
/// prueft der Test eine Verdrahtung, die es so nicht gibt.
Future<KeyValueStore> _prefsStore() async =>
    SharedPreferencesStore(await SharedPreferences.getInstance());

void main() {
  // Marker und Sentinel liegen in SharedPreferences — Binding und Prefs-Mock
  // sind deshalb Pflicht.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CacheKeyProvider.debugReset();
    // Die Ein-Schuss-Zaehler der Reports sind pro Prozess gedacht; ein
    // Testlauf ist viele simulierte Prozesse in einem.
    EncryptedKeyValueStore.debugResetReportGuards();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() {
    CacheKeyProvider.debugReset();
    EncryptedKeyValueStore.debugResetReportGuards();
    CrashReporter.debugSentrySink = null;
  });

  test(
      'der verworfene Klartext-Slot wird als ExpiredPlaintextCacheSlot '
      'gemeldet — ohne Key und ohne Wert', () async {
    final reported = <Object>[];
    final contexts = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) {
      reported.add(error);
      contexts.add(context);
    };
    final keyStore = _MemoryKeyStore();

    await _boot(InMemoryKeyValueStore(), keyStore);
    _restartApp();
    final raw = InMemoryKeyValueStore({_slot: _plaintext});
    await (await _boot(raw, keyStore)).getString(_slot);
    // capture() laeuft unawaited.
    await Future<void>.delayed(Duration.zero);

    expect(contexts, ['cache_decrypt'],
        reason: 'Kein eigener Pfad — dieselbe Meldung wie fuer jeden anderen '
            'unentschluesselbaren Slot.');
    expect(reported.single.toString(), contains('ExpiredPlaintextCacheSlot'),
        reason: 'Der einzige Fall hier, der auf einen fremden SCHREIBZUGRIFF '
            'hindeuten kann, muss sich in Sentry von einem kaputten '
            'Ciphertext unterscheiden lassen.');
    expect(reported.single.toString(), isNot(contains('Kebab')));
    expect(reported.single.toString(), isNot(contains('user-1')),
        reason: 'Das User-Segment wird redigiert.');
  });

  group('Bestandsschutz: erster Start nach dem Update', () {
    test('uebernimmt den Klartext-Slot und verschluesselt ihn', () async {
      final raw = InMemoryKeyValueStore({_slot: _plaintext});

      final store = await _boot(raw, _MemoryKeyStore());

      expect(await store.getString(_slot), _plaintext,
          reason: 'Der Marker wird in DIESEM Bootstrap gesetzt — massgeblich '
              'ist sein Stand von davor, sonst verlieren Bestandsnutzer beim '
              'Update ihre nicht quittierten Writes.');
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));
      expect(raw.snapshot[_slot], isNot(contains('Kebab')));
    });

    test('setzt dabei den Marker in SharedPreferences', () async {
      await _boot(InMemoryKeyValueStore(), _MemoryKeyStore());

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue,
          reason: 'Der Marker muss neben dem Sentinel liegen: beide gehen nur '
              'gemeinsam mit den Blobs verloren.');
    });
  });

  group('W7a: der migrierende Start zieht ALLE uids ein', () {
    test(
        'Nutzer B behaelt seinen Klartext-Slot, obwohl nur Nutzer A den ersten '
        'Start nach dem Update gemacht hat', () async {
      // Die Platte einer Bestandsinstallation mit zwei Konten: beide tragen
      // nicht quittierte Writes aus der Zeit vor der Verschluesselung.
      SharedPreferences.setMockInitialValues(<String, Object>{
        _slotA: _plaintextA,
        _slotB: _plaintext,
      });
      final keyStore = _MemoryKeyStore();

      // Start 1: angemeldet ist A. Von sich aus liest dieser Start NIE einen
      // Slot von B — genau daran ist der Marker frueher gescheitert.
      final storeA = await _boot(await _prefsStore(), keyStore);
      expect(await storeA.getString(_slotA), _plaintextA);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic),
          reason: 'Der Marker schliesst fuer ALLE uids gleichzeitig — dann '
              'muss dieser Start auch fuer alle uids migriert haben.');
      expect(prefs.getString(_slotB), isNot(contains('Kebab')));
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue);

      // Start 2: jetzt meldet sich B an. Der Marker steht laengst.
      _restartApp();
      final storeB = await _boot(await _prefsStore(), keyStore);

      expect(await storeB.getString(_slotB), _plaintext,
          reason: 'Der eigentliche Beweis: B hatte nie die Gelegenheit zu '
              'einer eigenen Migration. Faellt seine Outbox trotzdem in '
              'ExpiredPlaintextCacheSlot, sind bis zu 500 nicht quittierte '
              'Writes weg — und zwar endgueltig.');
      expect(keyStore.writes, 1, reason: 'Kein zweiter DEK.');
    });

    test('fremde eatova.v1.-Keys fasst der Sweep nicht an', () async {
      // Diese vier liegen im selben Namensraum, werden aber OHNE den Dekorator
      // gelesen. Ein Sweep ueber den ganzen Praefix wuerde sie verschluesseln
      // und damit dauerhaft zerstoeren — der teurere Fehler, weil er JEDE
      // Installation traefe, nicht nur Mehrkonten-Geraete.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'eatova.v1.locale': 'de',
        'eatova.v1.theme_mode': 'dark',
        'eatova.v1.search_credentials': '{"host":"suche.example"}',
        'eatova.v1.otp_guard.mail@example.com': '3',
        'sb-eatova-auth-token': '{"access_token":"xyz"}',
        _slotB: _plaintext,
      });

      await _boot(await _prefsStore(), _MemoryKeyStore());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('eatova.v1.locale'), 'de');
      expect(prefs.getString('eatova.v1.theme_mode'), 'dark');
      expect(prefs.getString('eatova.v1.search_credentials'),
          '{"host":"suche.example"}');
      expect(prefs.getString('eatova.v1.otp_guard.mail@example.com'), '3');
      expect(prefs.getString('sb-eatova-auth-token'),
          '{"access_token":"xyz"}');
      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic),
          reason: 'Und der echte Cache-Slot muss trotzdem migriert werden — '
              'sonst prueft der Test nur einen Sweep, der gar nichts tut.');
    });

    test('nur die Slot-Namen von LocalCache gelten als Cache-Slot', () {
      for (final slot in legacyCacheSlotNames) {
        expect(isLegacyCacheSlotKey('eatova.v1.$slot.user-1'), isTrue,
            reason: '$slot fehlt in der Erlaubnisliste.');
      }
      expect(isLegacyCacheSlotKey('eatova.v1.locale'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.theme_mode'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.search_credentials'), isFalse);
      expect(isLegacyCacheSlotKey('eatova.v1.otp_guard.mail@example.com'),
          isFalse);
      expect(isLegacyCacheSlotKey(CacheKeyProvider.dekProvisionedKey), isFalse);
      expect(isLegacyCacheSlotKey(CacheKeyProvider.plaintextMigrationClosedKey),
          isFalse);
      expect(isLegacyCacheSlotKey('sb-eatova-auth-token'), isFalse);
    });

    test('scheitert der Sweep, bleibt der Marker OFFEN', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _slotB: _plaintext,
      });
      final keyStore = _MemoryKeyStore();

      // Start 1: die Aufzaehlung wirft. Wer nicht weiss, ob noch etwas zu
      // erben war, darf den Pfad nicht zumachen.
      await _boot(await _prefsStore(), keyStore,
          legacyProbe: _FailingLegacyProbe());

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isNot(isTrue),
          reason: 'Der Marker ist einweg — ein Prefs-Aussetzer darf ihn nicht '
              'setzen, sonst kostet ein einzelner Fehlstart die Outbox.');

      // Start 2: mit funktionierender Probe holt der Sweep alles nach.
      _restartApp();
      await _boot(await _prefsStore(), keyStore);

      expect(prefs.getString(_slotB), startsWith(cacheCipherMagic));
      await prefs.reload();
      expect(prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey),
          isTrue);
    });
  });

  group('nach gesetztem Marker', () {
    test('wird DERSELBE Klartext-Slot verworfen statt uebernommen', () async {
      final keyStore = _MemoryKeyStore();
      // Start 1: leerer Cache, der Bootstrap setzt den Marker.
      await _boot(InMemoryKeyValueStore(), keyStore);

      // Start 2: derselbe DEK, derselbe Slot, derselbe Klartext — jetzt aber
      // untergeschoben statt geerbt.
      _restartApp();
      final raw = InMemoryKeyValueStore({_slot: _plaintext});
      final store = await _boot(raw, keyStore);

      expect(await store.getString(_slot), isNull,
          reason: 'Ohne Magic gibt es weder GCM-Tag noch AAD — der Wert darf '
              'nicht als Outbox in die Sync-Schleife gelangen.');
      expect(raw.snapshot.containsKey(_slot), isFalse,
          reason: 'Behandlung wie ein unentschluesselbarer Slot: raeumen.');
      expect(keyStore.writes, 1, reason: 'Kein zweiter DEK.');
    });

    test('ein Klartext-Slot wird nicht mehr verschluesselt nachgezogen',
        () async {
      final keyStore = _MemoryKeyStore();
      await _boot(InMemoryKeyValueStore(), keyStore);

      _restartApp();
      final raw = InMemoryKeyValueStore({_slot: _plaintext});
      final store = await _boot(raw, keyStore);
      await store.getString(_slot);
      // Eine Migration liefe ueber die Write-Kette: erst deren Ende abwarten,
      // sonst behauptet der Snapshot nur, dass sie noch nicht fertig ist.
      await Future<void>.delayed(Duration.zero);

      expect(raw.snapshot, isEmpty,
          reason: 'Ein untergeschobener Wert darf nicht durch die Migration '
              'zu einem gueltig signierten Ciphertext aufgewertet werden.');
    });
  });

  group('regulaerer Ciphertext', () {
    test('funktioniert vor und nach dem Marker', () async {
      final keyStore = _MemoryKeyStore();
      final raw = InMemoryKeyValueStore();

      // Start 1 (Marker noch offen): schreiben und lesen.
      final first = await _boot(raw, keyStore);
      await first.setString(_slot, _plaintext);
      expect(await first.getString(_slot), _plaintext);
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));

      // Start 2 (Marker steht): derselbe DEK, derselbe Blob.
      _restartApp();
      final second = await _boot(raw, keyStore);

      expect(await second.getString(_slot), _plaintext,
          reason: 'Die Befristung betrifft ausschliesslich den magic-losen '
              'Zweig — verschluesselte Slots bleiben unberuehrt.');
      await second.setString(_slot, '{"items":[]}');
      expect(await second.getString(_slot), '{"items":[]}');
      expect(raw.snapshot[_slot], startsWith(cacheCipherMagic));
    });
  });

  group('Sichtbarkeit statt Garantie', () {
    test(
        'der verworfene Klartext-Slot wird auch gemeldet, wenn vorher schon '
        'ein toter Ciphertext gemeldet wurde', () async {
      final reported = <String>[];
      CrashReporter.debugSentrySink = (error, stack, context) {
        reported.add(error.toString());
      };
      final keyStore = _MemoryKeyStore();
      await _boot(InMemoryKeyValueStore(), keyStore);

      // Start 2: der Marker steht. Im Cache liegen zwei tote Ciphertexte (der
      // Keystore-Reset-Fall) UND der untergeschobene Klartext.
      _restartApp();
      final raw = InMemoryKeyValueStore({
        _toterSlot: _toterCiphertext,
        _zweiterToterSlot: _toterCiphertext,
        _slot: _plaintext,
      });
      final store = await _boot(raw, keyStore);

      expect(await store.getString(_toterSlot), isNull);
      expect(await store.getString(_zweiterToterSlot), isNull);
      expect(await store.getString(_slot), isNull);
      // capture() laeuft unawaited.
      await Future<void>.delayed(Duration.zero);

      expect(reported.where((e) => e.contains('ExpiredPlaintextCacheSlot')),
          hasLength(1),
          reason: 'Die Befristung haelt einen Angreifer mit Schreibzugriff '
              'nicht auf — sie macht ihn sichtbar. Ein gemeinsamer '
              'Ein-Schuss-Zaehler wuerde genau dieses Signal verschlucken, '
              'sobald irgendein Slot vorher am Tag gescheitert ist.');
      expect(reported, hasLength(2),
          reason: 'Ein Schuss je ART, nicht je Slot: der zweite tote '
              'Ciphertext bleibt still, sonst waeren es nach einem '
              'Keystore-Reset neun identische Reports pro Kaltstart.');
    });
  });
}
