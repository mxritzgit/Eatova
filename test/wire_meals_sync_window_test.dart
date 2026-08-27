// Wire test for the diary boot window (docs/REVIEW-2026-08-08.md, G2).
//
// WHY THIS FILE SITS NEXT TO sync_query_bounds_test.dart
//
// That test asserts the bounds against the very constants it tests, so setting
// `loggedMealsWindowDays = 0` feeds the 0 into both sides: the assertion still
// passes while every cold start shows an empty diary. Its MockClient also
// answers every request with the same row list, so the `gte` filter is
// inspected but never applied.
//
// This file inverts that:
//
//   * a real loopback `HttpServer` speaks PostgREST — it parses and APPLIES
//     `gte`/`lt`, `order` and `limit`, so rows outside the window do not come
//     back, as in Postgres;
//   * the service runs its full chain over it: URL -> socket -> bytes ->
//     jsonDecode -> `_mealFromRow` -> `LoggedMeal`;
//   * NO assertion names `loggedMealsWindowDays` or `loggedMealsMaxRows`. The
//     EFFECT is checked with fixed numbers.
//
// The last group queries the fake directly over HTTP, so "the filter applies"
// is not itself just a claim about the fake.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/meals_sync.dart';

/// Loopback server implementing the PostgREST semantics `MealsSync` uses:
/// `eq`, `gte`, `lt`, plus `order` and `limit`. Anything else throws, so a
/// newly used filter surfaces here instead of silently passing.
class _PostgrestFake {
  _PostgrestFake._(this._server);

  final HttpServer _server;

  /// Table name -> rows. The rows are what is "in the database"; what the
  /// client sees is decided by the query alone.
  final Map<String, List<Map<String, dynamic>>> tables =
      <String, List<Map<String, dynamic>>>{};

  final List<Uri> requests = <Uri>[];

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port';

  static Future<_PostgrestFake> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _PostgrestFake._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri);
    try {
      final segmente = request.uri.pathSegments;
      if (segmente.length != 3 ||
          segmente[0] != 'rest' ||
          segmente[1] != 'v1') {
        throw StateError('Unerwarteter Pfad: ${request.uri.path}');
      }
      final zeilen = _query(segmente[2], request.uri);
      final bytes = utf8.encode(jsonEncode(zeilen));
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..add(bytes);
    } catch (fehler) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..add(
          utf8.encode(
            jsonEncode(<String, String>{'message': fehler.toString()}),
          ),
        );
    }
    await request.response.close();
  }

  /// The emulation itself: filter -> sort -> cap -> project columns.
  List<Map<String, dynamic>> _query(String tabelle, Uri uri) {
    final bestand = tables[tabelle];
    if (bestand == null) throw StateError('Unbekannte Tabelle: $tabelle');

    var zeilen = bestand.toList();

    for (final eintrag in uri.queryParametersAll.entries) {
      const steuerung = <String>{'select', 'order', 'limit', 'offset'};
      if (steuerung.contains(eintrag.key)) continue;
      for (final filter in eintrag.value) {
        zeilen = zeilen
            .where((zeile) => _trifft(zeile, eintrag.key, filter))
            .toList();
      }
    }

    final order = uri.queryParameters['order'];
    if (order != null) {
      // `logged_at.desc.nullslast` -> column, direction.
      final teile = order.split('.');
      final spalte = teile[0];
      final absteigend = teile.length > 1 && teile[1] == 'desc';
      zeilen.sort((a, b) {
        final links = _sortierschluessel(a[spalte]);
        final rechts = _sortierschluessel(b[spalte]);
        return absteigend ? rechts.compareTo(links) : links.compareTo(rechts);
      });
    }

    final limit = uri.queryParameters['limit'];
    if (limit != null) {
      final deckel = int.parse(limit);
      if (deckel < zeilen.length) zeilen = zeilen.sublist(0, deckel);
    }

    final select = uri.queryParameters['select'];
    if (select == null || select == '*') return zeilen;
    final spalten = select.split(',').map((s) => s.trim()).toList();
    return zeilen
        .map(
          (zeile) => <String, dynamic>{
            for (final spalte in spalten) spalte: zeile[spalte],
          },
        )
        .toList();
  }

  bool _trifft(Map<String, dynamic> zeile, String spalte, String filter) {
    final punkt = filter.indexOf('.');
    if (punkt < 0) throw StateError('Filter ohne Operator: $filter');
    final operator = filter.substring(0, punkt);
    final wert = filter.substring(punkt + 1);
    if (!zeile.containsKey(spalte)) {
      // Fail loudly rather than filter everything away: in Postgres a filter
      // on a missing column is an error, here it would look like a pass.
      throw StateError('Zeile hat keine Spalte "$spalte": $zeile');
    }
    final zelle = zeile[spalte];

    switch (operator) {
      case 'eq':
        return zelle?.toString() == wert;
      case 'gte':
        // timestamptz comparison on the timeline, not on the string: Postgres
        // compares instants regardless of the offset they are written in.
        return !_instant(zelle).isBefore(_instant(wert));
      case 'lt':
        return _instant(zelle).isBefore(_instant(wert));
      default:
        throw StateError(
          'Operator "$operator" ist im PostgREST-Fake nicht implementiert. '
          'Wer ihn in meals_sync.dart benutzt, muss ihn hier nachziehen — '
          'sonst prueft dieser Test ihn nur scheinbar.',
        );
    }
  }

  static DateTime _instant(Object? roh) =>
      DateTime.parse(roh! as String).toUtc();

  static Comparable<Object> _sortierschluessel(Object? zelle) {
    if (zelle is String) {
      final zeit = DateTime.tryParse(zelle);
      if (zeit != null) return zeit.toUtc().toIso8601String();
      return zelle;
    }
    return zelle.toString();
  }
}

