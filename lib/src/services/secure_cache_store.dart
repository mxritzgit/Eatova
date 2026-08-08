import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart'
    show AEADParameters, InvalidCipherTextException, KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_reporter.dart';
import 'local_cache.dart';

// SEC-1: Verschluesselung des LocalCache (DSGVO Art. 9).
//
// Der LocalCache haelt Gesundheitsdaten im Klartext in SharedPreferences:
// 35 Tage Tagebuch inkl. Freitext-Notizen, die Gewichtsreihe, die
// Koerpermasse des Profils und die Lifetime-Stats. Auf einem gerooteten oder
// per Backup/ADB ausgelesenen Geraet liegt das als lesbares JSON in
// `shared_prefs/FlutterSharedPreferences.xml`. Diese Datei legt eine
// Verschluesselungsschicht darunter, ohne den LocalCache selbst umzubauen.
//
// --- Warum ENVELOPE-Verschluesselung und nicht flutter_secure_storage fuer
//     die Blobs selbst? -----------------------------------------------------
// Im OS-Keystore (Android Keystore / iOS Keychain) liegt NUR ein 32-Byte-DEK.
// Die JSON-Blobs bleiben in SharedPreferences und werden mit diesem DEK
// AES-256-GCM-verschluesselt.
//
// Grund: `_cacheLoggedMeals()` schreibt bei JEDEM Hinzufuegen/Bearbeiten/
// Loeschen einer Mahlzeit den KOMPLETTEN Tagebuch-Blob neu (~78 kB, Worst
// Case ~557 kB), und mehrere Cache-Writes laufen `unawaited` und koennen sich
// ueberlappen. Einen 78-kB-Blob wiederholt und nebenlaeufig durch den
// Platform-Channel des Plugins zu schieben trifft genau den Pfad, auf dem
// dessen Android-Backend historisch schwach ist (Nebenlaeufigkeit,
// Grosse Payloads, Keystore-Roundtrips pro Write). Envelope-Verschluesselung
// schrumpft den Wirkungsbereich des Plugins auf EINEN 44-Byte-Read pro
// Kaltstart; der heisse Pfad ist danach reine Dart-Krypto ohne Channel.

/// Magic-Prefix des Wire-Formats: `"EATOVA1:" + base64(nonce ‖ ct ‖ tag)`.
///
/// Bewusst ein POSITIVES Magic statt einer `{`-vs-base64-Heuristik: der Test
/// "faengt mit EATOVA1: an" ist auf BEIDEN Zweigen positiv. Die Umkehrung
/// ("faengt nicht mit `{` an, also Ciphertext") wuerde jeden kuenftigen
/// Nicht-Objekt-Write (Array, Zahl, nackter String) still fehlklassifizieren
/// und ihn dann ueber den Undecryptable-Pfad LOESCHEN.
///
/// Die `1` ist die Algorithmus-Version: eine spaetere Rotation ist ein
/// weiterer `startsWith`-Zweig, kein Ratespiel. Der `:` gehoert nicht zum
/// base64-Alphabet, das Trennzeichen kann also nie mehrdeutig werden.
const String cacheCipherMagic = 'EATOVA1:';

/// Injizierbare Naht fuer die Verschluesselung eines Cache-Slots.
///
/// [key] ist der SharedPreferences-Schluessel des Slots und geht als AAD in
/// die Verschluesselung ein — Implementierungen MUESSEN ihn binden.
///
/// PERF-G9: bewusst `Future`-wertig, obwohl AES-GCM eine reine Rechnung ist.
/// Die Produktionsimplementierung schiebt die Rechnung ueber `compute()` in
/// einen Isolate; eine synchrone Signatur wuerde das verbieten und die
/// Verschluesselung im Tap-Handler festnageln (gemessen 91,5 ms bei 210
/// Mahlzeiten auf Desktop-JIT, mobil AOT 2-4x davon).
abstract class CacheCipher {
  /// Verschluesselt [plaintext] gebunden an [key]. Liefert das armored
  /// Wire-Format (siehe [cacheCipherMagic]).
  Future<String> encrypt(String key, String plaintext);

  /// Entschluesselt [armored] gebunden an [key]. Wirft bei falschem Key,
  /// falschem Slot (AAD) oder manipuliertem Ciphertext.
  Future<String> decrypt(String key, String armored);
}

/// Transportobjekt fuer den Isolate-Hop. Nur einfache Daten (Uint8List +
/// zwei Strings) — keine Closures, keine Ports, keine nativen Handles.
class _CipherJob {
  const _CipherJob(this.dek, this.key, this.payload);

