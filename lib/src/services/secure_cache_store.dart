import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart'
    show AEADParameters, InvalidCipherTextException, KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

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
abstract class CacheCipher {
  /// Verschluesselt [plaintext] gebunden an [key]. Liefert das armored
  /// Wire-Format (siehe [cacheCipherMagic]).
  String encrypt(String key, String plaintext);

  /// Entschluesselt [armored] gebunden an [key]. Wirft bei falschem Key,
  /// falschem Slot (AAD) oder manipuliertem Ciphertext.
  String decrypt(String key, String armored);
}

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

  @override
  String encrypt(String key, String plaintext) {
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
            KeyParameter(_dek), tagLengthBits, nonce, _associatedData(key)),
      );
    // process() liefert bei GCM ciphertext ‖ tag.
    final sealed = cipher.process(_bytes(plaintext));

    final framed = Uint8List(nonce.length + sealed.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealed.length, sealed);
    return '$cacheCipherMagic${base64.encode(framed)}';
  }

  @override
  String decrypt(String key, String armored) {
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
            KeyParameter(_dek), tagLengthBits, nonce, _associatedData(key)),
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
}

/// Production-Implementierung: flutter_secure_storage.
class PluginSecureKeyStore implements SecureKeyStore {
  const PluginSecureKeyStore();

  // Diese beiden Options-Zeilen sind wichtiger als die Krypto darueber —
  // sie entscheiden, ob der DEK einen normalen Geraete-Alltag ueberlebt.
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    // ANDROID: bewusst die PLUGIN-DEFAULTS (AES-GCM-Daten, RSA-OAEP-
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
    aOptions: AndroidOptions(),
    // iOS: `first_unlock` (nicht `unlocked`), damit Lifecycle- und
    // Notification-Pfade den DEK auch nach einem Reboot ohne aktive
    // Entsperrung lesen koennen. `_this_device`, damit der DEK NIE in die
    // iCloud-Keychain synchronisiert und nie auf ein anderes Geraet migriert
    // (dort laege der Ciphertext dann ohne Key — bzw. der Key ohne Geraet).
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Bootstrap des Data-Encryption-Key (DEK) — memoisiert und single-flight.
class CacheKeyProvider {
  const CacheKeyProvider._();

  /// EIN app-weiter DEK. Die Cache-Keys sind bereits pro User genamespaced
  /// (`eatova.v1.<slot>.<uid>`) und das Bedrohungsmodell ist Extraktion auf
  /// GERAETE-Ebene — ein Key pro User wuerde dagegen nichts zusaetzlich
  /// schuetzen, aber den Bootstrap pro Login-Wechsel verdoppeln.
  static const String dekStorageKey = 'eatova.v1.cache_dek';

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
  static Future<Uint8List?> obtain({SecureKeyStore? keyStore}) {
    final started = _pending ??= _bootstrap(keyStore ?? const PluginSecureKeyStore());
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

  static Future<Uint8List?> _bootstrap(SecureKeyStore keyStore) async {
    final String? stored;
    try {
      stored = await keyStore.read(dekStorageKey);
    } catch (e, s) {
      // Der Read ist FEHLGESCHLAGEN — das ist NICHT dasselbe wie "kein Key da".
      // Wuerden wir hier einen neuen DEK erzeugen, koennten wir einen
      // vorhandenen, nur gerade unlesbaren ueberschreiben und damit den
      // kompletten Cache (inkl. Outbox) endgueltig verwaisen lassen. Also:
      // aufgeben, Cache bleibt diese Session aus, naechster Start versucht neu.
      dev.log('CacheKeyProvider: DEK-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return null;
    }

    if (stored != null && stored.isNotEmpty) {
      final decoded = _tryDecodeDek(stored);
      if (decoded != null) return decoded;
      // Ein vorhandener, aber strukturell kaputter DEK-Eintrag: die damit
      // geschriebenen Daten sind ohnehin verloren. Neu erzeugen laesst die
      // App sich selbst heilen (jeder Slot faellt beim naechsten Read in den
      // Undecryptable-Pfad und wird geraeumt).
      dev.log('CacheKeyProvider: DEK-Eintrag korrupt, wird neu erzeugt',
          name: 'secure_cache_store');
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
    return fresh;
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
  }) async {
    final dek = await CacheKeyProvider.obtain(keyStore: keyStore);
    if (dek == null) return null;
    return EncryptedKeyValueStore(inner, AesGcmCacheCipher(dek));
  }

  @override
  Future<String?> getString(String key) async {
    final raw = await _inner.getString(key);
    if (raw == null || raw.isEmpty) return null;

    if (raw.startsWith(cacheCipherMagic)) {
      try {
        return _cipher.decrypt(key, raw);
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
      await _inner.setString(key, _cipher.encrypt(key, raw));
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
      _inner.setString(key, _cipher.encrypt(key, value));

  @override
  Future<void> remove(String key) => _inner.remove(key);

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
