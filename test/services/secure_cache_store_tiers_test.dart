// PERF-B1b: B1 gave the cache cipher an OS route and left everything else on
// pointycastle. That "everything else" is desktop, the whole VM test
// environment and every device whose plugin channel is not registered — i.e.
// exactly the platforms the fallback exists for kept paying the original
// 91.5 ms. package:cryptography's PURE-DART AES-GCM was already a direct
// dependency (cryptography_flutter is built on it) and does the same bytes
// ~13x faster, so the fallback now leads with it and keeps pointycastle as the
// last resort.
//
// Three tiers: platform -> DartAesGcm -> pointycastle.
//
// This file pins the parts that can silently go wrong:
//
//   1. the wire format does NOT move — the golden vector comes out
//      byte-identical from the new tier AND from the forced last resort, and
//      blobs cross between them in both directions,
//   2. the failure semantics do NOT move — a bad tag is a verdict about the
//      DATA on every tier: pointycastle's InvalidCipherTextException with
//      pointycastle's message, and never a fallthrough to the next tier,
//   3. the tier ORDER and when each one hands over,
//   4. review 2026-09-01 / L5: a platform failure is no longer a one-way
//      switch for the process.
//
// The counting fakes below rely on one property of the production code: the
// tier-2 algorithm is a STATIC of this isolate, and `compute()` runs in a
// fresh one. So a counter that moved proves the work stayed in the caller's
// isolate, and a counter that did not move proves it went through the hop.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart'
    show FlutterCipher;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';

// ---------------------------------------------------------------------------
// Fixtures — the SAME ones as secure_cache_store_golden_test.dart, so the
// hard-coded blob below is the identical vector and the two files cannot drift
// apart on what "the wire format" means.
// ---------------------------------------------------------------------------

final Uint8List _dek = Uint8List.fromList(
  List<int>.generate(
      CacheCipherFrame.dekLengthBytes, (i) => (i * 7 + 11) & 0xFF),
);

final Uint8List _fremderDek =
    Uint8List.fromList(List<int>.filled(CacheCipherFrame.dekLengthBytes, 9));

final Uint8List _nonce = Uint8List.fromList(
  List<int>.generate(CacheCipherFrame.nonceLengthBytes, (i) => 0xA0 + i),
);

const String _key = 'eatova.v1.logged_meals.user-1';

const String _plaintext =
    '{"items":[{"id":"m-1","name":"Döner Teller","kcal":820,"note":"süß"}]}';

const String _goldenBlob = 'EATOVA1:oKGio6SlpqeoqaqraH8NwkoYHjPagVxGfcc/8M0b'
    'F3Zp9DevkMLKfEpQrXTcqNtH5Dz6S98uFCBrrP7YTJjmhSNUdZi9tdAznZd/UQ4Hu4UZKF0N'
    'gPXYvNk3OPNF7Tn8BNFNNFw=';

/// pointycastle's wording, hard-coded and NOT read from the source, so a
/// change to the constant shows up here as a failing test.
const String _tagFehler = 'Authentication tag check failed';

/// Longer than [AesGcmCacheCipher.inlineMaxChars], so it takes the isolate.
String _grosserKlartext() =>
    jsonEncode(<String, Object?>{'items': List<String>.filled(400, 'Döner')});

// ---------------------------------------------------------------------------
// Scriptable tier-2 algorithm
// ---------------------------------------------------------------------------

/// Real [DartAesGcm], but counted and scriptable: each entry in [fehler] makes
/// exactly one call throw, consumed from the front.
class _SkriptDartAesGcm extends DartAesGcm {
  _SkriptDartAesGcm() : super(secretKeyLength: 32);

  final List<Object> fehler = <Object>[];
  int encrypts = 0;
  int decrypts = 0;

  @override
  SecretBox encryptSync(
    List<int> clearText, {
    required SecretKeyData secretKeyData,
    List<int>? nonce,
    List<int> aad = const <int>[],
  }) {
    encrypts++;
    if (fehler.isNotEmpty) throw fehler.removeAt(0);
    return super.encryptSync(clearText,
        secretKeyData: secretKeyData, nonce: nonce, aad: aad);
  }

  @override
  List<int> decryptSync(
    SecretBox secretBox, {
    required SecretKeyData secretKeyData,
    List<int> aad = const <int>[],
  }) {
    decrypts++;
    if (fehler.isNotEmpty) throw fehler.removeAt(0);
    return super.decryptSync(secretBox,
        secretKeyData: secretKeyData, aad: aad);
  }
}

