import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';

import 'support/harness.dart';

// Performance package B6 — two separate problems of the trends view:
//
//  1. The 90-day window was refetched from the server on EVERY open. It is now
//     served from [TrendTotalsCache], which must drop its entry on every event
//     that can make it wrong (day rollover, account switch, auth event, write,
//     TTL). Every invalidation source gets a test; the day rollover runs on an
//     INJECTED clock, never on the real date (finding K-02, review
//     2026-08-29).
//  2. The painter rebuilt every DateFormat and TextPainter inside paint(), so
//     the 550 ms build-up paid for them on each of its ~33 frames. They are
//     laid out once in [TrendChartLabels] now.

TrendDayTotals _day(DateTime day, {int kcal = 2000}) =>
    TrendDayTotals(day: day, kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0);

List<TrendDayTotals> _zweiTage() => <TrendDayTotals>[
  _day(DateTime(2026, 8, 30)),
  _day(DateTime(2026, 8, 31)),
];

DateTime _heuteMinus(int tage) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - tage);
}

/// Loader that counts its calls — the stand-in for the server round trip.
class _ZaehlenderLader {
  _ZaehlenderLader({this.error});

  final Object? error;
  int calls = 0;

  Future<List<TrendDayTotals>> call() async {
    calls++;
    final err = error;
    if (err != null) throw err;
    return _zweiTage();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // Problem 1 — Sitzungs-Cache und seine Invalidierung
  // =========================================================================
  group('TrendTotalsCache', () {
    late TrendTotalsCache cache;

    setUp(() => cache = TrendTotalsCache());
    tearDown(() => cache.dispose());

    test(
      'zweites Oeffnen in derselben Sitzung fragt den Server nicht erneut',
      () async {
        final lader = _ZaehlenderLader();
        final erst = await cache.read(userId: 'u1', load: lader.call);
        final zweit = await cache.read(userId: 'u1', load: lader.call);

        expect(lader.calls, 1);
        // Identical list: the entry is handed out, not aggregated again.
        expect(identical(erst, zweit), isTrue);
      },
    );

    test(
      'Tageswechsel laedt das 90-Tage-Fenster neu (injizierte Uhr)',
      () async {
        final lader = _ZaehlenderLader();
        // 23:50 on the 31st — the entry belongs to local day 2026-08-31.
        await withClock(
          Clock.fixed(DateTime(2026, 8, 31, 23, 50)),
          () => cache.read(userId: 'u1', load: lader.call),
        );
        expect(lader.calls, 1);

        // 00:05 on the 1st: still inside the TTL, but the window has slid.
        await withClock(
          Clock.fixed(DateTime(2026, 9, 1, 0, 5)),
          () => cache.read(userId: 'u1', load: lader.call),
        );
        expect(lader.calls, 2);
      },
    );

    test('derselbe Tag zu einer anderen Uhrzeit laedt NICHT neu', () async {
      final lader = _ZaehlenderLader();
      await withClock(
        Clock.fixed(DateTime(2026, 8, 31, 8, 0)),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      await withClock(
        Clock.fixed(DateTime(2026, 8, 31, 8, 1)),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      expect(lader.calls, 1);
    });

    test('nach Ablauf der TTL wird neu geladen', () async {
      final lader = _ZaehlenderLader();
      final start = DateTime(2026, 8, 31, 12);
      await withClock(
        Clock.fixed(start),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      await withClock(
        Clock.fixed(
          start.add(TrendTotalsCache.defaultTtl - const Duration(seconds: 1)),
        ),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      expect(lader.calls, 1, reason: 'innerhalb der TTL');

      await withClock(
        Clock.fixed(start.add(TrendTotalsCache.defaultTtl)),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      expect(lader.calls, 2);
    });

    test('eine rueckwaerts gestellte Uhr gilt als Verfehlung, nicht als ewig '
        'frisch', () async {
      final lader = _ZaehlenderLader();
      await withClock(
        Clock.fixed(DateTime(2026, 8, 31, 12)),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      await withClock(
        Clock.fixed(DateTime(2026, 8, 31, 11)),
        () => cache.read(userId: 'u1', load: lader.call),
      );
      expect(lader.calls, 2);
    });

    test('ein anderer Nutzer bekommt niemals den Cache des vorigen', () async {
      final lader = _ZaehlenderLader();
      await cache.read(userId: 'u1', load: lader.call);
      await cache.read(userId: 'u2', load: lader.call);
      expect(lader.calls, 2);

      // The entry now belongs to u2, so u1 must fetch again.
      await cache.read(userId: 'u1', load: lader.call);
      expect(lader.calls, 3);
    });

    test(
      'invalidate (Mahlzeit/Gewicht geschrieben) erzwingt ein Neuladen',
      () async {
        final lader = _ZaehlenderLader();
        await cache.read(userId: 'u1', load: lader.call);
        expect(cache.debugHasEntry, isTrue);

        cache.invalidate();
        expect(cache.debugHasEntry, isFalse);

        await cache.read(userId: 'u1', load: lader.call);
        expect(lader.calls, 2);
      },
    );

    test('Abmelden ueber das Auth-Ereignis verwirft den Cache', () async {
      final events = StreamController<AuthChangeEvent>.broadcast();
      addTearDown(events.close);
      cache.attachAuthEvents(events.stream);
      final lader = _ZaehlenderLader();
      await cache.read(userId: 'u1', load: lader.call);

      events.add(AuthChangeEvent.signedOut);
      await pumpEventQueue();
      expect(cache.debugHasEntry, isFalse);

      await cache.read(userId: 'u1', load: lader.call);
      expect(lader.calls, 2);
    });

    test('ein Konto-Wechsel (signedIn) verwirft den Cache', () async {
      final events = StreamController<AuthChangeEvent>.broadcast();
      addTearDown(events.close);
      cache.attachAuthEvents(events.stream);
      final lader = _ZaehlenderLader();
      await cache.read(userId: 'u1', load: lader.call);

      events.add(AuthChangeEvent.signedIn);
      await pumpEventQueue();
      expect(cache.debugHasEntry, isFalse);
    });

    test('ein Token-Refresh verwirft den Cache NICHT', () async {
      final events = StreamController<AuthChangeEvent>.broadcast();
      addTearDown(events.close);
      cache.attachAuthEvents(events.stream);
      final lader = _ZaehlenderLader();
      await cache.read(userId: 'u1', load: lader.call);

      events.add(AuthChangeEvent.tokenRefreshed);
      await pumpEventQueue();
      expect(cache.debugHasEntry, isTrue);

      await cache.read(userId: 'u1', load: lader.call);
      expect(lader.calls, 1);
    });

    test(
      'ein Fehler auf dem Auth-Strom verwirft, statt die Zone zu killen',
      () async {
        final events = StreamController<AuthChangeEvent>.broadcast();
        addTearDown(events.close);
        cache.attachAuthEvents(events.stream);
        final lader = _ZaehlenderLader();
        await cache.read(userId: 'u1', load: lader.call);

        events.addError(StateError('auth stream broken'));
        await pumpEventQueue();
        expect(cache.debugHasEntry, isFalse);
      },
    );

    test('attachAuthEvents haengt sich nur einmal ein', () async {
      final erst = StreamController<AuthChangeEvent>.broadcast();
      final zweit = StreamController<AuthChangeEvent>.broadcast();
      addTearDown(erst.close);
      addTearDown(zweit.close);
      cache.attachAuthEvents(erst.stream);
      cache.attachAuthEvents(zweit.stream);
      expect(erst.hasListener, isTrue);
      expect(zweit.hasListener, isFalse);
    });

    test(
      'ein Fehler wird nicht gecacht — der naechste Versuch geht raus',
      () async {
        final lader = _ZaehlenderLader(error: StateError('offline'));
        await expectLater(
          cache.read(userId: 'u1', load: lader.call),
          throwsStateError,
        );
        expect(cache.debugHasEntry, isFalse);

        await expectLater(
          cache.read(userId: 'u1', load: lader.call),
          throwsStateError,
        );
        expect(lader.calls, 2);
      },
    );

    test('zwei gleichzeitige Oeffnungen teilen sich eine Anfrage', () async {
      var calls = 0;
      final completer = Completer<List<TrendDayTotals>>();
      Future<List<TrendDayTotals>> load() {
        calls++;
        return completer.future;
      }

      final a = cache.read(userId: 'u1', load: load);
      final b = cache.read(userId: 'u1', load: load);
      expect(calls, 1);

      completer.complete(_zweiTage());
      expect(await a, hasLength(2));
      expect(await b, hasLength(2));
    });

    test(
      'ein invalidate WAEHREND der Anfrage speichert das alte Ergebnis nicht',
      () async {
        final completer = Completer<List<TrendDayTotals>>();
        final laufend = cache.read(userId: 'u1', load: () => completer.future);

        // A meal is logged while the window is in flight.
        cache.invalidate();
        completer.complete(_zweiTage());
        expect(await laufend, hasLength(2));

        expect(cache.debugHasEntry, isFalse);
      },
    );
  });

  // =========================================================================
  // Problem 1 — der Dienst selbst spricht nur einmal mit PostgREST
  // =========================================================================
  group('TrendService gegen einen gezaehlten Server', () {
    test('das zweite Oeffnen loest keine zweite Abfrage aus', () async {
      var anfragen = 0;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/rest/v1/logged_meals')) anfragen++;
          return http.Response(
            jsonEncode(const [
              {
                'local_day': '2026-08-30',
                'logged_at': '2026-08-30T08:00:00Z',
                'calories_kcal': 700,
                'protein_g': 30,
                'carbs_g': 70,
                'fat_g': 20,
              },
              {
                'local_day': '2026-08-31',
                'logged_at': '2026-08-31T08:00:00Z',
                'calories_kcal': 800,
                'protein_g': 40,
                'carbs_g': 80,
                'fat_g': 25,
              },
            ]),
            200,
            headers: const {'Content-Type': 'application/json'},
            // postgrest dereferences `response.request` while parsing.
            request: req,
          );
        }),
        // No auto-refresh ticker: nothing here exercises auth.
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final cache = TrendTotalsCache();
      addTearDown(cache.dispose);

      // Two opens = two services sharing one cache, as in the app.
      final erst = await TrendService(
        client,
        'u1',
        cache: cache,
      ).loadDailyTotals();
      final zweit = await TrendService(
        client,
        'u1',
        cache: cache,
      ).loadDailyTotals();

      expect(anfragen, 1);
      expect(erst, hasLength(2));
      expect(zweit, hasLength(2));

      // After a write the next open really goes to the server again.
      cache.invalidate();
      await TrendService(client, 'u1', cache: cache).loadDailyTotals();
      expect(anfragen, 2);
    });
  });

  // =========================================================================
  // Problem 2 — Beschriftungen einmal setzen, nicht pro Frame
  // =========================================================================
  group('TrendChartLabels', () {
    setUp(debugClearTrendDateFormats);

    test('DateFormat wird pro Sprache genau einmal gebaut', () {
      final de = trendWeekdayFormat('de');
      expect(identical(trendWeekdayFormat('de'), de), isTrue);
      expect(identical(trendWeekdayFormat('en'), de), isFalse);

      final md = trendDayMonthFormat('de');
      expect(identical(trendDayMonthFormat('de'), md), isTrue);
      expect(identical(trendDayMonthFormat('en'), md), isFalse);
    });

    test(
      'gleiche Eingaben liefern dieselbe Instanz, ein Sprachwechsel nicht',
      () {
        final window = <TrendDayTotals?>[
          for (var i = 0; i < 7; i++) _day(DateTime(2026, 8, 25 + i)),
        ];
        final goals = List<int>.filled(7, 2200);
        TrendChartLabels bauen(
          TrendChartLabels? vorher,
          AppLocalizations l10n,
        ) => TrendChartLabels.resolve(
          vorher,
          window: window,
          goalPerDay: goals,
          firstDay: DateTime(2026, 8, 25),
          axisTextColor: const Color(0xFF888888),
          l10n: l10n,
        );

        final erst = bauen(null, deL10n);
        expect(identical(bauen(erst, deL10n), erst), isTrue);
        // 7-day view: weekday row present, one label per slot.
        expect(erst.weekdayLabels, hasLength(7));
        expect(erst.gridLabels, hasLength(4));
        expect(erst.goalLabel, isNotNull);

        final englisch = bauen(erst, enL10n);
        expect(identical(englisch, erst), isFalse);
        expect(
          englisch.weekdayLabels.first.text!.toPlainText(),
          isNot(erst.weekdayLabels.first.text!.toPlainText()),
        );
      },
    );

    test(
      'ein anderer Farbtoken (Theme-Wechsel) baut die Beschriftungen neu',
      () {
        final window = <TrendDayTotals?>[_day(DateTime(2026, 8, 30))];
        TrendChartLabels bauen(TrendChartLabels? vorher, Color farbe) =>
            TrendChartLabels.resolve(
              vorher,
              window: window,
              goalPerDay: const [2200],
              firstDay: DateTime(2026, 8, 30),
              axisTextColor: farbe,
              l10n: deL10n,
            );

        final erst = bauen(null, const Color(0xFF888888));
        expect(identical(bauen(erst, const Color(0xFF222222)), erst), isFalse);
        // Not the 7-day view: no weekday row at all.
        expect(erst.weekdayLabels, isEmpty);
      },
    );
  });

  // =========================================================================
  // Problem 2 — im echten Baum, ueber die Frames der Aufbau-Animation
  // =========================================================================
  group('TrendsScreen Aufbau-Animation', () {
    testWidgets('legt ueber die Frames hinweg keine Beschriftung neu an', (
      tester,
    ) async {
      final totals = <TrendDayTotals>[
        for (var i = 0; i < 7; i++)
          _day(_heuteMinus(6 - i), kcal: 1800 + i * 50),
      ];
      await pumpLocalized(
        tester,
        TrendsScreen(kcalGoal: 2200, loadTotals: () async => totals),
        // The build-up must really run; the harness kills motion by default.
        reducedMotion: false,
        // TrendsScreen brings its own Scaffold and SafeArea.
        scaffold: false,
        safeArea: false,
      );
      await tester.pump();
      // 7-day range: the weekday row is the most expensive label set.
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pump();

      // The first frame of the build-up lays the labels out.
      final nachErstemFrame = TrendChartLabels.debugLayoutCount;
      expect(nachErstemFrame, greaterThan(0));

      // ~20 further frames of the 550 ms build-up.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(
        TrendChartLabels.debugLayoutCount,
        nachErstemFrame,
        reason: 'paint() darf keine TextPainter mehr bauen',
      );

      await tester.pumpAndSettle();
      expect(TrendChartLabels.debugLayoutCount, nachErstemFrame);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });
  });
}
