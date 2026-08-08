import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';

// Sentinel-Fund 3 (Nachverifikation 2026-08-08), Server-Gate: ProfileSync.load
// fuellte unlesbare Zahlenfelder mit erfundenen Werten auf (78 kg, 178 cm,
// 2200 kcal, ...) und lieferte das Ergebnis als vollwertiges Profil zurueck.
// Der Boot markierte es damit als echte Hydrationsquelle
// (_hydratedFromRealSource = true), und der naechste profile.save() schrieb
// die Fantasie dauerhaft auf den Server — der A7-Mechanismus, nur fuer die
// Zahlenfelder.
//
// Neuer Vertrag: eine Zeile, deren Zahlenfelder nicht lesbar sind, ist ALS
// GANZES keine Hydrationsquelle — load() wirft (FormatException), _safeLoad
// im Boot faengt das, es gibt KEINE Hydration und der Clobber-Schutz bleibt
// geschlossen. Die DB garantiert die Spalten ohnehin als NOT NULL; dieser
// Pfad feuert nur bei Parse-Muell/Schema-Drift — und dann ist Lautstaerke
// richtig, nicht Erfinden.
//
// Die Enum-Felder (sex, activity_level, weight_goal, diet_preference) bleiben
// bewusst nachsichtig (A7-Entscheidung, parseProfile*-Tests): sie erfinden
// Einordnungen mit dokumentiertem Fallback, keine Messwerte.

SupabaseClient _clientMitZeile(Map<String, dynamic> zeile) => SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response(
            jsonEncode(zeile),
            200,
            headers: const {'Content-Type': 'application/json'},
            request: req,
          )),
      // Kein Auto-Refresh-Ticker: der Test braucht keinen Auth-Refresh und
      // soll keinen pendenden Timer hinterlassen.
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
