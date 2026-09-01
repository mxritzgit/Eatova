import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart'
    show AesGcm, Mac, SecretBox, SecretBoxAuthenticationError, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;
import 'package:cryptography_flutter/cryptography_flutter.dart'
    show FlutterAesGcm;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart'
    show AEADParameters, InvalidCipherTextException, KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_reporter.dart';
import 'local_cache.dart';

// SEC-1: encryption layer under LocalCache, which holds health data in
// plaintext in SharedPreferences (GDPR Art. 9). Envelope encryption: only a
// 32-byte DEK lives in the OS keystore, the blobs stay in prefs under
// AES-256-GCM, because every meal edit rewrites the whole ~78 kB blob and
// writes overlap — the plugin's weak spot.

/// Wire format: `"EATOVA1:" + base64(nonce ‖ ct ‖ tag)`. A positive magic,
/// since a `{`-vs-base64 heuristic would misclassify a non-object write and
/// DELETE it via the undecryptable path.
const String cacheCipherMagic = 'EATOVA1:';

/// pointycastle's OWN wording for a failed GCM tag check
/// (`base_aead_block_cipher.dart`), copied verbatim so a crash report reads
/// identically no matter which of the three implementations answered. Type AND
/// message are load-bearing: [EncryptedKeyValueStore._provesBrokenCiphertext]
/// purges the slot on the type, `crash_reporter.dart` allowlists it by name.
const String _tagFailureMessage = 'Authentication tag check failed';

/// Seam for encrypting one cache slot. Implementations MUST bind [key] as
/// AAD. `Future`-valued so production can compute in an isolate (PERF-G9).
abstract class CacheCipher {
  /// Encrypts [plaintext] bound to [key] into [cacheCipherMagic] format.
  Future<String> encrypt(String key, String plaintext);

  /// Decrypts [armored] bound to [key]; throws on wrong key, slot or tag.
  Future<String> decrypt(String key, String armored);
}

/// PERF-B1: everything the wire format fixes, in ONE place, because there are
/// now THREE AES-256-GCM implementations under [CacheCipher] and the blobs they
/// write have to stay mutually readable: which one a start picks depends on
/// the platform, so the same install can encrypt with one and decrypt with the
/// other. Duplicating the framing per implementation is exactly how that
/// drifts.
///
/// Layout: `nonce ‖ ct ‖ tag`, base64, behind [cacheCipherMagic]. pointycastle
/// works on [sealed] (ct and tag in one buffer, the shape `process()` returns),
/// package:cryptography on [cipherText] and [tag] separately — the same bytes,
/// two views, which [secretBox] and [CacheCipherFrame.fromSecretBox] convert
/// between.
class CacheCipherFrame {
  const CacheCipherFrame(this.nonce, this.sealed);

  /// The package:cryptography view of a freshly sealed payload: its
  /// [SecretBox] keeps ciphertext and tag apart, the frame keeps them in one
  /// buffer. Copies, so the returned frame does not alias the box's internal
  /// key-stream buffer (which is longer than the ciphertext).
  factory CacheCipherFrame.fromSecretBox(Uint8List nonce, SecretBox box) {
    final ct = box.cipherText;
    final tag = box.mac.bytes;
    return CacheCipherFrame(
      nonce,
      Uint8List(ct.length + tag.length)
        ..setRange(0, ct.length, ct)
        ..setRange(ct.length, ct.length + tag.length, tag),
    );
  }

  /// AES-256.
  static const int dekLengthBytes = 32;

  /// 96-bit nonce, GCM's intended length; anything else is slower, not safer.
  static const int nonceLengthBytes = 12;

  /// 128-bit auth tag (full, not truncated).
  static const int tagLengthBits = 128;

  static const int tagLengthBytes = tagLengthBits ~/ 8;

  /// CSPRNG, backed by the OS on Android/iOS.
  static final Random _rng = Random.secure();

  final Uint8List nonce;

  /// Ciphertext followed by the auth tag, in that order.
  final Uint8List sealed;

  Uint8List get cipherText =>
      Uint8List.sublistView(sealed, 0, sealed.length - tagLengthBytes);

  Uint8List get tag =>
      Uint8List.sublistView(sealed, sealed.length - tagLengthBytes);

  /// The same bytes as [sealed], in the shape package:cryptography decrypts.
  /// Views, not copies: nothing downstream writes into them.
  SecretBox get secretBox => SecretBox(cipherText, nonce: nonce, mac: Mac(tag));

  /// The stored form. Concatenation order is part of the format.
  String get armored {
    final framed = Uint8List(nonce.length + sealed.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealed.length, sealed);
    return '$cacheCipherMagic${base64.encode(framed)}';
  }

  /// Splits a stored slot. Throws exactly the [FormatException]s the
  /// pointycastle-only version threw, since
  /// [EncryptedKeyValueStore._provesBrokenCiphertext] purges the slot on them.
  static CacheCipherFrame parse(String armored) {
    if (!armored.startsWith(cacheCipherMagic)) {
      throw const FormatException('Cache-Slot ohne EATOVA1-Magic');
    }
    // No ciphertext in the error text: base64's FormatException embeds its
    // source, which would reach the crash report.
    final Uint8List framed;
    try {
      framed = base64.decode(armored.substring(cacheCipherMagic.length));
    } on FormatException {
      throw const FormatException('Cache-Slot ist kein gueltiges base64');
    }
    if (framed.length < nonceLengthBytes + tagLengthBytes) {
      throw const FormatException('Cache-Slot zu kurz fuer nonce+tag');
    }
    return CacheCipherFrame(
      Uint8List.sublistView(framed, 0, nonceLengthBytes),
      Uint8List.fromList(framed.sublist(nonceLengthBytes)),
    );
  }

  /// 12 FRESH random bytes per encryption, never derived, never a counter:
  /// reuse under one GCM key leaks the authentication subkey.
  static Uint8List freshNonce() {
    final nonce = Uint8List(nonceLengthBytes);
    for (var i = 0; i < nonceLengthBytes; i++) {
      nonce[i] = _rng.nextInt(256);
    }
    return nonce;
  }

  /// AAD = the storage key, so moving a value to another slot or user
  /// namespace fails the tag check.
  static Uint8List associatedData(String key) => bytes(key);

  static Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
}

/// Transport object for the isolate hop: plain data only.
class _CipherJob {
  const _CipherJob(this.dek, this.key, this.payload);

  final Uint8List dek;
  final String key;
  final String payload;
}

