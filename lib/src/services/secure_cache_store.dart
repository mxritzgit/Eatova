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
  /// Keychain-Fehler nichts, sondern reicht den OSStatus durch
  /// (`FlutterSecureStorage.swift:469`: alles ausser `errSecItemNotFound`
  /// wird zur PlatformException).
  ///
  /// PREIS DIESER WAHL — und der Grund fuer die Aufgabe-Logik in
  /// [CacheKeyProvider]: `ThisDeviceOnly`-Keychain-Items sind von iCloud- UND
  /// von verschluesselten iTunes-Backups AUSGESCHLOSSEN. Auf einem
  /// wiederhergestellten Geraet ist der DEK also weg — waehrend
  /// NSUserDefaults (= SharedPreferences, wo die `EATOVA1:`-Blobs und der
  /// Sentinel liegen) mitwandert. Das Android-Gegenstueck dazu ist
  /// `android/app/src/main/res/xml/data_extraction_rules.xml`, das genau
  /// deshalb ALLE SharedPreferences von Backup und D2D-Transfer ausnimmt;
  /// eine iOS-Entsprechung dafuer gibt es im Repo nicht.
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
/// Traegt daneben drei weitere Bits, die denselben Vorfall ueberleben muessen
/// wie der Sentinel selbst: den Strike-Zaehler des Aufgabe-Budgets, den
/// Nutzerhinweis und den Marker fuer den beendeten Klartext-Migrationspfad.
/// Alle drei gehoeren fachlich zum Sentinel — sie beschreiben dessen Nachspiel
/// — und teilen seine Haltbarkeitszusage (gehen NUR gemeinsam mit den Blobs
/// verloren). Ein eigener Speicher waere ein zweiter Ort mit derselben
/// Anforderung.
///
/// Das ist eine Aussage ueber HALTBARKEIT, nicht ueber Integritaet: keines der
/// vier Bits ist gegen jemanden geschuetzt, der in die Prefs-Datei schreiben
/// kann. Wo das den Unterschied macht, steht bei
/// [CacheKeyProvider.plaintextMigrationClosedKey].
abstract class DekSentinelStore {
  Future<bool> isProvisioned();
  Future<void> markProvisioned();

  /// Anzahl bisheriger App-Starts, die den DEK vermisst haben, obwohl der
  /// Sentinel steht. 0 = kein laufender Vorfall.
  Future<int> vanishStrikes();

  /// Setzt den Zaehler. `<= 0` loescht den Eintrag.
  Future<void> setVanishStrikes(int value);

  /// Hinterlegt "der lokale Cache musste aufgegeben werden" fuer die UI.
  /// Wird von [CacheKeyProvider.consumeCacheResetNotice] gelesen und geloescht.
  Future<void> raiseCacheResetNotice();

  /// Ob der Klartext-Migrationspfad zu ist — siehe
  /// [CacheKeyProvider.plaintextMigrationClosedKey].
  Future<bool> isPlaintextMigrationClosed();

  /// Setzt den Marker. Einweg: es gibt keinen Weg zurueck in den migrierbaren
  /// Zustand, ausser die Blobs gehen ohnehin mit verloren.
  Future<void> closePlaintextMigration();
}

/// A1/iOS: Blick auf die verschluesselten Cache-Slots, OHNE den DEK zu
/// brauchen.
///
/// Der Bootstrap muss vor dem Praegen wissen, ob ueberhaupt etwas da ist, das
/// ein frischer DEK verwaisen lassen wuerde. Das geht nicht ueber
/// [KeyValueStore]: der kann nur nach EINEM bekannten Key fragen, kennt keine
/// Aufzaehlung — und `local_cache.dart` gehoert nicht dieser Datei. Deshalb
/// eine eigene, schmale Naht direkt auf SharedPreferences.
///
/// Die Zugehoerigkeit wird ausschliesslich am [cacheCipherMagic] festgemacht,
/// NICHT am Key-Namen: das Magic schreibt nur [EncryptedKeyValueStore], es ist
/// damit die einzige Aussage, die tatsaechlich "nur unser DEK oeffnet das"
/// bedeutet. Ein zusaetzlicher `eatova.v1.`-Namensfilter waere eine zweite,
/// schwaechere Wahrheit, die auseinanderlaufen kann.
abstract class CacheCiphertextProbe {
  /// Storage-Keys, deren Wert mit [cacheCipherMagic] beginnt.
  Future<List<String>> encryptedKeys();

  /// Loescht GENAU [keys]. Wird nur mit dem Ergebnis von [encryptedKeys]
  /// aufgerufen, raeumt also nie einen Klartext- oder Fremd-Slot.
  Future<void> purge(Iterable<String> keys);
}

/// Production-Implementierung: SharedPreferences.
class PrefsCacheCiphertextProbe implements CacheCiphertextProbe {
  const PrefsCacheCiphertextProbe();

  @override
  Future<List<String>> encryptedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      // `get` statt `getString`: im selben Namensraum liegen auch bool-, int-
      // und List-Werte (unser Sentinel z.B.), und `getString` wuerde darauf
      // einen TypeError werfen.
      final value = prefs.get(key);
      if (value is String && value.startsWith(cacheCipherMagic)) hits.add(key);
    }
    return hits;
  }

  @override
  Future<void> purge(Iterable<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}

/// W7a: Aufzaehlung der Slots, die noch KLARTEXT aus einer Installation von
/// VOR der Verschluesselung tragen koennen.
///
/// Gegenstueck zu [CacheCiphertextProbe] und bewusst eine EIGENE Naht statt
/// zweier weiterer Methoden dort: die Ciphertext-Probe gehoert dem Bootstrap,
/// diese hier dem Dekorator — und `implements CacheCiphertextProbe` gibt es
/// auch ausserhalb dieser Datei, wo ein zusaetzliches Interface-Member ein
/// Compile-Fehler waere.
///
/// Der Blick geht direkt auf SharedPreferences, weil [KeyValueStore] nur nach
/// EINEM bekannten Key fragen kann und den Namensraum nicht aufzaehlt — und
/// genau die Slots, die nie gelesen werden (fremde uid, `pending_stats`,
/// `notifications_enabled`), sind der Grund fuer den Sweep.
abstract class LegacyPlaintextProbe {
  /// Kandidaten: Keys, die [isLegacyCacheSlotKey] erfuellen und deren Wert ein
  /// nicht-leerer String OHNE [cacheCipherMagic] ist.
  Future<List<String>> plaintextCacheKeys();
}

