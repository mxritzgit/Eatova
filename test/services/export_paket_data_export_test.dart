// Two DataExportService findings (review 2026-08-19):
//
// 1. Truncation detection assumed the server really hands out `limit`+1 rows.
//    PostgREST does not: with `db-max-rows` (Supabase default 1000) it cuts
//    silently, so the probe row never arrived and the recipient mistook 1000
//    rows for their whole data set.
// 2. `buildExportJson` catches every section error and never throws offline,
//    so measuring only "no error" reports a complete export even when no
//    section arrived.
//
// The fake here therefore behaves like real PostgREST: a `Content-Range` on
// every GET, the total only under `Prefer: count=exact`, and never more rows
// than `db-max-rows` allows.
//
// Since the 2026-10-19 review every section is keyset-paged until an empty
// page, so a server cap no longer truncates anything; `gekappt` is left for
// rows behind the service's own per-section bound.

import 'dart:convert';
import 'dart:io';

import '../support/recipe_read_fake.dart';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/data_export.dart';

class _ZaehlenderPostgrest {
  _ZaehlenderPostgrest({
    this.vorhanden = const <String, int>{},
    this.statusCode = 200,
    this.serverMax = 1000,
    this.zaehltMit = true,
    this.ignoriertCursor = false,
    this.loeschtNachErsterSeite = const <String>{},
  });

  /// Table -> rows the user really has on the server.
  final Map<String, int> vorhanden;

  /// What PostgREST hands out at most (`db-max-rows`, live 1000): a page
  /// never holds more, whatever the client asks for.
  final int serverMax;

  /// `false` = a peer that never sends a total (proxy, older PostgREST): the
  /// `Content-Range` stays `*` even under `Prefer: count=exact`, which is the
  /// only situation the uncounted first-page read exists for.
  final bool zaehltMit;

  /// A faulty peer that ignores the keyset filter and repeats page one.
  final bool ignoriertCursor;

  /// Tables whose last row another device deletes right after page one.
  final Set<String> loeschtNachErsterSeite;

  /// 200, or an error status for the "nothing loaded at all" case.
  final int statusCode;

  /// Requests per table — proof the counting path needs only ONE request.
  final Map<String, int> requests = <String, int>{};

  final Map<String, Set<int>> _geloescht = <String, Set<int>>{};

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final tabelle = req.url.path.split('/').last;
    requests[tabelle] = (requests[tabelle] ?? 0) + 1;

    if (statusCode != 200) {
      return http.Response(
        jsonEncode(<String, dynamic>{'message': 'kaputt'}),
        statusCode,
        headers: const <String, String>{'Content-Type': 'application/json'},
        request: req,
      );
    }

    final recipe = emptyRecipeReadResponse(req);
    if (recipe != null) return recipe;

    // Like PostgREST: ordered by the requested column, `<key>=gt.<value>`
    // applied, then `limit` capped at db-max-rows. Keys are zero-padded so
    // their text order is their row order.
    final schluessel =
        (req.url.queryParameters['order'] ?? 'id.asc').split('.').first;
    final gesamt = vorhanden[tabelle] ?? 0;
    final geloescht = _geloescht[tabelle] ?? const <int>{};
    var zeilen = <Map<String, dynamic>>[
      for (var i = 0; i < gesamt; i++)
        if (!geloescht.contains(i))
          <String, dynamic>{
            schluessel: '$tabelle-${i.toString().padLeft(6, '0')}',
            'user_id': 'user-export',
          },
    ];
    final nach = (req.url.queryParametersAll[schluessel] ?? const <String>[])
        .where((wert) => wert.startsWith('gt.'))
        .map((wert) => wert.substring(3))
        .firstOrNull;
    if (nach != null && !ignoriertCursor) {
      zeilen = zeilen
          .where((zeile) => (zeile[schluessel] as String).compareTo(nach) > 0)
          .toList();
    }
    final gewuenscht =
        int.tryParse(req.url.queryParameters['limit'] ?? '') ?? zeilen.length;
    final geliefert = zeilen.take(math.min(gewuenscht, serverMax)).toList();
    if (nach == null && loeschtNachErsterSeite.contains(tabelle)) {
      _geloescht.putIfAbsent(tabelle, () => <int>{}).add(gesamt - 1);
    }

