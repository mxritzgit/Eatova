import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/profile_sync.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

import 'support/harness.dart';

// F7-01 (review 2026-08-27): the goals page RECONSTRUCTED "manual" by
// comparing stored kcal/macros with the calculator. After PR #47/#48 (PAL
// 1.2 -> 1.3) every existing profile differed, opened in manual mode and
// froze the old target. The flag is now persisted (profiles.manual_energy);
// in live mode the calculator is the truth and ProfileSync.load heals the
// stored goals.

/// A profile saved by the OLD calculator: 2000 kcal where the current one
/// yields 2150. Live mode (flag false) must still open live.
const UserProfile _altesLiveProfil = UserProfile(
  dailyKcalGoal: 2000,
  proteinGoalG: 100,
  carbsGoalG: 200,
  fatGoalG: 60,
  onboardingCompleted: true,
);

const UserProfile _manuellesProfil = UserProfile(
  dailyKcalGoal: 2000,
  proteinGoalG: 100,
  carbsGoalG: 200,
  fatGoalG: 60,
  onboardingCompleted: true,
  manualEnergy: true,
);

Future<Future<SettingsResult?>> _openGoals(
  WidgetTester tester,
  UserProfile profile,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  late Future<SettingsResult?> result;
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-goals'),
          onPressed: () {
            result = Navigator.of(context).push<SettingsResult>(
              MaterialPageRoute<SettingsResult>(
                builder: (_) => GoalsScreen(profile: profile),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
    reducedMotion: false,
    brightness: Brightness.light,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('open-goals')));
  await tester.pumpAndSettle();
  return result;
}

bool _schalter(WidgetTester tester) => tester
    .widget<AppToggle>(find.byKey(const ValueKey('settings-manual-energy')))
    .value;

Future<SettingsResult?> _speichern(
  WidgetTester tester,
  Future<SettingsResult?> result,
) async {
  await tester.ensureVisible(find.byKey(const ValueKey('settings-save')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('settings-save')));
  await tester.pumpAndSettle();
  return result;
}

Map<String, dynamic> _serverZeile({
  int kcal = 2000,
  bool? manual,
  bool onboarding = true,
}) =>
    <String, dynamic>{
      'weight_kg': 78,
      'height_cm': 178,
      'age_years': 30,
      'sex': 'neutral',
      'activity_level': 'sedentary',
      'target_weight_kg': 78,
      'daily_steps_goal': 8000,
      'daily_kcal_goal': kcal,
      'daily_water_goal_ml': 2500,
      'daily_sleep_goal_minutes': 450,
      'protein_goal_g': 100,
      'carbs_goal_g': 200,
      'fat_goal_g': 60,
      'weight_goal': 'maintain',
      'diet_preference': 'none',
      'onboarding_completed': onboarding,
      if (manual != null) 'manual_energy': manual,
    };

/// Client answering every request with [zeile]; records the requests so the
/// save payload can be inspected.
({SupabaseClient client, List<http.Request> requests}) _client(
  Map<String, dynamic> zeile,
) {
  final requests = <http.Request>[];
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) async {
      requests.add(req);
      return http.Response(
        jsonEncode(zeile),
        200,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  return (client: client, requests: requests);
}

void main() {
  final rechner = const KcalCalculator().calculate(_altesLiveProfil);

  group('GoalsScreen — Manuell-Modus ist ein persistiertes Flag', () {
    testWidgets('Profil aus aelterem Rechner oeffnet im Live-Modus',
        (tester) async {
      await _openGoals(tester, _altesLiveProfil);

      expect(_schalter(tester), isFalse,
          reason: '2000 != 2150 darf NICHT mehr „manuell" bedeuten');
      expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
      // The hero shows the calculator, not the stale stored number.
      expect(find.text('${rechner.kcal}'), findsOneWidget);
      expect(find.text('2000'), findsNothing);
    });

    testWidgets('Speichern im Live-Modus schreibt Rechnerwerte und false',
        (tester) async {
      final result = await _speichern(
        tester,
        await _openGoals(tester, _altesLiveProfil),
      );

      final p = result!.profile;
      expect(p.manualEnergy, isFalse);
      expect(p.dailyKcalGoal, rechner.kcal);
      expect(p.proteinGoalG, rechner.proteinG);
      expect(p.carbsGoalG, rechner.carbsG);
      expect(p.fatGoalG, rechner.fatG);
      // Untouched fields survive the page (water/sleep rows are gone).
      expect(p.onboardingCompleted, isTrue);
      expect(p.dailyWaterGoalMl, 2500);
    });

    testWidgets('manuelles Profil oeffnet manuell und behaelt seine Zahlen',
        (tester) async {
      final result = await _speichern(
        tester,
        await _openGoals(tester, _manuellesProfil),
      );

      final p = result!.profile;
      expect(p.manualEnergy, isTrue);
      expect(p.dailyKcalGoal, 2000);
      expect(p.proteinGoalG, 100);
    });

    testWidgets('manuelles Profil zeigt Schalter an und kcal-Feld mit 2000',
        (tester) async {
      await _openGoals(tester, _manuellesProfil);

      expect(_schalter(tester), isTrue);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('settings-kcal')))
            .controller!
            .text,
        '2000',
      );
    });

    testWidgets('Umschalten auf Manuell wird beim Speichern zu true',
        (tester) async {
      final result = await _openGoals(tester, _altesLiveProfil);
      await tester
          .ensureVisible(find.byKey(const ValueKey('settings-manual-energy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
      await tester.pumpAndSettle();

      final p = (await _speichern(tester, result))!.profile;
      expect(p.manualEnergy, isTrue);
      // The fields were prefilled from the live calculation on the flip.
      expect(p.dailyKcalGoal, rechner.kcal);
    });
  });

  group('KcalCalculator.applyLiveGoals', () {
    test('Live + abweichend -> Rechnerwerte, sonst dieselbe Instanz', () {
      const rechner = KcalCalculator();
      final geheilt = rechner.applyLiveGoals(_altesLiveProfil);
      expect(identical(geheilt, _altesLiveProfil), isFalse);
      expect(geheilt.dailyKcalGoal, rechner.calculate(_altesLiveProfil).kcal);
      expect(geheilt.manualEnergy, isFalse);

      // Already equal -> identical (no needless write).
      expect(identical(rechner.applyLiveGoals(geheilt), geheilt), isTrue);
      // Manual -> untouched.
      expect(
        identical(rechner.applyLiveGoals(_manuellesProfil), _manuellesProfil),
        isTrue,
      );
      // Onboarding not done -> bootstrap row, nothing to heal.
      const roh = UserProfile(dailyKcalGoal: 2000);
      expect(identical(rechner.applyLiveGoals(roh), roh), isTrue);
    });
  });

  group('ProfileSync — Selbstheilung beim Laden', () {
    test('Zeile ohne Flag (Altbestand) und altem Ziel -> Rechnerwerte',
        () async {
      final c = _client(_serverZeile(kcal: 2000));
      final p = await ProfileSync(c.client, 'user-1').load();

      expect(p, isNotNull);
      expect(p!.manualEnergy, isFalse);
      expect(p.dailyKcalGoal, rechner.kcal,
          reason: 'Live-Modus: der Rechner ist die Wahrheit, 2000 war der '
              'Stand des alten Rechners');
      expect(p.proteinGoalG, rechner.proteinG);
      // A load stays a read: no upsert fired behind the caller's back.
      expect(c.requests.where((r) => r.method != 'GET'), isEmpty);
    });

    test('manual_energy = true -> gespeicherte Ziele bleiben', () async {
      final c = _client(_serverZeile(kcal: 2000, manual: true));
      final p = await ProfileSync(c.client, 'user-1').load();

      expect(p!.manualEnergy, isTrue);
      expect(p.dailyKcalGoal, 2000);
    });

    test('Bootstrap-Zeile (Onboarding offen) wird nicht angefasst', () async {
      final c = _client(_serverZeile(kcal: 2000, onboarding: false));
      final p = await ProfileSync(c.client, 'user-1').load();

      expect(p!.dailyKcalGoal, 2000);
    });

    test('save schreibt manual_energy explizit (false UND true)', () async {
      final c = _client(_serverZeile());
      final sync = ProfileSync(c.client, 'user-1');

      await sync.save(_altesLiveProfil);
      await sync.save(_manuellesProfil);

      final payloads = c.requests
          .where((r) => r.method == 'POST')
          .map((r) => jsonDecode(r.body))
          .toList();
      expect(payloads, hasLength(2));
      expect(payloads[0]['manual_energy'], isFalse);
      expect(payloads[1]['manual_energy'], isTrue);
    });

    test('load fragt die Spalte manual_energy ab', () async {
      final c = _client(_serverZeile());
      await ProfileSync(c.client, 'user-1').load();

      final select = c.requests.single.url.queryParameters['select'];
      expect(select, contains('manual_energy'));
    });
  });
}