/// Die Slot-Namen von `LocalCache`, hier bewusst NOCH EINMAL aufgeschrieben.
///
/// WARUM EINE ERLAUBNISLISTE und nicht schlicht "alles unter `eatova.v1.`":
/// in demselben Prefs-Namensraum liegen `eatova.v1.locale`,
/// `eatova.v1.theme_mode`, `eatova.v1.search_credentials` und
/// `eatova.v1.otp_guard.*` — die werden OHNE den Dekorator gelesen. Ein Sweep
/// ueber den ganzen Praefix wuerde sie verschluesseln und damit dauerhaft und
/// lautlos zerstoeren. Das ist der umgekehrte Fehler des Fundes, den der Sweep
/// behebt, und er waere schlimmer, weil er JEDE Installation trifft.
///
/// WARUM DIE DOPPELUNG VERTRETBAR IST: die Menge der Slots, die ueberhaupt
/// Klartext enthalten KANN, ist historisch und abgeschlossen — sie stammt aus
/// der Zeit vor [EncryptedKeyValueStore]. Ein spaeter hinzugefuegter Slot wird
/// von Anfang an durch den Dekorator geschrieben und traegt immer das Magic;
/// er fehlt hier also zu Recht. (`daily` steht mit drin: der Legacy-Slot des
/// frueheren Heute-Tabs traegt eine Mood-Freitextnotiz und wird nur fuer den
/// AKTUELLEN User geraeumt — der eines fremden Users lag sonst weiter roh da.)
const Set<String> legacyCacheSlotNames = <String>{
  'profile',
  'daily',
  'stats',
  'notifications_enabled',
  'logged_meals',
  'favorites',
  'weight_log',
  'outbox',
  'pending_stats',
  'user_recipes',
  'daily_activity',
};

/// Ob [key] ein Cache-Slot der Form `eatova.v1.<slot>.<uid>` ist.
///
/// Die uid selbst wird NICHT geprueft (sie ist eine beliebige Fremdkennung) —
/// nur Praefix und Slot-Name. Keys mit weniger als vier Segmenten sind
/// Steuerbits ([CacheKeyProvider.dekProvisionedKey] & Co.) und fallen durch.
@visibleForTesting
bool isLegacyCacheSlotKey(String key) {
  final parts = key.split('.');
  if (parts.length < 4) return false;
  if (parts[0] != 'eatova' || parts[1] != 'v1') return false;
  return legacyCacheSlotNames.contains(parts[2]);
}

/// Production-Implementierung: SharedPreferences.
class PrefsLegacyPlaintextProbe implements LegacyPlaintextProbe {
  const PrefsLegacyPlaintextProbe();

  @override
  Future<List<String>> plaintextCacheKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      if (!isLegacyCacheSlotKey(key)) continue;
      // `get` statt `getString`: im selben Namensraum liegen auch bool-, int-
      // und List-Werte, und `getString` wuerde darauf einen TypeError werfen.
      final value = prefs.get(key);
      if (value is! String || value.isEmpty) continue;
      if (value.startsWith(cacheCipherMagic)) continue;
      hits.add(key);
    }
    return hits;
  }
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

  @override
  Future<int> vanishStrikes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0;
  }

  @override
  Future<void> setVanishStrikes(int value) async {
    final prefs = await SharedPreferences.getInstance();
    // 0 als Abwesenheit speichern statt als Wert: der Normalfall (kein
    // Vorfall) hinterlaesst dann gar keinen Eintrag.
    if (value <= 0) {
      await prefs.remove(CacheKeyProvider.dekVanishStrikesKey);
      return;
    }
    await prefs.setInt(CacheKeyProvider.dekVanishStrikesKey, value);
  }

  @override
  Future<void> raiseCacheResetNotice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.cacheResetNoticeKey, true);
  }

  @override
  Future<bool> isPlaintextMigrationClosed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey) ?? false;
  }

  @override
  Future<void> closePlaintextMigration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.plaintextMigrationClosedKey, true);
  }
}

/// Bereinigtes Fehlerobjekt fuer den Crash-Report, wenn der DEK verschwunden
/// ist, obwohl der Sentinel steht — der Bootstrap hat abgebrochen und die
/// Ciphertexte liegen lassen. Traegt bewusst KEINE Kennung.
class VanishedCacheKey implements Exception {
  const VanishedCacheKey({required this.strike, required this.budget});

  /// Der wievielte App-Start in Folge das war.
  final int strike;

  /// Ab wie vielen Strikes aufgegeben wird ([CacheKeyProvider.vanishStrikeBudget]).
  final int budget;

  @override
  String toString() =>
      'VanishedCacheKey($strike/$budget): DEK fehlt trotz gesetztem Sentinel — '
      'Bootstrap abgebrochen statt neu gepraegt';
}

/// Bereinigtes Fehlerobjekt fuer den Crash-Report, wenn der DEK-READ geworfen
/// hat — der Keystore konnte also weder „hier ist er" noch „gibt es nicht"
/// sagen (siehe [CacheKeyProvider._handleUnreadableDek]).
///
/// Traegt neben dem Budget-Stand nur den LAUFZEITTYP des Keystore-Fehlers,
/// niemals dessen Message: eine `PlatformException` fuehrt dort die rohe
/// Plugin-/OS-Begruendung mit.
class UnreadableCacheKey implements Exception {
  const UnreadableCacheKey({
    required this.strike,
    required this.budget,
    required this.errorType,
  });

  /// Der wievielte App-Start in Folge ohne verfuegbaren DEK das war.
  final int strike;

  /// Ab wie vielen Strikes aufgegeben wird ([CacheKeyProvider.vanishStrikeBudget]).
  final int budget;

  /// Nur der Typname, nie der Fehlertext.
  final String errorType;

  @override
  String toString() =>
      'UnreadableCacheKey($strike/$budget): DEK-Read warf $errorType — '
      'Bootstrap abgebrochen, Key nicht ueberschrieben';
}

/// Bereinigtes Fehlerobjekt fuer den Crash-Report, wenn das Strike-Budget
/// aufgebraucht ist: der DEK gilt als endgueltig verloren, die toten
/// Ciphertexte wurden geraeumt und ein frischer DEK gepraegt.
///
/// Das ist der Zustand, in dem die App auf iOS nach einem Geraete-Restore
/// landet — und der einzige Weg zurueck zu einem funktionierenden Cache samt
/// Outbox. Traegt nur eine Anzahl, keinen Key und keinen Ciphertext.
class AbandonedCacheKey implements Exception {
  const AbandonedCacheKey({required this.purgedSlots, required this.budget});

  final int purgedSlots;
  final int budget;

  @override
  String toString() =>
      'AbandonedCacheKey: DEK nach $budget Starts als verloren behandelt — '
      '$purgedSlots tote Slots geraeumt, frischer DEK gepraegt';
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

  /// Zaehler der App-Starts ohne verfuegbaren DEK: entweder vermisst
  /// (Keystore meldet „gibt es nicht", obwohl der Sentinel steht) oder
  /// unlesbar (der Read wirft, s. [_handleUnreadableDek]). Beide Zustaende
  /// enden in derselben Sackgasse und teilen sich deshalb Zaehler und Budget;
  /// ein gelungener Read raeumt ihn in beiden Faellen ab.
  static const String dekVanishStrikesKey = 'eatova.v1.dek_vanish_strikes';

  /// Flag fuer die UI: der lokale Cache musste aufgegeben werden.
  /// Wird von [consumeCacheResetNotice] gelesen und dabei geloescht.
  static const String cacheResetNoticeKey = 'eatova.v1.cache_reset_notice';

