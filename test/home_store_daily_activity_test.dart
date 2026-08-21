import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Burned-kcal pro Tag (2026-08-12): "Verbrannt" war eine reine Live-Ableitung
// aus den HEUTIGEN Schritten (ein Skalar, nie persistiert) — jeder Archivtag
// zeigte deshalb dauerhaft "—". Jetzt schreibt jeder verifizierte Health-
// Refresh den Tageswert in [HomeStore.dailyActivity] plus LocalCache-Slot
// fest (der letzte Refresh eines Tages IST sein Endwert), und fuer Archivtage
// holt setFoodDate die volle Tagessumme einmalig pro Sitzung aus der
// Health-Historie nach (HealthService.readStepsOnDay). Getestet wird:
//   1. Refresh schreibt den heutigen Tageswert fest (Map + Cache-Blob).
//   2. burnedKcalForFoodDate: heute live aus dailySteps, Archivtag aus dem
//      Speicher, ohne Eintrag 0 (Kachel zeigt dann "—").
//   3. Hydration: der Slot uebersteht den Kaltstart (zweiter Store, gleiche
//      Platte).
//   4. Backfill: Archivtag-Auswahl fragt die Health-Historie genau EINMAL
//      pro Sitzung; ein null-Ergebnis (kein Zugriff/Ruhetag/Android)
//      schreibt nichts fest.
//   5. clear() raeumt den Slot (M-1: Schritte/kcal sind Gesundheitsdaten).
//
// Kalorien-Review 2026-08-21: "Verbrannt" zaehlt JEDEN Schritt (ACSM-Netto,
// 0,5 kcal/kg/km) — das Tagesziel rechnet dafuer mit einer PAL-Leiter OHNE
// Gehen, eine Schritt-Basis gibt es nicht. Auch ein kleiner Tag (4000
// Schritte) liefert deshalb einen Wert, nicht 0.

/// Health-Double: kontrollierbare heutige Schritte + Historie pro Tag.
class _FakeHealth implements HealthService {
  int stepsToday = 12000;

  /// Antworten fuer readStepsOnDay, gekeyt per localDayKey. Fehlender
  /// Eintrag == null (kein Zugriff / keine Daten).
  final Map<String, int?> stepsByDay = <String, int?>{};

  /// Alle readStepsOnDay-Aufrufe (fuer die Einmal-pro-Sitzung-Zusicherung).
  final List<DateTime> dayReads = <DateTime>[];

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: stepsToday, fetchedAt: clock.now());

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    dayReads.add(day);
    return stepsByDay[localDayKey(day)];
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}

void _ignoreSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

/// Leerer Fake-PostgREST: alle Reads leer, alle Writes Erfolg — der Boot
/// laeuft durch, ohne dass Serverdaten die Aktivitaets-Tests beruehren.
http.Client _emptyServer() => MockClient((req) async {
      if (req.method == 'GET') {
        return http.Response(jsonEncode(const <dynamic>[]), 200,
            headers: const {'Content-Type': 'application/json'}, request: req);
      }
      return http.Response('', 201, request: req);
    });

/// Store MIT Sync + Cache (debugCache): der Boot setzt _cache, damit
/// Festschreiben/Hydration gegen die (In-Memory-)Platte laufen.
({HomeStore store, _FakeHealth health, LocalCache cache}) _setupSynced(
    InMemoryKeyValueStore kv) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _emptyServer(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache = LocalCache(kv, 'user-activity');
  final health = _FakeHealth();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-activity'),
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _ignoreSnack,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, health: health, cache: cache);
}

/// Leichter Store OHNE Sync (kein Boot, kein Cache) fuer die reinen
/// In-Memory-Pfade (Anzeige + Backfill).
({HomeStore store, _FakeHealth health}) _setupLight() {
  final health = _FakeHealth();
  final store = HomeStore(
    sync: null,
    health: health,
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: _ignoreSnack,
  );
  addTearDown(store.dispose);
  return (store: store, health: health);
}

