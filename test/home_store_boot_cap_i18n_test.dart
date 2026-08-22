import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Review 2026-08-19, "home store core": the welcome gate hung on the untimed
// end of the network boot, so a silent socket stranded the app in the
// WelcomeScreen; the 5-item recents cap was local only, so favorite_meals grew
// server-side; and the edit-sheet confirmations were hardcoded German.

/// Fake PostgREST: serves favorite_meals rows, records deletions, and can go
/// SILENT instead of failing — a silent socket fires no `catchError` at all.
class _FakeServer {
  _FakeServer({this.schweigt = false});

  /// No request is ever answered. Deliberately not "throws".
  final bool schweigt;

  /// favorite_meals rows as `loadFavorites` expects them: added_at descending.
  final List<Map<String, dynamic>> favoriteRows = <Map<String, dynamic>>[];

  /// Every favorite_key hit by a DELETE on favorite_meals.
  final List<String> geloeschteFavoriten = <String>[];

  http.Client client() => MockClient((req) async {
        if (schweigt) return Completer<http.Response>().future;
        final path = req.url.path;
        http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
            headers: const {'Content-Type': 'application/json'}, request: req);
        // A ROW, not `[]`: `.select().single()` throws on an empty answer.
        if (path.contains('/rpc/')) return ok(_statsRow);
        if (path.endsWith('/favorite_meals')) {
          if (req.method == 'DELETE') {
            final roh = req.url.queryParameters['favorite_key'];
            if (roh != null) {
              geloeschteFavoriten
                  .add(roh.startsWith('eq.') ? roh.substring(3) : roh);
            }
            return ok(const <dynamic>[]);
          }
          if (req.method == 'GET') return ok(favoriteRows);
          return ok(const <dynamic>[]);
        }
        // Everything else: the "fresh device" state the gate tests need.
        return ok(const <dynamic>[]);
      });
}

/// Response row of the two counter RPCs; only the SHAPE matters here.
const Map<String, dynamic> _statsRow = <String, dynamic>{
  'workouts_completed': 0,
  'meals_logged': 0,
  'water_total_ml': 0,
  'steps_recorded': 0,
  'weight_logs': 0,
  'current_streak': 1,
  'longest_streak': 1,
  'last_workout_date': null,
  'session_start': '2026-08-01T00:00:00Z',
};

class _SnackCapture {
  final List<String> messages = <String>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline_rounded,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
  }
}

const String _userId = 'user-boot-cap';

({HomeStore store, _FakeServer server, LocalCache cache, _SnackCapture snacks})
    _setup({bool schweigt = false}) {
  final server = _FakeServer(schweigt: schweigt);
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    // No GoTrue auto-refresh ticker in tests (see clobber_guard_test.dart).
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  // No `addTearDown(client.dispose)`: in silent mode a request hangs forever
  // and dispose would wait it into the test timeout; no timer is left pending.
  final cache = LocalCache(InMemoryKeyValueStore(), _userId);
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, _userId),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, server: server, cache: cache, snacks: snacks);
}