  /// SEC/W7a: Marker "der Klartext-Migrationspfad ist zu".
  ///
  /// Ohne ihn nimmt [EncryptedKeyValueStore.getString] jeden Slot ohne
  /// [cacheCipherMagic] UNBEFRISTET als migrierbaren Legacy-Wert an. Echten
  /// Legacy-Klartext kann es aber nur aus Installationen von VOR der
  /// Verschluesselung geben — seit [EncryptedKeyValueStore] schreibt, traegt
  /// jeder Wert das Magic. Der Marker beendet also einen UEBERGANGSZUSTAND,
  /// der sonst dauerhaft offen bliebe: danach ist ein magic-loser Slot kein
  /// Erbstueck mehr, sondern ein unlesbarer Wert, der verworfen und gemeldet
  /// wird. Mehr behauptet er nicht — siehe "GRENZE DER ZUSAGE".
  ///
  /// GESETZT WIRD ER, WENN DER SWEEP DURCH IST: der erste Start nach dem
  /// Update migriert ALLE geerbten Klartext-Slots aktiv
  /// ([EncryptedKeyValueStore.migrateAllLegacySlots]) und schliesst den Pfad
  /// erst danach.
  ///
  /// FRUEHER STAND ER BEIM SENTINEL ([_markProvisioned]) — das war ein
  /// Datenverlustpfad: der Marker gilt GLOBAL, die Slots liegen PRO UID
  /// (`eatova.v1.<slot>.<uid>`). Meldet sich nach dem Update zuerst Nutzer A
  /// an, schliesst DESSEN Bootstrap den Pfad, bevor je ein Slot von Nutzer B
  /// gelesen wurde; B's nie zugestellte Outbox faellt beim naechsten Start in
  /// [ExpiredPlaintextCacheSlot] und ist weg, ohne dass B jemals die Chance
  /// auf eine Migration hatte. Warum der Sweep und nicht ein Marker pro uid,
  /// steht bei [EncryptedKeyValueStore.migrateAllLegacySlots].
  ///
  /// BESTANDSSCHUTZ: der Marker wird NUR gesetzt, wenn der Sweep jeden
  /// gefundenen Slot danach tatsaechlich verschluesselt vorfindet. Scheitert
  /// er (Prefs-Fehler, Schreibfehler), bleibt der Pfad offen und der naechste
  /// Start wiederholt ihn. "Pfad zu" heisst damit immer: es gibt nichts mehr
  /// zu erben.
  ///
  /// GRENZE DER ZUSAGE: der Marker liegt in DERSELBEN Prefs-Datei wie die
  /// Klartext-Slots, um die es geht. Wer dort `eatova.v1.outbox.<uid>`
  /// hineinschreiben kann, loescht im selben Zug dieses Bool; der naechste
  /// Start sieht "Marker abwesend", sweept wieder und wertet den
  /// untergeschobenen Wert sogar zu einem gueltig signierten EATOVA1-Blob auf.
  /// Gegen einen Angreifer mit Schreibzugriff auf die Prefs-Datei leistet der
  /// Marker also NICHTS — er befristet einen Migrationspfad, er sichert keine
  /// Integritaet. Die einzige Integritaetsaussage dieser Datei ist der
  /// GCM-Tag samt AAD, und die gilt ausschliesslich fuer Slots MIT Magic. Was
  /// gegen den Root-Fall bleibt, ist Sichtbarkeit: [ExpiredPlaintextCacheSlot]
  /// hat deshalb einen eigenen Ein-Schuss-Zaehler.
  ///
  /// KEIN Marker im OS-Keystore, obwohl er dort nicht mit einem Texteditor zu
  /// kippen waere. Zwei Gruende: (1) `ThisDeviceOnly`-Eintraege sind von
  /// Backup und Geraetewechsel ausgeschlossen, SharedPreferences nicht (siehe
  /// [PluginSecureKeyStore.iosOptions]). Nach einem Restore waere der Marker
  /// weg und die eingespielten Prefs — inklusive etwaiger Klartext-Slots
  /// FREMDER Herkunft — wieder migrierbar; der Pfad ginge also genau dort auf,
  /// wo der Inhalt am wenigsten vertrauenswuerdig ist. (2) Er kostet einen
  /// zweiten Plugin-Roundtrip pro Kaltstart, gegen den der Dateikopf die ganze
  /// Envelope-Konstruktion gebaut hat.
  static const String plaintextMigrationClosedKey =
      'eatova.v1.cache_plaintext_migrated';

  /// Wie viele App-Starts in Folge abgebrochen wird, bevor der DEK als
  /// ENDGUELTIG verloren gilt.
  ///
  /// Warum ueberhaupt ein Budget — und warum genau dieses:
  ///
  /// Seit `resetOnError: false` ist ein `null` aus dem Keystore KEIN
  /// Fehlersignal mehr. Beide Plattformen melden jeden echten Fehler als
  /// Exception (Android: `FlutterSecureStoragePlugin.java:240` ruft ohne
  /// `shouldDeleteOnFailure` direkt `result.error`; Apple:
  /// `FlutterSecureStorage.swift:466-470` mappt nur `errSecItemNotFound` auf
  /// nil und reicht jeden anderen OSStatus als Fehler durch). Der Zweig hier
  /// sieht also immer ein definitives "diesen Eintrag gibt es nicht" — und
  /// dafuer gibt es keinen Rueckweg: `ThisDeviceOnly` ist in keinem iOS-Backup,
  /// und ein Android-Keystore-Key ist nicht exportierbar. Ein Warten auf die
  /// Rueckkehr des DEK wartet auf etwas, das nicht passieren kann.
  ///
  /// Trotzdem 3 statt 1: das ist eine Aussage ueber ZWEI Plugin-Quelltexte und
  /// zwei Hersteller-Dokus, nicht ueber ein Naturgesetz. Ein neues
  /// Plugin-Release, eine OEM-Eigenheit oder der Secure-Enclave-Fallback
  /// koennten irgendwann doch einmal ein transientes nil liefern. Der Preis
  /// des Budgets ist im schlimmsten Fall zwei zusaetzliche Kaltstarts ohne
  /// Cache (Minuten, nicht Tage) — der Preis eines Fehlurteils in der
  /// Gegenrichtung waere ein geraeumter Outbox-Blob. Damit muss die Analyse
  /// oben nicht stimmen, damit die App richtig handelt.
  ///
  /// DASSELBE Budget gilt fuer den WERFENDEN Read ([_handleUnreadableDek]).
  /// Dort ist der transiente Fall sogar der Regelfall (Keystore beim Boot
  /// noch nicht bereit), der dauerhafte aber ebenso moeglich (beschaedigter
  /// Wrapping-Key nach einem System-Update). Drei Starts trennen die beiden,
  /// ohne dass eine der Richtungen still in einer Sackgasse endet.
  static const int vanishStrikeBudget = 3;

  /// Memoisierter Bootstrap. MUSS synchron gesetzt werden, bevor irgendein
  /// `await` laufen kann — siehe [obtain].
  static Future<Uint8List?>? _pending;