/// PERF-B1: the cipher production uses — the OS one where it exists,
/// [AesGcmCacheCipher] everywhere else. The choice is invisible to callers:
/// every implementation writes [cacheCipherMagic] frames that the others read
/// (golden test `secure_cache_store_golden_test.dart`), so an install may
/// switch between them from one start to the next without touching its blobs.
///
/// PERF-B1b: the "everywhere else" branch is NOT the slow one any more —
/// [AesGcmCacheCipher] leads with package:cryptography's pure-Dart AES-GCM and
/// keeps pointycastle only as its last resort. See that class for the ladder.
CacheCipher createCacheCipher(Uint8List dek) =>
    PlatformAesGcmCacheCipher.isAvailable
        ? PlatformAesGcmCacheCipher(dek)
        : AesGcmCacheCipher(dek);

// `compute()` needs a top-level or static function, not a closure.
String _encryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.encryptSync(job.dek, job.key, job.payload);

String _decryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.decryptSync(job.dek, job.key, job.payload);

/// AES-256-GCM in pure Dart, using the DEK from [CacheKeyProvider]. The
/// MANDATORY implementation: desktop, the VM test environment and every device
/// whose plugin channel is missing run on it, and [PlatformAesGcmCacheCipher]
/// degrades into it.
///
/// PERF-B1b: two primitives, not one. B1 added `cryptography` as
/// `cryptography_flutter`'s base package but used only its OS route, so every
/// platform WITHOUT that channel kept paying pointycastle's pure-Dart round
/// loop — the original 91.5 ms problem, left standing on exactly the platforms
/// the fallback exists for. package:cryptography's own pure-Dart AES-GCM needs
/// no channel and does the same bytes ~13x faster (measured here on a 58 kB
/// blob, desktop JIT: 3.7 ms against 48.7 ms), so it leads.
///
/// pointycastle STAYS as the last resort, and not as dead weight: it is the
/// one primitive that cannot refuse the machine (package:cryptography's
/// AES-GCM throws on big-endian hosts outright), and it is what minted every
/// blob installed today.
class AesGcmCacheCipher implements CacheCipher {
  AesGcmCacheCipher(this._dek) {
    if (_dek.length != dekLengthBytes) {
      throw ArgumentError.value(
          _dek.length, 'dek', 'DEK muss genau $dekLengthBytes Bytes haben');
    }
  }

  /// AES-256. Format constants live on [CacheCipherFrame], which all cipher
  /// implementations share; these names stay as the established spelling.
  static const int dekLengthBytes = CacheCipherFrame.dekLengthBytes;

  static const int nonceLengthBytes = CacheCipherFrame.nonceLengthBytes;

  static const int tagLengthBits = CacheCipherFrame.tagLengthBits;

  /// PERF-B1b: payloads shorter than this are encrypted in the CALLER's stack
  /// instead of an isolate, because below it the hop costs more than the work
  /// it offloads.
  ///
  /// This is a CAP ON MAIN-THREAD WORK, not a guess. Measured here: the hop is
  /// a constant ~0.13 ms, the fast primitive does 58 kB in ~3.6 ms, i.e.
  /// ~0.13 ms per 2 kB — so anything under this bound costs the caller at most
  /// what the hop it replaces already cost, and PERF-G9 ("no crypto in the
  /// caller's stack") keeps its guarantee for every payload that could be
  /// felt. G9's original "it would win at no size" was measured against
  /// pointycastle at 0.29 ms for the smallest real slot; 13x faster inverts it.
  ///
  /// The same number the plugin picked independently:
  /// `FlutterCipher.defaultChannelPolicy` has `minLength: 2000` and routes
  /// everything below it to in-process pure-Dart AES-GCM. Pinned against the
  /// package in the tests, so the two ladders cannot silently split.
  ///
  /// Compared against `String.length` (UTF-16 code units, not bytes) on
  /// purpose: it is the free measure and the bound only has to hold to within
  /// a factor. Worst case is 3 UTF-8 bytes per code unit, so an all-umlaut
  /// slot at the limit is ~6 kB, still ~0.4 ms — a quarter frame, and the real
  /// slots are JSON with ASCII keys. For decrypt it is the ARMORED length,
  /// which is base64 and thus ~1.37x the plaintext: conservative in the right
  /// direction.
  @visibleForTesting
  static const int inlineMaxChars = 2000;

  final Uint8List _dek;

  /// Tier 2, memoized: the constructor reads `Endian.host` and throws on
  /// big-endian machines, which is a permanent property of the host — probing
  /// once turns that into a one-time cost instead of a throw per call.
  /// `null` = tier 2 unusable here, everything goes to pointycastle.
  static DartAesGcm? _dartGcm;
  static bool _dartGcmProbed = false;

  /// One log line per isolate for a tier-2 CALL that threw. Not a switch:
  /// see [_logDartFailure].
  static bool _dartGcmFailureLogged = false;