  final Uint8List dek;
  final String key;
  final String payload;
}

// `compute()` verlangt eine TOP-LEVEL- oder statische Funktion: die
// Referenz wird als Code-Zeiger in den Isolate geschickt, eine Closure haette
// einen eingefangenen Kontext, den es dort nicht gibt.
String _encryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.encryptSync(job.dek, job.key, job.payload);

String _decryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.decryptSync(job.dek, job.key, job.payload);

/// AES-256-GCM ueber pointycastle, mit dem DEK aus [CacheKeyProvider].
class AesGcmCacheCipher implements CacheCipher {
  AesGcmCacheCipher(this._dek) {
    if (_dek.length != dekLengthBytes) {
      throw ArgumentError.value(
          _dek.length, 'dek', 'DEK muss genau $dekLengthBytes Bytes haben');
    }
  }

  /// AES-256.
  static const int dekLengthBytes = 32;

  /// 96-bit-Nonce — die von GCM vorgesehene Standardlaenge (alles andere
  /// laeuft durch GHASH und ist nur langsamer, nicht sicherer).
  static const int nonceLengthBytes = 12;

  /// 128-bit-Auth-Tag (voll, nicht gekuerzt).
  static const int tagLengthBits = 128;

  final Uint8List _dek;

  /// Kryptographisch sicherer RNG. `Random.secure()` zieht auf Android/iOS
  /// aus dem OS-CSPRNG.
  static final Random _rng = Random.secure();

  // --- PERF-G9: der Isolate-Hop -------------------------------------------
  //
  // Beide Richtungen laufen ueber `compute()`. KEINE Schwelle "kleine Blobs
  // synchron", und das ist gemessen und nicht geraten (Dart 3.11 JIT,
  // flutter test, 40 Durchlaeufe je Groesse, verschraenkt gemessen):
  //
  //   Blob     sync      compute   Delta
  //     64 B   0,286 ms  0,397 ms  0,111 ms
  //    256 B   0,343 ms  0,485 ms  0,142 ms
  //    512 B   0,597 ms  0,665 ms  0,067 ms
  //   1024 B   0,916 ms  1,045 ms  0,130 ms
  //   2048 B   1,789 ms  1,925 ms  0,137 ms
  //   4096 B   3,524 ms  3,664 ms  0,140 ms
  //
  // Der Isolate-Overhead ist eine KONSTANTE von ~0,13 ms und waechst nicht
  // mit der Blobgroesse (Isolate.run spawnt in derselben Isolate-Group, der
  // Heap wird geteilt). Schon der kleinste reale Slot kostet synchron 0,29 ms
  // Krypto — also mehr als der Hop. Eine Schwelle wuerde damit einen zweiten
  // Codepfad einfuehren, der auf KEINER Groesse gewinnt. Die 0,13 ms sind
  // ausserdem Wanduhrzeit; auf dem Main-Isolate bleibt davon nur das
  // Verschicken der Nachricht.
  @override
  Future<String> encrypt(String key, String plaintext) => compute(
        _encryptInIsolate,
        _CipherJob(_dek, key, plaintext),
        debugLabel: 'cache-encrypt',
      );

  @override
  Future<String> decrypt(String key, String armored) => compute(
        _decryptInIsolate,
        _CipherJob(_dek, key, armored),
        debugLabel: 'cache-decrypt',
      );

