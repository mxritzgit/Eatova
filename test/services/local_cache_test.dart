import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';

// DATA-3: LocalCache is the durable write-through JSON cache for the profile
// and lifetime_stats. Driven here through InMemoryKeyValueStore (no
// SharedPreferences channel): lossless roundtrips of EVERY field (see A7),
// corrupt or partial entries return null instead of crashing, an empty cache
// returns null everywhere, clear() removes all entries including the legacy
// daily slot (M-1), and the cache is separated per userId.

LocalCache _cache(InMemoryKeyValueStore store, [String userId = 'user-1']) =>
    LocalCache(store, userId);

/// camelCase -> snake_case, the naming convention of the cache wire format.
String _snake(String camel) =>
    camel.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

/// Complete numeric part of a profile blob. A blob with unreadable numbers is
/// no hydration source at all, so enum leniency is tested on numerically
/// complete blobs.
Map<String, dynamic> _zahlenVollstaendig() => <String, dynamic>{
      'weight_kg': 82,
      'height_cm': 181,
      'age_years': 34,
      'target_weight_kg': 77,
      'daily_steps_goal': 9000,
      'daily_kcal_goal': 2450,
      'daily_water_goal_ml': 3000,
      'daily_sleep_goal_minutes': 480,
      'protein_goal_g': 160,
      'carbs_goal_g': 250,
      'fat_goal_g': 80,
    };

