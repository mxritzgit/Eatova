import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/uuid.dart';

// Fix 3 (Replay-Doppelzaehlung der Lifetime-Stats): der Zaehler einer
// nachgeholten Op laeuft als eigener Outbox-Eintrag, dessen Request-Id
// DETERMINISTISCH aus der Quell-UUID abgeleitet wird. Genau diese Ableitung
// traegt die ganze Idempotenz-Garantie:
//   * stabil  — jede Wiederholung (erneuter Replay, erneute Erzeugung nach
//     einem App-Kill) sendet dieselbe Id, der Server erkennt EINEN Vorgang;
//   * bijektiv — verschiedene Quellen koennen sich nicht gegenseitig
//     wegdedupen;
//   * formaterhaltend — der RPC-Parameter ist `uuid`, alles andere ist ein
//     Server-Fehler statt einer Zaehlung.

void main() {
  group('deriveStatsRequestId', () {
    test(
        'Golden-Vektor: friert das Wire-Format ein (schlaegt dieser Test fehl, '
        'ist der Server-Dedup fuer alle Bestands-Eintraege gebrochen)', () {
      // Die Maske ist das ASCII von 'eatova-stats-rid'; eine Null-UUID mit
      // gesetzten Versions-/Variant-Bits (0x40 an Byte 6, 0x80 an Byte 8) zeigt
      // die Maske deshalb fast unveraendert — genau daran ist ein versehentlich
      // geaenderter Namensraum sofort zu sehen.
      expect(
        deriveStatsRequestId('00000000-0000-4000-8000-000000000000'),
        '6561746f-7661-6d73-f461-74732d726964',
      );
    });

    test('deterministisch: dieselbe Quelle ergibt immer dieselbe Id', () {
      const quelle = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final einmal = deriveStatsRequestId(quelle);
      final nochmal = deriveStatsRequestId(quelle);
      expect(einmal, isNotNull);
      expect(nochmal, einmal,
          reason: 'ohne Stabilitaet waere jeder Retry fuer den Server ein '
              'neuer Vorgang — und die Doppelzaehlung zurueck');
    });

    test('das Ergebnis hat UUID-Form und ist NICHT die Quelle', () {
      const quelle = '9d2f1a6c-7b3e-4c51-9f08-1e2d3c4b5a69';
      final abgeleitet = deriveStatsRequestId(quelle)!;
      expect(isUuidShape(abgeleitet), isTrue,
          reason: 'der RPC-Parameter ist uuid — eine andere Form ist ein '
              'Server-Fehler, keine Zaehlung');
      expect(abgeleitet, isNot(quelle),
          reason: 'die Maske haelt den Namensraum von den rohen Entitaets-Ids '
              'getrennt');
    });

    test('bijektiv: zwei verschiedene Quellen ergeben zwei verschiedene Ids',
        () {
      final a = uuidV4();
      final b = uuidV4();
      expect(a, isNot(b), reason: 'Vorbedingung');
      expect(deriveStatsRequestId(a), isNot(deriveStatsRequestId(b)),
          reason: 'kollidierende Ableitungen wuerden zwei echte Zaehlungen zu '
              'einer verschmelzen (Unterzaehlung)');
    });

    test('Grossschreibung der Eingabe aendert die Id nicht', () {
      const quelle = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      expect(deriveStatsRequestId(quelle),
          deriveStatsRequestId(quelle.toLowerCase()));
    });

    test('Nicht-UUID-Eingaben liefern null statt einer Fantasie-Id', () {
      // 'm-a' ist die Form, die aeltere Tests/fremde Blobs tragen koennen.
      expect(deriveStatsRequestId('m-a'), isNull);
      expect(deriveStatsRequestId(''), isNull);
      // 31 bzw. 33 Hexzeichen — knapp daneben ist auch daneben.
      expect(deriveStatsRequestId('a' * 31), isNull);
      expect(deriveStatsRequestId('a' * 33), isNull);
      // Hex-Laenge stimmt, aber ein Zeichen ist keins.
      expect(deriveStatsRequestId('${'a' * 31}z'), isNull);
    });

    test('Bindestriche sind egal — die 32 Hexzeichen entscheiden', () {
      expect(
        deriveStatsRequestId('aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa'),
        deriveStatsRequestId('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      );
    });
  });

  group('isUuidShape', () {
    test('akzeptiert 8-4-4-4-12 Hex in beiden Schreibweisen', () {
      expect(isUuidShape(uuidV4()), isTrue);
      expect(isUuidShape('00000000-0000-4000-8000-000000000000'), isTrue);
      expect(isUuidShape('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'), isTrue,
          reason: 'bewusst OHNE Versions-Pruefung: Postgres akzeptiert jede '
              'Hex-UUID, und genau die Form muss stimmen');
      // Die abgeleitete Id traegt keine gueltigen Versions-Bits mehr — sie
      // MUSS trotzdem durchgehen, sonst verwirft der Replay seinen eigenen
      // Eintrag als korrupt.
      expect(
          isUuidShape(
              deriveStatsRequestId('00000000-0000-4000-8000-000000000000')!),
          isTrue);
    });

    test('lehnt alles andere ab', () {
      expect(isUuidShape('m-a'), isFalse);
      expect(isUuidShape(''), isFalse);
      expect(isUuidShape('2026-08-15'), isFalse);
      expect(isUuidShape('aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa'), isFalse,
          reason: 'ohne Bindestriche ist es kein uuid-Literal');
      expect(isUuidShape(' 00000000-0000-4000-8000-000000000000'), isFalse);
    });
  });
}
