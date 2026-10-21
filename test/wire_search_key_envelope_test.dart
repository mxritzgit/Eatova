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
// So this file is the other half, and it runs the REAL client: a body built
// from the field names in the FUNCTION's success literal is served over
// loopback to the real `EdgeFunctionSearchKeyFetcher`. A rename on either
// side, or a new field the client requires, makes the client return `null`
// and turns this red. Source-only comparisons of the two field sets were
// removed in the 2026-10-21 test review: this behaviour check already fails
// on every rename they could see.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/search_credentials.dart';

const String _functionPfad = 'supabase/functions/search-key/index.ts';

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
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
  late Map<String, String> gelieferteFelder;

  setUpAll(() {
    gelieferteFelder =
        _gelieferteFelder(_antwortLiteral(_lies(_functionPfad)));
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
