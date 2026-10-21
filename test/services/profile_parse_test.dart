import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';

// Table tests for the pure profile parsers in profile_sync.dart. A wrong
// parseProfileGoal branch is a silent ±550 kcal/day target bug, since the
// daily target hangs off WeightGoal (the kcal per goal is pinned in
// kcal_effective_pace_test.dart).

void main() {
  test('parseProfileGoal: Legacy-Tempi, kanonische Namen, sonst maintain', () {
    // Legacy pace strings -> kg/week rates; health-critical, so spelled out.
    const legacy = <String, WeightGoal>{
      'loseFast': WeightGoal.lose05kg,
      'loseSteady': WeightGoal.lose025kg,
      'gainFast': WeightGoal.gain05kg,
      'gainSteady': WeightGoal.gain025kg,
    };
    legacy.forEach((raw, expected) {
      expect(parseProfileGoal(raw), expected, reason: raw);
    });
    // Canonical names must round-trip via .name, as save() writes them.
    for (final goal in WeightGoal.values) {
      expect(parseProfileGoal(goal.name), goal);
    }
    for (final raw in <String?>[null, 'voll_random', '', 'LoseFast']) {
      expect(parseProfileGoal(raw), WeightGoal.maintain, reason: '$raw');
    }
  });

  test('parseProfileSex: Namen roundtrippen, sonst neutral', () {
    for (final sex in BiologicalSex.values) {
      expect(parseProfileSex(sex.name), sex);
    }
    for (final raw in <String?>[null, 'divers', 'Male']) {
      expect(parseProfileSex(raw), BiologicalSex.neutral, reason: '$raw');
    }
  });

  test('parseProfileActivity: Namen roundtrippen, sonst sedentary', () {
    for (final level in ActivityLevel.values) {
      expect(parseProfileActivity(level.name), level);
    }
    // The conservative PAL 1.2 for anything unknown.
    for (final raw in <String?>[null, 'couchpotato', 'Athlete']) {
      expect(
        parseProfileActivity(raw),
        ActivityLevel.sedentary,
        reason: '$raw',
      );
    }
  });

  test('parseDietPreference: Namen roundtrippen, sonst none', () {
    for (final diet in DietPreference.values) {
      expect(parseDietPreference(diet.name), diet);
    }
    // A broken field must not silently restrict recommendations.
    for (final raw in <String?>[null, 'paleo', '', 'Vegan']) {
      expect(parseDietPreference(raw), DietPreference.none, reason: '$raw');
    }
  });
}
