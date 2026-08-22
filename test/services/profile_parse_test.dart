import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';

// Table tests for the pure profile parsers in profile_sync.dart. A wrong
// parseProfileGoal branch is a silent ±550 kcal/day target bug, since the
// daily target hangs off WeightGoal.

void main() {
  group('parseProfileGoal', () {
    // Legacy pace strings -> kg/week rates; health-critical, so spelled out.
    const legacy = <String, WeightGoal>{
      'loseFast': WeightGoal.lose05kg,
      'loseSteady': WeightGoal.lose025kg,
      'gainFast': WeightGoal.gain05kg,
      'gainSteady': WeightGoal.gain025kg,
    };
    legacy.forEach((raw, expected) {
      test('Legacy "$raw" -> $expected (kcalDelta ${expected.kcalDelta})', () {
        expect(parseProfileGoal(raw), expected);
      });
    });

    // Canonical names must round-trip via .name, as save() writes them.
    for (final goal in WeightGoal.values) {
      test('Kanonischer Name "${goal.name}" roundtrippt zu $goal', () {
        expect(parseProfileGoal(goal.name), goal);
      });
    }

    test('null -> maintain', () {
      expect(parseProfileGoal(null), WeightGoal.maintain);
    });

    test('unbekannter String -> maintain (kein Crash, kein Default-Delta-Bug)', () {
      expect(parseProfileGoal('voll_random'), WeightGoal.maintain);
      expect(parseProfileGoal(''), WeightGoal.maintain);
      expect(parseProfileGoal('LoseFast'), WeightGoal.maintain); // case-sensitive
    });

    test('Legacy-Mappings landen auf den richtigen kcal-Deltas', () {
      // Second safeguard: the rate behind the mapped goal.
      expect(parseProfileGoal('loseFast').kcalDelta, -550);
      expect(parseProfileGoal('loseSteady').kcalDelta, -275);
      expect(parseProfileGoal('gainFast').kcalDelta, 550);
      expect(parseProfileGoal('gainSteady').kcalDelta, 275);
    });
  });

  group('parseProfileSex', () {
    for (final sex in BiologicalSex.values) {
      test('Name "${sex.name}" roundtrippt zu $sex', () {
        expect(parseProfileSex(sex.name), sex);
      });
    }
    test('null -> neutral', () {
      expect(parseProfileSex(null), BiologicalSex.neutral);
    });
    test('Muell -> neutral', () {
      expect(parseProfileSex('divers'), BiologicalSex.neutral);
      expect(parseProfileSex('Male'), BiologicalSex.neutral); // case-sensitive
    });
  });

  group('parseProfileActivity', () {
    for (final level in ActivityLevel.values) {
      test('Name "${level.name}" roundtrippt zu $level', () {
        expect(parseProfileActivity(level.name), level);
      });
    }
    test('null -> sedentary', () {
      expect(parseProfileActivity(null), ActivityLevel.sedentary);
    });
    test('Muell -> sedentary (konservativer PAL 1.2)', () {
      expect(parseProfileActivity('couchpotato'), ActivityLevel.sedentary);
      expect(parseProfileActivity('Athlete'), ActivityLevel.sedentary);
    });
  });

  group('parseDietPreference', () {
    // Canonical names round-trip via .name.
    for (final diet in DietPreference.values) {
      test('Name "${diet.name}" roundtrippt zu $diet', () {
        expect(parseDietPreference(diet.name), diet);
      });
    }
    test('null -> none (empfiehlt alles, schraenkt nicht ungewollt ein)', () {
      expect(parseDietPreference(null), DietPreference.none);
    });
    test('Muell -> none (kein Crash, keine stille Einschraenkung)', () {
      expect(parseDietPreference('paleo'), DietPreference.none);
      expect(parseDietPreference(''), DietPreference.none);
      expect(parseDietPreference('Vegan'), DietPreference.none); // case-sensitive
    });
  });
}
