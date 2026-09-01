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

import 'dart:convert';
import 'dart:math' as math;

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
  });

  /// Table -> rows the user really has on the server.
  final Map<String, int> vorhanden;

  /// What PostgREST hands out at most (`db-max-rows`). Supabase default 1000,
  /// well below [DataExportService.einSeitenLimit] — that is the whole point
  /// of the truncation tests. Raised only where OUR OWN cap has to bite.
  final int serverMax;

  /// `false` = a peer that never sends a total (proxy, older PostgREST): the
  /// `Content-Range` stays `*` even under `Prefer: count=exact`, which is the
  /// only situation the over-fetch fallback exists for.
  final bool zaehltMit;

  /// 200, or an error status for the "nothing loaded at all" case.
  final int statusCode;

  /// Requests per table — proof the counting path needs only ONE request.
  final Map<String, int> requests = <String, int>{};

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

    final gesamt = vorhanden[tabelle] ?? 0;
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '') ?? 0;
    final gewuenscht =
        int.tryParse(req.url.queryParameters['limit'] ?? '') ?? gesamt;
    final geliefert = math
        .min(math.min(gewuenscht, serverMax), math.max(gesamt - offset, 0));

    final prefer = req.headers['Prefer'] ?? req.headers['prefer'] ?? '';
    final zaehlt = zaehltMit && prefer.contains('count=exact');
    return http.Response(
      jsonEncode(List.generate(
        geliefert,
        (i) => <String, dynamic>{
          'id': '$tabelle-${offset + i}',
          'user_id': 'user-export',
        },
      )),
      200,
      headers: <String, String>{
        'Content-Type': 'application/json',
        // PostgREST always answers a GET with Content-Range; the total is in
        // it only under `count=exact`, otherwise a `*`.
        'content-range': zaehlt
            ? '$offset-${offset + geliefert - 1}/$gesamt'
            : '$offset-${offset + geliefert - 1}/*',
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
        'grenzeProSektion': DataExportService.einSeitenLimit,
        'sektionen': <String>['chat_messages'],
      },
  };
  return const JsonEncoder.withIndent('  ').convert(map);
}

void main() {
  DataExportService service(_ZaehlenderPostgrest server) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return DataExportService(client, 'user-export');
  }

  group('Kappung, die nicht an unserer eigenen Grenze passiert', () {
    test(
        'kappt der SERVER still bei db-max-rows, steht die Kappung trotzdem im '
        'Export', () async {
      // 4200 rows exist, PostgREST hands out 1000 — the old probe saw nothing
      // because 1000 is far below einSeitenLimit + 1.
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'chat_messages': 4200},
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(
        gekappt,
        isNotNull,
        reason: 'ein stilles Abschneiden durch den Server ist genauso '
            'unauffaellig unvollstaendig wie eines an unserer eigenen Grenze',
      );
      expect(gekappt!['sektionen'], contains('chat_messages'));
      expect(
        (gekappt['zeilenAufDemServer'] as Map)['chat_messages'],
        4200,
        reason: 'ohne die echte Zeilenzahl haelt der Empfaenger wieder eine '
            'fremde Grenze fuer seinen Datenbestand',
      );
      expect(json['chat_messages'], hasLength(1000));
      expect(
        json.containsKey('unvollstaendig'),
        isFalse,
        reason: 'eine gekappte Sektion ist da, nur nicht ganz',
      );
    });

    test('stimmt der Zaehler mit den gelieferten Zeilen ueberein, gibt es '
        'keinen Kappungs-Hinweis', () async {
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 12},
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      expect(json.containsKey('gekappt'), isFalse);
      expect(json['weight_log'], hasLength(12));
    });

    test('auch EINE fehlende Zeile ist eine Kappung', () async {
      // The other side of the same comparison. Both existing cases sit far
      // apart (4200 vs. 1000 / 12 vs. 12), so the check could drift to
      // "clearly fewer" and still pass — while an export missing a single
      // entry would call itself complete.
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': 1001},
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      expect(json['weight_log'], hasLength(1000));
      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(gekappt, isNotNull);
      expect(gekappt!['sektionen'], contains('weight_log'));
      expect((gekappt['zeilenAufDemServer'] as Map)['weight_log'], 1001);
    });

    test('zaehlt der Server gar nicht mit, faengt die Ueberholzeile UNSEREN '
        'eigenen Deckel', () async {
      // The only path that exercises einSeitenLimit itself: no total in the
      // Content-Range, so the counting request throws and the fallback
      // over-fetches by one. Every other test here stays under db-max-rows
      // (1000), where our own 10 000 cap is never reached — so all three of
      // "fetch limit + 1", "report the cut" and "trim the probe row away"
      // could be removed without a single red test.
      const grenze = DataExportService.einSeitenLimit;
      final server = _ZaehlenderPostgrest(
        vorhanden: const <String, int>{'weight_log': grenze + 5},
        serverMax: grenze + 5,
        zaehltMit: false,
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(gekappt, isNotNull, reason: 'unser eigener Deckel schneidet ab');
      expect(gekappt!['sektionen'], contains('weight_log'));
      expect(gekappt['grenzeProSektion'], grenze);
      expect(
        (gekappt['zeilenAufDemServer'] as Map?)?.containsKey('weight_log'),
        isNot(isTrue),
        reason: 'ohne Serverzaehler darf keine Zeilenzahl erfunden werden',
      );
      expect(
        json['weight_log'],
        hasLength(grenze),
        reason: 'die Ueberholzeile ist Messmittel, kein Exportinhalt',
      );
      expect(server.requests['weight_log'], 2,
          reason: 'genau eine Zaehl-Runde und eine Rueckfall-Runde');
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