    final prefer = req.headers['Prefer'] ?? req.headers['prefer'] ?? '';
    final zaehlt = zaehltMit && prefer.contains('count=exact');
    final summe = zaehlt ? '${zeilen.length}' : '*';
    return http.Response(
      jsonEncode(geliefert),
      200,
      headers: <String, String>{
        'Content-Type': 'application/json',
        // PostgREST always answers a GET with Content-Range; the total is in
        // it only under `count=exact`, otherwise a `*`.
        'content-range': geliefert.isEmpty
            ? '*/$summe'
            : '0-${geliefert.length - 1}/$summe',
      },
      request: req,
    );
  }
}

/// Builds a finished export JSON by hand, for the scope detection that works
/// on the result rather than on the service.
String _exportJson({
  Iterable<String>? sektionen,
  List<String> unvollstaendig = const <String>[],
  bool gekappt = false,
  String format = DataExportService.formatKennung,
}) {
  final map = <String, dynamic>{
    'format': format,
    'exportedAt': '2026-08-19T10:00:00.000Z',
    'userId': 'user-export',
    for (final tabelle
        in sektionen ?? DataExportService.alleExportTabellen)
      tabelle: <dynamic>[],
    if (unvollstaendig.isNotEmpty) 'unvollstaendig': unvollstaendig,
    if (gekappt)
      'gekappt': <String, dynamic>{
        'grenzeProSektion': DataExportService.standardGrenzeProSektion,
        'sektionen': <String>['chat_messages'],
      },
  };
  return const JsonEncoder.withIndent('  ').convert(map);
}