/// Store WITHOUT sync, for the pure text paths (finding 3).
({HomeStore store, _SnackCapture snacks}) _setupOhneSync() {
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

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 300,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Mittel',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Map<String, dynamic> _favoriteRow(String name,
        {required DateTime addedAt, bool pinned = false}) =>
    <String, dynamic>{
      'favorite_key': FavoriteMeal.idFor(_meal(name)),
      'added_at': addedAt.toUtc().toIso8601String(),
      'pinned': pinned,
      'payload': mealResultToJson(_meal(name)),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Befund 1 — das Willkommens-Gate haengt nicht mehr am Netz', () {
    test(
        'Cache-Profil + stummer Server: profileReady faellt, ohne auf eine '
        'Server-Antwort zu warten', () async {
      final s = _setup(schweigt: true);
      await s.cache.writeProfile(const UserProfile(
        weightKg: 80,
        heightCm: 180,
        onboardingCompleted: true,
      ));

      s.store.start();

      // Without the fix this times out: the completer only fired at the end of
      // _bootFromSupabase, whose Future.wait never returns.
      await expectLater(
        s.store.profileReady.timeout(const Duration(seconds: 3)),
        completes,
      );
      expect(s.store.profile.weightKg, 80,
          reason: 'das Gate faellt genau deshalb, weil der Cache den '
              'anzeigefaehigen Zustand schon getragen hat');
    });

    test(
        'ohne Cache-Profil oeffnet spaetestens das Boot-Budget das Gate — '
        'vorher haelt es', () {
      fakeAsync((async) {
        final s = _setup(schweigt: true);
        var offen = false;
        unawaited(s.store.profileReady.then((_) => offen = true));

        s.store.start();
        async.elapse(kBootNetworkBudget - const Duration(seconds: 1));

        expect(offen, isFalse,
            reason: 'ohne Cache-Profil steht `profile` auf den Ctor-Defaults '
                '— das Gate darf nicht fallen, sonst blitzt das Onboarding '
                'auf und verschwindet wieder');

        async.elapse(const Duration(seconds: 2));

        expect(offen, isTrue,
            reason: 'das Boot-Budget ist die Auffanglinie fuer den Start ohne '
                'brauchbaren Cache');
      });
    });

    test(
        'Kontrolle: ein antwortender Server oeffnet das Gate weiterhin ueber '
        'den regulaeren Boot-Weg', () async {
      // No cached profile, responding server: 3 s is well under
      // [kBootNetworkBudget], so the gate opens at boot end, not via the guard.
      final s = _setup();

      s.store.start();

      await expectLater(
        s.store.profileReady.timeout(const Duration(seconds: 3)),
        completes,
      );
    });
  });

  group('Befund 2 — der Recents-Deckel gilt auch serverseitig', () {
    test('der Boot kappt die geladene Favoritenliste auf den Deckel', () async {
      final s = _setup();
      // The server knows no cap: eight auto recents plus one pinned favorite.
      s.server.favoriteRows.add(_favoriteRow('Angeheftet',
          addedAt: DateTime.utc(2026, 8, 19, 12), pinned: true));
      for (var i = 0; i < 8; i++) {
        s.server.favoriteRows.add(_favoriteRow('Gericht $i',
            addedAt: DateTime.utc(2026, 8, 19, 11 - i)));
      }

      s.store.start();
      await s.store.profileReady.timeout(const Duration(seconds: 3));
      await pumpEventQueue(times: 60);

      expect(s.store.favorites.map((f) => f.result.mealName).toList(), [
        'Angeheftet',
        'Gericht 0',
        'Gericht 1',
        'Gericht 2',
        'Gericht 3',
        'Gericht 4',
      ],
          reason: 'ohne das Kappen zeigte das Add-Sheet nach jedem Kaltstart '
              'die komplette Historie; Angeheftetes steht ausserhalb der '
              'Quote und bleibt vollstaendig');
    });

    test(
        'ein aus dem Deckel gefallener Recent wird auch serverseitig '
        'geloescht', () async {
      final s = _setup();
      s.store.start();
      await s.store.profileReady.timeout(const Duration(seconds: 3));
      await pumpEventQueue(times: 60);

      // Six distinct meals -> the oldest falls out of the 5-item cap.
      for (var i = 0; i < 6; i++) {
        s.store.addResultToDailyTotal(_meal('Gericht $i'));
        await pumpEventQueue(times: 60);
      }

      expect(s.store.favorites.length, 5);
      expect(s.server.geloeschteFavoriten,
          [FavoriteMeal.idFor(_meal('Gericht 0'))],
          reason: 'fuer den herausgefallenen Recent entstand bis zum Review '
              'NIE eine favoriteDelete-Op — favorite_meals wuchs deshalb '
              'unbegrenzt weiter');
    });

    test('ein ANGEHEFTETER Favorit wird vom Deckel nie geloescht', () async {
      final s = _setup();
      s.store.start();
      await s.store.profileReady.timeout(const Duration(seconds: 3));
      await pumpEventQueue(times: 60);

      s.store.toggleFavorite(_meal('Liebling'));
      await pumpEventQueue(times: 60);
      for (var i = 0; i < 6; i++) {
        s.store.addResultToDailyTotal(_meal('Gericht $i'));
        await pumpEventQueue(times: 60);
      }

      expect(s.store.favorites.map((f) => f.result.mealName),
          contains('Liebling'));
      expect(s.server.geloeschteFavoriten,
          isNot(contains(FavoriteMeal.idFor(_meal('Liebling')))),
          reason: 'eine Loeschung, die der Nutzer nie angeordnet hat, waere '
              'der teurere Fehler');
    });
  });

  group('Befund 3 — die Bestaetigungen folgen der App-Sprache', () {
    // Clock pinned past the spring DST switch — the edge B5 covers.
    void mitUhr(void Function() body) =>
        withClock(Clock.fixed(DateTime(2026, 3, 30, 10)), body);

    test('Deutsch bleibt zeichengleich zum hartkodierten Bestand', () {
      mitUhr(() {
        final s = _setupOhneSync();
        final id = s.store.addResultToDailyTotal(_meal('Bowl'));

        s.store.updateLoggedMealDetails(id, slot: MealSlot.snack);
        expect(s.snacks.messages.last, 'Mahlzeit aktualisiert.');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 29));
        expect(s.snacks.messages.last, 'Mahlzeit auf gestern verschoben.');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 28));
        expect(s.snacks.messages.last, 'Mahlzeit auf den 28.3. verschoben.',
            reason: 'das intl-Skeleton Md liefert unter `de` genau das alte '
                '„28.3."');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 30));
        expect(s.snacks.messages.last, 'Mahlzeit auf heute verschoben.');
      });
    });

    test('Englisch bekommt englische Texte UND ein englisches Datumsformat',
        () {
      mitUhr(() {
        final s = _setupOhneSync();
        s.store.setLocalizations(enL10n);
        final id = s.store.addResultToDailyTotal(_meal('Bowl'));

        s.store.updateLoggedMealDetails(id, slot: MealSlot.snack);
        expect(s.snacks.messages.last, 'Meal updated.');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 29));
        expect(s.snacks.messages.last, 'Meal moved to yesterday.');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 28));
        expect(s.snacks.messages.last, 'Meal moved to 3/28.',
            reason: 'die deutsche Praeposition („den") steckt im ARB-Text, '
                'das Datum kommt locale-bewusst aus intl');

        s.store.updateLoggedMealDetails(id, day: DateTime(2026, 3, 30));
        expect(s.snacks.messages.last, 'Meal moved to today.');
      });
    });
  });
}
