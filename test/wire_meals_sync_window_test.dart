// Wire-Test fuer das Boot-Fenster des Tagebuchs (docs/REVIEW-2026-08-08.md, G2,
// Schalter 1: `meals_sync.dart:26` -> `loggedMealsWindowDays = 0`).
//
// WARUM DIESE DATEI NEBEN sync_query_bounds_test.dart STEHT
//
// `test/services/sync_query_bounds_test.dart` prueft die Grenzen gegen die
// Konstanten, die sie testet:
//
//     expect(params['limit'], '${MealsSync.loggedMealsMaxRows}');
//     expect(age.inDays, inInclusiveRange(
//       MealsSync.loggedMealsWindowDays - 1, MealsSync.loggedMealsWindowDays));
//
// Setzt jemand `loggedMealsWindowDays = 0`, wandert die 0 in BEIDE Seiten der
// Behauptung: der Cutoff liegt dann 0 Tage zurueck, `inInclusiveRange(-1, 0)`
// ist erfuellt, der Test bleibt gruen — und jeder Kaltstart zeigt ein leeres
// Tagebuch. Derselbe Test laesst ausserdem den MockClient jede Anfrage mit
// DERSELBEN Zeilenliste beantworten: der `gte`-Filter, um den es geht, hat auf
// dem Rueckweg keinerlei Wirkung. Er wird angeschaut, aber nie angewandt.
//
// Diese Datei dreht das um:
//
//   * Ein echter Loopback-`HttpServer` spricht PostgREST: er PARST
//     `logged_at=gte.…` / `lt.…`, `order=…` und `limit=…` aus der URL und
//     WENDET SIE AN. Was ausserhalb des angefragten Fensters liegt, kommt
//     nicht zurueck — genauso wie in Postgres.
//   * Der Service faehrt seine vollstaendige Kette darueber: postgrest-dart
//     baut die URL -> echter Socket -> Bytes -> jsonDecode -> `_mealFromRow`
//     -> `LoggedMeal`. Kein MockClient, kein vorgefertigtes Zeilen-Literal.
//   * KEINE Behauptung nennt `loggedMealsWindowDays` oder
//     `loggedMealsMaxRows`. Geprueft wird die WIRKUNG mit festen Zahlen:
//     „eine vor zwei Stunden geloggte Mahlzeit ist nach dem Kaltstart da",
//     „eine 30 Tage alte auch", „eine 300 Tage alte nicht".
//
// Die Gegenprobe zum Fake selbst steht in der letzten Gruppe: dort wird der
// Server ohne den Service direkt per HTTP befragt, damit „der Filter greift"
// nicht selbst nur eine Behauptung ueber den Fake ist.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/meals_sync.dart';

/// Loopback-Server, der die PostgREST-Semantik der drei Operatoren
/// implementiert, die `MealsSync` benutzt: `eq`, `gte`, `lt` — dazu `order`
/// und `limit`. Alles andere ist bewusst nicht implementiert und wirft, damit
/// eine spaeter dazukommende Filterart hier auffaellt statt still zu wirken.
class _PostgrestFake {
  _PostgrestFake._(this._server);

  final HttpServer _server;

  /// Tabellenname -> Zeilen. Die Zeilen sind das, was „in der Datenbank
  /// steht"; was der Client sieht, entscheidet allein die Query.
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

  /// Die eigentliche Emulation: filtern -> sortieren -> deckeln -> Spalten
  /// projizieren.
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
      // `logged_at.desc.nullslast` -> Spalte, Richtung.
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
      // Lieber laut scheitern als still alles wegfiltern: ein Filter auf eine
      // Spalte, die es nicht gibt, ist in Postgres ein Fehler — hier waere er
      // sonst ein leeres Ergebnis, das wie ein bestandener Test aussieht.
      throw StateError('Zeile hat keine Spalte "$spalte": $zeile');
    }
    final zelle = zeile[spalte];

    switch (operator) {
      case 'eq':
        return zelle?.toString() == wert;
      case 'gte':
        // timestamptz-Vergleich auf der Zeitachse, nicht auf dem String —
        // Postgres vergleicht Instants, egal in welchem Offset sie notiert
        // sind.
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

/// Eine `logged_meals`-Zeile, wie PostgREST sie liefert: `logged_at` ist eine
/// UTC-Instant-Notation, der Payload das JSONB der App.
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
      // Kein GoTrue-Auto-Refresh-Ticker im Test (Muster aus
      // sync_query_bounds_test.dart).
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
  });

  tearDown(() async {
    await client.dispose();
    await server.close();
  });

  group('Boot-Fenster: was im Fenster liegt, sieht die App auch', () {
    // DAS ist die Wache gegen Schalter 1. Keine dieser Zahlen kommt aus
    // MealsSync — sie beschreiben, was ein Nutzer erwartet.
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

    test('eine vor zwei Stunden geloggte Mahlzeit ueberlebt den Kaltstart', () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(
        meals.map((m) => m.id),
        contains('vor-2-stunden'),
        reason:
            'Das Boot-Fenster darf die Gegenwart nicht ausschliessen. Ein '
            'Fenster von 0 Tagen setzt den Cutoff auf JETZT — dann faellt '
            'jede bereits geloggte Mahlzeit heraus und das Tagebuch ist beim '
            'Kaltstart leer.',
      );
      expect(meals, isNotEmpty);
      expect(meals.first.result.mealName, 'Mittagessen heute');
      expect(meals.first.result.caloriesKcal, 640);
    });

    test('eine 30 Tage alte Mahlzeit liegt noch im Fenster', () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(
        meals.map((m) => m.id),
        contains('vor-30-tagen'),
        reason:
            'Der Kalender im Food-Tab laedt Tage innerhalb des Boot-Fensters '
            'ohne Nachladen. Ein Fenster unter 30 Tagen schrumpft diese '
            'Historie still.',
      );
    });

    test('eine 300 Tage alte Mahlzeit bleibt draussen (Fenster ist gedeckelt)',
        () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(
        meals.map((m) => m.id),
        isNot(contains('vor-300-tagen')),
        reason:
            'Ohne Fenster laedt jeder Kaltstart die gesamte Historie inkl. '
            'JSONB-Payload.',
      );
      expect(meals.length, 4);
    });

    test('Ergebnis kommt neueste zuerst, so wie bestellt', () async {
      final meals = await MealsSync(client, 'user-1').loadLoggedMeals();

      expect(meals.map((m) => m.id).toList(), <String>[
        'vor-2-stunden',
        'gestern',
        'vor-6-tagen',
        'vor-30-tagen',
      ]);
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

      // Zonenunabhaengig pruefbar: `.toLocal()` liefert immer isUtc == false,
      // auch auf einer UTC-Maschine. Faellt das weg, buckete jede Mahlzeit
      // spaeter nach UTC-Kalendertag (siehe wire_local_day_probe.dart).
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
      // Der Instant selbst bleibt derselbe.
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
    // Wirkungsprobe fuer loadLoggedMealsForDay: der Server filtert auf den
    // UEBERSETZTEN Instants, der Test denkt in Ortszeit. Damit ist die
    // Uebersetzung lokale Mitternacht -> UTC Teil der Behauptung und nicht
    // nur eine nachgerechnete Formel.
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
    // Ohne diese Gruppe waere „der Filter greift" eine Behauptung ueber den
    // Fake statt ueber den Service. Hier wird der Server ohne Supabase-Client
    // direkt per HTTP befragt.
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
    });

    test('ein Fenster, das JETZT beginnt, liefert nichts Vergangenes',
        () async {
      // Genau die Wirkung von loggedMealsWindowDays = 0.
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