  /// Die eigentliche Rechnung — REIN (kein Feldzugriff, keine IO), damit sie
  /// im Isolate laufen kann. Wire-Format unveraendert gegenueber der
  /// synchronen Fassung; der Golden-Blob im Test haelt das fest.
  static String encryptSync(Uint8List dek, String key, String plaintext) {
    // NONCE: 12 FRISCHE Zufallsbytes pro Verschluesselung — niemals aus dem
    // Key abgeleitet, niemals ein Zaehler, niemals konstant. Eine
    // Nonce-Wiederverwendung unter demselben GCM-Key gibt den
    // Authentifizierungs-Subkey preis und erlaubt Forgery fuer ALLE
    // Ciphertexte unter diesem Key. Das ist der schaedlichste plausible
    // Fehler in dieser ganzen Datei.
    final nonce = Uint8List(nonceLengthBytes);
    for (var i = 0; i < nonceLengthBytes; i++) {
      nonce[i] = _rng.nextInt(256);
    }

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
            KeyParameter(dek), tagLengthBits, nonce, _associatedData(key)),
      );
    // process() liefert bei GCM ciphertext ‖ tag.
    final sealed = cipher.process(_bytes(plaintext));

    final framed = Uint8List(nonce.length + sealed.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealed.length, sealed);
    return '$cacheCipherMagic${base64.encode(framed)}';
  }

  /// Gegenstueck zu [encryptSync], ebenfalls rein und isolate-tauglich.
  static String decryptSync(Uint8List dek, String key, String armored) {
    if (!armored.startsWith(cacheCipherMagic)) {
      throw const FormatException('Cache-Slot ohne EATOVA1-Magic');
    }
    // Bewusst KEIN Ciphertext im Fehlertext: FormatException von base64.decode
    // wuerde die Quelle einbetten und damit in den Crash-Report tragen.
    final Uint8List framed;
    try {
      framed = base64.decode(armored.substring(cacheCipherMagic.length));
    } on FormatException {
      throw const FormatException('Cache-Slot ist kein gueltiges base64');
    }
    if (framed.length < nonceLengthBytes + tagLengthBits ~/ 8) {
      throw const FormatException('Cache-Slot zu kurz fuer nonce+tag');
    }

    final nonce = Uint8List.sublistView(framed, 0, nonceLengthBytes);
    final sealed = Uint8List.fromList(framed.sublist(nonceLengthBytes));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
            KeyParameter(dek), tagLengthBits, nonce, _associatedData(key)),
      );
    // Wirft InvalidCipherTextException, wenn der Tag nicht passt — also bei
    // falschem DEK, falschem Slot (AAD) oder manipuliertem Blob.
    return utf8.decode(cipher.process(sealed));
  }

  /// AAD = der Storage-Key selbst. Bindet jeden Ciphertext an SEINEN Slot:
  /// wer Schreibzugriff auf die Datei hat, kann einen Wert damit weder in
  /// einen anderen Slot noch in den Namensraum eines anderen Users
  /// verschieben — die Tag-Pruefung schlaegt fehl.
  static Uint8List _associatedData(String key) => _bytes(key);

  static Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
}

/// Minimale Naht ueber den OS-Keystore, damit [CacheKeyProvider] ohne
/// Plugin-Channel testbar ist.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production-Implementierung: flutter_secure_storage.
class PluginSecureKeyStore implements SecureKeyStore {
  const PluginSecureKeyStore();

  // Diese Options-Zeilen sind wichtiger als die Krypto darueber — sie
  // entscheiden, ob der DEK einen normalen Geraete-Alltag ueberlebt.
  // Oeffentlich, weil der Session-Storage (supabase_config.dart, C5) exakt
  // dieselbe Haltung braucht und sie nicht neu erfinden soll.
  static const AndroidOptions androidOptions = AndroidOptions(
    // SEC/A1: `resetOnError` ist in flutter_secure_storage 10.x per Default
    // TRUE (in 9.x war es false). Die Java-Seite faengt damit JEDEN
    // Keystore-Fehler ab, ruft `delete(key)` bzw. `deleteAll()` und meldet
    // Erfolg — auf dem Read-Pfad kommt bei Dart ein blankes `null` an,
    // ununterscheidbar von einem Erststart. Genau daraus wuerde der Bootstrap
    // einen frischen DEK praegen und ALLE `EATOVA1:`-Slots (inkl. der Outbox
    // mit bis zu 500 nicht quittierten Writes) unlesbar und damit
    // loeschungsreif machen.
    //
    // Mit `false` wirft der Fehler durch, und der `catch` in
    // [CacheKeyProvider._bootstrap] tut das einzig Richtige: aufgeben, den
    // Ciphertext liegen lassen, naechster Start versucht neu.
    resetOnError: false,
    // ANDROID sonst: bewusst die PLUGIN-DEFAULTS (AES-GCM-Daten, RSA-OAEP-
    // Key-Wrapping, enforceBiometrics = false => setUserAuthenticationRequired
    // (false)). KEINE `AndroidOptions.biometric()`-Variante, KEIN
    // enforceBiometrics: true.
    //
    // Grund: Android-Keystore-Keys werden durch Aenderungen an Sperrbildschirm
    // und Biometrie-Enrollment NUR DANN invalidiert, wenn
    // setUserAuthenticationRequired(true) gesetzt ist. Mit dem Flag wuerde das
    // blosse Hinzufuegen eines Fingerabdrucks den DEK vernichten und damit den
    // gesamten Cache — inklusive der Outbox, die der Server NICHT
    // rekonstruieren kann. Ohne das Flag faellt genau dieses (mit Abstand
    // haeufigste) Key-Verlust-Szenario weg.
    //
    // Wer hier spaeter "mehr Sicherheit" einbauen will: das Ergebnis waere
    // Datenverlust beim Fingerabdruck-Anlegen, kein Sicherheitsgewinn. Der
    // Schutzzweck ist Extraktion vom RUHENDEN Geraet, nicht Schutz gegen den
    // eingeloggten Nutzer selbst.
  );

