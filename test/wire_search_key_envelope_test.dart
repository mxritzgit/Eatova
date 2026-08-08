// Vertrag zwischen der Edge Function `search-key` und ihrem einzigen Client
// (docs/REVIEW-2026-08-08.md, G2, Schalter 3) — die DART-Seite.
//
// WAS DIESE DATEI ABDECKT, DAS DER DENO-TEST NICHT KANN
//
// `supabase/functions/search-key/wire_response_contract_test.ts` faehrt den
// echten Handler und nagelt die Feldnamen auf der SERVER-Seite fest. Die
// Umbenennung kann aber genauso gut auf der CLIENT-Seite passieren:
//
//     final baseUrl = decoded['mirrorBaseUrl'];   ->  decoded['mirror_base_url']
//
// Das ist dieselbe Ein-Token-Aenderung mit derselben Folge — `fetch` liefert
// `null`, `null` heisst „behalte, was du hast", die Rotation ist still und
// dauerhaft tot. Und es gibt dafuer heute keinen einzigen Test:
// `test/services/search_credentials_test.dart` steckt einen eigenen
// `SearchKeyFetcher` ein und betritt `EdgeFunctionSearchKeyFetcher._fetch()`
// nie.
//
// WARUM HIER QUELLTEXT VERGLICHEN WIRD UND NICHT VERHALTEN
//
// `EdgeFunctionSearchKeyFetcher` hat keine Testnaht: Basis-URL
// (`EatovaSupabaseConfig.url`) und Token (`Supabase.instance`) sind fest
// verdrahtet, es gibt keinen Konstruktor-Parameter wie den, den
// `OpenFoodFactsProductService` fuer seinen Wire-Test bekommen hat. Ein
// echter Loopback-Wire-Test der Client-Seite ist ohne Produktionsaenderung
// unmoeglich (siehe Bericht). Bis diese Naht existiert, ist der Abgleich der
// beiden Quelltexte die schaerfste verfuegbare Aussage — und er faengt beide
// Umbenennungsrichtungen.
//
// Der Schluessel-Satz wird aus dem CLIENT gelesen, nicht aus der Function:
// waere er hier als Literal notiert, stammte er wieder aus demselben
// Denkmodell wie der Code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _clientPfad = 'lib/src/services/search_credentials.dart';
const String _functionPfad = 'supabase/functions/search-key/index.ts';

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
}

/// Der Rumpf von `EdgeFunctionSearchKeyFetcher._fetch()` — bewusst NUR dieser
/// Ausschnitt: `_CachedEntry.tryParse` liest ebenfalls `decoded[...]`, aber
/// aus dem PERSISTENZ-Format (`base_url`, `key`, `ttl_seconds`). Die beiden
/// Formate sind verschieden, und genau ihre Verwechslung ist die Falle.
String _fetchRumpf(String quelle) {
  final start = quelle.indexOf('Future<FetchedSearchCredentials?> _fetch()');
  expect(start, greaterThan(-1), reason: '_fetch() nicht gefunden');
  final ende = quelle.indexOf('class SearchCredentialsStore', start);
  expect(ende, greaterThan(start), reason: 'Ende von _fetch() nicht gefunden');
  return quelle.substring(start, ende);
}

void main() {
  late String clientQuelle;
  late String functionQuelle;
  late Set<String> gelesendeFelder;

  setUpAll(() {
    clientQuelle = _lies(_clientPfad);
    functionQuelle = _lies(_functionPfad);
    gelesendeFelder = RegExp(r"decoded\['([A-Za-z0-9_]+)'\]")
        .allMatches(_fetchRumpf(clientQuelle))
        .map((m) => m.group(1)!)
        .toSet();
  });

  test('der Client liest ueberhaupt Felder aus der Antwort', () {
    // Sicherheitsnetz gegen eine stille Nullaussage: waere der Parser
    // umgebaut, wuerde die Extraktion leer laufen und alles unten waere
    // trivial wahr.
    expect(
      gelesendeFelder,
      hasLength(3),
      reason:
          'Erwartet werden genau drei Felder (Basis-URL, Key, TTL). Gefunden: '
          '$gelesendeFelder. Wurde der Parser umgebaut, muss dieser Test '
          'nachgezogen werden statt still gruen zu bleiben.',
    );
  });

  test('jedes vom Client gelesene Feld steht so auch in der Function', () {
    for (final feld in gelesendeFelder) {
      expect(
        functionQuelle,
        contains('$feld:'),
        reason:
            'Der Client liest `$feld` aus der Antwort von search-key, aber '
            '$_functionPfad liefert kein solches Feld. Der Fetcher bekommt '
            'damit `null` — und `null` heisst per Vertrag „behalte, was du '
            'hast". Die Key-Rotation ist still und dauerhaft tot, waehrend '
            'FallbackProductService weiter plausible OFF-Treffer liefert.',
      );
    }
  });

  test('die beiden Pflichtfelder scheitern hart, nicht halb', () {
    // Der Vertrag des Fetchers: fehlt eines der beiden, gibt es KEINE
    // halb gefuellten Credentials, sondern null.
    expect(
      _fetchRumpf(clientQuelle),
      contains('if (baseUrl is! String || searchKey is! String) return null;'),
      reason:
          'Ohne diese Zeile koennte ein umbenanntes Feld als leerer String '
          'durchgehen und den funktionierenden Key ueberschreiben.',
    );
  });

  test('Wire-Format und Cache-Format werden nicht verwechselt', () {
    // Die Function liefert camelCase, die Platte snake_case. Wer eines der
    // beiden Formate ins andere kopiert, faellt hier auf.
    for (final wireFeld in gelesendeFelder) {
      expect(
        wireFeld,
        isNot(contains('_')),
        reason:
            'Das Antwort-Format von search-key ist camelCase; `$wireFeld` '
            'sieht nach dem Persistenz-Format aus (_CachedEntry.encode).',
      );
    }
    for (final cacheFeld in const <String>[
      'base_url',
      'ttl_seconds',
      'fetched_at',
    ]) {
      expect(
        gelesendeFelder,
        isNot(contains(cacheFeld)),
        reason: '`$cacheFeld` gehoert in den Cache, nicht in die Antwort.',
      );
    }
  });
}
