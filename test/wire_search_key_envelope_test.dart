// Contract between the `search-key` edge function and its only client — the
// DART side. The Deno test pins the field names on the SERVER side, but the
// same one-token rename can happen on the client
// (`decoded['mirrorBaseUrl']` -> `decoded['mirror_base_url']`) with the same
// consequence: `fetch` returns `null`, `null` means "keep what you have", and
// key rotation is silently dead forever.
//
// Source text is compared instead of behaviour because
// `EdgeFunctionSearchKeyFetcher` has no test seam: base URL and token are
// hard-wired, so a loopback wire test is impossible without a production
// change. Until that seam exists, comparing both sources is the sharpest
// available statement, and it catches renames in either direction.
//
// The key set is read from the CLIENT, not the function — a literal here would
// come from the same mental model as the code.

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

/// The body of `EdgeFunctionSearchKeyFetcher._fetch()` — deliberately only
/// this slice: `_CachedEntry.tryParse` also reads `decoded[...]`, but from the
/// PERSISTENCE format. Confusing the two formats is the trap.
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
    // Safety net against a silent null statement: a rebuilt parser would make
    // the extraction come up empty and everything below trivially true.
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
    // The fetcher's contract: if either is missing there are NO half-filled
    // credentials, only null.
    expect(
      _fetchRumpf(clientQuelle),
      contains('if (baseUrl is! String || searchKey is! String) return null;'),
      reason:
          'Ohne diese Zeile koennte ein umbenanntes Feld als leerer String '
          'durchgehen und den funktionierenden Key ueberschreiben.',
    );
  });

  test('Wire-Format und Cache-Format werden nicht verwechselt', () {
    // The function returns camelCase, the disk snake_case. Copying one format
    // into the other trips here.
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