  /// iOS: `first_unlock` (nicht `unlocked`), damit Lifecycle- und
  /// Notification-Pfade den DEK auch nach einem Reboot ohne aktive
  /// Entsperrung lesen koennen. `_this_device`, damit der DEK NIE in die
  /// iCloud-Keychain synchronisiert und nie auf ein anderes Geraet migriert
  /// (dort laege der Ciphertext dann ohne Key — bzw. der Key ohne Geraet).
  ///
  /// Ein `resetOnError`-Aequivalent gibt es auf Apple NICHT: `AppleOptions`
  /// (flutter_secure_storage 10.3.1, `lib/options/apple_options.dart`) kennt
  /// kein solches Feld, und die Swift-Seite loescht bei einem
  /// Keychain-Fehler nichts, sondern reicht den OSStatus durch. Auf iOS ist
  /// der Sentinel unten also die einzige — und ausreichende — Absicherung.
  static const IOSOptions iosOptions =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: androidOptions,
    iOptions: iosOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A1: Klartext-Marker "auf diesem Geraet wurde schon einmal ein DEK
/// gepraegt".
///
/// Der Marker traegt kein Geheimnis — nur ein Bit. Sein einziger Zweck ist,
/// die beiden Zustaende auseinanderzuhalten, die der Keystore auf `null`
/// abbildet:
///   (a) Erststart / frische Installation  -> DEK praegen ist richtig
///   (b) Der Keystore hat den Eintrag verloren -> DEK praegen zerstoert Daten
abstract class DekSentinelStore {
  Future<bool> isProvisioned();
  Future<void> markProvisioned();
}

/// Production-Implementierung: SharedPreferences.
///
/// WARUM NICHT im selben Secure Storage? Weil der Sentinel genau den Vorfall
/// ueberleben MUSS, den er meldet. Ein `deleteAll()` aus `handleStorageError`
/// oder ein invalidierter Keystore-Key raeumt den gesamten
/// flutter_secure_storage-Namensraum mit ab — ein Sentinel dort waere im
/// Ernstfall exakt gleichzeitig weg und wuerde nie feuern.
///
/// SharedPreferences ist der richtige Ort, weil dort ohnehin schon die
/// verschluesselten Blobs liegen, deren Wiederverwendbarkeit der Sentinel
/// behauptet: beide gehen nur gemeinsam verloren (App-Daten loeschen,
/// Deinstallation). Genau dann ist ein frischer DEK auch wieder korrekt, die
/// App heilt sich also von selbst — waehrend "Keystore kaputt, Blobs noch da"
/// zuverlaessig erkannt wird.
///
/// Der Marker ist ein blankes `true` ohne Kennung: nichts, was ein Angreifer
/// mit Dateizugriff nicht ohnehin aus der Existenz der Ciphertexte ablesen
/// koennte.
class PrefsDekSentinelStore implements DekSentinelStore {
  const PrefsDekSentinelStore();

  @override
  Future<bool> isProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(CacheKeyProvider.dekProvisionedKey) ?? false;
  }

  @override
  Future<void> markProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.dekProvisionedKey, true);
  }
}

/// Bereinigtes Fehlerobjekt fuer den Crash-Report, wenn der DEK verschwunden
/// ist, obwohl der Sentinel steht. Traegt bewusst KEINE Kennung.
class VanishedCacheKey implements Exception {
  const VanishedCacheKey();

  @override
  String toString() =>
      'VanishedCacheKey: DEK fehlt trotz gesetztem Sentinel — Bootstrap '
      'abgebrochen statt neu gepraegt';
}

/// Bootstrap des Data-Encryption-Key (DEK) — memoisiert und single-flight.
class CacheKeyProvider {
  const CacheKeyProvider._();

  /// EIN app-weiter DEK. Die Cache-Keys sind bereits pro User genamespaced
  /// (`eatova.v1.<slot>.<uid>`) und das Bedrohungsmodell ist Extraktion auf
  /// GERAETE-Ebene — ein Key pro User wuerde dagegen nichts zusaetzlich
  /// schuetzen, aber den Bootstrap pro Login-Wechsel verdoppeln.
  static const String dekStorageKey = 'eatova.v1.cache_dek';

