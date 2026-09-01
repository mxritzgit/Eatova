// PERF-B1: the cache cipher gained a SECOND implementation — AES-256-GCM
// through the OS provider (javax.crypto / CryptoKit) instead of pointycastle's
// pure-Dart round loop, which costs 91.5 ms per 210 meals on desktop JIT and
// 2-4x that under mobile AOT, on every meal mutation.
//
// The pick is per app start and per platform, so the SAME install can encrypt
// a slot with one implementation and read it back with the other. This file is
// the proof that this is safe:
//
//   1. a fixed DEK + fixed nonce + fixed plaintext yields a byte-exact,
//      hard-coded blob — from BOTH implementations,
//   2. each implementation decrypts what the other wrote, in both directions,
//   3. a blob written by the version BEFORE this change still decrypts,
//   4. the failure semantics are unchanged: a bad tag arrives as
//      InvalidCipherTextException (which purges the slot), a broken frame as
//      FormatException, and anything else degrades silently to pointycastle.
//
// The platform channel does not exist in the VM test environment, so
// [PlatformAesGcmCacheCipher] gets its algorithm INJECTED here: DartAesGcm
// from package:cryptography. That is still a genuinely different AES-GCM
// implementation from pointycastle, and it runs the exact framing, AAD, nonce
// and tag-splitting code the platform path uses — only the primitive
// underneath is swapped, and the primitive is pinned by the golden vector.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Same 32 bytes as `secure_cache_store_test.dart`, so the old golden blob
/// below stays valid.
final Uint8List _dek = Uint8List.fromList(
  List<int>.generate(
      CacheCipherFrame.dekLengthBytes, (i) => (i * 7 + 11) & 0xFF),
);

/// PINNED, never random: a golden vector needs a fixed nonce. Production never
/// pins one — see [CacheCipherFrame.freshNonce].
final Uint8List _nonce = Uint8List.fromList(
  List<int>.generate(CacheCipherFrame.nonceLengthBytes, (i) => 0xA0 + i),
);

const String _goldenKey = 'eatova.v1.logged_meals.user-1';

/// Non-ASCII on purpose: it pins UTF-8 as the plaintext encoding.
const String _goldenPlaintext =
    '{"items":[{"id":"m-1","name":"Döner Teller","kcal":820,"note":"süß"}]}';

/// THE wire format. `"EATOVA1:" + base64(nonce ‖ ct ‖ tag)`, AAD = the slot
/// key. If a change makes this string move, every installed app loses its
/// offline diary — that is what this constant is here to stop.
///
/// Derived from the four fixtures above as
/// `AesGcmCacheCipher.encryptSync(_dek, _goldenKey, _goldenPlaintext,
/// nonce: _nonce)`. No generator script is needed to regenerate it: the first
/// two tests recompute it from exactly those inputs, once per implementation,
/// so a mismatch prints the current value next to this literal. Only ever
/// replace it when the format change is deliberate AND a migration exists.
const String _goldenBlob = 'EATOVA1:oKGio6SlpqeoqaqraH8NwkoYHjPagVxGfcc/8M0b'
    'F3Zp9DevkMLKfEpQrXTcqNtH5Dz6S98uFCBrrP7YTJjmhSNUdZi9tdAznZd/UQ4Hu4UZKF0N'
    'gPXYvNk3OPNF7Tn8BNFNNFw=';

/// Written by the pointycastle-only version, BEFORE B1 and before the
/// compute() rewrite. Same DEK, slot `eatova.v1.profile.user-1`.
const String _altBlob = 'EATOVA1:XVBMN7A2JEKw9nyL7fLgHj53HpbeXoMtRyx6d/Nl5ATL'
    '9MlrwKDsaeDUxBqzt/UPSleFveICKMU0kyb2O8elPdCIDEXWtgUPLFENVkD7EyfUyPG3R+'
    'LwSA==';

const String _altKey = 'eatova.v1.profile.user-1';

const String _altPlaintext =
    '{"weight_kg":82,"height_cm":181,"age_years":34,"sex":"male"}';

/// The platform cipher with a pure-Dart primitive injected, so the codec runs
/// without a plugin channel.
PlatformAesGcmCacheCipher _platformCodec({Uint8List? dek, AesGcm? algorithm}) =>
    PlatformAesGcmCacheCipher(dek ?? _dek,
        algorithm: algorithm ?? DartAesGcm.with256bits());

