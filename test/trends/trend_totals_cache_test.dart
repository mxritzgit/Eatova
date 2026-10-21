import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// The session cache in front of the trends window (perf package B6). The
// window used to be refetched on EVERY open; it is now served from
// [TrendTotalsCache], which must drop its entry on every event that can make
// it wrong: day rollover, account switch, auth event, error, TTL and every
// meal write the server will see. The day rollover runs on an INJECTED clock
// (finding K-02, review 2026-08-29).
//
// The HomeStore group pins each meal write path on its own: they were
// forgotten one by one when the hooks were first listed (undo and
// updateLoggedMealResult). Since mutation run T4 (2026-09-01) it also checks
// the visible day total those paths update next to the cache.

TrendDayTotals _day(DateTime day, {int kcal = 2000}) =>
    TrendDayTotals(day: day, kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0);

List<TrendDayTotals> _zweiTage() => <TrendDayTotals>[
  _day(DateTime(2026, 8, 30)),
  _day(DateTime(2026, 8, 31)),
];

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

/// Faengt die Undo-Aktion ab: _restoreLoggedMeal ist privat und nur ueber den
/// Snack erreichbar, den das Loeschen ausloest.
class _SnackCapture {
  SnackBarAction? letzteAktion;

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    if (action != null) letzteAktion = action;
  }
}

({HomeStore store, _SnackCapture snacks}) _store() {
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
  );
  addTearDown(store.dispose);
  return (store: store, snacks: snacks);
}

