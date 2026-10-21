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
// Every filter the fake applies is exercised by an expectation on rows that
// must or must not come back; an unknown filter fails instead of passing.

import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/meals_sync.dart';

import 'support/postgrest_filters.dart';

/// Loopback server implementing the PostgREST semantics `MealsSync` uses:
/// `eq`, `gte`, `lt`, `is.null`, `and`/`or`, plus `order` and `limit`. Anything else throws, so a
/// newly used filter surfaces here instead of silently passing.
class _PostgrestFake {
  _PostgrestFake._(this._server);

  final HttpServer _server;

  /// Table name -> rows. The rows are what is "in the database"; what the
  /// client sees is decided by the query alone.
  final Map<String, List<Map<String, dynamic>>> tables =
      <String, List<Map<String, dynamic>>>{};

  final List<Uri> requests = <Uri>[];
  void Function(Uri)? afterQuery;

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
      afterQuery?.call(request.uri);
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

    zeilen = zeilen.where((row) => matchesPostgrestFilters(row, uri)).toList();

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

  static Comparable<Object> _sortierschluessel(Object? zelle) {
    if (zelle is String) {
      final zeit = DateTime.tryParse(zelle);
      if (zeit != null) return zeit.toUtc().toIso8601String();
      return zelle;
    }
    return zelle.toString();
  }
}

/// The boot window is measured from `clock.now()`; pinned, so the ages
/// below never depend on when the suite runs.
final DateTime _jetzt = DateTime.utc(2026, 9, 28, 12);