/// A `logged_meals` row as PostgREST delivers it: `logged_at` is a UTC
/// instant, the payload the app's JSONB.
Map<String, dynamic> _zeile({
  required String id,
  required DateTime loggedAt,
  String? localDay,
  int kcal = 500,
  String name = 'Mahlzeit',
  String userId = 'user-1',
}) {
  return <String, dynamic>{
    'id': id,
    'user_id': userId,
    'logged_at': loggedAt.toUtc().toIso8601String(),
    'forced_slot': null,
    'local_day': localDay,
    'payload': <String, dynamic>{
      'mealName': name,
      'caloriesKcal': kcal,
      'estimatedGrams': 250,
      'kcalPer100G': 200.0,
      'protein': '20 g',
      'carbs': '50 g',
      'fat': '15 g',
      'confidence': 'Hoch',
      'portionNotes': '',
      'items': <dynamic>[],
      'isAdjusted': false,
      'sourceLabel': 'KI-Schätzung',
    },
  };
}

void main() {
  late _PostgrestFake server;
  late SupabaseClient client;

  setUp(() async {
    server = await _PostgrestFake.start();
    client = SupabaseClient(
      server.url,
      'test-anon-key',
      // No GoTrue auto-refresh ticker in tests.
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
  });

  tearDown(() async {
    await client.dispose();
    await server.close();
  });

  group('Boot-Fenster: was im Fenster liegt, sieht die App auch', () {
    // The guard against a zeroed window. None of these numbers come from
    // MealsSync; they describe what a user expects.
    setUp(() {
      final jetzt = DateTime.now().toUtc();
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        _zeile(
          id: 'vor-2-stunden',
          loggedAt: jetzt.subtract(const Duration(hours: 2)),
          kcal: 640,
          name: 'Mittagessen heute',
        ),
        _zeile(
          id: 'gestern',
          loggedAt: jetzt.subtract(const Duration(days: 1)),
          kcal: 520,
        ),
        _zeile(
          id: 'vor-6-tagen',
          loggedAt: jetzt.subtract(const Duration(days: 6)),
          kcal: 410,
        ),
        _zeile(
          id: 'vor-30-tagen',
          loggedAt: jetzt.subtract(const Duration(days: 30)),
          kcal: 380,
        ),
        _zeile(
          id: 'vor-300-tagen',
          loggedAt: jetzt.subtract(const Duration(days: 300)),
          kcal: 300,
        ),
      ];
    });

    // Membership is one question asked of four ages, so it runs as one
    // parametrised block — each age keeps its own name and its own reason.
    for (final (id, imFenster, grund) in const <(String, bool, String)>[
      (
        'vor-2-stunden',
        true,
        'Das Boot-Fenster darf die Gegenwart nicht ausschliessen. Ein Fenster '
            'von 0 Tagen setzt den Cutoff auf JETZT — dann faellt jede bereits '
            'geloggte Mahlzeit heraus und das Tagebuch ist beim Kaltstart leer.'
      ),
      (
        'gestern',
        true,
        'Der gestrige Tag ist der meistgeoeffnete Kalendertag ueberhaupt.'
      ),
      (
        'vor-30-tagen',
        true,
        'Der Kalender im Food-Tab laedt Tage innerhalb des Boot-Fensters ohne '
            'Nachladen. Ein Fenster unter 30 Tagen schrumpft diese Historie '
            'still.'
      ),
      (
        'vor-300-tagen',
        false,
        'Ohne Fenster laedt jeder Kaltstart die gesamte Historie inkl. '
            'JSONB-Payload.'
      ),
    ]) {
      final wasPassiert = imFenster
          ? 'ueberlebt den Kaltstart'
          : 'bleibt draussen (Fenster ist gedeckelt)';
      test('$id $wasPassiert', () async {
        final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

        expect(meals.map((m) => m.id),
            imFenster ? contains(id) : isNot(contains(id)),
            reason: grund);
      });
    }

    test('Ergebnis kommt neueste zuerst, so wie bestellt', () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(meals.map((m) => m.id).toList(), <String>[
        'vor-2-stunden',
        'gestern',
        'vor-6-tagen',
        'vor-30-tagen',
      ]);
      expect(meals, hasLength(4),
          reason: 'genau die vier im Fenster, nichts Aelteres');
      // And the payload of the newest one arrives complete.
      expect(meals.first.result.mealName, 'Mittagessen heute');
      expect(meals.first.result.caloriesKcal, 640);
    });

    test('die Anfrage holt alle fuenf Spalten, die _mealFromRow braucht',
        () async {
      await MealsSync(client, 'user-1').loadLoggedMeals();

      final select = server.requests.single.queryParameters['select'];
      expect(select, isNotNull);
      expect(
        select!.split(',').map((s) => s.trim()),
        containsAll(<String>[
          'id',
          'logged_at',
          'forced_slot',
          'local_day',
          'payload',
        ]),
        reason:
            'Eine fehlende Spalte laesst _mealFromRow auf null laufen bzw. '
            'kippt das local_day-Bucketing still auf den Alt-Pfad.',
      );
    });

    test('logged_at kommt als LOKALE Zeit zurueck, nicht als UTC-Instanz',
        () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      // Zone-independent: `.toLocal()` always yields isUtc == false, even on
      // a UTC machine. Without it, meals would bucket by UTC calendar day.
      for (final meal in meals) {
        expect(
          meal.loggedAt.isUtc,
          isFalse,
          reason:
              'meals_sync.dart:110 muss die Server-Instant in die lokale Zone '
              'holen — LoggedMeal.slot und das Bucketing lesen danach '
              'Wanduhr-Felder.',
        );
      }
      // The instant itself is unchanged.
      final erste = meals.first.loggedAt.toUtc().toIso8601String();
      expect(
        erste,
        (server.tables['logged_meals']!.first['logged_at'] as String),
      );
    });
  });

  group('Zeilen-Deckel: der Deckel deckelt, aber nicht das Tagebuch', () {
    test('60 Mahlzeiten der letzten drei Tage kommen vollstaendig an', () async {
      final jetzt = DateTime.now().toUtc();
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          _zeile(id: 'm$i', loggedAt: jetzt.subtract(Duration(hours: i))),
      ];

      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(
        meals.length,
        60,
        reason:
            'Der Deckel ist ein Schutz gegen das stille db-max-rows, kein '
            'Anzeigelimit. Ein zu kleiner Deckel schneidet reale Tage ab.',
      );
    });

    test('der Deckel steht ueberhaupt auf dem Wire', () async {
      server.tables['logged_meals'] = <Map<String, dynamic>>[];
      await MealsSync(client, 'user-1').loadLoggedMeals();

      final limit = server.requests.single.queryParameters['limit'];
      expect(limit, isNotNull, reason: 'Ohne Limit kappt PostgREST STILL.');
      expect(int.parse(limit!), greaterThanOrEqualTo(500));
    });
  });

  group('Tages-Query: halboffenes Fenster der lokalen Wanduhr', () {
    // Effect check for loadLoggedMealsForDay: the server filters translated
    // instants while the test thinks in local time, so the local-midnight ->
    // UTC translation is part of the assertion, not a re-derived formula.
    setUp(() {
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        _zeile(id: 'vortag-2345', loggedAt: DateTime(2026, 3, 13, 23, 45)),
        _zeile(id: 'tag-0015', loggedAt: DateTime(2026, 3, 14, 0, 15)),
        _zeile(id: 'tag-1200', loggedAt: DateTime(2026, 3, 14, 12, 0)),
        _zeile(id: 'tag-2345', loggedAt: DateTime(2026, 3, 14, 23, 45)),
        _zeile(id: 'folgetag-0015', loggedAt: DateTime(2026, 3, 15, 0, 15)),
      ];
    });

    test('genau die Mahlzeiten des lokalen Kalendertags, neueste zuerst',
        () async {
      final meals = await MealsSync(
        client,
        'user-1',
      ).loadLoggedMealsForDay(DateTime(2026, 3, 14, 15, 30));

      expect(meals.map((m) => m.id).toList(), <String>[
        'tag-2345',
        'tag-1200',
        'tag-0015',
      ]);
    });

    test('23:45 Ortszeit gehoert zum Tag, 00:15 des Folgetags nicht', () async {
      final meals = await MealsSync(
        client,
        'user-1',
      ).loadLoggedMealsForDay(DateTime(2026, 3, 14));

      expect(meals.map((m) => m.id), contains('tag-2345'));
      expect(meals.map((m) => m.id), isNot(contains('folgetag-0015')));
      expect(meals.map((m) => m.id), isNot(contains('vortag-2345')));
    });

    test('der Folgetag sieht genau seinen eigenen Eintrag', () async {
      final meals = await MealsSync(
        client,
        'user-1',
      ).loadLoggedMealsForDay(DateTime(2026, 3, 15));

      expect(meals.map((m) => m.id).toList(), <String>['folgetag-0015']);
    });
  });

  group('Der PostgREST-Fake verhaelt sich wie PostgREST', () {
    // Without this group, "the filter applies" would be a claim about the
    // fake. Here the server is queried directly over HTTP.
    setUp(() {
      server.tables['probe'] = <Map<String, dynamic>>[
        <String, dynamic>{'id': 'a', 'at': '2026-03-14T00:00:00Z', 'u': 'x'},
        <String, dynamic>{'id': 'b', 'at': '2026-03-15T00:00:00Z', 'u': 'x'},
        <String, dynamic>{'id': 'c', 'at': '2026-03-16T00:00:00Z', 'u': 'y'},
      ];
    });

    Future<List<dynamic>> hole(String query) async {
      final antwort = await HttpClient()
          .getUrl(Uri.parse('${server.url}/rest/v1/probe?$query'))
          .then((r) => r.close());
      expect(antwort.statusCode, 200);
      final koerper = await antwort.transform(utf8.decoder).join();
      return jsonDecode(koerper) as List<dynamic>;
    }

    List<String> ids(List<dynamic> zeilen) =>
        zeilen.map((z) => (z as Map<String, dynamic>)['id'] as String).toList();

    test('gte ist inklusive, lt ist exklusiv', () async {
      expect(ids(await hole('at=gte.2026-03-15T00:00:00Z')), <String>['b', 'c']);
      expect(ids(await hole('at=lt.2026-03-15T00:00:00Z')), <String>['a']);
      expect(
        ids(
          await hole(
            'at=gte.2026-03-14T00:00:00Z&at=lt.2026-03-16T00:00:00Z',
          ),
        ),
        <String>['a', 'b'],
      );
      // And the degenerate case: a window starting NOW returns nothing past —
      // exactly the effect of loggedMealsWindowDays = 0.
      final jetzt = DateTime.now().toUtc().toIso8601String();
      expect(ids(await hole('at=gte.$jetzt')), isEmpty);
    });

    test('eq filtert, order sortiert, limit deckelt', () async {
      expect(ids(await hole('u=eq.x')), <String>['a', 'b']);
      expect(
        ids(await hole('order=at.desc.nullslast')),
        <String>['c', 'b', 'a'],
      );
      expect(ids(await hole('order=at.desc.nullslast&limit=2')), <String>[
        'c',
        'b',
      ]);
      expect(ids(await hole('limit=0')), isEmpty);
    });

    test('select projiziert genau die angefragten Spalten', () async {
      final zeilen = await hole('select=id,at');
      expect((zeilen.first as Map<String, dynamic>).keys, <String>['id', 'at']);
    });
  });

  group('LoggedMeal-Konstruktion aus echten Bytes', () {
    test('Payload, Slot und local_day kommen vollstaendig durch', () async {
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        <String, dynamic>{
          ..._zeile(
            id: 'voll',
            loggedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            localDay: '2026-03-14',
            kcal: 777,
            name: 'Lachsbowl',
          ),
          'forced_slot': 'dinner',
        },
      ];

      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();
      final meal = meals.single;

      expect(meal.id, 'voll');
      expect(meal.result.mealName, 'Lachsbowl');
      expect(meal.result.caloriesKcal, 777);
      expect(meal.result.protein, '20 g');
      expect(meal.forcedSlot, MealSlot.dinner);
      expect(meal.slot, MealSlot.dinner);
      expect(meal.localDay, '2026-03-14');
      expect(meal.effectiveLocalDay, '2026-03-14');
    });
  });
}