void main() {
  group('LocalCache Profil', () {
    test('roundtrippt ein vollstaendiges Profil verlustfrei', () async {
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      const profile = UserProfile(
        weightKg: 82,
        heightCm: 181,
        ageYears: 34,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.active,
        targetWeightKg: 77,
        dailyStepsGoal: 9000,
        dailyKcalGoal: 2450,
        dailyWaterGoalMl: 3000,
        dailySleepGoalMinutes: 8 * 60,
        proteinGoalG: 160,
        carbsGoalG: 250,
        fatGoalG: 80,
        weightGoal: WeightGoal.lose05kg,
        diet: DietPreference.vegan,
        onboardingCompleted: true,
      );

      await cache.writeProfile(profile);
      final back = await cache.readProfile();

      expect(back, isNotNull);
      expect(back!.weightKg, 82);
      expect(back.heightCm, 181);
      expect(back.ageYears, 34);
      expect(back.sex, BiologicalSex.male);
      expect(back.activityLevel, ActivityLevel.active);
      expect(back.targetWeightKg, 77);
      expect(back.dailyStepsGoal, 9000);
      expect(back.dailyKcalGoal, 2450);
      expect(back.dailyWaterGoalMl, 3000);
      expect(back.dailySleepGoalMinutes, 8 * 60);
      expect(back.proteinGoalG, 160);
      expect(back.carbsGoalG, 250);
      expect(back.fatGoalG, 80);
      expect(back.weightGoal, WeightGoal.lose05kg);
      // A7: diet was missing from the wire format entirely — the cache
      // silently returned DietPreference.none and the next profile.save()
      // persisted that to the server.
      expect(back.diet, DietPreference.vegan);
      expect(back.onboardingCompleted, isTrue);
    });

    test(
        'Legacy-Blob ohne Zahlen-Schluessel liefert null statt erfundener '
        'Werte (Sentinel-Fund 3)', () async {
      // A blob from an older build missing a numeric field used to be filled
      // with invented values and still set the clobber lock
      // (_hydratedFromRealSource), so the next profile.save() persisted the
      // fantasy — the A7 mechanism. An incomplete blob is therefore no
      // hydration source at all: null, and the server load provides truth.
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      final blob = <String, dynamic>{
        'weight_kg': 82,
        'height_cm': 181,
        'age_years': 34,
        'sex': 'male',
        'activity_level': 'active',
        'target_weight_kg': 77,
        'daily_steps_goal': 9000,
        'daily_kcal_goal': 2450,
        'daily_water_goal_ml': 3000,
        'daily_sleep_goal_minutes': 480,
        // protein_goal_g missing, like a blob from before the macro rollout.
        'carbs_goal_g': 250,
        'fat_goal_g': 80,
        'weight_goal': 'lose05kg',
        'diet_preference': 'vegan',
        'onboarding_completed': true,
      };
      await store.setString('eatova.v1.profile.user-1', jsonEncode(blob));

      expect(await cache.readProfile(), isNull,
          reason: 'aufgefuellte 130 g Protein wuerden beim naechsten Save '
              'als echte Daten auf den Server geschrieben');
    });

    test('Zahlen-Muell im Blob liefert null statt erfundener Werte', () async {
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      final blob = <String, dynamic>{'weight_kg': 'kaputt'};
      await store.setString('eatova.v1.profile.user-1', jsonEncode(blob));

      expect(await cache.readProfile(), isNull);
    });

    test('Wire-Format deckt JEDES UserProfile-Feld ab (neue Felder -> rot)',
        () async {
      // A7 pinned structurally: adding a field to UserProfile without adding
      // it to _profileToJson turns this test red. Flutter has no reflection,
      // so the field declarations are read from the model source.
      final quelle =
          File('lib/src/models/user_profile.dart').readAsStringSync();
      final klassenRumpf =
          quelle.substring(quelle.indexOf('class UserProfile {'));
      final felder = RegExp(r'^\s+final\s+[\w<>?]+\s+(\w+);', multiLine: true)
          .allMatches(klassenRumpf)
          .map((m) => m.group(1)!)
          .toList();
      expect(felder, hasLength(16),
          reason: 'Feldliste aus lib/src/models/user_profile.dart gelesen');

      // Field name -> cache key: camelCase -> snake_case, with `diet` the one
      // exception (server-side it is `diet_preference`).
      const aliase = <String, String>{'diet': 'diet_preference'};
      final erwarteteSchluessel =
          felder.map((f) => aliase[f] ?? _snake(f)).toSet();

      final store = InMemoryKeyValueStore();
      await _cache(store).writeProfile(const UserProfile());
      final geschriebeneSchluessel =
          (jsonDecode(store.snapshot['eatova.v1.profile.user-1']!)
                  as Map<String, dynamic>)
              .keys
              .toSet();

      expect(geschriebeneSchluessel, erwarteteSchluessel);
    });

    test('unbekannte diet_preference faellt auf none (kein Crash)', () async {
      final store = InMemoryKeyValueStore({
        'eatova.v1.profile.user-1':
            jsonEncode(_zahlenVollstaendig()..['diet_preference'] = 'karnivor'),
      });
      final back = await _cache(store).readProfile();
      expect(back, isNotNull);
      expect(back!.diet, DietPreference.none);
    });

    test('leerer Cache -> null (kein Default-Profil aus dem Nichts)', () async {
      final cache = _cache(InMemoryKeyValueStore());
      expect(await cache.readProfile(), isNull);
    });

    test('korrupter Eintrag -> null statt Crash', () async {
      final store = InMemoryKeyValueStore({
        'eatova.v1.profile.user-1': '{ das ist kein json',
      });
      expect(await _cache(store).readProfile(), isNull);
    });

    test('unbekannte enum-Strings fallen auf Defaults (kein Crash)', () async {
      final store = InMemoryKeyValueStore({
        'eatova.v1.profile.user-1': jsonEncode(_zahlenVollstaendig()
          ..['sex'] = 'divers'
          ..['activity_level'] = 'couch'
          ..['weight_goal'] = 'hyperbulk'),
      });
      final back = await _cache(store).readProfile();
      expect(back, isNotNull);
      expect(back!.sex, BiologicalSex.neutral);
      expect(back.activityLevel, ActivityLevel.sedentary);
      expect(back.weightGoal, WeightGoal.maintain);
      // The numbers come from the blob: invented measurements no longer count
      // as a hydration source.
      expect(back.weightKg, 82);
      expect(back.heightCm, 181);
    });
  });

  group('LocalCache lifetime_stats', () {
    test('roundtrippt inkl. Streak-Felder', () async {
      final store = InMemoryKeyValueStore();
      final cache = _cache(store);
      final stats = LifetimeStats(
        workoutsCompleted: 12,
        mealsLogged: 88,
        waterTotalMl: 42000,
        stepsRecorded: 310000,
        weightLogs: 9,
        currentStreak: 4,
        longestStreak: 11,
        lastTrackedDate: DateTime(2026, 6, 3),
      );

      await cache.writeLifetimeStats(stats);
      final back = await cache.readLifetimeStats();

      expect(back, isNotNull);
      expect(back!.workoutsCompleted, 12);
      expect(back.mealsLogged, 88);
      expect(back.waterTotalMl, 42000);
      expect(back.stepsRecorded, 310000);
      expect(back.weightLogs, 9);
      expect(back.currentStreak, 4);
      expect(back.longestStreak, 11);
      expect(back.lastTrackedDate, DateTime(2026, 6, 3));
    });

    test('leerer Cache -> null', () async {
      expect(await _cache(InMemoryKeyValueStore()).readLifetimeStats(), isNull);
    });
  });

  group('LocalCache Housekeeping', () {
    test('clear() entfernt Profil + Stats + Legacy-daily-Slot (M-1)', () async {
      // Legacy entry of the old today tab (mood note = PII): no longer
      // written, but must still disappear on logout.
      final store = InMemoryKeyValueStore({
        'eatova.v1.daily.user-1': '{"mood_note":"privat"}',
      });
      final cache = _cache(store);
      await cache.writeProfile(const UserProfile(weightKg: 90));
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 3));

      await cache.clear();

      expect(await cache.readProfile(), isNull);
      expect(await cache.readLifetimeStats(), isNull);
      expect(store.snapshot.containsKey('eatova.v1.daily.user-1'), isFalse);
    });

    test('Cache ist pro userId getrennt (kein Cross-User-Leak)', () async {
      final store = InMemoryKeyValueStore();
      final a = _cache(store, 'user-a');
      final b = _cache(store, 'user-b');

      await a.writeProfile(const UserProfile(weightKg: 95));
      // user-b wrote nothing -> does NOT see user-a.
      expect(await b.readProfile(), isNull);
      expect((await a.readProfile())!.weightKg, 95);
    });
  });
}