  static DartAesGcm? get _dartAlgorithm {
    if (_dartGcmProbed) return _dartGcm;
    _dartGcmProbed = true;
    try {
      _dartGcm = DartAesGcm.with256bits();
    } catch (e, s) {
      dev.log('AesGcmCacheCipher: DartAesGcm nicht baubar — pointycastle',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
    return _dartGcm;
  }

  /// Pins tier 2 (tests only). `null` forces the pointycastle tier; an
  /// instance that throws exercises the per-call degrade.
  @visibleForTesting
  static void debugSetDartAlgorithm(DartAesGcm? algorithm) {
    _dartGcm = algorithm;
    _dartGcmProbed = true;
    _dartGcmFailureLogged = false;
  }

  /// Restores the real probe (tests only).
  @visibleForTesting
  static void debugResetDartAlgorithm() {
    _dartGcm = null;
    _dartGcmProbed = false;
    _dartGcmFailureLogged = false;
  }

  @override
  Future<String> encrypt(String key, String plaintext) =>
      plaintext.length < inlineMaxChars
          // `Future.sync`, not a bare call: the seam's contract is
          // `Future`-valued and callers' ordering rests on awaiting it, so a
          // synchronous throw has to arrive as a rejected future like before.
          ? Future<String>.sync(() => encryptSync(_dek, key, plaintext))
          : compute(
              _encryptInIsolate,
              _CipherJob(_dek, key, plaintext),
              debugLabel: 'cache-encrypt',
            );

  @override
  Future<String> decrypt(String key, String armored) =>
      armored.length < inlineMaxChars
          ? Future<String>.sync(() => decryptSync(_dek, key, armored))
          : compute(
              _decryptInIsolate,
              _CipherJob(_dek, key, armored),
              debugLabel: 'cache-decrypt',
            );

  /// Pure, so it can run in the isolate; the golden blob pins the format.
  ///
  /// [nonce] exists for the golden test ONLY. Passing a repeated nonce under
  /// one DEK leaks GCM's authentication subkey, so production never supplies
  /// it and takes [CacheCipherFrame.freshNonce] instead.
  static String encryptSync(
    Uint8List dek,
    String key,
    String plaintext, {
    Uint8List? nonce,
  }) {
    final iv = nonce ?? CacheCipherFrame.freshNonce();
    final clear = CacheCipherFrame.bytes(plaintext);
    final aad = CacheCipherFrame.associatedData(key);

    final dart = _dartAlgorithm;
    if (dart != null) {
      try {
        return CacheCipherFrame.fromSecretBox(
          iv,
          dart.encryptSync(clear,
              secretKeyData: SecretKeyData(dek), nonce: iv, aad: aad),
        ).armored;
      } catch (e, s) {
        // Unlike the platform path, pointycastle may take the SAME [iv] here:
        // this tier is a pure in-process function, so a throw means nothing
        // was produced and exactly one ciphertext will ever exist under
        // (dek, iv). A channel can have emitted bytes we never saw, which is
        // why [PlatformAesGcmCacheCipher] mints a fresh nonce instead.
        _logDartFailure('encryptSync', e, s);
      }
    }
    return _pointyCastleEncrypt(dek, iv, aad, clear);
  }

  /// Counterpart to [encryptSync], likewise pure and isolate-safe.
  static String decryptSync(Uint8List dek, String key, String armored) {
    // Parse OUTSIDE every try: a FormatException is a verdict about the SLOT,
    // which [EncryptedKeyValueStore._provesBrokenCiphertext] purges on — never
    // a reason to ask the next tier the same question.
    final frame = CacheCipherFrame.parse(armored);
    final aad = CacheCipherFrame.associatedData(key);

    final dart = _dartAlgorithm;
    if (dart != null) {
      final List<int> clear;
      try {
        clear = dart.decryptSync(frame.secretBox,
            secretKeyData: SecretKeyData(dek), aad: aad);
      } on SecretBoxAuthenticationError {
        // Wrong DEK, wrong slot (AAD) or tampering: a verdict about the DATA,
        // so it must NOT fall through to pointycastle, which would spend
        // 48 ms reaching the same answer. Translated to pointycastle's type
        // and message because both `_provesBrokenCiphertext` and the Sentry
        // allowlist key off them.
        throw InvalidCipherTextException(_tagFailureMessage);
      } catch (e, s) {
        _logDartFailure('decryptSync', e, s);
        return _pointyCastleDecrypt(dek, frame, aad);
      }
      // Outside the try: invalid UTF-8 is a broken PLAINTEXT, not a broken
      // implementation, and must keep throwing FormatException rather than
      // sending the same bytes down the ladder again.
      return utf8.decode(clear);
    }
    return _pointyCastleDecrypt(dek, frame, aad);
  }

  /// Tier 3. Kept whole and separate, so the last resort stays exactly the
  /// code that minted every stored blob before B1b.
  static String _pointyCastleEncrypt(
      Uint8List dek, Uint8List iv, Uint8List aad, Uint8List clear) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
            KeyParameter(dek), CacheCipherFrame.tagLengthBits, iv, aad),
      );
    // For GCM, process() returns ciphertext ‖ tag.
    return CacheCipherFrame(iv, cipher.process(clear)).armored;
  }

  static String _pointyCastleDecrypt(
      Uint8List dek, CacheCipherFrame frame, Uint8List aad) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(dek), CacheCipherFrame.tagLengthBits,
            frame.nonce, aad),
      );
    // Tag mismatch = wrong DEK, wrong slot (AAD) or tampered blob; throws
    // InvalidCipherTextException itself.
    return utf8.decode(cipher.process(frame.sealed));
  }

  /// A tier-2 CALL threw for a reason that is not a verdict about the data.
  ///
  /// Deliberately NOT sticky, unlike the platform path: the only sticky cause
  /// (a host this primitive refuses) already throws in its constructor and is
  /// memoized by [_dartAlgorithm], so what reaches here is an anomaly such as
  /// memory pressure. Remembering it would drop the whole process to the 13x
  /// slower tier over one bad moment — the cost this class exists to remove.
  /// Logged once per isolate, because a repeated cause would repeat per call.
  static void _logDartFailure(String operation, Object error, StackTrace s) {
    if (_dartGcmFailureLogged) return;
    _dartGcmFailureLogged = true;
    dev.log(
        'AesGcmCacheCipher: $operation ueber DartAesGcm fehlgeschlagen — '
        'dieser Aufruf laeuft ueber pointycastle',
        error: error,
        stackTrace: s,
        name: 'secure_cache_store');
  }
}

/// PERF-B1: the same AES-256-GCM, but through the operating system's crypto
/// provider (javax.crypto on Android, CryptoKit on Apple), which uses the
/// ARMv8 AES instructions — tier 1 of three, the only one that is not a
/// software round loop, and the cache's dominant recurring CPU cost is exactly
/// that loop (91.5 ms for 210 meals on desktop JIT, mobile AOT 2-4x slower,
/// re-run on every meal mutation).
///
/// The plugin runs a ladder of its own: `FlutterCipher.defaultChannelPolicy`
/// keeps payloads under 2 kB out of the channel and answers them in process,
/// so tier 1 is really "the OS, for the payloads where crossing to it pays".
/// [AesGcmCacheCipher.inlineMaxChars] mirrors that same bound below.
///
/// A DROP-IN for [AesGcmCacheCipher], not a replacement: identical nonce
/// length, tag length, AAD, byte order and magic, all pinned by
/// `secure_cache_store_golden_test.dart`. Whichever wrote a slot, the others
/// read it.
///
/// EVERY failure that is not a statement about the ciphertext degrades to
/// [AesGcmCacheCipher] — for the next [platformRetryAfterCalls] calls, not
/// forever; see there.
class PlatformAesGcmCacheCipher implements CacheCipher {
  /// [algorithm] and [fallback] are seams for the golden test, which injects a
  /// second pure-Dart implementation to prove the two agree byte for byte
  /// without a platform channel.
  PlatformAesGcmCacheCipher(
    Uint8List dek, {
    AesGcm? algorithm,
    CacheCipher? fallback,
  })  : _secretKey = SecretKeyData(dek),
        _algorithm = algorithm ?? _platformAlgorithm,
        _fallback = fallback ?? AesGcmCacheCipher(dek);