void main() {
  DataExportService service(
    _ZaehlenderPostgrest server, {
    int pageSize = 1000,
    int grenze = DataExportService.standardGrenzeProSektion,
  }) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return DataExportService(
      client,
      'user-export',
      pageSize: pageSize,
      grenzeProSektion: grenze,
    );
  }

  List<String> ids(Map<String, dynamic> json, String tabelle) =>
      (json[tabelle] as List).map((row) => (row as Map)['id'] as String).toList();

  List<String> erwartet(String tabelle, int anzahl) => <String>[
    for (var i = 0; i < anzahl; i++) '$tabelle-${i.toString().padLeft(6, '0')}',
  ];

  group('Keyset-Paging: eine Servergrenze schneidet keine Sektion mehr ab', () {
    test(
        'max_rows 1000: 4200 Coach-Nachrichten kommen vollstaendig, '
        'ohne Duplikate und ohne Kappungs-Hinweis an', () async {
      // 2026-10-19 review: each section was one `limit(10000)` page, live
      // PostgREST returned 1000 and the export reported the rest as cut.
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'chat_messages': 4200},
      );
      final text = await service(server).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(ids(json, 'chat_messages'), erwartet('chat_messages', 4200));
      expect(json, isNot(contains('gekappt')));
      expect(json, isNot(contains('vollstaendigkeitUnbekannt')));
      expect(json, isNot(contains('unvollstaendig')));
      expect(exportUmfangAus(text), ExportUmfang.vollstaendig);
      expect(server.requests['chat_messages'], 6,
          reason: 'fuenf volle oder kurze Seiten, dann die leere Seite');
    });

    test('max_rows 500 unter der Seitengroesse: jede Sektion bleibt komplett',
        () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{
          'weight_log': 1234,
          'favorite_meals': 501,
          'chat_quota_usage': 777,
          'profiles': 1,
        },
        serverMax: 500,
      );
      final text = await service(server).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(ids(json, 'weight_log'), erwartet('weight_log', 1234));
      // Sections keyed by another column page on that column.
      expect(
        (json['favorite_meals'] as List).map((row) => (row as Map)['favorite_key']),
        erwartet('favorite_meals', 501),
      );
      expect(
        (json['chat_quota_usage'] as List).map((row) => (row as Map)['day']),
        erwartet('chat_quota_usage', 777),
      );
      expect(json['profiles'], hasLength(1));
      expect(exportUmfangAus(text), ExportUmfang.vollstaendig);
    });

    test('ohne Zaehler und mit niedriger Servergrenze kommt per Keyset '
        'trotzdem alles an', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const {'weight_log': 5},
        serverMax: 2,
        zaehltMit: false,
      );
      final text = await service(server).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(ids(json, 'weight_log'), erwartet('weight_log', 5));
      expect(exportUmfangAus(text), ExportUmfang.vollstaendig,
          reason: 'erst die leere Seite beweist das Ende, kein Zaehler noetig');
      expect(server.requests['weight_log'], 5,
          reason: 'Zaehlversuch, dieselbe Seite ohne Zaehler, zwei weitere, '
              'dann die leere Seite');
    });

    test('jede Folgeseite fragt nach dem letzten Schluessel, nie nach Offsets',
        () async {
      final anfragen = <Uri>[];
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 5},
        serverMax: 2,
      );
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) {
          if (req.url.path.endsWith('/weight_log')) anfragen.add(req.url);
          return server._handle(req);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      await DataExportService(client, 'user-export').buildExportJson();

      expect(anfragen.map((url) => url.queryParametersAll['id']), [
        null,
        ['gt.weight_log-000001'],
        ['gt.weight_log-000003'],
        ['gt.weight_log-000004'],
      ]);
      for (final url in anfragen) {
        expect(url.queryParameters['user_id'], 'eq.user-export');
        expect(url.queryParameters['order'], startsWith('id.asc'));
        expect(url.queryParameters, isNot(contains('offset')));
      }
    });

    test('ein Server ohne Seitenfortschritt endet als unvollstaendig, nicht '
        'als Endlosschleife', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 5},
        serverMax: 2,
        ignoriertCursor: true,
      );
      final text = await service(server).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(json['unvollstaendig'], contains('weight_log'));
      expect(json, isNot(contains('weight_log')));
      expect(exportUmfangAus(text), ExportUmfang.teilweise);
      expect(server.requests['weight_log'], 2);
    });

    test('verschwindet waehrend des Pagings eine Zeile, ist die Sektion nicht '
        'als vollstaendig belegt', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'chat_messages': 5},
        serverMax: 2,
        loeschtNachErsterSeite: const <String>{'chat_messages'},
      );
      final text = await service(server).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(ids(json, 'chat_messages'), erwartet('chat_messages', 4));
      expect(json['vollstaendigkeitUnbekannt'], ['chat_messages']);
      expect(exportUmfangAus(text), ExportUmfang.teilweise);
    });

    test('jede gepagte Sektion hat eine Schluesselspalte', () {
      for (final tabelle in <String>[
        'profiles',
        ...DataExportService.userIdTabellen.where((t) => t != 'user_recipes'),
      ]) {
        expect(DataExportService.schluesselSpalten, contains(tabelle),
            reason: '$tabelle landet ohne Schluessel in unvollstaendig');
      }
    });

    test('die Schluesselspalten sind die Primaerschluessel laut Migrationen',
        () {
      // A non-unique keyset column would skip rows that share a value at a
      // page boundary, so the column must be the primary key without user_id.
      final sql = Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((datei) => datei.path.endsWith('.sql'))
          .map((datei) => datei.readAsStringSync())
          .join('\n');
      for (final MapEntry(key: tabelle, value: spalte)
          in DataExportService.schluesselSpalten.entries) {
        final block = RegExp(
          'create table (?:if not exists )?public\\.$tabelle \\((.*?)\\r?\\n\\);',
          dotAll: true,
        ).firstMatch(sql);
        expect(block, isNotNull, reason: tabelle);
        final spalten = block!.group(1)!;
        final inline = RegExp('^\\s*$spalte\\s+[a-z]+\\s+primary key',
                multiLine: true)
            .hasMatch(spalten);
        final zusammengesetzt = RegExp(
          'primary key\\s*\\(\\s*user_id\\s*,\\s*$spalte\\s*\\)',
        ).hasMatch(spalten);
        expect(inline || zusammengesetzt, isTrue,
            reason: '$tabelle.$spalte ist nicht ihr Primaerschluessel');
      }
    });
  });

  group('die eigene Grenze pro Sektion', () {
    test('eine Zeile hinter der Grenze ist eine Kappung, mit echter '
        'Serverzahl', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 11},
      );
      final json = jsonDecode(
        await service(server, pageSize: 4, grenze: 10).buildExportJson(),
      ) as Map<String, dynamic>;

      expect(ids(json, 'weight_log'), erwartet('weight_log', 10),
          reason: 'die Pruefzeile ist Messmittel, kein Exportinhalt');
      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(gekappt, isNotNull);
      expect(gekappt!['sektionen'], ['weight_log']);
      expect(gekappt['grenzeProSektion'], 10);
      expect((gekappt['zeilenAufDemServer'] as Map)['weight_log'], 11);
      expect(json, isNot(contains('unvollstaendig')),
          reason: 'eine gekappte Sektion ist da, nur nicht ganz');
    });

    test('genau die Grenze ist KEINE Kappung', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 10},
      );
      final text =
          await service(server, pageSize: 4, grenze: 10).buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(ids(json, 'weight_log'), erwartet('weight_log', 10));
      expect(json, isNot(contains('gekappt')));
      expect(exportUmfangAus(text), ExportUmfang.vollstaendig);
    });

    test('zaehlt der Server gar nicht mit, faengt die Pruefzeile die Grenze '
        'ohne erfundene Zeilenzahl', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 15},
        zaehltMit: false,
      );
      final json = jsonDecode(
        await service(server, pageSize: 4, grenze: 10).buildExportJson(),
      ) as Map<String, dynamic>;

      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(gekappt, isNotNull, reason: 'die eigene Grenze schneidet ab');
      expect(gekappt!['sektionen'], contains('weight_log'));
      expect(
        (gekappt['zeilenAufDemServer'] as Map?)?.containsKey('weight_log'),
        isNot(isTrue),
        reason: 'ohne Serverzaehler darf keine Zeilenzahl erfunden werden',
      );
      expect(ids(json, 'weight_log'), erwartet('weight_log', 10));
      expect(server.requests['weight_log'], 5,
          reason: 'Zaehlversuch, Rueckfall, zwei Seiten, eine Pruefzeile');
    });

    test('der Zaehler kommt im SELBEN Request mit — keine zweite Runde pro '
        'Tabelle', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 3},
      );
      await service(server).buildExportJson();

      expect(
        server.requests['weight_log'],
        1,
        reason: 'ein zweiter Request pro Tabelle waere der Rueckfallweg — der '
            'darf nur greifen, wenn der Server gar nicht mitzaehlt',
      );
    });
  });

  group('ohne Netz', () {
    /// A client whose requests fail at once like a phone in airplane mode,
    /// except [antwortet] (path -> rows as a counted 200).
    (SupabaseClient, Map<String, int>) netzlos({
      Map<String, int> antwortet = const <String, int>{},
    }) {
      final anfragen = <String, int>{};
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) async {
          final tabelle = req.url.path.split('/').last;
          anfragen[tabelle] = (anfragen[tabelle] ?? 0) + 1;
          final zeilen = antwortet[tabelle];
          if (zeilen == null) {
            throw const SocketException('Failed host lookup');
          }
          return http.Response(
            jsonEncode(<Object>[]),
            200,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'content-range': '*/$zeilen',
            },
            request: req,
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      return (client, anfragen);
    }

    test('offline endet der Export sofort, jede Sektion fehlt ausgewiesen', () {
      // Built outside the fake zone, so the teardown's dispose can finish.
      final (client, anfragen) = netzlos();
      fakeAsync((async) {
        String? roh;
        DataExportService(client, 'user-export')
            .buildExportJson()
            .then((json) => roh = json);
        async.elapse(const Duration(seconds: 1));

        // Before, every GET waited out the client's 1 + 2 + 4 s backoff and
        // the counted read sent a second GET: about 189 s of spinner.
        expect(roh, isNotNull, reason: 'der Export wartet noch auf Backoff');
        final json = jsonDecode(roh!) as Map<String, dynamic>;
        expect(json['unvollstaendig'], DataExportService.alleExportTabellen);
        expect(exportUmfangAus(roh!), ExportUmfang.nichtsGeladen);
        expect(
          anfragen,
          <String, int>{'profiles': 1},
          reason: 'die erste Netzantwort zeigt: das Geraet ist offline',
        );
      });
    });

    test('faellt das Netz nach der ersten Sektion, kommt jede Sektion noch '
        'genau einmal dran', () {
      final (client, anfragen) = netzlos(
        antwortet: const <String, int>{'profiles': 0},
      );
      fakeAsync((async) {
        String? roh;
        DataExportService(client, 'user-export')
            .buildExportJson()
            .then((json) => roh = json);
        async.elapse(const Duration(seconds: 1));

        expect(roh, isNotNull);
        final json = jsonDecode(roh!) as Map<String, dynamic>;
        expect(
          json['unvollstaendig'],
          DataExportService.alleExportTabellen.skip(1),
        );
        expect(exportUmfangAus(roh!), ExportUmfang.teilweise);
        for (final tabelle in <String>['logged_meals', 'weight_log']) {
          expect(anfragen[tabelle], 1, reason: tabelle);
        }
      });
    });
  });

  group('wieviel eine fertige Auskunft wirklich enthaelt', () {
    test('scheitert JEDE Sektion, ist das nicht „vollstaendig" sondern '
        '„nichts geladen"', () async {
      final server = _ZaehlenderPostgrest(statusCode: 500);
      final roh = await service(server).buildExportJson();

      // The service still does not throw, which is exactly why the caller
      // cannot read completeness off a missing error.
      final json = jsonDecode(roh) as Map<String, dynamic>;
      expect(json['unvollstaendig'], hasLength(
          DataExportService.alleExportTabellen.length));
      expect(exportUmfangAus(roh), ExportUmfang.nichtsGeladen);
    });

    test('alle Sektionen da und nichts abgeschnitten heisst vollstaendig', () {
      expect(exportUmfangAus(_exportJson()), ExportUmfang.vollstaendig);
    });

    test('eine fehlende Sektion heisst teilweise — nicht vollstaendig', () {
      final ohneChat = DataExportService.alleExportTabellen
          .where((t) => t != 'chat_messages');
      expect(
        exportUmfangAus(_exportJson(
          sektionen: ohneChat,
          unvollstaendig: const <String>['chat_messages'],
        )),
        ExportUmfang.teilweise,
      );
    });

    test('eine gekappte Sektion heisst ebenfalls teilweise', () {
      expect(
        exportUmfangAus(_exportJson(gekappt: true)),
        ExportUmfang.teilweise,
      );
    });

    test('fremder Text bekommt kein Urteil — Raten waere derselbe Fehler',
        () {
      expect(exportUmfangAus('kein JSON'), isNull);
      expect(exportUmfangAus('{"logged_meals": ["alle Zeilen"]}'), isNull);
      expect(exportUmfangAus(_exportJson(format: 'fremd/1')), isNull);
    });
  });
}
