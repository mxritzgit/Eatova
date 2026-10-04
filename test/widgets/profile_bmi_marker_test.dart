// The BMI scale's marker per display mode (light pass, 2026-10-04). Dark keeps
// the light dot cut out of the track by a card-coloured border; light used to
// paint `ink` there, a near-black dot on the white card, and now shows a
// white knob in an accent ring — the calorie arc's knob tokens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

const UserProfile _profile = UserProfile(
  weightKg: 82,
  heightCm: 182,
  ageYears: 31,
  sex: BiologicalSex.male,
  onboardingCompleted: true,
);

Future<BoxDecoration> _marker(WidgetTester tester, Brightness b) async {
  await pumpLocalized(
    tester,
    const SingleChildScrollView(
      child: BmiCard(profile: _profile, log: WeightLog()),
    ),
    brightness: b,
    surfaceSize: const Size(390, 900),
  );
  final box = tester.widget<DecoratedBox>(
    find.byKey(const ValueKey('profile-bmi-marker')),
  );
  return box.decoration as BoxDecoration;
}

void main() {
  testWidgets('hell: weisser Knopf im Akzentring statt schwarzem Punkt', (
    tester,
  ) async {
    const t = AppTokens.light;
    final d = await _marker(tester, Brightness.light);
    expect(d.color, isNot(t.ink), reason: 'der alte schwarze Punkt');
    expect(d.color, t.knob);
    expect((d.border! as Border).top.color, t.knobRing);
  });

  testWidgets('dunkel: unveraendert der helle Punkt mit Kartenrand', (
    tester,
  ) async {
    const t = AppTokens.dark;
    final d = await _marker(tester, Brightness.dark);
    expect(d.color, t.ink);
    expect((d.border! as Border).top.color, t.surf);
  });
}
