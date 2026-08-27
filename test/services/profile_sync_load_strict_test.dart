import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';

// Sentinel finding 3: ProfileSync.load used to fill unreadable numeric fields
// with invented defaults and return them as a full profile. Boot then marked it
// as a real hydration source and the next save wrote the fiction to the server.
//
// Contract: a row whose numeric fields are unreadable is NOT a hydration source
// at all — load() throws (FormatException), boot catches it, nothing hydrates
// and the clobber guard stays closed. The DB has these columns NOT NULL, so
// this path only fires on parse garbage or schema drift, where being loud beats
// inventing.
//
// Enum fields stay lenient on purpose (A7): they fall back to a documented
// value, not to an invented measurement.

SupabaseClient _clientMitZeile(Map<String, dynamic> zeile) => SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response(
            jsonEncode(zeile),
            200,
            headers: const {'Content-Type': 'application/json'},
            request: req,
          )),
      // No auto-refresh ticker: the test needs none and must leave no pending
      // timer.
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

Map<String, dynamic> _vollstaendigeZeile() => <String, dynamic>{
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
      'protein_goal_g': 160,
      'carbs_goal_g': 250,
      'fat_goal_g': 80,
      'weight_goal': 'lose05kg',
      'diet_preference': 'vegan',
      'onboarding_completed': true,
      // Manual mode: load() returns the stored goals untouched. Without the
      // flag the live-mode healing (F7-01) would replace 2450 with the
      // calculator's value — covered in fixlauf_g_manual_energy_test.
      'manual_energy': true,
    };

void main() {
  test('Kontrolle: eine vollstaendige Zeile parst verlustfrei', () async {
    final sync = ProfileSync(_clientMitZeile(_vollstaendigeZeile()), 'user-1');

    final profil = await sync.load();

    expect(profil, isNotNull);
    expect(profil!.weightKg, 82);
    expect(profil.dailyKcalGoal, 2450);
    expect(profil.diet, DietPreference.vegan);
    expect(profil.onboardingCompleted, isTrue);
  });

  test('unlesbares Zahlenfeld: load() wirft statt 78 kg zu erfinden',
      () async {
    final zeile = _vollstaendigeZeile()..['weight_kg'] = 'kaputt';
    final sync = ProfileSync(_clientMitZeile(zeile), 'user-1');

    await expectLater(sync.load(), throwsFormatException,
        reason: 'ein erfundenes Gewicht wuerde als echte Hydrationsquelle '
            'markiert und beim naechsten Save dauerhaft auf den Server '
            'geschrieben');
  });

  test('fehlendes Zahlenfeld (Schema-Drift): load() wirft ebenfalls',
      () async {
    final zeile = _vollstaendigeZeile()..remove('protein_goal_g');
    final sync = ProfileSync(_clientMitZeile(zeile), 'user-1');

    await expectLater(sync.load(), throwsFormatException);
  });

  test('Enum-Muell bleibt nachsichtig (A7-Entscheidung, kein Wurf)', () async {
    final zeile = _vollstaendigeZeile()..['diet_preference'] = 'voll_random';
    final sync = ProfileSync(_clientMitZeile(zeile), 'user-1');

    final profil = await sync.load();

    expect(profil!.diet, DietPreference.none,
        reason: 'unbekannte Enum-Werte (z. B. aus einem neueren Build) '
            'fallen dokumentiert auf none — das ist Vorwaertskompatibilitaet, '
            'kein erfundener Messwert');
  });
}