  /// A1-Sentinel. Liegt in SharedPreferences, NICHT im Secure Storage —
  /// Begruendung siehe [PrefsDekSentinelStore].
  static const String dekProvisionedKey = 'eatova.v1.dek_provisioned';

  /// Memoisierter Bootstrap. MUSS synchron gesetzt werden, bevor irgendein
  /// `await` laufen kann — siehe [obtain].
  static Future<Uint8List?>? _pending;

  /// Liefert den DEK (32 Bytes) oder null, wenn er weder gelesen noch angelegt
  /// werden konnte.
  ///
  /// SINGLE-FLIGHT (nicht optional): `LocalCache.create` ist aus ZWEI
  /// Aufrufstellen erreichbar (`home_store.dart` beim Boot,
  /// `home_store_sync.dart` beim Logout), die sich ueberlappen koennen — ein
  /// Sign-out waehrend des Boots macht genau das. Zwei nebenlaeufige,
  /// unmemoisierte Bootstraps wuerden JEWEILS einen DEK erzeugen; der zweite
  /// ueberschreibt den ersten, und jeder unter dem Verlierer geschriebene Wert
  /// ist ab sofort unwiederbringlich — ohne Fehler, bis zum naechsten Read.
  /// Das ist der Fehler, der im manuellen Test perfekt aussieht.
  ///
  /// Die Zuweisung an [_pending] passiert SYNCHRON in dieser (nicht-`async`)
  /// Methode: `??=` liest und schreibt das Feld in derselben Microtask, in der
  /// [_bootstrap] gestartet wird. Zwischen Lesen und Schreiben kann also kein
  /// zweiter Aufrufer dazwischenkommen — der erste `await` liegt erst INNEN in
  /// [_bootstrap], lange nach der Memoisierung.
  static Future<Uint8List?> obtain({
    SecureKeyStore? keyStore,
    DekSentinelStore? sentinelStore,
  }) {
    final started = _pending ??= _bootstrap(
      keyStore ?? const PluginSecureKeyStore(),
      sentinelStore ?? const PrefsDekSentinelStore(),
    );
    // Ein GESCHEITERTER Bootstrap (null) wird nicht dauerhaft gemerkt: sonst
    // bliebe der Cache nach EINEM transienten Keystore-Fehler fuer den Rest
    // des Prozesses tot. Das ist race-frei, weil im Null-Fall garantiert kein
    // DEK geschrieben und kein Wert verschluesselt wurde.
    unawaited(started.then((dek) {
      if (dek == null && identical(_pending, started)) _pending = null;
    }, onError: (_, __) {
      if (identical(_pending, started)) _pending = null;
    }));
    return started;
  }

  /// Setzt die Memoisierung zurueck (nur Tests).
  @visibleForTesting
  static void debugReset() => _pending = null;