  /// Review 2026-09-01 (L5): calls served from the fallback after a platform
  /// failure before the platform is tried again.
  ///
  /// The degrade used to be a ONE-WAY switch on an instance that lives as long
  /// as the process, so a single transient oddity sent every later cache read
  /// and write down the slow path for the rest of the session — precisely the
  /// cost this class exists to remove. A COUNT and not a clock, so the
  /// behaviour is deterministic and pinnable.
  ///
  /// 64 bounds the price in both directions: a channel that is really gone
  /// wastes at most one doomed call in 64 (~1.5 %, and a dead channel throws
  /// at once), while a channel that merely hiccupped is back on the fast path
  /// within one screen's worth of cache writes.
  @visibleForTesting
  static const int platformRetryAfterCalls = 64;

  final SecretKeyData _secretKey;

  /// null when the platform cipher could not even be BUILT. [createCacheCipher]
  /// never gets there, but a direct caller must not crash the cache over it —
  /// the instance then simply starts out degraded, permanently: a constructor
  /// that threw describes the build, not the moment.
  final AesGcm? _algorithm;
  final CacheCipher _fallback;

  /// Calls still owed to the fallback after a RUNTIME failure; 0 = the
  /// platform is in play. Counted down by [_takePlatformTurn].
  int _skipPlatformCalls = 0;

  /// One log line per instance, so a permanently dead channel does not write
  /// one every [platformRetryAfterCalls] calls.
  bool _degradeLogged = false;

  /// Whether THIS call goes to the platform, consuming one unit of the
  /// cooldown if not — so the retry lands exactly [platformRetryAfterCalls]
  /// calls after the failure.
  bool _takePlatformTurn() {
    if (_algorithm == null) return false;
    if (_skipPlatformCalls == 0) return true;
    _skipPlatformCalls--;
    return false;
  }

  static FlutterAesGcm? _platform;
  static bool _platformProbed = false;