/// The NON-PLATFORM cipher.
///
/// Named `_pointyCastle` before the tiering of 2026-09-01; since then
/// [AesGcmCacheCipher] leads with `DartAesGcm` and falls back to pointycastle,
/// so this returns "whichever software tier is in charge" — which is exactly
/// what these tests want to pin against the platform path. Real tier 3 is
/// exercised explicitly in `secure_cache_store_tiers_test.dart` via
/// `debugSetDartAlgorithm(null)`.
AesGcmCacheCipher _softwareCipher({Uint8List? dek}) =>
    AesGcmCacheCipher(dek ?? _dek);

// ---------------------------------------------------------------------------
// Test doubles for the degradation paths
// ---------------------------------------------------------------------------

/// An algorithm that always throws something that is NOT a verdict about the
/// ciphertext — a dead method channel, in other words.
class _KaputteAesGcm implements AesGcm {
  @override
  Future<SecretBox> encrypt(List<int> clearText,
          {required SecretKey secretKey,
          List<int>? nonce,
          List<int> aad = const <int>[],
          Uint8List? possibleBuffer}) async =>
      throw StateError('MissingPluginException(No implementation found)');

  @override
  Future<List<int>> decrypt(SecretBox secretBox,
          {required SecretKey secretKey,
          List<int> aad = const <int>[],
          Uint8List? possibleBuffer}) async =>
      throw StateError('MissingPluginException(No implementation found)');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Delegates to a real implementation and counts how often it was actually
/// asked — the only way to observe that an instance did NOT degrade.
class _ZaehlendeAesGcm implements AesGcm {
  _ZaehlendeAesGcm(this._inner);

  final AesGcm _inner;
  int encrypts = 0;
  int decrypts = 0;

  @override
  Future<SecretBox> encrypt(List<int> clearText,
      {required SecretKey secretKey,
      List<int>? nonce,
      List<int> aad = const <int>[],
      Uint8List? possibleBuffer}) {
    encrypts++;
    return _inner.encrypt(clearText,
        secretKey: secretKey, nonce: nonce, aad: aad);
  }

