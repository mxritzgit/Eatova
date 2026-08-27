// Fix wave 2026-08-27, smaller cross-package items:
//   * WeightLog.add stamps entries with `clock.now()` (G M-5) — testable time.
//   * profiles.manual_energy survives the cache/outbox JSON round trip
//     (Review G gap b): an offline manual goal must not be healed back to the
//     calculator after the next boot.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/sync_outbox.dart';

void main() {
  group('WeightLog.add — Zeitstempel aus clock.now()', () {
    test('unter withClock traegt der Eintrag die Fake-Zeit', () {
      final fest = DateTime(2026, 8, 27, 10, 30);
      final log = withClock(
        Clock.fixed(fest),
        () => const WeightLog().add(80),
      );
      expect(log.latest!.timestamp, fest);
    });

    test('zwei Eintraege unter zwei Uhren bleiben aufsteigend', () {
      final erst = withClock(
        Clock.fixed(DateTime(2026, 8, 26)),
        () => const WeightLog().add(80),
      );
      final dann = withClock(
        Clock.fixed(DateTime(2026, 8, 27)),
        () => erst.add(79.5),
      );
      expect(dann.entries.map((e) => e.timestamp).toList(), [
        DateTime(2026, 8, 26),
        DateTime(2026, 8, 27),
      ]);
    });
  });

  group('manual_energy im Profil-JSON (userProfileToJson/FromJson)', () {
    const manuell = UserProfile(
      dailyKcalGoal: 1850,
      proteinGoalG: 140,
      onboardingCompleted: true,
      manualEnergy: true,
    );

    test('true ueberlebt den Roundtrip samt Zielwerten', () {
      final json = userProfileToJson(manuell);
      expect(json['manual_energy'], isTrue);

      final zurueck = userProfileFromJson(json);
      expect(zurueck, isNotNull);
      expect(zurueck!.manualEnergy, isTrue);
      expect(zurueck.dailyKcalGoal, 1850);
      expect(zurueck.proteinGoalG, 140);
      expect(zurueck.onboardingCompleted, isTrue);
    });

    test('false ueberlebt den Roundtrip', () {
      final json = userProfileToJson(manuell.copyWith(manualEnergy: false));
      expect(json['manual_energy'], isFalse);
      expect(userProfileFromJson(json)!.manualEnergy, isFalse);
    });

    test('fehlender Schluessel (aelterer Cache) zaehlt als Live', () {
      final json = Map<String, dynamic>.of(userProfileToJson(manuell))
        ..remove('manual_energy');
      expect(userProfileFromJson(json)!.manualEnergy, isFalse);
    });
  });
}