  /// Ein Strike ist ein APP-START, kein [obtain]-Aufruf. `LocalCache.create`
  /// ist aus zwei Stellen erreichbar (Boot, Logout) und ein gescheiterter
  /// Bootstrap wird bewusst NICHT memoisiert — ohne dieses Flag waere das
  /// Budget nach einer einzigen Session aufgebraucht.
  static bool _vanishStrikeCounted = false;

  /// Stand des Klartext-Markers VOR dem Bootstrap dieses Prozesses.
  ///
  /// Fail-closed vorbelegt: solange kein Bootstrap gelaufen ist, gibt es auch
  /// keinen DEK und damit keinen Store, der migrieren duerfte.
  static bool _legacyPlaintextAccepted = false;

  /// Ob dieser App-Start Legacy-Klartext noch uebernehmen darf. Wird von
  /// [EncryptedKeyValueStore.create] NACH [obtain] gelesen und entscheidet
  /// dort zweierlei: ob der Sweep laeuft und ob ein magic-loser Slot beim Read
  /// noch migriert statt verworfen wird (siehe [plaintextMigrationClosedKey]).
  ///
  /// Der Schnappschuss entsteht im Bootstrap, also VOR dem Sweep, der ihn
  /// schliesst — der migrierende Lauf sieht damit noch `true`.
  static bool get legacyPlaintextAccepted => _legacyPlaintextAccepted;

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
    CacheCiphertextProbe? probe,
  }) {
    final started = _pending ??= _bootstrap(
      keyStore ?? const PluginSecureKeyStore(),
      sentinelStore ?? const PrefsDekSentinelStore(),
      probe ?? const PrefsCacheCiphertextProbe(),
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

  /// Liest den Hinweis "der lokale Cache musste aufgegeben werden" und loescht
  /// ihn dabei — der Aufrufer zeigt ihn genau einmal.
  ///
  /// NOCH NICHT VERDRAHTET: die UI-Seite (ein Hinweis beim ersten Frame nach
  /// dem Boot) liegt ausserhalb dieser Datei. Bis dahin ist der Hinweis
  /// persistiert und geht nicht verloren — er wartet nur.
  static Future<bool> consumeCacheResetNotice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(cacheResetNoticeKey) != true) return false;
      await prefs.remove(cacheResetNoticeKey);
      return true;
    } catch (e, s) {
      dev.log('CacheKeyProvider: Cache-Reset-Hinweis nicht lesbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return false;
    }
  }

  /// Setzt die Memoisierung zurueck (nur Tests). Simuliert einen App-Start:
  /// auch der Pro-Prozess-Strike faellt weg.
  @visibleForTesting
  static void debugReset() {
    _pending = null;
    _vanishStrikeCounted = false;
    _legacyPlaintextAccepted = false;
  }

  static Future<Uint8List?> _bootstrap(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
  ) async {
    // Der Stand von VOR dem Sweep ist massgeblich fuer diesen App-Start:
    // derselbe Start schliesst den Marker gleich mit, und wer ihn danach
    // liest, wuerde die Legacy-Werte der Bestandsnutzer verwerfen statt sie zu
    // migrieren.
    _legacyPlaintextAccepted = !await _plaintextMigrationClosed(sentinel);

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
      //
      // „Aufgeben und naechster Start versucht neu" ist aber nur die halbe
      // Antwort: sie setzt einen VORUEBERGEHENDEN Fehler voraus. Ein nach
      // System-Update beschaedigter Keystore-Wrapping-Key ist dauerhaft —
      // dann ist der Cache still und unsichtbar tot, in jeder kuenftigen
      // Session. Deshalb Budget, Meldung und Endzustand: [_handleUnreadableDek].
      dev.log('CacheKeyProvider: DEK-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return _handleUnreadableDek(keyStore, sentinel, probe, e);
    }

    if (stored != null && stored.isNotEmpty) {
      final decoded = _tryDecodeDek(stored);
      if (decoded != null) {
        // Bestandsinstallationen von VOR dem Sentinel nachziehen: ohne diese
        // Zeile waere jedes bereits installierte Geraet dauerhaft
        // ungeschuetzt, weil der Sentinel erst beim naechsten (nie
        // stattfindenden) Erst-Praegen entstuende.
        await _markProvisioned(sentinel);
        // Der Vorfall (falls einer lief) ist vorbei. Ohne diesen Reset
        // summierten sich unabhaengige Aussetzer ueber Monate, und irgendwann
        // gaebe EIN einzelner sofort auf.
        await _clearVanishStrikes(sentinel);
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
      // A1: der Keystore meldet "kein Key", aber auf diesem Geraet wurde schon
      // einmal einer gepraegt. Ob das ein Grund zum Abbrechen ist, haengt
      // davon ab, ob ueberhaupt etwas da ist, das verwaisen koennte.
      if (!await _mayMintAfterVanishedDek(sentinel, probe)) return null;
    }

    return _mintFreshDek(keyStore, sentinel);
  }

  /// Praegt einen frischen DEK und legt ihn ab. null = konnte nicht abgelegt
  /// werden; dann gibt es fuer diese Session keinen Cache.
  static Future<Uint8List?> _mintFreshDek(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
  ) async {
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

  /// Entscheidet den Zustand „der DEK-Read hat GEWORFEN".
  ///
  /// Anders als beim verschwundenen DEK ([_mayMintAfterVanishedDek]) ist hier
  /// UNBEKANNT, ob ueberhaupt noch ein Key existiert — ein Wurf ist kein
  /// „gibt es nicht". Deshalb bleibt der erste Reflex richtig: aufgeben, den
  /// vorhandenen Key nicht ueberschreiben, naechster Start versucht neu.
  ///
  /// Was fehlte, war das Ende. Ein beschaedigter Wrapping-Key im Keystore
  /// (Android-System-Update, Secure-Enclave-Wechsel) wirft bei JEDEM Start
  /// wieder — und dann laeuft die App fuer immer ohne Cache und ohne
  /// persistierte Outbox weiter, ohne dass irgendwo etwas davon steht. Das ist
  /// derselbe Sackgassen-Zustand, gegen den [vanishStrikeBudget] gebaut wurde,
  /// nur ueber den anderen Zweig erreicht — also dasselbe Budget, derselbe
  /// Zaehler (er misst „Starts in Folge ohne verfuegbaren DEK", und ein
  /// gelungener Read raeumt ihn in beiden Faellen ab).
  ///
  /// REIHENFOLGE beim Aufgeben, und hier anders als im Vanish-Pfad: erst
  /// praegen, DANN raeumen. Dort ist der DEK nachweislich fort, die Blobs sind
  /// also ohnehin tot. Hier koennte der alte Key noch existieren — erst wenn
  /// der Write ihn wirklich ersetzt hat, sind die alten Ciphertexte sicher
  /// unbrauchbar. Scheitert der Write, ist nichts geraeumt und nichts
  /// zurueckgesetzt: der naechste Start faengt denselben Vorgang von vorne an.
  ///
  /// PREIS, den man kennen muss: haelt der Fehler genau
  /// [vanishStrikeBudget] Starts an und ist DANN doch voruebergehend gewesen,
  /// ueberschreibt dieser Pfad einen lesbaren DEK. Der Preis der Gegenrichtung
  /// ist ein dauerhaft toter Cache — dieselbe Abwaegung wie bei
  /// [vanishStrikeBudget], nur mit vertauschten Vorzeichen.
  static Future<Uint8List?> _handleUnreadableDek(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
    Object error,
  ) async {
    final int? strike = await _recordVanishStrike(sentinel);
    // Schon in diesem Prozess entschieden — nicht doppelt zaehlen, nicht
    // doppelt melden. `LocalCache.create` laeuft aus Boot UND Logout.
    if (strike == null) return null;

    if (strike < vanishStrikeBudget) {
      unawaited(CrashReporter.capture(
        UnreadableCacheKey(
          strike: strike,
          budget: vanishStrikeBudget,
          errorType: error.runtimeType.toString(),
        ),
        StackTrace.current,
        context: 'cache_dek_unreadable',
      ));
      return null;
    }

    final Uint8List? fresh = await _mintFreshDek(keyStore, sentinel);
    if (fresh == null) return null;

    // Ab hier ist der alte Key ersetzt: alles, was mit ihm verschluesselt
    // wurde, ist endgueltig unlesbar. Raeumen statt liegen lassen — es sind
    // echte Gesundheitsdaten, und `_onUndecryptable` erwischt ohnehin nur die
    // Slots des AKTUELLEN Users.
    final List<String>? orphans = await _encryptedSlots(probe);
    final int purged = orphans?.length ?? 0;
    if (orphans != null && orphans.isNotEmpty) {
      await _purgeSlots(probe, orphans);
    }
    await _raiseCacheResetNotice(sentinel);
    await _clearVanishStrikes(sentinel);
    dev.log(
        'CacheKeyProvider: DEK-Read warf $vanishStrikeBudget Starts in Folge — '
        'Key als verloren behandelt, $purged tote Slots geraeumt, neu gepraegt',
        name: 'secure_cache_store');
    unawaited(CrashReporter.capture(
      AbandonedCacheKey(purgedSlots: purged, budget: vanishStrikeBudget),
      StackTrace.current,
      context: 'cache_dek_given_up',
    ));
    return fresh;
  }

  /// Entscheidet den Zustand "Sentinel steht, aber der Keystore hat keinen DEK
  /// mehr". `true` = praegen ist jetzt richtig, `false` = abbrechen.
  ///
  /// --- Warum der urspruengliche Dauer-Abbruch falsch war -------------------
  ///
  /// Er wurde gegen "der DEK ist nur GERADE weg und kommt zurueck" gebaut.
  /// Dieses Szenario ist seit `resetOnError: false` in einem anderen Zweig
  /// (der `catch` um `keyStore.read`) — hier unten kommt nur noch ein
  /// definitives "gibt es nicht" an, siehe [vanishStrikeBudget].
  ///
  /// Real erreichen diesen Punkt zwei Zustaende:
  ///
  ///   (a) DEK weg, Sentinel da, KEIN `EATOVA1:`-Slot.
  ///       "App-Daten teilweise geloescht" bzw. ein Restore, bei dem auch die
  ///       Blobs fehlen. Es gibt nichts zu verwaisen — der ganze Abbruchgrund
  ///       existiert nicht. Sofort praegen.
  ///
  ///   (b) DEK weg, Sentinel da, `EATOVA1:`-Slots da.
  ///       Der iOS-Restore-Fall (siehe [PluginSecureKeyStore.iosOptions]).
  ///       Diese Blobs sind UNENTSCHLUESSELBAR UND BLEIBEN ES: der DEK
  ///       existiert nirgends mehr, auch nicht im Backup. Sie festzuhalten
  ///       schuetzt kein einziges Byte — es blockiert nur den Cache, und damit
  ///       die persistierte Outbox, in JEDER kuenftigen Session. Der Abbruch
  ///       taeuscht also totes Datum gegen alle zukuenftigen ein: die
  ///       gerettete Mahlzeit von gestern gibt es nicht, die verlorene von
  ///       morgen schon.
  ///
  /// Deshalb: in (b) abbrechen, aber MITZAEHLEN, und nach
  /// [vanishStrikeBudget] Starts aufgeben — Ciphertexte raeumen, frisch
  /// praegen, Nutzerhinweis hinterlegen. Ein sichtbarer Neuanfang ist besser
  /// als ein stiller, und beides ist besser als dauerhaft klemmt.
  static Future<bool> _mayMintAfterVanishedDek(
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
  ) async {
    // null = Probe unbrauchbar. FAIL CLOSED wie ueberall hier: unbekannt wird
    // wie "Blobs vorhanden" behandelt.
    final List<String>? orphans = await _encryptedSlots(probe);

    if (orphans != null && orphans.isEmpty) {
      await _clearVanishStrikes(sentinel);
      dev.log(
          'CacheKeyProvider: DEK fehlt trotz Sentinel, aber kein EATOVA1-Slot '
          '— Praegen ist gefahrlos',
          name: 'secure_cache_store');
      return true;
    }

    final int? strike = await _recordVanishStrike(sentinel);
    // Schon in diesem Prozess entschieden — nicht doppelt zaehlen und nicht
    // doppelt melden.
    if (strike == null) return false;

    if (strike < vanishStrikeBudget) {
      dev.log(
          'CacheKeyProvider: DEK fehlt trotz Sentinel (Start $strike von '
          '$vanishStrikeBudget) — kein Neu-Praegen, Ciphertexte bleiben liegen',
          name: 'secure_cache_store');
      unawaited(CrashReporter.capture(
        VanishedCacheKey(strike: strike, budget: vanishStrikeBudget),
        StackTrace.current,
        context: 'cache_dek_vanished',
      ));
      return false;
    }

    // Budget aufgebraucht: der DEK kommt nicht zurueck.
    //
    // Die toten Ciphertexte werden hier AKTIV geraeumt statt sie
    // `_onUndecryptable` zu ueberlassen. Zwei Gruende: sie sind zwar
    // unlesbare, aber echte Gesundheitsdaten, und `_onUndecryptable` erwischt
    // nur die neun Slots, die [LocalCache] beim aktuellen User wirklich liest
    // — Slots eines frueheren Users im selben Namensraum blieben sonst fuer
    // immer liegen.
    final int purged = orphans?.length ?? 0;
    if (orphans != null) await _purgeSlots(probe, orphans);
    await _raiseCacheResetNotice(sentinel);
    await _clearVanishStrikes(sentinel);
    dev.log(
        'CacheKeyProvider: DEK nach $vanishStrikeBudget Starts als verloren '
        'behandelt — $purged tote Slots geraeumt, praege neu',
        name: 'secure_cache_store');
    unawaited(CrashReporter.capture(
      AbandonedCacheKey(purgedSlots: purged, budget: vanishStrikeBudget),
      StackTrace.current,
      context: 'cache_dek_given_up',
    ));
    return true;
  }

  /// Erhoeht den Strike-Zaehler — HOECHSTENS EINMAL pro Prozess. Liefert den
  /// neuen Stand, oder null, wenn dieser Prozess schon gezaehlt hat.
  static Future<int?> _recordVanishStrike(DekSentinelStore sentinel) async {
    if (_vanishStrikeCounted) return null;
    _vanishStrikeCounted = true;
    final int next = await _vanishStrikes(sentinel) + 1;
    await _setVanishStrikes(sentinel, next);
    return next;
  }

  /// Verschluesselte Slots ermitteln. null = konnte nicht ermittelt werden.
  static Future<List<String>?> _encryptedSlots(
      CacheCiphertextProbe probe) async {
    try {
      return await probe.encryptedKeys();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Ciphertext-Probe fehlgeschlagen — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return null;
    }
  }

  static Future<void> _purgeSlots(
      CacheCiphertextProbe probe, List<String> keys) async {
    try {
      await probe.purge(keys);
    } catch (e, s) {
      // Nicht schlimm: was liegen bleibt, faellt beim naechsten Read in
      // `_onUndecryptable` und wird dort geraeumt.
      dev.log('CacheKeyProvider: Purge toter Slots fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Strike-Zaehler lesen. Bei Fehler 0 — dann bleibt der Zaehler stehen und
  /// das Budget laeuft nie ab. Das ist genau dann der Fall, wenn
  /// SharedPreferences als Ganzes nicht funktioniert; dort liegen aber auch
  /// die Blobs, es gibt also weder etwas zu verlieren noch zu cachen.
  static Future<int> _vanishStrikes(DekSentinelStore sentinel) async {
    try {
      return await sentinel.vanishStrikes();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Strike-Zaehler nicht lesbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return 0;
    }
  }

  static Future<void> _setVanishStrikes(
      DekSentinelStore sentinel, int value) async {
    try {
      await sentinel.setVanishStrikes(value);
    } catch (e, s) {
      dev.log('CacheKeyProvider: Strike-Zaehler nicht schreibbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Nur schreiben, wenn es etwas zu loeschen gibt — der Erfolgspfad laeuft
  /// bei JEDEM Kaltstart hier durch.
  static Future<void> _clearVanishStrikes(DekSentinelStore sentinel) async {
    if (await _vanishStrikes(sentinel) == 0) return;
    await _setVanishStrikes(sentinel, 0);
  }

  static Future<void> _raiseCacheResetNotice(DekSentinelStore sentinel) async {
    try {
      await sentinel.raiseCacheResetNotice();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Cache-Reset-Hinweis nicht schreibbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
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

  /// Marker lesen. FAIL CLOSED: wer nicht sagen kann, ob die Migration schon
  /// gelaufen ist, uebernimmt keinen Klartext mehr. Der Marker liegt in
  /// DENSELBEN SharedPreferences wie die Legacy-Werte — faellt der Read aus,
  /// gibt es dort ohnehin nichts zu uebernehmen; die Gegenrichtung wuerde den
  /// Migrationspfad per Prefs-Fehler wieder aufsperren.
  ///
  /// Dieselbe Ko-Lokation ist auf dem SCHREIB-Weg kein Vorteil, sondern die
  /// Grenze der Zusage: wer die Legacy-Werte legen kann, kann den Marker
  /// entfernen ([plaintextMigrationClosedKey]).
  static Future<bool> _plaintextMigrationClosed(
      DekSentinelStore sentinel) async {
    try {
      return await sentinel.isPlaintextMigrationClosed();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Klartext-Marker nicht lesbar — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return true;
    }
  }

  /// Best effort: schlaegt das Setzen fehl, degradiert das Verhalten auf den
  /// Stand VOR dieser Aenderung (naechster Keystore-Reset praegt neu) — es
  /// wird dadurch nie schlimmer, also kein Grund den Bootstrap abzubrechen.
  ///
  /// Der Klartext-Marker faehrt hier BEWUSST NICHT mehr mit: er ist global,
  /// die Slots sind pro uid, und der Sentinel steht schon nach dem Bootstrap
  /// des ERSTEN Nutzers. Wer beides koppelt, schliesst den Migrationspfad fuer
  /// alle anderen, bevor deren Slots je gelesen wurden
  /// ([plaintextMigrationClosedKey]). Der Marker gehoert deshalb ans Ende des
  /// Sweeps, nicht ans Praegen.
  static Future<void> _markProvisioned(DekSentinelStore sentinel) async {
    try {
      await sentinel.markProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Schliesst den Klartext-Pfad. Aufrufer ist AUSSCHLIESSLICH
  /// [EncryptedKeyValueStore.migrateAllLegacySlots], und zwar erst, wenn kein
  /// geerbter Klartext-Slot mehr uebrig ist ([plaintextMigrationClosedKey]).
  ///
  /// Best effort: schlaegt das Setzen fehl, bleibt der Pfad einen Start
  /// laenger offen — das ist die harmlose Richtung, der Sweep ist idempotent.
  static Future<void> _closePlaintextMigration(
      DekSentinelStore sentinel) async {
    try {
      await sentinel.closePlaintextMigration();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Klartext-Marker nicht schreibbar',
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
  /// [acceptLegacyPlaintext] ist der Migrationspfad aus
  /// [CacheKeyProvider.plaintextMigrationClosedKey]. Der Default steht auf
  /// `true`, weil der Dekorator produktiv NUR ueber [create] entsteht und der
  /// blanke Konstruktor damit den Zustand behaelt, den die bestehenden Tests
  /// mit rohen Klartext-Werten voraussetzen.
  EncryptedKeyValueStore(this._inner, this._cipher,
      {bool acceptLegacyPlaintext = true})
      : _acceptLegacyPlaintext = acceptLegacyPlaintext;

  final KeyValueStore _inner;
  final CacheCipher _cipher;
  final bool _acceptLegacyPlaintext;

  /// Wird nur EINMAL pro Prozess an [CrashReporter] gemeldet — ein kaputter
  /// DEK macht ALLE Slots unlesbar, das waeren sonst neun identische Reports
  /// pro Kaltstart.
  static bool _undecryptableReported = false;

  /// SEC: eigener Zaehler fuer [ExpiredPlaintextCacheSlot], KEIN gemeinsamer.
  ///
  /// Der Marker aus [CacheKeyProvider.plaintextMigrationClosedKey] haelt einen
  /// Angreifer mit Schreibzugriff nicht auf (dort steht, warum) — was gegen
  /// diesen Fall bleibt, ist die Meldung. Sie darf nicht davon abhaengen, ob
  /// vorher zufaellig ein kaputter Ciphertext denselben Schuss verbraucht hat:
  /// nach einem Keystore-Reset scheitert JEDER Slot, und ausgerechnet der
  /// untergeschobene waere danach still.
  static bool _expiredPlaintextReported = false;

  /// Dritter Ein-Schuss-Zaehler: Reads, die an der AUSFUEHRUNG der
  /// Entschluesselung scheitern statt am Ciphertext (siehe
  /// [_provesBrokenCiphertext]).
  ///
  /// Bewusst nicht [_undecryptableReported] mitbenutzt: die beiden Faelle
  /// verlangen entgegengesetzte Reaktionen (raeumen vs. liegen lassen), und
  /// ein gemeinsamer Zaehler machte ausgerechnet den seltenen, diagnostisch
  /// wertvollen Fall still, sobald vorher irgendein kaputter Ciphertext
  /// denselben Schuss verbraucht hat.
  static bool _cipherUnavailableReported = false;

  /// Setzt alle Ein-Schuss-Zaehler zurueck (nur Tests). Sie sind pro PROZESS
  /// gedacht; ein Testlauf ist aber viele simulierte Prozesse in einem.
  @visibleForTesting
  static void debugResetReportGuards() {
    _undecryptableReported = false;
    _expiredPlaintextReported = false;
    _cipherUnavailableReported = false;
  }

  /// Baut den Dekorator auf dem OS-Keystore-DEK. Gibt null zurueck, wenn der
  /// DEK weder gelesen noch angelegt werden konnte — der Aufrufer
  /// ([LocalCache.create]) liefert dann seinerseits null und die App laeuft
  /// ohne Cache weiter. KEIN Klartext-Fallback.
  static Future<EncryptedKeyValueStore?> create(
    KeyValueStore inner, {
    SecureKeyStore? keyStore,
    DekSentinelStore? sentinelStore,
    CacheCiphertextProbe? probe,
    LegacyPlaintextProbe? legacyProbe,
  }) async {
    final dek = await CacheKeyProvider.obtain(
      keyStore: keyStore,
      sentinelStore: sentinelStore,
      probe: probe,
    );
    if (dek == null) return null;
    final store = EncryptedKeyValueStore(
      inner,
      AesGcmCacheCipher(dek),
      acceptLegacyPlaintext: CacheKeyProvider.legacyPlaintextAccepted,
    );
    // W7a: der Sweep laeuft VOR der Rueckgabe. `LocalCache.create` haengt
    // direkt daran, der Aufrufer bekommt also nie einen Store, der noch mitten
    // in der Migration steckt. Er kostet einen Prefs-Durchlauf — aber nur auf
    // dem einen Start, an dem der Marker noch offen ist.
    if (CacheKeyProvider.legacyPlaintextAccepted) {
      await store.migrateAllLegacySlots(
        legacyProbe ?? const PrefsLegacyPlaintextProbe(),
        sentinelStore ?? const PrefsDekSentinelStore(),
      );
    }
    return store;
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
        // Nicht jeder Wurf aus decrypt() ist eine Aussage UEBER DEN SLOT —
        // deshalb entscheidet [_provesBrokenCiphertext], ob geraeumt wird.
        if (_provesBrokenCiphertext(e)) {
          await _onUndecryptable(key, e, s);
        } else {
          _onCipherUnavailable(key, e, s);
        }
        return null;
      }
    }

    // Ein Slot ohne Magic, nachdem die Migration durch ist: ab hier ist das
    // kein Legacy-Wert mehr, sondern ein Wert, der weder Tag noch AAD
    // vorweisen kann — also derselbe Fall wie ein kaputter Ciphertext, und
    // derselbe Pfad.
    if (!_acceptLegacyPlaintext) {
      await _onUndecryptable(
          key, const ExpiredPlaintextCacheSlot(), StackTrace.current);
      return null;
    }

    // Legacy-Klartext aus einer Installation vor dieser Aenderung.
    //
    // Bleibt neben [migrateAllLegacySlots] bestehen: der Sweep raeumt auf, was
    // beim Start DA war — dieser Zweig faengt, was waehrend des migrierenden
    // Starts noch dazukommt, und er ist der Pfad, den die Tests mit dem
    // blanken Konstruktor treiben.
    try {
      await _migrateLegacyPlaintext(key, raw);
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

  /// W7a: zieht ALLE geerbten Klartext-Slots ein und schliesst danach den
  /// Migrationspfad ([CacheKeyProvider.plaintextMigrationClosedKey]).
  ///
  /// --- Warum der Sweep und nicht ein Marker PRO UID -------------------------
  ///
  /// Der Fund: der Marker ist global, die Slots sind pro uid. Wer nach dem
  /// Update zuerst startet, schliesst den Pfad fuer alle anderen.
  ///
  /// Ein Marker pro uid haette den Fund zwar entschaerft, aber drei Probleme:
  ///   (1) Diese Datei KENNT die uid nicht. Der DEK ist app-weit, der Dekorator
  ///       sitzt unter [LocalCache] und sieht nur Slot-Keys. Die uid daraus zu
  ///       schnitzen hiesse, den Key-Aufbau von `local_cache.dart` hier ein
  ///       zweites Mal zu behaupten — und den Marker fuer jede fremde uid zu
  ///       fuehren, die je in den Prefs auftaucht.
  ///   (2) Es gibt keinen Zeitpunkt "fuer diese uid fertig". Welcher Slot noch
  ///       Klartext ist, weiss nur der Read, und `outbox`, `pending_stats`,
  ///       `notifications_enabled` werden womoeglich nie gelesen. Ein Marker,
  ///       der nach dem ersten Read faellt, laesst die uebrigen acht Slots
  ///       derselben uid genauso fallen wie vorher B's ganzen Namensraum.
  ///   (3) Fuer eine uid, die sich auf diesem Geraet NIE wieder anmeldet,
  ///       bliebe der Klartext-Pfad fuer immer offen — also genau dort, wo er
  ///       am laengsten offen steht, und ohne dass je jemand hinschaut.
  ///
  /// Der Sweep dreht das um: er migriert in dem einen Moment, in dem die App
  /// den geerbten Werten noch traut, JEDEN Slot — auch den von Nutzer B, den
  /// niemand liest. Danach ist der Pfad fuer alle gleichzeitig zu, und der
  /// Zustand ist ehrlich pruefbar ("es liegt kein magic-loser Cache-Slot mehr
  /// da"), statt nur behauptet.
  ///
  /// PREIS, den man kennen muss: waehrend dieses einen Starts wird auch ein
  /// UNTERGESCHOBENER Klartext-Slot uebernommen, den vorher nur ein Read
  /// erwischt haette. Das ist derselbe Vertrauensmoment, nur vollstaendig
  /// ausgenutzt — unterscheiden liesse sich beides nicht, weil geerbter
  /// Klartext per Definition keine Signatur hat. Die Bedingung "Bestandsnutzer
  /// verlieren nichts" entscheidet den Fall: der echte Verlust ist sicher, der
  /// Angriff setzt Schreibzugriff voraus, gegen den der Marker ohnehin nichts
  /// ausrichtet ([CacheKeyProvider.plaintextMigrationClosedKey]).
  Future<void> migrateAllLegacySlots(
      LegacyPlaintextProbe probe, DekSentinelStore sentinel) async {
    final List<String> keys;
    try {
      keys = await probe.plaintextCacheKeys();
    } catch (e, s) {
      // Marker NICHT setzen: wer nicht aufzaehlen kann, weiss nicht, ob noch
      // etwas zu erben war. Der naechste Start versucht es erneut.
      dev.log('EncryptedKeyValueStore: Klartext-Sweep nicht aufzaehlbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return;
    }

    for (final key in keys) {
      final String? raw;
      try {
        raw = await _inner.getString(key);
      } catch (e, s) {
        dev.log('EncryptedKeyValueStore: Klartext-Sweep, Read fehlgeschlagen',
            error: e, stackTrace: s, name: 'secure_cache_store');
        return;
      }
      // Zwischen Aufzaehlung und Read kann ein regulaerer Write gelaufen sein.
      if (raw == null || raw.isEmpty || raw.startsWith(cacheCipherMagic)) {
        continue;
      }
      try {
        await _migrateLegacyPlaintext(key, raw);
        // NACHPRUEFEN statt vertrauen: der Marker ist einweg, und ein still
        // gescheiterter Write wuerde den Slot beim naechsten Start in den
        // Verwerfen-Pfad kippen. Lieber ein Start mehr mit offenem Marker.
        final after = await _inner.getString(key);
        if (after != null &&
            after.isNotEmpty &&
            !after.startsWith(cacheCipherMagic)) {
          dev.log('EncryptedKeyValueStore: Klartext-Sweep unvollstaendig',
              name: 'secure_cache_store');
          return;
        }
      } catch (e, s) {
        dev.log('EncryptedKeyValueStore: Klartext-Sweep, Write fehlgeschlagen',
            error: e, stackTrace: s, name: 'secure_cache_store');
        return;
      }
    }

    await CacheKeyProvider._closePlaintextMigration(sentinel);
  }

  /// Schreibt einen magic-losen Wert verschluesselt in seinen Slot zurueck.
  /// Wirft, wenn das misslingt — die Aufrufer entscheiden, was das bedeutet.
  Future<void> _migrateLegacyPlaintext(String key, String raw) =>
      _enqueueWrite(key, () async {
        // Der Isolate-Hop macht ein Fenster auf, in dem ein regulaerer
        // setString denselben Slot schon neu geschrieben haben kann. Dann ist
        // der Klartext von oben veraltet und darf ihn NICHT ueberschreiben.
        if (await _inner.getString(key) != raw) return;
        await _inner.setString(key, await _cipher.encrypt(key, raw));
      });

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

  /// Ob [error] ein Ciphertext- oder Formatproblem NACHWEIST — nur dann darf
  /// der Slot geraeumt werden.
  ///
  /// Beide Typen entstehen ausschliesslich in [AesGcmCacheCipher.decryptSync]:
  /// `InvalidCipherTextException` aus der GCM-Tag-Pruefung (falscher DEK,
  /// falscher Slot/AAD, manipulierter Blob), `FormatException` aus der Magic-,
  /// base64-, Laengen- und utf8-Pruefung. Ihre Aussage gilt dauerhaft —
  /// derselbe Blob geht auch beim naechsten Start nicht auf, Wegwerfen ist
  /// das Self-Healing aus [_onUndecryptable].
  ///
  /// Jeder ANDERE Fehler kommt aus dem Transport, nicht aus den Daten:
  /// [AesGcmCacheCipher.decrypt] ist `compute(...)`, also ein Isolate-Spawn
  /// pro Read. Scheitert der unter Speicherdruck (`IsolateSpawnException`,
  /// `RemoteError`, `OutOfMemoryError`), sagt das ueber den Ciphertext GAR
  /// NICHTS. Ihn daraufhin zu loeschen vernichtet lesbare Daten — bei der
  /// Outbox bis zu 500 nie zugestellte Writes, die der Server nicht
  /// rekonstruieren kann. Der naechste Read bekommt seinen Isolate
  /// wahrscheinlich; ein geloeschter Slot kommt nie zurueck.
  static bool _provesBrokenCiphertext(Object error) =>
      error is InvalidCipherTextException || error is FormatException;

  /// Der Read ist gescheitert, ohne dass der Slot etwas dafuer kann (siehe
  /// [_provesBrokenCiphertext]). Der Slot bleibt LIEGEN, der Aufrufer bekommt
  /// `null` — fuer ihn ist das derselbe Fall wie ein leerer Cache.
  ///
  /// Gemeldet wird einmal pro Prozess: faellt der Isolate-Spawn aus, faellt er
  /// fuer alle Slots aus, das waeren sonst neun identische Reports pro
  /// Kaltstart.
  ///
  /// Bewusst DERSELBE Fehlertyp wie im Raeum-Pfad, aber ein eigener
  /// Kontext-Tag: `crash_reporter.dart` laesst den `toString()` von
  /// [UndecryptableCacheSlot] als „per Konstruktion sanitisiert" durch (die
  /// Allowlist dort haengt am Typnamen). Ein neuer Typ fiele in den
  /// zumachenden Default-Zweig und verloere genau die eine Information, fuer
  /// die diese Meldung existiert — WELCHER Fehler den Read verhindert hat.
  void _onCipherUnavailable(String key, Object error, StackTrace s) {
    dev.log(
        'EncryptedKeyValueStore: Entschluesselung nicht ausfuehrbar ($key) — '
        'Slot bleibt liegen',
        error: error,
        name: 'secure_cache_store');
    if (_cipherUnavailableReported) return;
    _cipherUnavailableReported = true;
    unawaited(CrashReporter.capture(
      UndecryptableCacheSlot(
        errorType: error.runtimeType.toString(),
        storageKey: redactUserSegment(key),
      ),
      s,
      context: 'cache_decrypt_unavailable',
    ));
  }

  /// Ein Slot ist nachweislich nicht entschluesselbar (invalidierter
  /// Keystore-Key, zurueckgespieltes Backup, Manipulation) — oder er traegt
  /// nach abgeschlossener Migration keinen [cacheCipherMagic] mehr.
  ///
  /// NUR fuer diese Faelle, nicht fuer jeden Wurf aus `decrypt()`: die
  /// Abgrenzung steht in [_provesBrokenCiphertext].
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
    if (error is ExpiredPlaintextCacheSlot) {
      if (_expiredPlaintextReported) return;
      _expiredPlaintextReported = true;
    } else {
      if (_undecryptableReported) return;
      _undecryptableReported = true;
    }
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

/// Grund fuer den Undecryptable-Pfad in [EncryptedKeyValueStore.getString],
/// wenn ein Slot nach abgeschlossener Migration ohne [cacheCipherMagic]
/// auftaucht.
///
/// Eigener Typ statt einer FormatException, damit der Crash-Report ihn von
/// einem kaputten Ciphertext unterscheidet: das hier ist der einzige Fall in
/// dieser Datei, der auf einen SCHREIBZUGRIFF von aussen hindeuten kann —
/// deshalb auch ein eigener Ein-Schuss-Zaehler im Dekorator.
/// Traegt bewusst keinen Key und keinen Wert.
class ExpiredPlaintextCacheSlot implements Exception {
  const ExpiredPlaintextCacheSlot();

  @override
  String toString() => 'ExpiredPlaintextCacheSlot: Klartext-Slot nach '
      'abgeschlossener Migration — verworfen statt uebernommen';
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