  @override
  Future<List<int>> decrypt(SecretBox secretBox,
      {required SecretKey secretKey,
      List<int> aad = const <int>[],
      Uint8List? possibleBuffer}) {
    decrypts++;
    return _inner.decrypt(secretBox, secretKey: secretKey, aad: aad);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // -------------------------------------------------------------------------
  // 1. The golden vector
  // -------------------------------------------------------------------------
  group('Golden-Blob (fester DEK, feste Nonce, fester Klartext)', () {
    test('der Software-Pfad erzeugt exakt den festgeschriebenen Blob', () {
      expect(
        AesGcmCacheCipher.encryptSync(_dek, _goldenKey, _goldenPlaintext,
            nonce: _nonce),
        _goldenBlob,
      );
    });

    test('der Plattform-Codec erzeugt BYTE-IDENTISCH denselben Blob', () async {
      expect(
        await _platformCodec()
            .encryptWithNonce(_goldenKey, _goldenPlaintext, _nonce),
        _goldenBlob,
      );
    });

    test('der Blob traegt Magic, 12-Byte-Nonce und 16-Byte-Tag', () {
      expect(_goldenBlob, startsWith(cacheCipherMagic));
      final frame = CacheCipherFrame.parse(_goldenBlob);
      expect(frame.nonce, _nonce);
      expect(frame.nonce, hasLength(12));
      expect(frame.tag, hasLength(16));
      // GCM is a stream mode: the ciphertext is exactly as long as the UTF-8
      // plaintext, so nothing padded or truncated the payload.
      expect(frame.cipherText, hasLength(utf8.encode(_goldenPlaintext).length));
      expect(
          frame.sealed, hasLength(frame.cipherText.length + frame.tag.length));
    });

    test('beide Implementierungen lesen den festgeschriebenen Blob', () async {
      expect(await _softwareCipher().decrypt(_goldenKey, _goldenBlob),
          _goldenPlaintext);
      expect(await _platformCodec().decrypt(_goldenKey, _goldenBlob),
          _goldenPlaintext);
    });

    test(
        'auch OHNE Injektion — das ECHTE FlutterAesGcm, das auf dem Geraet '
        'laeuft, erzeugt und liest denselben Blob', () async {
      // Construction needs no channel, only `isSupportedPlatform` does; here
      // the object routes internally to its own Dart fallback. Das prueft den
      // Produktions-Objektgraphen statt einer Testattrappe.
      PlatformAesGcmCacheCipher.debugResetPlatformProbe();
      final echt = PlatformAesGcmCacheCipher(_dek);

      expect(await echt.encryptWithNonce(_goldenKey, _goldenPlaintext, _nonce),
          _goldenBlob);
      expect(await echt.decrypt(_goldenKey, _goldenBlob), _goldenPlaintext);
    });
  });

  // -------------------------------------------------------------------------
  // 2. Cross-compatibility in BOTH directions
  // -------------------------------------------------------------------------
  group('Kreuz-Kompatibilitaet der beiden Implementierungen', () {
    test('der Software-Pfad liest, was der Plattform-Pfad geschrieben hat',
        () async {
      final geschrieben =
          await _platformCodec().encrypt(_goldenKey, _goldenPlaintext);
      expect(await _softwareCipher().decrypt(_goldenKey, geschrieben),
          _goldenPlaintext);
    });

    test('der Plattform-Pfad liest, was der Software-Pfad geschrieben hat',
        () async {
      final geschrieben =
          await _softwareCipher().encrypt(_goldenKey, _goldenPlaintext);
      expect(await _platformCodec().decrypt(_goldenKey, geschrieben),
          _goldenPlaintext);
    });

    test(
        'mit ECHTEN Zufalls-Nonces, mehrfach — die Nonce liegt im Blob und '
        'muss aus dem fremden Rahmen gelesen werden', () async {
      final plattform = _platformCodec();
      final pointy = _softwareCipher();
      final blobs = <String>{};
      for (var i = 0; i < 5; i++) {
        final a = await plattform.encrypt(_goldenKey, 'runde-$i');
        final b = await pointy.encrypt(_goldenKey, 'runde-$i');
        blobs.addAll(<String>[a, b]);
        expect(await pointy.decrypt(_goldenKey, a), 'runde-$i');
        expect(await plattform.decrypt(_goldenKey, b), 'runde-$i');
      }
      // 10 Blobs, 10 verschiedene Nonces: keine Wiederverwendung.
      expect(blobs, hasLength(10));
    });

    test('leerer Klartext: der Rahmen besteht nur aus Nonce und Tag', () async {
      final leer = await _platformCodec().encrypt(_goldenKey, '');
      final frame = CacheCipherFrame.parse(leer);
      expect(frame.cipherText, isEmpty);
      expect(frame.sealed, hasLength(CacheCipherFrame.tagLengthBytes));
      expect(await _softwareCipher().decrypt(_goldenKey, leer), '');
      expect(await _platformCodec().decrypt(_goldenKey, leer), '');
    });

    test('grosser Blob (~200 kB) kreuzt in beide Richtungen', () async {
      final gross = jsonEncode({'items': List<String>.filled(4000, 'Döner')});
      final vonPlattform = await _platformCodec().encrypt(_goldenKey, gross);
      final vonPointy = await _softwareCipher().encrypt(_goldenKey, gross);
      expect(await _softwareCipher().decrypt(_goldenKey, vonPlattform), gross);
      expect(await _platformCodec().decrypt(_goldenKey, vonPointy), gross);
    });
  });

  // -------------------------------------------------------------------------
  // 3. The blob from the version before this change
  // -------------------------------------------------------------------------
  group('Bestandsdaten', () {
    test('ein Blob aus der Fassung VOR B1 bleibt in beiden Pfaden lesbar',
        () async {
      expect(await _softwareCipher().decrypt(_altKey, _altBlob), _altPlaintext);
      expect(await _platformCodec().decrypt(_altKey, _altBlob), _altPlaintext);
    });

    test('die AAD-Bindung des Alt-Blobs gilt auch im Plattform-Pfad', () async {
      // Same ciphertext, foreign slot: the tag check must fail.
      await expectLater(
          () async =>
              _platformCodec().decrypt('eatova.v1.profile.user-2', _altBlob),
          throwsA(isA<InvalidCipherTextException>()));
    });
  });

  // -------------------------------------------------------------------------
  // 4. Failure semantics — unchanged, because EncryptedKeyValueStore decides
  //    purge-or-keep by exception TYPE.
  // -------------------------------------------------------------------------
  group('Fehlersemantik bleibt', () {
    test(
        'falscher DEK wirft InvalidCipherTextException, NICHT '
        'SecretBoxAuthenticationError', () async {
      final fremd = Uint8List.fromList(
          List<int>.filled(CacheCipherFrame.dekLengthBytes, 9));
      await expectLater(
        () async => _platformCodec(dek: fremd).decrypt(_goldenKey, _goldenBlob),
        throwsA(isA<InvalidCipherTextException>()),
      );
      // Die Meldung ist wortgleich mit pointycastle, damit der Sentry-Report
      // sich nicht je nach Plattform unterscheidet.
      try {
        await _platformCodec(dek: fremd).decrypt(_goldenKey, _goldenBlob);
        fail('haette werfen muessen');
      } on InvalidCipherTextException catch (e) {
        expect(e.message, 'Authentication tag check failed');
      }
    });

    test('manipuliertes Tag wirft ebenfalls InvalidCipherTextException',
        () async {
      final frame = CacheCipherFrame.parse(_goldenBlob);
      final tag = Uint8List.fromList(frame.sealed);
      tag[tag.length - 1] ^= 0xFF;
      final manipuliert = CacheCipherFrame(frame.nonce, tag).armored;

      await expectLater(
          () async => _platformCodec().decrypt(_goldenKey, manipuliert),
          throwsA(isA<InvalidCipherTextException>()));
    });

    test('Rahmenfehler bleiben FormatException, in beiden Pfaden', () async {
      const ohneMagic = 'nur-klartext';
      final zuKurz = '$cacheCipherMagic${base64.encode(Uint8List(20))}';
      const keinBase64 = '$cacheCipherMagic!!!nicht base64!!!';

      for (final CacheCipher cipher in <CacheCipher>[
        _softwareCipher(),
        _platformCodec(),
      ]) {
        for (final kaputt in <String>[ohneMagic, zuKurz, keinBase64]) {
          await expectLater(() async => cipher.decrypt(_goldenKey, kaputt),
              throwsA(isA<FormatException>()),
              reason: '${cipher.runtimeType} / $kaputt');
        }
      }
    });

    test('die FormatException traegt keinen Ciphertext (Crash-Report)', () {
      try {
        CacheCipherFrame.parse('${cacheCipherMagic}xx!!!geheim!!!');
        fail('haette werfen muessen');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('geheim')));
      }
    });

    test(
        'ein undechiffrierbarer Slot wird auch im Plattform-Pfad GELOESCHT '
        '(die Uebersetzung erreicht _provesBrokenCiphertext)', () async {
      EncryptedKeyValueStore.debugResetReportGuards();
      final raw = InMemoryKeyValueStore({_goldenKey: _goldenBlob});
      final fremd = Uint8List.fromList(
          List<int>.filled(CacheCipherFrame.dekLengthBytes, 9));
      final store = EncryptedKeyValueStore(raw, _platformCodec(dek: fremd));

      expect(await store.getString(_goldenKey), isNull);
      expect(raw.snapshot.containsKey(_goldenKey), isFalse,
          reason: 'Ohne die Uebersetzung nach InvalidCipherTextException '
              'bliebe der tote Slot liegen.');
    });
  });