// ---------------------------------------------------------------------------
// Scriptable tier-1 algorithm (the platform seam)
// ---------------------------------------------------------------------------

/// Delegates to a real implementation, counts, and fails the first
/// [fehlschlaege] calls with something that is NOT a verdict about the data.
class _FlakigeAesGcm implements AesGcm {
  _FlakigeAesGcm(this._inner, {this.fehlschlaege = 0});

  final AesGcm _inner;
  int fehlschlaege;
  int aufrufe = 0;

  @override
  Future<SecretBox> encrypt(List<int> clearText,
      {required SecretKey secretKey,
      List<int>? nonce,
      List<int> aad = const <int>[],
      Uint8List? possibleBuffer}) {
    aufrufe++;
    if (fehlschlaege > 0) {
      fehlschlaege--;
      throw StateError('MissingPluginException(No implementation found)');
    }
    return _inner.encrypt(clearText,
        secretKey: secretKey, nonce: nonce, aad: aad);
  }

  @override
  Future<List<int>> decrypt(SecretBox secretBox,
      {required SecretKey secretKey,
      List<int> aad = const <int>[],
      Uint8List? possibleBuffer}) {
    aufrufe++;
    if (fehlschlaege > 0) {
      fehlschlaege--;
      throw StateError('MissingPluginException(No implementation found)');
    }
    return _inner.decrypt(secretBox, secretKey: secretKey, aad: aad);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Both probes are statics; every test that pins one puts the real one back,
  // or it leaks into the rest of the file.
  tearDown(() {
    AesGcmCacheCipher.debugResetDartAlgorithm();
    PlatformAesGcmCacheCipher.debugResetPlatformProbe();
  });

  // -------------------------------------------------------------------------
  // 1. The wire format survives the new tier
  // -------------------------------------------------------------------------
  group('Wire-Format ueber alle Stufen', () {
    test('der Golden-Blob ist auf der NEUEN Stufe byte-identisch', () {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      expect(
        AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext, nonce: _nonce),
        _goldenBlob,
        reason: 'DartAesGcm muss exakt dieselben Bytes liefern wie '
            'pointycastle, sonst verliert jede installierte App ihr Tagebuch.',
      );
    });

    test('… und auf der erzwungenen letzten Stufe ebenfalls', () {
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      expect(
        AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext, nonce: _nonce),
        _goldenBlob,
      );
    });

    test('beide Stufen lesen den festgeschriebenen Blob', () {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob), _plaintext);
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob), _plaintext);
    });

    test('von pointycastle geschrieben, von DartAesGcm gelesen', () {
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      final vonPointy = AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext);

      AesGcmCacheCipher.debugResetDartAlgorithm();
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonPointy), _plaintext);
    });

    test('von DartAesGcm geschrieben, von pointycastle gelesen', () {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final vonDart = AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext);

      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonDart), _plaintext);
    });

    test(
        'mit ECHTEN Zufalls-Nonces, mehrfach, in beide Richtungen — die Nonce '
        'liegt im fremden Rahmen und muss von dort gelesen werden', () {
      final blobs = <String>{};
      for (var i = 0; i < 5; i++) {
        AesGcmCacheCipher.debugResetDartAlgorithm();
        final vonDart = AesGcmCacheCipher.encryptSync(_dek, _key, 'runde-$i');
        AesGcmCacheCipher.debugSetDartAlgorithm(null);
        final vonPointy = AesGcmCacheCipher.encryptSync(_dek, _key, 'runde-$i');

        expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonDart), 'runde-$i');
        AesGcmCacheCipher.debugResetDartAlgorithm();
        expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonPointy), 'runde-$i');
        blobs.addAll(<String>[vonDart, vonPointy]);
      }
      expect(blobs, hasLength(10), reason: 'Keine Nonce-Wiederverwendung.');
    });

    test('leerer Klartext: der Rahmen besteht nur aus Nonce und Tag', () {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final leer = AesGcmCacheCipher.encryptSync(_dek, _key, '');
      final frame = CacheCipherFrame.parse(leer);

      expect(frame.cipherText, isEmpty);
      expect(frame.nonce, hasLength(CacheCipherFrame.nonceLengthBytes));
      expect(frame.sealed, hasLength(CacheCipherFrame.tagLengthBytes));
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, leer), '');
    });

    test('grosser Blob (~200 kB) kreuzt in beide Richtungen', () {
      final gross = jsonEncode({'items': List<String>.filled(4000, 'Döner')});
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final vonDart = AesGcmCacheCipher.encryptSync(_dek, _key, gross);
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      final vonPointy = AesGcmCacheCipher.encryptSync(_dek, _key, gross);

      expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonDart), gross);
      AesGcmCacheCipher.debugResetDartAlgorithm();
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, vonPointy), gross);
    });
  });

  // -------------------------------------------------------------------------
  // 2. A bad tag is a verdict about the DATA — on every tier
  // -------------------------------------------------------------------------
  group('Fehlersemantik: falsches Tag', () {
    /// The golden blob with the last tag byte flipped.
    String manipuliert() {
      final frame = CacheCipherFrame.parse(_goldenBlob);
      final sealed = Uint8List.fromList(frame.sealed);
      sealed[sealed.length - 1] ^= 0xFF;
      return CacheCipherFrame(frame.nonce, sealed).armored;
    }

    test('DartAesGcm: Typ UND Wortlaut sind die von pointycastle', () {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      try {
        AesGcmCacheCipher.decryptSync(_dek, _key, manipuliert());
        fail('haette werfen muessen');
      } on InvalidCipherTextException catch (e) {
        expect(e.message, _tagFehler);
      }
    });

    test('pointycastle: derselbe Typ, derselbe Wortlaut', () {
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      try {
        AesGcmCacheCipher.decryptSync(_dek, _key, manipuliert());
        fail('haette werfen muessen');
      } on InvalidCipherTextException catch (e) {
        expect(e.message, _tagFehler);
      }
    });

    test('falscher DEK ebenso, auf beiden Stufen', () {
      for (final DartAesGcm? stufe in <DartAesGcm?>[DartAesGcm.with256bits(), null]) {
        AesGcmCacheCipher.debugSetDartAlgorithm(stufe);
        expect(
          () => AesGcmCacheCipher.decryptSync(_fremderDek, _key, _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()),
          reason: 'Stufe: ${stufe?.runtimeType ?? 'pointycastle'}',
        );
      }
    });

    test('fremder Slot (AAD) ebenso, auf beiden Stufen', () {
      for (final DartAesGcm? stufe in <DartAesGcm?>[DartAesGcm.with256bits(), null]) {
        AesGcmCacheCipher.debugSetDartAlgorithm(stufe);
        expect(
          () => AesGcmCacheCipher.decryptSync(
              _dek, 'eatova.v1.logged_meals.user-2', _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()),
          reason: 'Stufe: ${stufe?.runtimeType ?? 'pointycastle'}',
        );
      }
    });

    test(
        'ein falsches Tag steigt NICHT auf pointycastle ab — sonst kostet '
        'jeder kaputte Slot zusaetzlich den langsamen Pfad', () {
      final skript = _SkriptDartAesGcm()
        ..fehler.add(SecretBoxAuthenticationError());
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      // Der Blob ist GUELTIG: wuerde pointycastle gefragt, kaeme der Klartext
      // zurueck statt der Ausnahme.
      expect(() => AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()));
      expect(skript.decrypts, 1);
    });

    test('und er schaltet die schnelle Stufe auch nicht ab', () {
      final skript = _SkriptDartAesGcm()
        ..fehler.add(SecretBoxAuthenticationError());
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      expect(() => AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()));
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob), _plaintext);
      expect(skript.decrypts, 2,
          reason: 'Der zweite Aufruf muss wieder auf der schnellen Stufe '
              'landen — ein Urteil ueber die Daten sagt nichts ueber die '
              'Implementierung.');
    });
  });

  // -------------------------------------------------------------------------
  // 3. Rahmenfehler: vor jedem try, also vor jeder Stufe
  // -------------------------------------------------------------------------
  group('Fehlersemantik: Rahmen', () {
    final kaputt = <String>[
      'nur-klartext',
      '$cacheCipherMagic${base64.encode(Uint8List(20))}',
      '$cacheCipherMagic!!!nicht base64!!!',
    ];

    test('FormatException auf beiden Stufen, ohne die Stufe zu belasten', () {
      for (final DartAesGcm? stufe in <DartAesGcm?>[DartAesGcm.with256bits(), null]) {
        AesGcmCacheCipher.debugSetDartAlgorithm(stufe);
        for (final blob in kaputt) {
          expect(() => AesGcmCacheCipher.decryptSync(_dek, _key, blob),
              throwsA(isA<FormatException>()),
              reason: '${stufe?.runtimeType ?? 'pointycastle'} / $blob');
        }
      }
    });

    test('ein Rahmenfehler erreicht die schnelle Stufe gar nicht erst', () {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      expect(() => AesGcmCacheCipher.decryptSync(_dek, _key, 'kein-magic'),
          throwsA(isA<FormatException>()));
      expect(skript.decrypts, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 4. Die Stufenfolge
  // -------------------------------------------------------------------------
  group('Stufenfolge Plattform -> DartAesGcm -> pointycastle', () {
    test('ohne Plugin waehlt createCacheCipher die Dart-Leiter', () {
      PlatformAesGcmCacheCipher.debugResetPlatformProbe();
      expect(PlatformAesGcmCacheCipher.isAvailable, isFalse,
          reason: 'flutter test laeuft ohne Plattform-Kanal.');
      expect(createCacheCipher(_dek), isA<AesGcmCacheCipher>());
    });

    test('Stufe 2 ist die Vorgabe: DartAesGcm wird gefragt', () {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext);
      AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob);

      expect(skript.encrypts, 1);
      expect(skript.decrypts, 1);
    });

    test('Stufe 2 nicht baubar -> Stufe 3 antwortet, im gleichen Format', () {
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      final blob =
          AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext, nonce: _nonce);

      expect(blob, _goldenBlob);
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, blob), _plaintext);
    });

    test(
        'ein Wurf auf Stufe 2, der KEIN Urteil ueber die Daten ist, wird von '
        'Stufe 3 beantwortet — encrypt wie decrypt', () {
      final skript = _SkriptDartAesGcm()
        ..fehler.addAll(<Object>[StateError('OOM'), StateError('OOM')]);
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      // encrypt: dieselbe Nonce darf weiterverwendet werden, weil auf Stufe 2
      // nichts entstanden ist — das Ergebnis ist deshalb der Golden-Blob.
      expect(
          AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext, nonce: _nonce),
          _goldenBlob);
      expect(AesGcmCacheCipher.decryptSync(_dek, _key, _goldenBlob), _plaintext);
      expect(skript.encrypts, 1);
      expect(skript.decrypts, 1);
    });

    test(
        'dieser Abstieg ist NICHT klebrig: der naechste Aufruf landet wieder '
        'auf Stufe 2', () {
      final skript = _SkriptDartAesGcm()..fehler.add(StateError('OOM'));
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);

      AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext);
      AesGcmCacheCipher.encryptSync(_dek, _key, _plaintext);

      expect(skript.encrypts, 2,
          reason: 'Ein einzelner Ausrutscher darf den Prozess nicht dauerhaft '
              'auf die 13x langsamere Stufe zwingen.');
    });

    test('Stufe 1 faellt auf die Dart-Leiter, nicht direkt auf pointycastle',
        () async {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);
      final cipher = PlatformAesGcmCacheCipher(_dek,
          algorithm: _FlakigeAesGcm(DartAesGcm.with256bits(),
              fehlschlaege: 1000));

      final blob = await cipher.encrypt(_key, _plaintext);

      expect(blob, startsWith(cacheCipherMagic));
      expect(skript.encrypts, 1,
          reason: 'Der Fallback der Plattform-Stufe ist AesGcmCacheCipher, '
              'und dessen erste Wahl ist DartAesGcm.');
      expect(await cipher.decrypt(_key, blob), _plaintext);
    });
  });

  // -------------------------------------------------------------------------
  // 5. L5 — die Plattform-Degradation ist wieder umkehrbar
  // -------------------------------------------------------------------------
  group('L5 Plattform-Degradation ist umkehrbar', () {
    test(
        'nach einem Fehlschlag ruht die Plattform genau '
        'platformRetryAfterCalls Aufrufe', () async {
      final flaky =
          _FlakigeAesGcm(DartAesGcm.with256bits(), fehlschlaege: 1);
      final cipher = PlatformAesGcmCacheCipher(_dek, algorithm: flaky);

      expect(await cipher.encrypt(_key, 'a'), startsWith(cacheCipherMagic));
      expect(flaky.aufrufe, 1, reason: 'Der Fehlschlag selbst.');

      for (var i = 0; i < PlatformAesGcmCacheCipher.platformRetryAfterCalls;
          i++) {
        await cipher.encrypt(_key, 'ruhe-$i');
      }
      expect(flaky.aufrufe, 1,
          reason: 'Waehrend der Abkuehlung wird die Plattform nicht gefragt.');

      await cipher.encrypt(_key, 'wieder');
      expect(flaky.aufrufe, 2,
          reason: 'Danach schon — sonst kostet EIN Ausrutscher den Rest der '
              'Sitzung den schnellen Pfad.');
    });

    test('der Wiederversuch traegt: die Plattform bleibt danach in Betrieb',
        () async {
      final flaky =
          _FlakigeAesGcm(DartAesGcm.with256bits(), fehlschlaege: 1);
      final cipher = PlatformAesGcmCacheCipher(_dek, algorithm: flaky);

      await cipher.encrypt(_key, 'a');
      for (var i = 0; i <= PlatformAesGcmCacheCipher.platformRetryAfterCalls;
          i++) {
        await cipher.encrypt(_key, 'x$i');
      }
      final vorher = flaky.aufrufe;
      await cipher.encrypt(_key, 'y');
      await cipher.encrypt(_key, 'z');

      expect(flaky.aufrufe, vorher + 2,
          reason: 'Ein geglueckter Wiederversuch beendet die Abkuehlung.');
    });

    test('ein erneuter Fehlschlag setzt die Abkuehlung neu auf', () async {
      final flaky =
          _FlakigeAesGcm(DartAesGcm.with256bits(), fehlschlaege: 1);
      final cipher = PlatformAesGcmCacheCipher(_dek, algorithm: flaky);

      await cipher.encrypt(_key, 'a'); // Fehlschlag 1
      for (var i = 0; i < PlatformAesGcmCacheCipher.platformRetryAfterCalls;
          i++) {
        await cipher.encrypt(_key, 'ruhe-$i');
      }
      flaky.fehlschlaege = 1;
      await cipher.encrypt(_key, 'wiederversuch'); // Fehlschlag 2
      expect(flaky.aufrufe, 2);

      for (var i = 0; i < PlatformAesGcmCacheCipher.platformRetryAfterCalls;
          i++) {
        await cipher.encrypt(_key, 'ruhe2-$i');
      }
      expect(flaky.aufrufe, 2, reason: 'Zweite Abkuehlung laeuft.');
      await cipher.encrypt(_key, 'dritter');
      expect(flaky.aufrufe, 3);
    });

    test(
        'ein falsches Tag loest die Abkuehlung NICHT aus — es ist ein Urteil '
        'ueber die Daten', () async {
      final flaky = _FlakigeAesGcm(DartAesGcm.with256bits());
      final cipher = PlatformAesGcmCacheCipher(_fremderDek, algorithm: flaky);

      await expectLater(() async => cipher.decrypt(_key, _goldenBlob),
          throwsA(isA<InvalidCipherTextException>()));
      expect(flaky.aufrufe, 1);

      // Ohne Abkuehlung erreicht der naechste Aufruf die Plattform sofort.
      await cipher.encrypt(_key, 'weiter');
      expect(flaky.aufrufe, 2);
    });

    test('ein NICHT baubarer Plattform-Cipher bleibt dauerhaft unten', () async {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);
      // "Konstruktion warf" ist eine Aussage ueber den Build, nicht ueber
      // einen Moment — es gibt also nichts abzukuehlen und nichts zu
      // wiederholen.
      PlatformAesGcmCacheCipher.debugMarkPlatformUnbuildable();
      final cipher = PlatformAesGcmCacheCipher(_dek);

      for (var i = 0; i < 5; i++) {
        await cipher.encrypt(_key, 'x$i');
      }
      expect(skript.encrypts, 5);
    });
  });

  // -------------------------------------------------------------------------
  // 6. Die Inline-Schwelle spiegelt die Politik des Plugins
  // -------------------------------------------------------------------------
  group('Inline-Schwelle', () {
    test('sie ist dieselbe Zahl, die das Plugin selbst verwendet', () {
      expect(AesGcmCacheCipher.inlineMaxChars,
          FlutterCipher.defaultChannelPolicy.minLength,
          reason: 'Unter dieser Groesse haelt cryptography_flutter die Arbeit '
              'ebenfalls im aufrufenden Isolate. Zieht das Paket die Grenze '
              'um, muessen die beiden Leitern zusammen umziehen.');
    });

    test('kleine Slots laufen OHNE Isolate-Hop', () async {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);
      final cipher = AesGcmCacheCipher(_dek);

      final blob = await cipher.encrypt(_key, _plaintext);

      expect(skript.encrypts, 1,
          reason: 'Der Zaehler ist ein Statik DIESES Isolates. Bewegt er '
              'sich, blieb die Arbeit hier — genau das ist der Gewinn: der '
              'Hop kostet ~0,13 ms, die Krypto eines kleinen Slots ~0,01 ms.');
      expect(await cipher.decrypt(_key, blob), _plaintext);
      expect(skript.decrypts, 1);
    });

    test('grosse Slots nehmen weiter den Isolate-Hop (PERF-G9)', () async {
      final skript = _SkriptDartAesGcm();
      AesGcmCacheCipher.debugSetDartAlgorithm(skript);
      final cipher = AesGcmCacheCipher(_dek);
      final gross = _grosserKlartext();
      expect(gross.length,
          greaterThanOrEqualTo(AesGcmCacheCipher.inlineMaxChars));

      final blob = await cipher.encrypt(_key, gross);

      expect(skript.encrypts, 0,
          reason: 'Unbewegter Zaehler = die Arbeit lief im fremden Isolate, '
              'wo die Statik frisch ist. Sonst laege die Krypto im Stack des '
              'Aufrufers.');
      expect(await cipher.decrypt(_key, blob), gross);
      expect(skript.decrypts, 0);
    });

    test('grosse Slots geben den Stack vor der Krypto frei', () async {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final cipher = AesGcmCacheCipher(_dek);
      final gross = jsonEncode({'items': List<String>.filled(4000, 'Döner')});

      final sw = Stopwatch()..start();
      final pending = cipher.encrypt(_key, gross);
      final syncMicros = sw.elapsedMicroseconds;
      sw.stop();

      expect(await cipher.decrypt(_key, await pending), gross);
      expect(syncMicros / 1000, lessThan(20));
    });

    test('ein synchroner Wurf auf dem Inline-Pfad kommt als Future-Fehler an',
        () async {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final cipher = AesGcmCacheCipher(_dek);

      // Nicht `throwsA` um einen synchronen Aufruf: der Pfad MUSS den Fehler
      // ueber das Future liefern, sonst faengt ihn `EncryptedKeyValueStore`
      // nicht und der Slot-Read wirft statt null zu liefern.
      final pending = cipher.decrypt(_key, 'kein-magic');
      await expectLater(pending, throwsA(isA<FormatException>()));
    });
  });

  // -------------------------------------------------------------------------
  // 7. Durchstich: der Decorator entscheidet weiter richtig
  // -------------------------------------------------------------------------
  group('Durchstich durch EncryptedKeyValueStore', () {
    test('von der schnellen Stufe geschrieben, von Stufe 3 gelesen', () async {
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final raw = InMemoryKeyValueStore();
      await EncryptedKeyValueStore(raw, AesGcmCacheCipher(_dek))
          .setString(_key, _plaintext);

      final gespeichert = raw.snapshot[_key]!;
      expect(gespeichert, startsWith(cacheCipherMagic));
      expect(gespeichert, isNot(contains('Döner')));

      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      expect(
          await EncryptedKeyValueStore(raw, AesGcmCacheCipher(_dek))
              .getString(_key),
          _plaintext);
    });

    test('und umgekehrt', () async {
      AesGcmCacheCipher.debugSetDartAlgorithm(null);
      final raw = InMemoryKeyValueStore();
      await EncryptedKeyValueStore(raw, AesGcmCacheCipher(_dek))
          .setString(_key, _plaintext);

      AesGcmCacheCipher.debugResetDartAlgorithm();
      expect(
          await EncryptedKeyValueStore(raw, AesGcmCacheCipher(_dek))
              .getString(_key),
          _plaintext);
    });

    test(
        'ein toter Slot wird auch auf der schnellen Stufe GELOESCHT — die '
        'Uebersetzung erreicht _provesBrokenCiphertext', () async {
      EncryptedKeyValueStore.debugResetReportGuards();
      AesGcmCacheCipher.debugResetDartAlgorithm();
      final raw = InMemoryKeyValueStore({_key: _goldenBlob});
      final store =
          EncryptedKeyValueStore(raw, AesGcmCacheCipher(_fremderDek));

      expect(await store.getString(_key), isNull);
      expect(raw.snapshot.containsKey(_key), isFalse,
          reason: 'Ohne die Uebersetzung nach InvalidCipherTextException '
              'bliebe der tote Slot liegen.');
    });
  });
}
