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

// Komplettreview 2026-08-19, Paket „Home-Store-Kern". Drei Befunde, drei
// Gruppen:
//
//   1. Das Willkommens-Gate (profileReady) hing am ENDE des Netz-Boots, und
//      auf diesem Weg traegt kein Schritt ein Timeout. Ein Socket, der nie
//      antwortet (WLAN mit Captive Portal), liess die App dauerhaft im
//      WelcomeScreen stehen — obwohl der Cache den anzeigefaehigen Zustand
//      laengst geliefert hatte.
//   2. Der 5er-Deckel auf die automatischen Recents war rein lokal:
//      favorite_meals wuchs serverseitig mit jeder distinkten Mahlzeit, und
//      der naechste Kaltstart holte die ganze Historie ins Add-Sheet zurueck.
//   3. Die Bestaetigungen des Bearbeiten-Sheets waren hart deutsch, obwohl
//      home_store_meals.dart als i18n-migriert galt.

/// Fake-PostgREST fuer genau die drei Fragen dieses Pakets: liefert
/// favorite_meals-Zeilen, zeichnet Loeschungen auf — und kann auf Wunsch
/// SCHWEIGEN statt zu scheitern. Das Schweigen ist der eigentliche Punkt von
/// Befund 1: ein Fehler feuert `catchError`, ein stummer Socket feuert gar
/// nichts.
class _FakeServer {
  _FakeServer({this.schweigt = false});

  /// Kein Request wird je beantwortet (Captive Portal). Bewusst NICHT „wirft":
  /// gegen einen Wurf war der Boot immer schon robust.
  final bool schweigt;

  /// favorite_meals, wie `loadFavorites` sie erwartet — Aufrufer legen sie in
  /// added_at-absteigender Reihenfolge ab (so sortiert der echte Query).
  final List<Map<String, dynamic>> favoriteRows = <Map<String, dynamic>>[];

  /// Jeder favorite_key, den ein DELETE auf favorite_meals getroffen hat.
  final List<String> geloeschteFavoriten = <String>[];

  http.Client client() => MockClient((req) async {
        if (schweigt) return Completer<http.Response>().future;
        final path = req.url.path;
        http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
            headers: const {'Content-Type': 'application/json'}, request: req);
        // Beide Zaehler-RPCs liefern eine ZEILE (nicht `[]`): `.select()
        // .single()` wuerde an einer leeren Antwort werfen, und der Store
        // liefe in seine Fehlerpfade — Rauschen, das mit keinem der drei
        // Befunde zu tun hat.
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
        // Alles Uebrige: leere Sammlung bzw. quittierter Write. Der Boot-Load
        // findet damit weder Profil noch Mahlzeiten — genau der „frisches
        // Geraet"-Zustand, den die Gate-Tests brauchen.
        return ok(const <dynamic>[]);
      });
}

/// Antwortzeile der beiden Zaehler-RPCs (increment_lifetime_stats /
/// record_tracking_day) — die Werte sind fuer dieses Paket egal, nur die FORM
/// zaehlt.
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
    // Kein GoTrue-Auto-Refresh-Ticker im Test (s. clobber_guard_test.dart).
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  // BEWUSST kein `addTearDown(client.dispose)` (Muster clobber_guard_test):
  // im Schweige-Modus haengt ein Request unbeantwortet in der Luft, und ein
  // dispose, das darauf wartet, liefe in den Test-Timeout. Da der
  // GoTrue-Auto-Refresh-Ticker via autoRefreshToken:false aus ist, bleibt kein
  // pendender Timer zurueck — der Client wird einfach GC'd.
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

/// Store OHNE Sync — fuer die reinen Textpfade (Befund 3).
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

      // Ohne den Fix laeuft das hier in den Test-Timeout: der Completer wurde
      // erst am Ende von _bootFromSupabase erfuellt, und der Future.wait der
      // sechs Loads antwortet nie.
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
      // Kein Cache-Profil, aber ein antwortender Server. Die Wanduhr ist hier
      // die Aussage: 3 s echte Zeit sind deutlich weniger als das Budget von
      // [kBootNetworkBudget] — das Gate faellt also am Boot-Ende, nicht am
      // Waechter. Der darf den Normalfall nicht verschieben.
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
      // Der Server kennt den Deckel nicht: acht Auto-Recents (added_at
      // absteigend, wie loadFavorites sortiert) plus ein angehefteter Favorit.
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

      // Sechs distinkte Mahlzeiten -> die aelteste faellt aus dem 5er-Deckel.
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
    // Uhr festgenagelt: der 30.03.2026 liegt hinter der Fruehjahrsumstellung,
    // dieselbe Kante, die B5 abgesichert hat (s.
    // home_store_edit_details_test.dart).
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