  /// Built lazily and at most once: construction reaches into
  /// `defaultTargetPlatform` and the plugin registry.
  static FlutterAesGcm? get _platformAlgorithm {
    if (_platformProbed) return _platform;
    _platformProbed = true;
    try {
      _platform = FlutterAesGcm.with256bits();
    } catch (e, s) {
      dev.log('PlatformAesGcmCacheCipher: Plattform-Cipher nicht baubar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
    return _platform;
  }

  /// Whether the OS path is really reachable here — the plugin must be
  /// REGISTERED, not merely depended on, which is false in every VM test and
  /// on desktop. A throwing probe counts as unavailable: the cache has to boot
  /// either way.
  static bool get isAvailable {
    try {
      return _platformAlgorithm?.isSupportedPlatform ?? false;
    } catch (e, s) {
      dev.log('PlatformAesGcmCacheCipher: Plattform-Probe warf — Dart-Leiter',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return false;
    }
  }

  /// Clears the memoized platform probe (tests only).
  @visibleForTesting
  static void debugResetPlatformProbe() {
    _platform = null;
    _platformProbed = false;
  }

  /// Pins "the platform cipher could not even be BUILT" (tests only) — the
  /// probe then answers null and instances start out on the fallback for
  /// good. The only way to reach that branch without a broken plugin.
  @visibleForTesting
  static void debugMarkPlatformUnbuildable() {
    _platform = null;
    _platformProbed = true;
  }

  @override
  Future<String> encrypt(String key, String plaintext) =>
      encryptWithNonce(key, plaintext, CacheCipherFrame.freshNonce());

  /// [nonce] exists for the golden test ONLY — see
  /// [AesGcmCacheCipher.encryptSync] for why production never pins one.
  @visibleForTesting
  Future<String> encryptWithNonce(
      String key, String plaintext, Uint8List nonce) async {
    final algorithm = _algorithm;
    if (algorithm == null || !_takePlatformTurn()) {
      return _fallback.encrypt(key, plaintext);
    }
    final SecretBox box;
    try {
      box = await algorithm.encrypt(
        CacheCipherFrame.bytes(plaintext),
        secretKey: _secretKey,
        nonce: nonce,
        aad: CacheCipherFrame.associatedData(key),
      );
    } catch (e, s) {
      // The fallback mints its OWN nonce, which is the safe direction: the
      // request may have reached the OS and produced bytes we never saw, so
      // two implementations must never reuse one nonce under the same DEK.
      _degrade('encrypt', e, s);
      return _fallback.encrypt(key, plaintext);
    }
    return CacheCipherFrame.fromSecretBox(nonce, box).armored;
  }

  @override
  Future<String> decrypt(String key, String armored) async {
    // Parse OUTSIDE the try: a FormatException here is a verdict about the
    // SLOT, which [EncryptedKeyValueStore._provesBrokenCiphertext] purges on —
    // never a reason to degrade or to ask the next tier the same question.
    final frame = CacheCipherFrame.parse(armored);
    final algorithm = _algorithm;
    if (algorithm == null || !_takePlatformTurn()) {
      return _fallback.decrypt(key, armored);
    }

    final List<int> clear;
    try {
      clear = await algorithm.decrypt(
        frame.secretBox,
        secretKey: _secretKey,
        aad: CacheCipherFrame.associatedData(key),
      );
    } on SecretBoxAuthenticationError {
      // Wrong DEK, wrong slot (AAD) or tampering — a verdict about the DATA.
      // It must NOT degrade (the next tier would only reach the same answer)
      // and it MUST arrive as the same type the other tiers use: both
      // `_provesBrokenCiphertext` (purge or keep the slot) and the Sentry
      // allowlist key off `InvalidCipherTextException`.
      throw InvalidCipherTextException(_tagFailureMessage);
    } catch (e, s) {
      // Says nothing about the ciphertext (channel gone, plugin error, OOM):
      // answer from the fallback, exactly as if the platform path had never
      // been selected.
      _degrade('decrypt', e, s);
      return _fallback.decrypt(key, armored);
    }
    // Outside the try: invalid UTF-8 is a broken plaintext, not a broken
    // platform, and must keep throwing FormatException as before.
    return utf8.decode(clear);
  }

  /// Puts the platform path on the bench for [platformRetryAfterCalls] calls.
  /// Re-arms on every later failure, so a channel that is really gone stays
  /// off the hot path without ever being written off for the process.
  void _degrade(String operation, Object error, StackTrace s) {
    _skipPlatformCalls = platformRetryAfterCalls;
    if (_degradeLogged) return;
    _degradeLogged = true;
    dev.log(
        'PlatformAesGcmCacheCipher: $operation ueber die Plattform '
        'fehlgeschlagen — die naechsten $platformRetryAfterCalls Aufrufe '
        'laufen ueber den Fallback, danach ein neuer Versuch',
        error: error,
        stackTrace: s,
        name: 'secure_cache_store');
  }
}

/// Seam over the OS keystore, testable without a plugin channel.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production implementation: flutter_secure_storage.
class PluginSecureKeyStore implements SecureKeyStore {
  const PluginSecureKeyStore();

  // These options decide whether the DEK survives everyday device use.
  // Public because the session storage (C5) needs the same stance.
  static const AndroidOptions androidOptions = AndroidOptions(
    // SEC/A1: the 10.x default TRUE deletes the entry on any keystore error
    // and reports success, leaving Dart a `null` it cannot tell from a first
    // start — and the bootstrap then orphans every slot.
    resetOnError: false,
    // Otherwise plugin defaults: biometrics set
    // setUserAuthenticationRequired, letting a new fingerprint destroy the
    // cache, and the threat model is a device at rest.
  );

  /// `first_unlock` so lifecycle and notification paths can read the DEK
  /// after a reboot; `_this_device` keeps it off iCloud and other devices.
  /// PRICE, and the reason for the give-up logic in [CacheKeyProvider]: such
  /// items are excluded from every backup, so a restored device loses the DEK
  /// while the prefs travel along.
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

/// A1: plaintext marker "a DEK was already minted here", separating the two
/// states the keystore maps onto `null`: a fresh install (minting is right)
/// from a lost entry (minting destroys data). A claim about DURABILITY, not
/// integrity.
abstract class DekSentinelStore {
  Future<bool> isProvisioned();
  Future<void> markProvisioned();

  /// App starts that missed the DEK despite a set sentinel. 0 = no incident.
  Future<int> vanishStrikes();

  /// Sets the counter. `<= 0` removes the entry.
  Future<void> setVanishStrikes(int value);

  /// Records "cache abandoned" for the UI; consumed once by the caller.
  Future<void> raiseCacheResetNotice();

  /// See [CacheKeyProvider.plaintextMigrationClosedKey].
  Future<bool> isPlaintextMigrationClosed();

  /// Sets the marker. One-way, short of losing the blobs too.
  Future<void> closePlaintextMigration();
}

/// A1/iOS: lists the encrypted cache slots WITHOUT the DEK, so the bootstrap
/// can tell whether minting would orphan anything. Membership is decided by
/// [cacheCipherMagic] alone, never by key name.
abstract class CacheCiphertextProbe {
  /// Storage keys whose value starts with [cacheCipherMagic].
  Future<List<String>> encryptedKeys();

  /// Deletes EXACTLY [keys], only ever [encryptedKeys]' own result.
  Future<void> purge(Iterable<String> keys);
}

/// Production implementation: SharedPreferences.
class PrefsCacheCiphertextProbe implements CacheCiphertextProbe {
  const PrefsCacheCiphertextProbe();

  @override
  Future<List<String>> encryptedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      // `get`, not `getString`: the namespace also holds bool/int/List
      // values, on which `getString` throws.
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

/// W7a: lists slots that may still hold PLAINTEXT from an install predating
/// encryption, reading prefs directly because the slots nobody reads are the
/// sweep's point.
abstract class LegacyPlaintextProbe {
  /// Keys matching [isLegacyCacheSlotKey] with a non-empty, magic-less value.
  Future<List<String>> plaintextCacheKeys();
}

/// The `LocalCache` slot names, repeated as an allowlist: the same namespace
/// holds `locale`, `theme_mode` and `search_credentials`, read WITHOUT the
/// decorator, which a prefix-wide sweep would encrypt and destroy.
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

/// Whether [key] is a cache slot `eatova.v1.<slot>.<uid>`. Checks prefix and
/// slot name only; keys with fewer than four segments are control bits.
@visibleForTesting
bool isLegacyCacheSlotKey(String key) {
  final parts = key.split('.');
  if (parts.length < 4) return false;
  if (parts[0] != 'eatova' || parts[1] != 'v1') return false;
  return legacyCacheSlotNames.contains(parts[2]);
}

/// Production implementation: SharedPreferences.
class PrefsLegacyPlaintextProbe implements LegacyPlaintextProbe {
  const PrefsLegacyPlaintextProbe();

  @override
  Future<List<String>> plaintextCacheKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      if (!isLegacyCacheSlotKey(key)) continue;
      // `get`, not `getString`: the namespace also holds bool/int/List
      // values, on which `getString` throws.
      final value = prefs.get(key);
      if (value is! String || value.isEmpty) continue;
      if (value.startsWith(cacheCipherMagic)) continue;
      hits.add(key);
    }
    return hits;
  }
}

/// Production implementation: SharedPreferences, NOT the secure storage,
/// because the sentinel must survive the incident it reports and a
/// `deleteAll()` wipes that namespace. Prefs holds the blobs too, so the two
/// are lost only together — when a fresh DEK is correct again.
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
    // Store 0 as absence, not as a value: the normal case leaves no entry.
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

/// Crash-report object for a DEK that vanished despite a set sentinel.
class VanishedCacheKey implements Exception {
  const VanishedCacheKey({required this.strike, required this.budget});

  /// Which consecutive app start this was.
  final int strike;

  /// See [CacheKeyProvider.vanishStrikeBudget].
  final int budget;

  @override
  String toString() =>
      'VanishedCacheKey($strike/$budget): DEK fehlt trotz gesetztem Sentinel — '
      'Bootstrap abgebrochen statt neu gepraegt';
}

/// Crash-report object for a DEK READ that threw (see
/// [CacheKeyProvider._handleUnreadableDek]). Carries the error's runtime TYPE
/// only, never its message, which can hold the raw OS reason.
class UnreadableCacheKey implements Exception {
  const UnreadableCacheKey({
    required this.strike,
    required this.budget,
    required this.errorType,
  });

  /// Which consecutive app start without an available DEK this was.
  final int strike;

  /// See [CacheKeyProvider.vanishStrikeBudget].
  final int budget;

  /// Type name only, never the error text.
  final String errorType;

  @override
  String toString() =>
      'UnreadableCacheKey($strike/$budget): DEK-Read warf $errorType — '
      'Bootstrap abgebrochen, Key nicht ueberschrieben';
}

/// Crash-report object for a spent strike budget: the DEK counts as lost,
/// dead ciphertexts were purged and a fresh one minted. Where the app lands
/// after an iOS device restore.
class AbandonedCacheKey implements Exception {
  const AbandonedCacheKey({required this.purgedSlots, required this.budget});

  final int purgedSlots;
  final int budget;

  @override
  String toString() =>
      'AbandonedCacheKey: DEK nach $budget Starts als verloren behandelt — '
      '$purgedSlots tote Slots geraeumt, frischer DEK gepraegt';
}

/// Bootstrap of the data encryption key (DEK) — memoized and single-flight.
class CacheKeyProvider {
  const CacheKeyProvider._();

  /// ONE app-wide DEK: keys are already namespaced per user and the threat
  /// model is device-level extraction, so a per-user key would only add a
  /// bootstrap per login switch.
  static const String dekStorageKey = 'eatova.v1.cache_dek';

  /// A1 sentinel; in SharedPreferences, see [PrefsDekSentinelStore].
  static const String dekProvisionedKey = 'eatova.v1.dek_provisioned';

  /// App starts without an available DEK, missing or unreadable; both end in
  /// the same dead end, so they share counter and budget.
  static const String dekVanishStrikesKey = 'eatova.v1.dek_vanish_strikes';

  /// UI flag, read and cleared by [consumeCacheResetNotice].
  static const String cacheResetNoticeKey = 'eatova.v1.cache_reset_notice';

  /// SEC/W7a: marker "the plaintext migration path is closed". Without it a
  /// magic-less slot would count as migratable legacy forever; after it, it
  /// is dropped and reported. It bounds that path and provides NO integrity,
  /// sharing a prefs file with the slots it guards.
  ///
  /// SET ONLY AFTER THE SWEEP ([EncryptedKeyValueStore.migrateAllLegacySlots])
  /// and only if every found slot is then verifiably encrypted. Never
  /// alongside the sentinel, which is GLOBAL while slots are PER UID: user
  /// A's bootstrap would close the path before B's slots were read.
  static const String plaintextMigrationClosedKey =
      'eatova.v1.cache_plaintext_migrated';

  /// Consecutive aborts before the DEK counts as permanently lost; the same
  /// budget covers [_handleUnreadableDek]. 3 and not 1 because "a `null` is
  /// definitive" rests on plugin sources, not a law of nature, and the budget
  /// costs two cold starts against a purged outbox blob.
  static const int vanishStrikeBudget = 3;

  /// Memoized bootstrap; MUST be assigned synchronously, see [obtain].
  static Future<Uint8List?>? _pending;

  /// A strike is an APP START, not an [obtain] call: `LocalCache.create` runs
  /// from boot and logout, so one session would spend the whole budget.
  static bool _vanishStrikeCounted = false;

  /// The plaintext marker BEFORE this process's bootstrap; fail-closed.
  static bool _legacyPlaintextAccepted = false;

  /// Whether this app start may still adopt legacy plaintext, deciding both
  /// the sweep and per-slot migration. The snapshot predates the sweep, so
  /// the migrating run sees `true`.
  static bool get legacyPlaintextAccepted => _legacyPlaintextAccepted;

  /// Returns the DEK (32 bytes), or null if it could be neither read nor
  /// created. SINGLE-FLIGHT, not optional: boot and logout both reach
  /// `LocalCache.create` and can overlap, and two unmemoized bootstraps would
  /// each mint a DEK, the second silently orphaning the first's writes.
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
    // A FAILED bootstrap is not memoized, or one transient error would kill
    // the cache for the process. Race-free: nothing was written.
    unawaited(started.then((dek) {
      if (dek == null && identical(_pending, started)) _pending = null;
    }, onError: (_, __) {
      if (identical(_pending, started)) _pending = null;
    }));
    return started;
  }

  /// Reads and clears the "cache abandoned" notice; the caller shows it once.
  ///
  /// WIRED UP: `HomeStore._hydrateThenBoot` (home_store.dart) is the sole
  /// consumer. It calls this unawaited during boot and emits a snack, so a
  /// silent fresh start does not leave the user believing the offline diary is
  /// still there. Reading clears the flag, hence exactly one showing.
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

  /// Resets the memoization and per-process strike (tests only).
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
    // The pre-sweep state governs this start, which closes the marker itself.
    _legacyPlaintextAccepted = !await _plaintextMigrationClosed(sentinel);

    final String? stored;
    try {
      stored = await keyStore.read(dekStorageKey);
    } catch (e, s) {
      // A FAILED read is not "no key there": minting would overwrite a merely
      // unreadable DEK and orphan the cache.
      dev.log('CacheKeyProvider: DEK-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return _handleUnreadableDek(keyStore, sentinel, probe, e);
    }

    if (stored != null && stored.isNotEmpty) {
      final decoded = _tryDecodeDek(stored);
      if (decoded != null) {
        // Bring installs predating the sentinel in line, since it would
        // otherwise wait for a never-happening first mint.
        await _markProvisioned(sentinel);
        // Without this reset, independent glitches would accumulate.
        await _clearVanishStrikes(sentinel);
        return decoded;
      }
      // A structurally broken DEK: its data is lost anyway, so minting heals
      // the app. The sentinel does not apply, the key is here.
      dev.log('CacheKeyProvider: DEK-Eintrag korrupt, wird neu erzeugt',
          name: 'secure_cache_store');
    } else if (await _wasProvisioned(sentinel)) {
      // A1: "no key" although one was minted here — abort only if something
      // could be orphaned.
      if (!await _mayMintAfterVanishedDek(sentinel, probe)) return null;
    }

    return _mintFreshDek(keyStore, sentinel);
  }

  /// Mints and stores a fresh DEK. null = not storable, so no cache this
  /// session.
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
      // NEVER fall back to plaintext: it would work while falsifying the
      // compliance claim.
      return null;
    }
    // ORDER: DEK first — a failed write would otherwise leave a sentinel
    // without a key and abort every future start.
    await _markProvisioned(sentinel);
    return fresh;
  }