  // -------------------------------------------------------------------------
  // 5. Degradation to pointycastle
  // -------------------------------------------------------------------------
  group('stille Degradation auf pointycastle', () {
    test('encrypt: ein toter Kanal liefert trotzdem einen lesbaren Blob',
        () async {
      final cipher = _platformCodec(algorithm: _KaputteAesGcm());

      final blob = await cipher.encrypt(_goldenKey, _goldenPlaintext);

      expect(blob, startsWith(cacheCipherMagic));
      expect(await _softwareCipher().decrypt(_goldenKey, blob), _goldenPlaintext);
    });

    test('decrypt: ein toter Kanal liest den Bestand trotzdem', () async {
      final cipher = _platformCodec(algorithm: _KaputteAesGcm());

      expect(await cipher.decrypt(_goldenKey, _goldenBlob), _goldenPlaintext);
    });

    test(
        'nach einem Fehlschlag wird die Plattform eine Abkuehlzeit lang nicht '
        'mehr gefragt', () async {
      final cipher = _platformCodec(algorithm: _KaputteAesGcm());

      await cipher.encrypt(_goldenKey, 'a');
      // Would throw again if the instance still consulted the platform, and a
      // second failure would be a second log line per write.
      expect(await cipher.decrypt(_goldenKey, _goldenBlob), _goldenPlaintext);
      expect(
          await cipher.encrypt(_goldenKey, 'b'), startsWith(cacheCipherMagic));
    });

    test(
        'ein FALSCHES Tag degradiert NICHT — es ist ein Urteil ueber den '
        'Slot, nicht ueber die Plattform', () async {
      final zaehler = _ZaehlendeAesGcm(DartAesGcm.with256bits());
      final fremd = Uint8List.fromList(
          List<int>.filled(CacheCipherFrame.dekLengthBytes, 9));
      final cipher = _platformCodec(dek: fremd, algorithm: zaehler);

      await expectLater(() async => cipher.decrypt(_goldenKey, _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()));
      expect(zaehler.decrypts, 1);

      // Still on the platform path: the next call reaches the algorithm again.
      final eigen = await cipher.encrypt(_goldenKey, 'weiter');
      expect(zaehler.encrypts, 1);
      expect(await cipher.decrypt(_goldenKey, eigen), 'weiter');
      expect(zaehler.decrypts, 2);
    });

    test(
        'ein Rahmenfehler degradiert NICHT und erreicht die Plattform gar '
        'nicht erst', () async {
      final zaehler = _ZaehlendeAesGcm(DartAesGcm.with256bits());
      final cipher = _platformCodec(algorithm: zaehler);

      await expectLater(() async => cipher.decrypt(_goldenKey, 'kein-magic'),
          throwsA(isA<FormatException>()));
      expect(zaehler.decrypts, 0);

      expect(await cipher.decrypt(_goldenKey, _goldenBlob), _goldenPlaintext);
      expect(zaehler.decrypts, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 6. Selection
  // -------------------------------------------------------------------------
  group('Auswahl der Implementierung', () {
    test('ohne registriertes Plugin ist der Plattform-Pfad nicht verfuegbar',
        () {
      PlatformAesGcmCacheCipher.debugResetPlatformProbe();
      expect(PlatformAesGcmCacheCipher.isAvailable, isFalse,
          reason: 'flutter test laeuft ohne Plattform-Kanal — genau der Fall, '
              'in dem pointycastle Pflicht ist.');
    });

    test('createCacheCipher faellt hier folglich auf pointycastle zurueck', () {
      PlatformAesGcmCacheCipher.debugResetPlatformProbe();
      expect(createCacheCipher(_dek), isA<AesGcmCacheCipher>());
    });

    test('ein DEK mit falscher Laenge wird in BEIDEN Pfaden abgelehnt', () {
      final kurz = Uint8List(16);
      expect(() => AesGcmCacheCipher(kurz), throwsArgumentError);
      // The platform cipher builds pointycastle as its fallback, so the same
      // guard applies — a 16-byte DEK must never quietly become AES-128.
      expect(() => _platformCodec(dek: kurz), throwsArgumentError);
    });
  });

  // -------------------------------------------------------------------------
  // 7. Through the whole decorator, with the platform codec underneath
  // -------------------------------------------------------------------------
  group('Durchstich durch EncryptedKeyValueStore', () {
    test(
        'LocalCache-Roundtrip mit dem Plattform-Codec, gelesen von '
        'pointycastle', () async {
      final raw = InMemoryKeyValueStore();
      final schreiber = EncryptedKeyValueStore(raw, _platformCodec());

      await schreiber.setString(_goldenKey, _goldenPlaintext);

      final gespeichert = raw.snapshot[_goldenKey]!;
      expect(gespeichert, startsWith(cacheCipherMagic));
      expect(gespeichert, isNot(contains('Döner')));

      // A later app start on a device without the plugin.
      final leser = EncryptedKeyValueStore(raw, _softwareCipher());
      expect(await leser.getString(_goldenKey), _goldenPlaintext);
    });

    test(
        'und umgekehrt: von pointycastle geschrieben, vom Plattform-Codec '
        'gelesen', () async {
      final raw = InMemoryKeyValueStore();
      await EncryptedKeyValueStore(raw, _softwareCipher())
          .setString(_goldenKey, _goldenPlaintext);

      expect(
          await EncryptedKeyValueStore(raw, _platformCodec())
              .getString(_goldenKey),
          _goldenPlaintext);
    });
  });
}