/// `loadLoggedMeals` under the pinned clock.
Future<List<LoggedMeal>> _boot(SupabaseClient client) => withClock(
  Clock.fixed(_jetzt),
  () => MealsSync(client, 'user-1').loadLoggedMeals(),
);

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
      final jetzt = _jetzt;
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

    test('genau die Mahlzeiten im Fenster, neueste zuerst', () async {
      // Two hours ago: a window of 0 days puts the cutoff at NOW and the diary
      // is empty at every cold start. Yesterday: the most opened calendar day.
      // 30 days: the food calendar loads days inside the boot window without
      // reloading. 300 days: without a window every cold start loads the
      // whole history including the JSONB payload.
      final meals = await _boot(client);

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
      await _boot(client);

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
      final meals = await _boot(client);

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
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          _zeile(id: 'm$i', loggedAt: _jetzt.subtract(Duration(hours: i))),
      ];

      final meals = await _boot(client);

      expect(
        meals.length,
        60,
        reason:
            'Der Deckel ist ein Schutz gegen das stille db-max-rows, kein '
            'Anzeigelimit. Ein zu kleiner Deckel schneidet reale Tage ab.',
      );
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

    // The half-open bounds themselves (start inclusive, end exclusive) on
    // four DST dates: 'legacy half-open midnight bounds' below.
  });

  group('Archive: canonical day before timestamp fallback', () {
    final day = DateTime(2026, 3, 14);
    final nextDay = DateTime(2026, 3, 15);

    test(
      'keeps canonical meals across timezone shifts in both directions',
      () async {
        server.tables['logged_meals'] = [
          // After travel, either side of the current-zone window can contain
          // a meal whose original local calendar date is the selected day.
          _zeile(
            id: 'earlier-zone',
            loggedAt: day.subtract(const Duration(hours: 1)),
            localDay: '2026-03-14',
          ),
          _zeile(
            id: 'later-zone',
            loggedAt: nextDay.add(const Duration(hours: 1)),
            localDay: '2026-03-14',
          ),
        ];
        final meals = await MealsSync(
          client,
          'user-1',
        ).loadLoggedMealsForDay(day);
        expect(meals.map((meal) => meal.id), ['later-zone', 'earlier-zone']);
        expect(
          meals.map((meal) => meal.effectiveLocalDay),
          everyElement('2026-03-14'),
        );
      },
    );

    test(
      'does not spend the day cap on timestamp matches for another day',
      () async {
        server.tables['logged_meals'] = [
          for (var i = 0; i < 60; i++)
            _zeile(
              id: 'other-day-$i',
              loggedAt: DateTime(2026, 3, 14, 20, i),
              localDay: i.isEven ? '2026-03-13' : '2026-03-15',
            ),
          _zeile(
            id: 'selected',
            loggedAt: DateTime(2026, 3, 14, 1),
            localDay: '2026-03-14',
          ),
          _zeile(
            id: 'foreign-canonical',
            loggedAt: nextDay,
            localDay: '2026-03-14',
            userId: 'other-user',
          ),
          _zeile(id: 'foreign-legacy', loggedAt: day, userId: 'other-user'),
        ];
        final meals = await MealsSync(
          client,
          'user-1',
        ).loadLoggedMealsForDay(day);
        expect(meals.map((meal) => meal.id), ['selected']);
        expect(server.requests, hasLength(1));
        expect(server.requests.single.queryParameters['user_id'], 'eq.user-1');
        expect(server.requests.single.queryParameters['limit'], '50');
        expect(
          server.requests.single.queryParameters['order'],
          startsWith('id.asc'),
        );
      },
    );

    test('propagates server failure without automatic retries', () async {
      server.tables.remove('logged_meals');
      await expectLater(
        MealsSync(client, 'user-1').loadLoggedMealsForDay(day),
        throwsA(isA<PostgrestException>()),
      );
      expect(server.requests, hasLength(1));
    });

    test(
      'loads every modern and legacy row beyond the first archive page',
      () async {
        server.tables['logged_meals'] = [
          for (var i = 0; i < 60; i++)
            _zeile(
              id: 'meal-$i',
              loggedAt: DateTime(2026, 3, 14, 12, i),
              localDay: i.isEven ? '2026-03-14' : null,
            ),
          _zeile(
            id: 'zzzz-foreign',
            loggedAt: DateTime(2026, 3, 14, 23),
            localDay: '2026-03-14',
            userId: 'other-user',
          ),
          _zeile(
            id: 'zzzz-wrong-day',
            loggedAt: DateTime(2026, 3, 14, 23),
            localDay: '2026-03-15',
          ),
        ];
        final meals = await MealsSync(
          client,
          'user-1',
        ).loadLoggedMealsForDay(day);
        expect(meals.map((meal) => meal.id), [
          for (var i = 59; i >= 0; i--) 'meal-$i',
        ]);
        expect(server.requests, hasLength(2));
        expect(server.requests.last.queryParameters['id'], startsWith('gt.'));
        expect(
          server.requests.last.queryParameters['user_id'],
          'eq.user-1',
        );
        expect(server.requests.last.queryParameters['or'], isNotNull);
      },
    );

    test('a deletion after page one cannot skip the next archive row', () async {
      server.tables['logged_meals'] = [
        for (var i = 0; i < 61; i++)
          _zeile(
            id: 'meal-${i.toString().padLeft(3, '0')}',
            loggedAt: DateTime(2026, 3, 14, 12, i),
            localDay: '2026-03-14',
          ),
      ];
      var first = true;
      server.afterQuery = (uri) {
        if (!first) return;
        first = false;
        server.tables['logged_meals']!.removeWhere(
          (row) => row['id'] == 'meal-010',
        );
      };

      final meals = await MealsSync(client, 'user-1').loadLoggedMealsForDay(day);
      expect(meals.map((meal) => meal.id).toSet(), contains('meal-050'));
      expect(meals.map((meal) => meal.id).toSet(), contains('meal-060'));
      expect(meals.map((meal) => meal.id).toSet().length, 61);
      expect(server.requests, hasLength(2));
    });

    test('equal timestamps have a stable id order', () async {
      final sameTime = DateTime(2026, 3, 14, 12);
      server.tables['logged_meals'] = [
        _zeile(id: 'aaa', loggedAt: sameTime, localDay: '2026-03-14'),
        _zeile(id: 'bbb', loggedAt: sameTime, localDay: '2026-03-14'),
      ];

      final meals = await MealsSync(client, 'user-1').loadLoggedMealsForDay(day);
      expect(meals.map((meal) => meal.id), ['bbb', 'aaa']);
    });

    test('a day above the safety bound fails instead of showing partial totals', () async {
      server.tables['logged_meals'] = [
        for (var i = 0; i < 1001; i++)
          _zeile(
            id: 'meal-${i.toString().padLeft(4, '0')}',
            loggedAt: DateTime(2026, 3, 14, 12, 0, i),
            localDay: '2026-03-14',
          ),
      ];

      await expectLater(
        MealsSync(client, 'user-1').loadLoggedMealsForDay(day),
        throwsA(isA<StateError>()),
      );
    });

    // Both European and North-American DST boundaries. The assertions follow
    // calendar midnights in the real process zone, never a fixed 24-hour span.
    for (final date in [
      DateTime(2026, 3, 8),
      DateTime(2026, 3, 29),
      DateTime(2026, 10, 25),
      DateTime(2026, 11, 1),
    ]) {
      test(
        'legacy half-open midnight bounds on ${date.toIso8601String()}',
        () async {
          final end = DateTime(date.year, date.month, date.day + 1);
          server.tables['logged_meals'] = [
            _zeile(
              id: 'before',
              loggedAt: date.subtract(const Duration(microseconds: 1)),
            ),
            _zeile(id: 'start', loggedAt: date),
            _zeile(
              id: 'last',
              loggedAt: end.subtract(const Duration(microseconds: 1)),
            ),
            _zeile(id: 'end', loggedAt: end),
          ];
          final meals = await MealsSync(
            client,
            'user-1',
          ).loadLoggedMealsForDay(date);
          expect(meals.map((meal) => meal.id), ['last', 'start']);
        },
      );
    }
  });

  // The fake's filters are exercised by every expectation above (window,
  // owner, canonical day, half-open bounds, order, cap, projection); this
  // guard keeps an unknown filter from passing silently.
  test('unsupported nested filters fail instead of being ignored', () {
    expect(
      () => matchesPostgrestFilters(
        <String, dynamic>{'u': 'x', 'at': '2026-03-14T00:00:00Z'},
        Uri.parse('http://localhost/?or=(u.eq.x,at.unsupported.1)'),
      ),
      throwsFormatException,
    );
  });

  group('LoggedMeal-Konstruktion aus echten Bytes', () {
    test('Payload, Slot und local_day kommen vollstaendig durch', () async {
      server.tables['logged_meals'] = <Map<String, dynamic>>[
        <String, dynamic>{
          ..._zeile(
            id: 'voll',
            loggedAt: _jetzt.subtract(const Duration(hours: 1)),
            localDay: '2026-03-14',
            kcal: 777,
            name: 'Lachsbowl',
          ),
          'forced_slot': 'dinner',
        },
      ];

      final meals = await _boot(client);
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