  static Future<Uint8List?> _bootstrap(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
  ) async {
    final String? stored;
    try {
      stored = await keyStore.read(dekStorageKey);
    } catch (e, s) {
      // Der Read ist FEHLGESCHLAGEN — das ist NICHT dasselbe wie "kein Key da".
      // Wuerden wir hier einen neuen DEK erzeugen, koennten wir einen
      // vorhandenen, nur gerade unlesbaren ueberschreiben und damit den
      // kompletten Cache (inkl. Outbox) endgueltig verwaisen lassen. Also:
      // aufgeben, Cache bleibt diese Session aus, naechster Start versucht neu.
      //
      // Dieser Zweig ist erst durch `resetOnError: false` ueberhaupt
      // erreichbar — mit dem 10.x-Default hatte die Java-Seite den Eintrag
      // vorher geloescht und `null` zurueckgemeldet.
      dev.log('CacheKeyProvider: DEK-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return null;
    }

    if (stored != null && stored.isNotEmpty) {
      final decoded = _tryDecodeDek(stored);
      if (decoded != null) {
        // Bestandsinstallationen von VOR dem Sentinel nachziehen: ohne diese
        // Zeile waere jedes bereits installierte Geraet dauerhaft
        // ungeschuetzt, weil der Sentinel erst beim naechsten (nie
        // stattfindenden) Erst-Praegen entstuende.
        await _markProvisioned(sentinel);
        return decoded;
      }
      // Ein vorhandener, aber strukturell kaputter DEK-Eintrag: die damit
      // geschriebenen Daten sind ohnehin verloren. Neu erzeugen laesst die
      // App sich selbst heilen (jeder Slot faellt beim naechsten Read in den
      // Undecryptable-Pfad und wird geraeumt).
      //
      // Der Sentinel greift hier BEWUSST nicht: er unterscheidet "Key weg" von
      // "Erststart", und hier ist der Key nachweislich DA, nur unbrauchbar.
      dev.log('CacheKeyProvider: DEK-Eintrag korrupt, wird neu erzeugt',
          name: 'secure_cache_store');
    } else if (await _wasProvisioned(sentinel)) {
      // A1, der eigentliche Schutz. Der Keystore meldet "kein Key", aber auf
      // diesem Geraet wurde schon einmal einer gepraegt — also wurde er
      // geloescht (resetOnError, invalidierter Key, Backup-Restore ohne
      // Keychain). Ein frischer DEK wuerde jetzt alle `EATOVA1:`-Slots
      // unentschluesselbar machen, `_onUndecryptable` wuerde sie raeumen, und
      // die Outbox-Ops waeren endgueltig weg — der Server kann sie nicht
      // rekonstruieren.
      //
      // Stattdessen: aufgeben. Die Ciphertexte bleiben unangetastet liegen.
      // Kehrt der Schluessel je zurueck (Restore der Keychain, Downgrade),
      // sind sie wieder lesbar. Loescht der Nutzer die App-Daten, verschwindet
      // der Sentinel mit den Blobs und der naechste Start praegt wieder
      // regulaer — die App bleibt also nicht dauerhaft klemmt.
      dev.log(
          'CacheKeyProvider: DEK fehlt trotz Sentinel — kein Neu-Praegen '
          '(sonst Totalverlust des Caches inkl. Outbox)',
          name: 'secure_cache_store');
      unawaited(CrashReporter.capture(
        const VanishedCacheKey(),
        StackTrace.current,
        context: 'cache_dek_vanished',
      ));
      return null;
    }

    final fresh = _generateDek();
    try {
      await keyStore.write(dekStorageKey, base64.encode(fresh));
    } catch (e, s) {
      dev.log('CacheKeyProvider: DEK-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      // NIEMALS auf Klartext zurueckfallen: ein stiller unverschluesselter
      // Fallback wuerde die Compliance-Aussage falsch machen und dabei
      // funktionieren. Lieber gar kein Cache.
      return null;
    }
    // REIHENFOLGE: erst der DEK, dann der Sentinel. Andersherum wuerde ein
    // gescheiterter DEK-Write einen Sentinel ohne Key hinterlassen — und der
    // naechste Start liefe in den Abbruch-Zweig oben, dauerhaft.
    await _markProvisioned(sentinel);
    return fresh;
  }

  /// Sentinel lesen. Faellt FAIL-CLOSED aus: wer nicht sagen kann, ob schon
  /// ein DEK existierte, darf keinen neuen praegen. Der Preis ist "diese
  /// Session ohne Cache" — der Preis der Gegenrichtung waere Datenverlust.
  /// Praktisch ist das folgenlos: SharedPreferences ist ohnehin der Speicher
  /// des Caches, faellt es aus, gibt es auch nichts zu cachen.
  static Future<bool> _wasProvisioned(DekSentinelStore sentinel) async {
    try {
      return await sentinel.isProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Read fehlgeschlagen — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return true;
    }
  }

  /// Best effort: schlaegt das Setzen fehl, degradiert das Verhalten auf den
  /// Stand VOR dieser Aenderung (naechster Keystore-Reset praegt neu) — es
  /// wird dadurch nie schlimmer, also kein Grund den Bootstrap abzubrechen.
  static Future<void> _markProvisioned(DekSentinelStore sentinel) async {
    try {
      await sentinel.markProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  static Uint8List _generateDek() {
    final rng = Random.secure();
    final key = Uint8List(AesGcmCacheCipher.dekLengthBytes);
    for (var i = 0; i < key.length; i++) {
      key[i] = rng.nextInt(256);
    }
    return key;
  }

  static Uint8List? _tryDecodeDek(String stored) {
    try {
      final bytes = base64.decode(stored);
      if (bytes.length != AesGcmCacheCipher.dekLengthBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// Dekorator ueber einem [KeyValueStore]: schreibt ausschliesslich
/// verschluesselt, liest verschluesselt UND (einmalig migrierend) Klartext.
///
/// Sitzt bewusst UNTER [LocalCache] (verdrahtet nur in `LocalCache.create`) —
/// der Cache selbst, seine neun Key-Getter und alle Serialisierer bleiben
/// unveraendert, ebenso der oeffentliche Konstruktor `LocalCache(store, uid)`,
/// den die bestehenden Tests mit einem [InMemoryKeyValueStore] und rohen
/// Klartext-Werten benutzen.
class EncryptedKeyValueStore implements KeyValueStore {
  EncryptedKeyValueStore(this._inner, this._cipher);

  final KeyValueStore _inner;
  final CacheCipher _cipher;

  /// Wird nur EINMAL pro Prozess an [CrashReporter] gemeldet — ein kaputter
  /// DEK macht ALLE Slots unlesbar, das waeren sonst neun identische Reports
  /// pro Kaltstart.
  static bool _undecryptableReported = false;

  /// Baut den Dekorator auf dem OS-Keystore-DEK. Gibt null zurueck, wenn der
  /// DEK weder gelesen noch angelegt werden konnte — der Aufrufer
  /// ([LocalCache.create]) liefert dann seinerseits null und die App laeuft
  /// ohne Cache weiter. KEIN Klartext-Fallback.
  static Future<EncryptedKeyValueStore?> create(
    KeyValueStore inner, {
    SecureKeyStore? keyStore,
    DekSentinelStore? sentinelStore,
  }) async {
    final dek = await CacheKeyProvider.obtain(
      keyStore: keyStore,
      sentinelStore: sentinelStore,
    );
    if (dek == null) return null;
    return EncryptedKeyValueStore(inner, AesGcmCacheCipher(dek));
  }

  /// PERF-G9: Seit die Verschluesselung im Isolate laeuft, ist [setString]
  /// zwischen Aufruf und Persistierung unterbrechbar. Ohne Serialisierung
  /// koennten zwei ueberlappende Writes auf DENSELBEN Slot in umgekehrter
  /// Reihenfolge landen — der Header dieser Datei haelt fest, dass genau das
  /// passiert (`_cacheLoggedMeals()` schreibt den ganzen Blob bei jeder
  /// Aenderung, mehrere Writes laufen `unawaited`).
  ///
  /// Vorher war das durch Zufall sicher: `setString` lief bis zum
  /// `_inner.setString` synchron, die Aufrufreihenfolge war also die
  /// Schreibreihenfolge. Diese Garantie wird hier explizit wiederhergestellt —
  /// PRO KEY, damit verschiedene Slots weiter parallel rechnen duerfen.
  final Map<String, Future<void>> _writeQueue = <String, Future<void>>{};

  @override
  Future<String?> getString(String key) async {
    final raw = await _inner.getString(key);
    if (raw == null || raw.isEmpty) return null;

    if (raw.startsWith(cacheCipherMagic)) {
      try {
        return await _cipher.decrypt(key, raw);
      } catch (e, s) {
        await _onUndecryptable(key, e, s);
        return null;
      }
    }

    // Legacy-Klartext aus einer Installation vor dieser Aenderung.
    //
    // EAGER migrieren, nicht auf Write-Through warten: die Slots `outbox`,
    // `pending_stats` und `notifications_enabled` werden nur bei ihren eigenen
    // Ereignissen geschrieben und laegen sonst womoeglich wochenlang weiter im
    // Klartext.
    try {
      await _enqueueWrite(key, () async {
        // Der Isolate-Hop macht ein Fenster auf, in dem ein regulaerer
        // setString denselben Slot schon neu geschrieben haben kann. Dann ist
        // der Klartext von oben veraltet und darf ihn NICHT ueberschreiben.
        if (await _inner.getString(key) != raw) return;
        await _inner.setString(key, await _cipher.encrypt(key, raw));
      });
    } catch (e) {
      // Eigener try/catch: ein Migrations-Fehler degradiert zu "bleibt
      // Klartext, naechster Read versucht es erneut" — NIEMALS zu einem
      // verlorenen Read. SharedPreferences.setString ersetzt einen Key atomar,
      // ein Prozess-Tod mitten in der Migration hinterlaesst also keinen
      // halben Wert.
      dev.log('EncryptedKeyValueStore: Migration fehlgeschlagen ($key)',
          error: e, name: 'secure_cache_store');
    }
    return raw;
  }

  @override
  Future<void> setString(String key, String value) =>
      _enqueueWrite(key, () async {
        await _inner.setString(key, await _cipher.encrypt(key, value));
      });

  /// Haengt [task] an das Ende der Kette fuer [key] und liefert dessen
  /// Ergebnis. Ein Fehler eines Vorgaengers blockiert die Nachfolger NICHT
  /// (sonst wuerde ein einzelner Plugin-Fehler den Slot fuer den Rest des
  /// Prozesses stilllegen) — er wird aber weiterhin an dessen eigenen
  /// Aufrufer gemeldet.
  Future<void> _enqueueWrite(String key, Future<void> Function() task) {
    final previous = _writeQueue[key];
    final Future<void> queued = previous == null
        ? task()
        : previous.then<void>((_) => task(),
            onError: (Object _, StackTrace __) => task());
    _writeQueue[key] = queued;
    unawaited(queued.then<void>(
      (_) => _releaseWriteSlot(key, queued),
      onError: (Object _, StackTrace __) => _releaseWriteSlot(key, queued),
    ));
    return queued;
  }

  void _releaseWriteSlot(String key, Future<void> queued) {
    if (identical(_writeQueue[key], queued)) _writeQueue.remove(key);
  }

  /// Laeuft ueber DIESELBE Kette wie [setString]. Sonst koennte ein `remove`
  /// eine noch im Isolate rechnende Verschluesselung ueberholen und der Wert
  /// nach dem Loeschen wieder auftauchen — bei `LocalCache.clear()` (Logout)
  /// waere das PII, die den Logout ueberlebt.
  @override
  Future<void> remove(String key) => _enqueueWrite(key, () => _inner.remove(key));

  /// Ein Slot ist nicht entschluesselbar (invalidierter Keystore-Key,
  /// zurueckgespieltes Backup, Manipulation).
  ///
  /// PRO KEY raeumen, nicht den ganzen Namensraum: der Dekorator sitzt unter
  /// [LocalCache] und hat mit dessen neun Key-Namen nichts zu tun. Da alle
  /// Slots denselben DEK teilen, scheitern im Ernstfall ohnehin alle — und
  /// jeder heilt sich beim naechsten Read selbst. Fuer den Nutzer ist das
  /// exakt derselbe Codepfad wie eine frische Installation: kein Crash, keine
  /// Boot-Schleife, nur ein leerer Cache, den der naechste Netz-Load fuellt.
  Future<void> _onUndecryptable(String key, Object error, StackTrace s) async {
    try {
      await _inner.remove(key);
    } catch (e) {
      dev.log('EncryptedKeyValueStore: remove nach Decrypt-Fehler scheiterte',
          error: e, name: 'secure_cache_store');
    }
    if (_undecryptableReported) return;
    _undecryptableReported = true;
    // NUR Fehlertyp und Key-Name — nie der Wert. crash_reporter.dart haelt
    // diese Einschraenkung fuer Gesundheitsdaten explizit fest. Auch das
    // Fehler-OBJEKT geht bewusst nicht roh raus: eine FormatException aus
    // base64.decode traegt die Quelle in ihrer Message.
    final sanitized = UndecryptableCacheSlot(
      errorType: error is InvalidCipherTextException
          ? 'InvalidCipherTextException'
          : error.runtimeType.toString(),
      storageKey: redactUserSegment(key),
    );
    unawaited(CrashReporter.capture(sanitized, s, context: 'cache_decrypt'));
  }
}

/// Ersetzt das User-Segment eines Cache-Keys (`eatova.v1.<slot>.<userId>`)
/// durch einen Platzhalter, bevor der Key in einen Crash-Report geht.
///
/// Die User-UUID hat fuer die Diagnose keinen Wert — welcher SLOT sich nicht
/// entschluesseln liess, ist die ganze Information. Sie waere aber eine
/// stabile Nutzer-Kennung in Sentry, und bei einer Gesundheits-App ist jede
/// vermeidbare Kennung eine zu viel. Keys ohne User-Segment (&lt;= 3 Teile)
/// bleiben unveraendert.
@visibleForTesting
String redactUserSegment(String key) {
  final parts = key.split('.');
  if (parts.length <= 3) return key;
  return '${parts.sublist(0, parts.length - 1).join('.')}.<uid>';
}

/// Bereinigtes Fehlerobjekt fuer den Crash-Report: traegt ausschliesslich
/// Fehlertyp und Slot-Namen, niemals Klar- oder Geheimtext.
class UndecryptableCacheSlot implements Exception {
  const UndecryptableCacheSlot({
    required this.errorType,
    required this.storageKey,
  });

  final String errorType;
  final String storageKey;

  @override
  String toString() => 'UndecryptableCacheSlot($storageKey): $errorType';
}