MealAnalysisResult _meal(String name, {int kcal = 300}) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// Fuellt den Singleton-Cache und behauptet, dass das auch geklappt hat —
/// sonst wuerde jeder Test unten trivial gruen, weil nie etwas drin war.
Future<void> _fillCache() async {
  TrendTotalsCache.instance.invalidate();
  await TrendTotalsCache.instance.read(
    userId: 'user-1',
    load: () async => const <TrendDayTotals>[],
  );
  expect(TrendTotalsCache.instance.debugHasEntry, isTrue,
      reason: 'Vorbedingung: der Cache muss vor dem Schreibvorgang gefuellt sein');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      'Tageswechsel laedt das Trendfenster neu (injizierte Uhr)',
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

    for (final event in [AuthChangeEvent.signedOut, AuthChangeEvent.signedIn]) {
      test('${event.name} (Abmelden, Konto-Wechsel) verwirft den Cache', () async {
        final events = StreamController<AuthChangeEvent>.broadcast();
        addTearDown(events.close);
        cache.attachAuthEvents(events.stream);
        final lader = _ZaehlenderLader();
        await cache.read(userId: 'u1', load: lader.call);

        events.add(event);
        await pumpEventQueue();
        expect(cache.debugHasEntry, isFalse);

        await cache.read(userId: 'u1', load: lader.call);
        expect(lader.calls, 2);
      });
    }

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

  group('TrendService gegen einen gezaehlten Server', () {
    test('das zweite Oeffnen loest keine zweite Abfrage aus', () async {
      var anfragen = 0;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/rest/v1/logged_meals')) anfragen++;
          // Only an empty page ends a read: the page after the cursor is it.
          final nachCursor = req.url.queryParameters.containsKey('id');
          return http.Response(
            jsonEncode(nachCursor ? const [] : const [
              {
                'id': 'a',
                'local_day': '2026-08-30',
                'logged_at': '2026-08-30T08:00:00Z',
                'calories_kcal': 700,
                'protein_g': 30,
                'carbs_g': 70,
                'fat_g': 20,
              },
              {
                'id': 'b',
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

      // One read: the page with rows and the empty page that ends it.
      expect(anfragen, 2);
      expect(erst, hasLength(2));
      expect(zweit, hasLength(2));

      // After a write the next open really goes to the server again.
      cache.invalidate();
      await TrendService(client, 'u1', cache: cache).loadDailyTotals();
      expect(anfragen, 4);
    });
  });

  group('HomeStore-Schreibpfade verwerfen das Fenster', () {
    tearDown(TrendTotalsCache.instance.invalidate);

    test('eine geloggte Mahlzeit verwirft das gecachte Trendfenster', () async {
      final s = _store();
      final store = s.store;
      await _fillCache();

      await store.addResultToDailyTotal(_meal('Bowl'));

      expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
    });

    test(
        'eine skalierte Portion (updateLoggedMealResult) verwirft es auch und '
        'zieht die Tagessumme nach', () async {
      final s = _store();
      final store = s.store;
      final id = await store.addResultToDailyTotal(_meal('Bowl'));
      expect(store.dailyConsumedKcal, 300);
      await _fillCache();

      await store.updateLoggedMealResult(id, _meal('Bowl', kcal: 600));

      expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
      expect(store.dailyConsumedKcal, 600,
          reason: 'die Kachel zeigt sonst die alte Portion weiter, obwohl die '
              'Zeile im Tagebuch schon die neue traegt');
      expect(store.macroProgress.kcal, 600);
    });

    test('das Bearbeiten der Details verwirft es', () async {
      final s = _store();
      final store = s.store;
      final id = await store.addResultToDailyTotal(_meal('Bowl'));
      await _fillCache();

      await store.updateLoggedMealDetails(id, slot: MealSlot.snack);

      expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
    });

    test('das Loeschen verwirft es und nimmt die Kalorien vom Tag', () async {
      final s = _store();
      final store = s.store;
      final id = await store.addResultToDailyTotal(_meal('Bowl'));
      expect(store.dailyConsumedKcal, 300);
      await _fillCache();

      await store.removeLoggedMeal(id);

      expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
      expect(store.dailyConsumedKcal, 0,
          reason: 'eine geloeschte Mahlzeit darf in der Tagessumme nicht '
              'stehenbleiben');
      expect(store.macroProgress, MacroProgress.empty);
    });

    test(
        'das RUECKGAENGIG eines Loeschens verwirft es ebenfalls und gibt die '
        'Kalorien zurueck — auch beim Doppeltipp nur einmal', () async {
      // Der Pfad, der bei der ersten Aufstellung der Hooks vergessen wurde:
      // _restoreLoggedMeal legt die Zeile wieder an, also aendert es die
      // Serversicht genauso wie das Loeschen davor.
      final s = _store();
      final store = s.store;
      final id = await store.addResultToDailyTotal(_meal('Bowl'));
      await store.removeLoggedMeal(id);
      final undo = s.snacks.letzteAktion;
      expect(undo, isNotNull, reason: 'das Loeschen muss einen Undo-Snack werfen');
      expect(store.dailyConsumedKcal, 0);
      await _fillCache();

      undo!.onPressed();
      await pumpEventQueue(times: 20);

      expect(TrendTotalsCache.instance.debugHasEntry, isFalse);
      expect(store.dailyConsumedKcal, 300,
          reason: 'die wiederhergestellte Mahlzeit zaehlt wieder — sonst fehlt '
              'sie in der Tagessumme, obwohl sie im Tagebuch steht');
      expect(store.macroProgress.proteinG, 30);

      // Zweiter Tipp auf denselben Snack: der Idempotenz-Schutz in
      // _restoreLoggedMeal muss halten, sonst steht die Mahlzeit doppelt im
      // Tagebuch und der Tag zaehlt 600 kcal.
      undo.onPressed();
      await pumpEventQueue(times: 20);

      expect(store.loggedMeals, hasLength(1));
      expect(store.loggedMeals.single.id, isNot(id));
      expect(store.loggedMeals.single.result.mealName, 'Bowl');
      expect(store.dailyConsumedKcal, 300);
    });

    test('ein Lesevorgang allein laesst den Cache stehen', () async {
      // Gegenprobe: haette ich die Verwerfung an _mutate gehaengt, waere der
      // Cache staendig weg (sieben der ~40 Aufrufer sitzen im Sync-Pfad). Ein
      // reiner Lesezugriff darf ihn nicht anfassen.
      final s = _store();
      final store = s.store;
      await store.addResultToDailyTotal(_meal('Bowl'));
      await _fillCache();

      store.consumedKcalForFoodDate(clock.now());
      store.macroProgressForFoodDate(clock.now());

      expect(TrendTotalsCache.instance.debugHasEntry, isTrue);
    });
  });
}