  /// Handles "the DEK read THREW", where unlike [_mayMintAfterVanishedDek] it
  /// is UNKNOWN whether a key still exists, so the response is to retry — but
  /// a damaged wrapping key throws on EVERY start, so it shares budget and
  /// counter with [vanishStrikeBudget]. ORDER when giving up is the opposite
  /// of the vanish path: mint FIRST, then purge.
  static Future<Uint8List?> _handleUnreadableDek(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
    Object error,
  ) async {
    final int? strike = await _recordVanishStrike(sentinel);
    // Already decided in this process; `create` runs from boot AND logout.
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

    // The old key is replaced, so its data is unreadable for good. Purge:
    // `_onUndecryptable` only catches the CURRENT user's slots.
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

  /// Handles "sentinel set, but the keystore has no DEK"; `true` = mint.
  /// With no `EATOVA1:` slot there is nothing to orphan, so mint at once; with
  /// slots present (the iOS restore case) they are permanently undecryptable
  /// and only block the cache, so that case aborts but COUNTS and after
  /// [vanishStrikeBudget] purges, mints and leaves a notice.
  static Future<bool> _mayMintAfterVanishedDek(
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
  ) async {
    // null = probe unusable. FAIL CLOSED: unknown means "blobs present".
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
    // Already decided in this process: do not count or report twice.
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

    // Budget spent. Purge actively, since `_onUndecryptable` only catches
    // the current user's slots.
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

  /// Increments the strike counter once per process; null if already done.
  static Future<int?> _recordVanishStrike(DekSentinelStore sentinel) async {
    if (_vanishStrikeCounted) return null;
    _vanishStrikeCounted = true;
    final int next = await _vanishStrikes(sentinel) + 1;
    await _setVanishStrikes(sentinel, next);
    return next;
  }

  /// Determines the encrypted slots. null = could not be determined.
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
      // Harmless: leftovers hit `_onUndecryptable` on the next read.
      dev.log('CacheKeyProvider: Purge toter Slots fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Reads the strike counter; 0 on error, which stalls the budget but only
  /// when prefs are broken as a whole, where the blobs live too.
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

  /// Only writes when there is something to clear, since the success path
  /// runs through here on every cold start.
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

  /// Reads the sentinel, FAIL CLOSED: not knowing whether a DEK ever existed
  /// forbids minting one. Costs a session without cache, not data.
  static Future<bool> _wasProvisioned(DekSentinelStore sentinel) async {
    try {
      return await sentinel.isProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Read fehlgeschlagen — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return true;
    }
  }

  /// Reads the marker, FAIL CLOSED: not knowing whether the migration ran
  /// forbids adopting plaintext, and a failed prefs read means there is none.
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

  /// Best effort: a failed write degrades to "next keystore reset mints
  /// fresh". The plaintext marker does NOT ride along, being global while
  /// slots are per uid ([plaintextMigrationClosedKey]).
  static Future<void> _markProvisioned(DekSentinelStore sentinel) async {
    try {
      await sentinel.markProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Closes the plaintext path; only called by
  /// [EncryptedKeyValueStore.migrateAllLegacySlots] once nothing is left to
  /// inherit. Best effort — the sweep is idempotent.
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

/// Decorator over a [KeyValueStore]: writes encrypted only, reads encrypted
/// AND (migrating once) plaintext. Sits BELOW [LocalCache], wired only in
/// `LocalCache.create`, so the cache and its serializers stay unchanged.
class EncryptedKeyValueStore implements KeyValueStore, RawSlotProbe {
  /// [acceptLegacyPlaintext] is the migration path from
  /// [CacheKeyProvider.plaintextMigrationClosedKey]. `true` by default, since
  /// production only builds via [create].
  EncryptedKeyValueStore(this._inner, this._cipher,
      {bool acceptLegacyPlaintext = true})
      : _acceptLegacyPlaintext = acceptLegacyPlaintext;

  final KeyValueStore _inner;
  final CacheCipher _cipher;
  final bool _acceptLegacyPlaintext;

  /// Reported once per process: a broken DEK makes every slot unreadable.
  static bool _undecryptableReported = false;

  /// SEC: own one-shot flag for [ExpiredPlaintextCacheSlot], the last signal
  /// against write access; a shared one a broken ciphertext could silence.
  static bool _expiredPlaintextReported = false;

  /// Third one-shot flag: reads that fail at EXECUTING the decryption, not
  /// at the ciphertext — opposite reactions, so a separate flag.
  static bool _cipherUnavailableReported = false;

  /// Resets all one-shot flags (tests only), which are per process.
  @visibleForTesting
  static void debugResetReportGuards() {
    _undecryptableReported = false;
    _expiredPlaintextReported = false;
    _cipherUnavailableReported = false;
  }

  /// Builds the decorator on the OS-keystore DEK; null means the app runs
  /// without cache. NO plaintext fallback.
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
      // PERF-B1: OS cipher where the plugin is registered, pure Dart
      // otherwise. Every tier writes the same frame, so the pick is per start
      // and needs no migration.
      createCacheCipher(dek),
      acceptLegacyPlaintext: CacheKeyProvider.legacyPlaintextAccepted,
    );
    // W7a: the sweep runs BEFORE returning, so no caller gets a store stuck
    // mid-migration. One prefs pass while the marker is open.
    if (CacheKeyProvider.legacyPlaintextAccepted) {
      await store.migrateAllLegacySlots(
        legacyProbe ?? const PrefsLegacyPlaintextProbe(),
        sentinelStore ?? const PrefsDekSentinelStore(),
      );
    }
    return store;
  }

  /// PERF-G9: with encryption in an isolate, overlapping writes to the SAME
  /// slot could land in reverse order. Serialized PER KEY only.
  final Map<String, Future<void>> _writeQueue = <String, Future<void>>{};

  /// Keys whose LAST read failed at executing the decryption (P3-02c).
  ///
  /// Cleared by every read that hands a value over, by the purge path (the
  /// slot is gone then) and by every write. It is the one thing only this
  /// class knows: from the outside a transient failure and a decrypted-but-
  /// unusable value are both `null`.
  final Set<String> _cipherUnavailableKeys = <String>{};

  @override
  Future<String?> getString(String key) async {
    final raw = await _inner.getString(key);
    if (raw == null || raw.isEmpty) {
      _cipherUnavailableKeys.remove(key);
      return null;
    }

    if (raw.startsWith(cacheCipherMagic)) {
      try {
        final plaintext = await _cipher.decrypt(key, raw);
        _cipherUnavailableKeys.remove(key);
        return plaintext;
      } catch (e, s) {
        // Not every throw is a statement ABOUT THE SLOT, so
        // [_provesBrokenCiphertext] decides whether to purge.
        if (_provesBrokenCiphertext(e)) {
          _cipherUnavailableKeys.remove(key);
          await _onUndecryptable(key, e, s);
        } else {
          _cipherUnavailableKeys.add(key);
          _onCipherUnavailable(key, e, s);
        }
        return null;
      }
    }
    _cipherUnavailableKeys.remove(key);

    // After the migration a magic-less slot has neither tag nor AAD: same
    // path as a broken ciphertext.
    if (!_acceptLegacyPlaintext) {
      await _onUndecryptable(
          key, const ExpiredPlaintextCacheSlot(), StackTrace.current);
      return null;
    }

    // Legacy plaintext: [migrateAllLegacySlots] handles what existed at
    // start, this branch what appears during it.
    try {
      await _migrateLegacyPlaintext(key, raw);
    } catch (e) {
      // A migration failure degrades to "stays plaintext, next read retries",
      // never to a lost read; setString is atomic per key.
      dev.log('EncryptedKeyValueStore: Migration fehlgeschlagen ($key)',
          error: e, name: 'secure_cache_store');
    }
    return raw;
  }

  /// P3-02: whether the slot still HOLDS bytes — no cipher, no purge, no
  /// report.
  ///
  /// [getString] cannot answer this: it returns `null` both for an empty slot
  /// and for one whose decryption was not executable ([_onCipherUnavailable]
  /// leaves that slot in place on purpose). The `OrThrow` readers in
  /// [LocalCache] need the difference, or an unreadable outbox counts as empty
  /// and the next write overwrites it.
  ///
  /// P3-02c: an occupied slot additionally reports WHY the read failed, taken
  /// from [_cipherUnavailableKeys] rather than from a fresh decryption
  /// attempt. A fresh attempt would answer the wrong question — memory
  /// pressure that has eased since would make the slot look readable and thus
  /// permanently broken, exactly backwards.
  ///
  /// A failing inner read propagates: "cannot say" must not become "empty".
  @override
  Future<RawSlotState> rawSlotState(String key) async {
    final raw = await _inner.getString(key);
    if (raw == null || raw.isEmpty) return RawSlotState.empty;
    return _cipherUnavailableKeys.contains(key)
        ? RawSlotState.unreadableForNow
        // The last read handed the value over (or none has run): whatever the
        // caller stumbled over sits in the CONTENT, and re-reading it produces
        // the same bytes.
        : RawSlotState.brokenContent;
  }

  /// W7a: adopts ALL inherited plaintext slots, then closes the migration
  /// path ([CacheKeyProvider.plaintextMigrationClosedKey]).
  ///
  /// A sweep, not a marker PER UID: this file does not know the uid, only a
  /// read reveals plaintext (and some slots are never read), and a uid that
  /// never returns would keep the path open forever. PRICE: a PLANTED slot is
  /// adopted too, since inherited plaintext has no signature.
  Future<void> migrateAllLegacySlots(
      LegacyPlaintextProbe probe, DekSentinelStore sentinel) async {
    final List<String> keys;
    try {
      keys = await probe.plaintextCacheKeys();
    } catch (e, s) {
      // Do NOT set the marker: without enumeration there is no telling what
      // was left to inherit. The next start retries.
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
      // A regular write may have run between enumeration and read.
      if (raw == null || raw.isEmpty || raw.startsWith(cacheCipherMagic)) {
        continue;
      }
      try {
        await _migrateLegacyPlaintext(key, raw);
        // Verify: the marker is one-way, and a silently failed write would
        // tip the slot into the drop path next start.
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

  /// Writes a magic-less value back encrypted; throws on failure.
  Future<void> _migrateLegacyPlaintext(String key, String raw) =>
      _enqueueWrite(key, () async {
        // The isolate hop lets a regular setString rewrite the slot first;
        // the stale plaintext must not win.
        if (await _inner.getString(key) != raw) return;
        await _inner.setString(key, await _cipher.encrypt(key, raw));
      });

  @override
  Future<void> setString(String key, String value) =>
      _enqueueWrite(key, () async {
        await _inner.setString(key, await _cipher.encrypt(key, value));
      });

  /// Appends [task] to the chain for [key]. A predecessor's failure reaches
  /// its own caller but does NOT block successors, which one plugin error
  /// would otherwise stall for the process.
  Future<void> _enqueueWrite(String key, Future<void> Function() task) {
    // Any write (or remove) replaces what the last read stumbled over, so its
    // verdict no longer describes this slot (P3-02c).
    _cipherUnavailableKeys.remove(key);
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

  /// Runs on the SAME chain as [setString], or a `remove` could overtake an
  /// encryption in the isolate and the value reappear — at
  /// `LocalCache.clear()`, PII surviving logout.
  @override
  Future<void> remove(String key) => _enqueueWrite(key, () => _inner.remove(key));

  /// Whether [error] PROVES a ciphertext or format problem — only then may
  /// the slot be purged. Both types are raised ONLY as a verdict about the
  /// stored bytes, by every cipher tier alike (that is why each one translates
  /// its own tag failure into `InvalidCipherTextException`), and that verdict
  /// is permanent. Any OTHER error is transport (a failed isolate spawn, a
  /// dead plugin channel), which says nothing about the ciphertext, so
  /// deleting on it destroys readable data.
  static bool _provesBrokenCiphertext(Object error) =>
      error is InvalidCipherTextException || error is FormatException;

  /// The read failed through no fault of the slot (see
  /// [_provesBrokenCiphertext]), so the slot STAYS and the caller gets `null`.
  /// Same error type as the purge path but its own context tag, because
  /// `crash_reporter.dart` allowlists it by type name.
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

  /// A slot is provably undecryptable (invalidated keystore key, restored
  /// backup, tampering) or lost its magic after the migration closed — ONLY
  /// these cases, see [_provesBrokenCiphertext]. Purges PER KEY.
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
    // Error type and key name ONLY: a raw error message can carry the
    // ciphertext.
    final sanitized = UndecryptableCacheSlot(
      errorType: error is InvalidCipherTextException
          ? 'InvalidCipherTextException'
          : error.runtimeType.toString(),
      storageKey: redactUserSegment(key),
    );
    unawaited(CrashReporter.capture(sanitized, s, context: 'cache_decrypt'));
  }
}

/// Replaces the user segment of `eatova.v1.<slot>.<userId>` before the key
/// enters a crash report: the slot is the diagnostic value, the UUID a stable
/// user identifier. Keys with &lt;= 3 parts are unchanged.
@visibleForTesting
String redactUserSegment(String key) {
  final parts = key.split('.');
  if (parts.length <= 3) return key;
  return '${parts.sublist(0, parts.length - 1).join('.')}.<uid>';
}

/// A slot without [cacheCipherMagic] after the migration closed. Its own
/// type, not a FormatException, so the crash report can tell it from a broken
/// ciphertext: the only case here hinting at outside WRITE access.
class ExpiredPlaintextCacheSlot implements Exception {
  const ExpiredPlaintextCacheSlot();

  @override
  String toString() => 'ExpiredPlaintextCacheSlot: Klartext-Slot nach '
      'abgeschlossener Migration — verworfen statt uebernommen';
}

/// Crash-report object carrying error type and slot name only.
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
