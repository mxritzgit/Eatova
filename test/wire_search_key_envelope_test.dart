// Contract between the `search-key` edge function and its only client — the
// DART side. The Deno test (supabase/functions/search-key/
// wire_response_contract_test.ts) runs the REAL function against a REPLICA of
// this parser, so it pins the field names on the SERVER side. The same
// one-token rename can happen on the client
// (`decoded['mirrorBaseUrl']` -> `decoded['mirror_base_url']`) with the same
// consequence: `fetch` returns `null`, `null` means "keep what you have", and
// key rotation is silently dead forever. Nothing over there can see that: its
// expected names are a constant in its own file.
//
// So this file is the other half, and it is the one that runs the REAL client.
// It states the contract twice, in two different kinds:
//
//   * SOURCE. The field set is EXTRACTED from both sources — from the client's
//     `_fetch()` and from the function's response literal — and compared. A
//     literal here would come from the same mental model as the code.
//   * BEHAVIOUR. A body built from the FUNCTION's names is served over loopback
//     to the real `EdgeFunctionSearchKeyFetcher`. A rename on either side makes
//     the client return `null` and turns this red. This is what the Deno file's
//     replica parser can only approximate.
//
// (The behavioural half became possible when `EdgeFunctionSearchKeyFetcher`
// gained its base-URL/anon-key/token seam; the older comment here claiming
// there is none was stale — test/services/search_key_fetcher_wire_test.dart
// already uses it.)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/search_credentials.dart';

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

/// The object literal `index.ts` hands to `jsonResponse` on the success path —
/// i.e. the wire envelope itself, not one of the error bodies.
String _antwortLiteral(String quelle) {
  final anker = quelle.indexOf("'search-key issued'");
  expect(anker, greaterThan(-1),
      reason: 'Der Erfolgs-Pfad von index.ts wurde nicht gefunden');
  final aufruf = quelle.indexOf('return jsonResponse(', anker);
  expect(aufruf, greaterThan(anker), reason: 'jsonResponse-Aufruf nicht '
      'gefunden');
  // From the opening brace of the object literal, so the `request,` argument
  // in front of it is not mistaken for a response field.
  final start = quelle.indexOf('{', aufruf);
  expect(start, greaterThan(aufruf), reason: 'Antwort-Literal nicht gefunden');
  final ende = quelle.indexOf('\n      },', start);
  expect(ende, greaterThan(start), reason: 'Ende des Antwort-Literals nicht '
      'gefunden');
  return quelle.substring(start, ende);
}

/// Field name -> right-hand side, for every entry of the response literal.
/// A shorthand entry (`requestId,`) maps to its own name.
Map<String, String> _gelieferteFelder(String literal) {
  final felder = <String, String>{};
  final eintrag = RegExp(r'^\s+([A-Za-z0-9_]+)(?::\s*(.+?))?,\s*$');
  for (final zeile in const LineSplitter().convert(literal)) {
    final treffer = eintrag.firstMatch(zeile);
    if (treffer == null) continue;
    final name = treffer.group(1)!;
    felder[name] = treffer.group(2) ?? name;
  }
  return felder;
}

/// A local HTTP server that answers the one `search-key` GET with [body].
class _KeyServer {
  _KeyServer._(this._server);

  final HttpServer _server;
  Object? body;

  static Future<_KeyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ks = _KeyServer._(server);
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(ks.body));
      await request.response.close();
    });
    return ks;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

void main() {
  late String clientQuelle;
  late String functionQuelle;
  late Set<String> gelesendeFelder;
  late Map<String, String> gelieferteFelder;

  setUpAll(() {
    clientQuelle = _lies(_clientPfad);
    functionQuelle = _lies(_functionPfad);
    gelesendeFelder = RegExp(r"decoded\['([A-Za-z0-9_]+)'\]")
        .allMatches(_fetchRumpf(clientQuelle))
        .map((m) => m.group(1)!)
        .toSet();
    gelieferteFelder = _gelieferteFelder(_antwortLiteral(functionQuelle));
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

  test('die Function liefert ueberhaupt ein lesbares Antwort-Literal', () {
    // Same safety net for the other extraction: an unparsed literal would make
    // the comparison below vacuous instead of red.
    expect(
      gelieferteFelder.keys,
      hasLength(greaterThanOrEqualTo(3)),
      reason:
          'Aus dem Erfolgs-Literal von $_functionPfad liessen sich keine drei '
          'Felder lesen. Gefunden: ${gelieferteFelder.keys.toList()}. Wurde '
          'die Antwort umgebaut, muss dieser Test nachgezogen werden statt '
          'still gruen zu bleiben.',
    );
  });

  test('jedes vom Client gelesene Feld liefert die Function auch wirklich',
      () {
    for (final feld in gelesendeFelder) {
      expect(
        gelieferteFelder.keys,
        contains(feld),
        reason:
            'Der Client liest `$feld` aus der Antwort von search-key, aber '
            'das Erfolgs-Literal in $_functionPfad liefert nur '
            '${gelieferteFelder.keys.toList()}. Der Fetcher bekommt damit '
            '`null` — und `null` heisst per Vertrag „behalte, was du hast". '
            'Die Key-Rotation ist still und dauerhaft tot, waehrend '
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

  group('Verhalten: der echte Client gegen die Feldnamen der echten Function',
      () {
    late _KeyServer server;

    setUp(() async {
      server = await _KeyServer.start();
    });

    tearDown(() => server.close());

    /// Builds the body from the names the FUNCTION emits. The role of each
    /// field is taken from its RIGHT-HAND SIDE in index.ts — the server-side
    /// constants `MIRROR_BASE_URL`, `TTL_SECONDS` and the local `searchKey` —
    /// never from the wire name. So renaming a wire name moves the value to
    /// the new name and the client, still reading the old one, returns `null`.
    Map<String, Object?> koerperAusFunctionNamen() {
      String feldMitRhs(String konstante) {
        final treffer = gelieferteFelder.entries
            .where((e) => e.value.contains(konstante))
            .map((e) => e.key)
            .toList();
        expect(treffer, hasLength(1),
            reason: 'Genau ein Antwortfeld muss aus `$konstante` kommen; '
                'gefunden: $treffer. Wurde index.ts umgebaut, muss dieser '
                'Test nachgezogen werden.');
        return treffer.single;
      }

      return <String, Object?>{
        feldMitRhs('MIRROR_BASE_URL'): 'https://mirror.example',
        feldMitRhs('searchKey'): 'ms-key-123',
        feldMitRhs('TTL_SECONDS'): 600,
      };
    }

    test('eine Antwort mit den Feldnamen der Function ist fuer den Client '
        'lesbar', () async {
      server.body = koerperAusFunctionNamen();

      final creds = await EdgeFunctionSearchKeyFetcher(
        baseUrl: server.baseUrl,
        anonKey: 'anon-key-test',
        tokenProvider: () => 'jwt-abc',
      ).fetch();

      expect(
        creds,
        isNotNull,
        reason:
            'Der echte Fetcher hat die echten Feldnamen der Function nicht '
            'gelesen und `null` geliefert — und `null` heisst „behalte, was '
            'du hast". Function und Client sind auseinandergelaufen. Body '
            'war: ${server.body}',
      );
      expect(creds!.baseUrl, 'https://mirror.example');
      expect(creds.searchKey, 'ms-key-123');
      expect(creds.ttl, const Duration(minutes: 10));
    });
  });
}