/// Dieselbe Rechnung wie HomeStore (home_store_tracking.dart): jeder Schritt
/// zaehlt, keine Basis.
int _erwarteteKcal(HomeStore store, int steps) => estimateKcalBurnedFromSteps(
      steps: steps,
      weightKg: store.profile.weightKg,
      heightCm: store.profile.heightCm,
      sex: store.profile.sex,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DateTime tageZurueck(int n) =>
      DateUtils.dateOnly(clock.now()).subtract(Duration(days: n));

  test('Health-Refresh schreibt den heutigen Tageswert in Map + Cache fest',
      () async {
    final s = _setupSynced(InMemoryKeyValueStore());
    s.store.start();
    await s.store.profileReady;

    await s.store.refreshHealthSteps();

    final key = localDayKey(clock.now());
    final kcal = _erwarteteKcal(s.store, 12000);
    // Standardprofil 78 kg / 178 cm / neutral:
    // 12 000 Schritte × 0,73692 m = 8,843 km × 78 kg × 0,5 = 344,9 kcal.
    expect(kcal, 345);
    expect(s.store.dailyActivity[key], (steps: 12000, kcal: kcal));
    expect(await s.cache.readDailyActivity(),
        containsPair(key, (steps: 12000, kcal: kcal)));
  });

  test('burnedKcalForFoodDate: heute live, Archivtag gespeichert, sonst 0',
      () async {
    final s = _setupLight();
    await s.store.refreshHealthSteps();

    // Heute: Live-Ableitung aus dailySteps (unveraendertes Verhalten).
    expect(s.store.burnedKcalForFoodDate(clock.now()),
        _erwarteteKcal(s.store, 12000));
    // Archivtag ohne Eintrag: 0 -> Kachel zeigt "—", keine Scheinangabe.
    expect(s.store.burnedKcalForFoodDate(tageZurueck(1)), 0);

    // Archivtag MIT Eintrag (per Backfill geholt): der gespeicherte Wert
    // (9000 Schritte × 0,73692 m = 6,632 km × 39 = 258,7 → 259 kcal).
    final gestern = tageZurueck(1);
    s.health.stepsByDay[localDayKey(gestern)] = 9000;
    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);
    final gesternKcal = _erwarteteKcal(s.store, 9000);
    expect(gesternKcal, 259);
    expect(s.store.burnedKcalForFoodDate(gestern), gesternKcal);
    // Heute bleibt live — auch wenn fuer heute ein (aelterer) Eintrag steht.
    expect(s.store.burnedKcalForFoodDate(clock.now()),
        _erwarteteKcal(s.store, 12000));

    // Kleiner Archivtag (4000 Schritte): auch der zaehlt voll — keine
    // Schritt-Basis, keine Schwelle (4000 × 0,73692 m = 2,948 km × 39 =
    // 114,96 → 115 kcal).
    final vorgestern = tageZurueck(2);
    s.health.stepsByDay[localDayKey(vorgestern)] = 4000;
    s.store.setFoodDate(vorgestern);
    await Future<void>.delayed(Duration.zero);
    expect(s.store.dailyActivity[localDayKey(vorgestern)],
        (steps: 4000, kcal: 115));
    expect(s.store.burnedKcalForFoodDate(vorgestern), 115);
  });

  test('Backfill fragt die Historie genau einmal pro Tag und Sitzung',
      () async {
    final s = _setupLight();
    final gestern = tageZurueck(1);
    s.health.stepsByDay[localDayKey(gestern)] = 6000;

    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);
    s.store.setFoodDate(clock.now());
    s.store.setFoodDate(gestern);
    await Future<void>.delayed(Duration.zero);

    // Heute loest nie eine Historien-Query aus, gestern genau eine.
    expect(s.health.dayReads, hasLength(1));
  });

  test('Backfill ohne Daten (null) schreibt nichts fest', () async {
    final s = _setupLight();
    final vorgestern = tageZurueck(2);

    s.store.setFoodDate(vorgestern);
    await Future<void>.delayed(Duration.zero);

    expect(s.store.dailyActivity, isEmpty);
    expect(s.store.burnedKcalForFoodDate(vorgestern), 0);
  });

  test('Hydration: der Tageswert uebersteht den Kaltstart', () async {
    final kv = InMemoryKeyValueStore();
    final erste = _setupSynced(kv);
    erste.store.start();
    await erste.store.profileReady;
    await erste.store.refreshHealthSteps();
    final key = localDayKey(clock.now());
    final erwartet = erste.store.dailyActivity[key];
    expect(erwartet, isNotNull);

    // "Naechste Sitzung": frischer Store auf derselben Platte, KEIN Refresh.
    final zweite = _setupSynced(kv);
    zweite.store.start();
    await zweite.store.profileReady;

    expect(zweite.store.dailyActivity[key], erwartet);
  });

  test('clear() raeumt den Aktivitaets-Slot (M-1)', () async {
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-activity');
    await cache.writeDailyActivity({
      '2026-08-11': (steps: 6000, kcal: 250),
    });
    expect(await cache.readDailyActivity(), isNotNull);

    await cache.clear();

    expect(await cache.readDailyActivity(), isNull);
  });

  test('korrupter Slot liefert null bzw. ueberspringt kaputte Tage', () async {
    final kv = InMemoryKeyValueStore({
      'eatova.v1.daily_activity.user-activity': jsonEncode({
        'days': {
          '2026-08-10': {'steps': 5000, 'kcal': 210},
          '2026-08-11': 'kaputt',
        },
      }),
    });
    final cache = LocalCache(kv, 'user-activity');
    final back = await cache.readDailyActivity();
    expect(back, {'2026-08-10': (steps: 5000, kcal: 210)});

    final kaputt = InMemoryKeyValueStore({
      'eatova.v1.daily_activity.user-activity': 'kein json',
    });
    expect(await LocalCache(kaputt, 'user-activity').readDailyActivity(),
        isNull);
  });
}
