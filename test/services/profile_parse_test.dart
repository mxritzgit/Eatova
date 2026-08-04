import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/profile_sync.dart';

// Table-Tests fuer die reinen Profil-Parser aus profile_sync.dart.
// parseProfileGoal ist korrektheitskritisch: jede falsche Branch ist ein
// stiller ±550/±1100 kcal/Tag-Zielbug (das Tagesziel haengt am WeightGoal).
// Deckt das Legacy-Tempo-Schema (loseFast/loseSteady/gainFast/gainSteady),
// die kanonischen enum-Namen, null und Muell ab. Netz-/Client-frei.

void main() {
  group('parseProfileGoal', () {
    // Legacy-Tempo-Strings -> kg/Woche-Raten. Jede Zeile ist ein geld-/
    // gesundheitskritisches Mapping, deshalb hier vollstaendig durchdekliniert.
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

    // Kanonische enum-Namen muessen 1:1 wieder ihren Wert ergeben (Roundtrip
    // ueber WeightGoal.name, so wie save() schreibt).
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
      expect(parseProfileGoal('LoseFast'), WeightGoal.maintain); // case-sensitiv
    });

    test('Legacy-Mappings landen auf den richtigen kcal-Deltas', () {
      // Doppelte Absicherung: die Rate hinter dem gemappten Goal stimmt.
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
      expect(parseProfileSex('Male'), BiologicalSex.neutral); // case-sensitiv
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
    // Kanonische enum-Namen roundtrippen 1:1 (so wie save() ueber .name schreibt).
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
      expect(parseDietPreference('Vegan'), DietPreference.none); // case-sensitiv
    });
  });
}
