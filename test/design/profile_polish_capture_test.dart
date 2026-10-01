// Visual evidence for the profile page polish (design polish run 2026-10-02).
//
// Mounts the real ProfileScreen at the design's reference geometry with a
// realistic, lived-in account: eight weeks of weigh-ins, a running streak,
// a cut towards a target weight and a connected Apple Health. Shots:
//   profile-00..03   the page top to bottom (en)
//   profile-de-00/01 the densest part in German
//   profile-new-00   a fresh account (one weigh-in, nothing connected)
//   profile-weight-sheet / profile-bmi-sheet  the two sheets
//   profile-xl-00/01 the page at 2.0 text scale
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/. Without it the suite still pins that the page renders
// overflow-free at 1.0 and 2.0, that the scenario's numbers reach the screen,
// and that every action of the page is still mounted.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 10, 2, 9, 30);

const UserProfile _profile = UserProfile(
  weightKg: 84,
  heightCm: 182,
  ageYears: 31,
  sex: BiologicalSex.male,
  activityLevel: ActivityLevel.light,
  targetWeightKg: 76,
  weightGoal: WeightGoal.lose05kg,
  dailyKcalGoal: 2050,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
  dailyStepsGoal: 8000,
);

/// Eight weeks of mostly weekly weigh-ins with realistic noise.
WeightLog _log() {
  const kg = <double>[
    84.6, 84.1, 84.3, 83.5, 83.2, 82.6, 82.9, 82.1, 81.7, 81.4, 81.2,
  ];
  final start = DateTime(2026, 8, 7, 7, 40);
  return WeightLog(
    entries: <WeightLogEntry>[
      for (var i = 0; i < kg.length; i++)
        WeightLogEntry(
          timestamp: start.add(Duration(days: i * 5 + (i == 10 ? 6 : 0))),
          weightKg: kg[i],
        ),
    ],
  );
}

LifetimeStats _stats() => LifetimeStats(
  mealsLogged: 412,
  weightLogs: 23,
  currentStreak: 12,
  longestStreak: 21,
  lastTrackedDate: DateTime(2026, 10, 2),
  sessionStart: DateTime(2026, 6, 14),
);

Widget _screen({
  UserProfile profile = _profile,
  WeightLog? log,
  LifetimeStats? stats,
  HealthAuthState health = HealthAuthState.granted,
  DateTime? lastFetch,
  int? steps = 6430,
  int kcal = 1221,
}) => ProfileScreen(
  name: 'Moritz Schneider',
  profile: profile,
  weightLog: log ?? _log(),
  stats: stats ?? _stats(),
  dailyConsumedKcal: kcal,
  dailySteps: steps,
  healthAuthState: health,
  healthLastFetch: lastFetch ?? _now.subtract(const Duration(minutes: 12)),
  onLogWeight: (_) {},
  onEditProfile: () {},
  onOpenSettings: () {},
  onConnectHealth: () {},
  onRefreshHealth: () {},
);

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        screen,
        locale: locale,
        textScale: textScale,
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _page() => find.descendant(
  of: find.byKey(const ValueKey('screen-profile')),
  matching: find.byType(Scrollable),
).first;

Future<void> _scrollTo(WidgetTester tester, double offset) async {
  final position = tester.state<ScrollableState>(_page()).position;
  position.jumpTo(offset.clamp(0, position.maxScrollExtent));
  await tester.pumpAndSettle();
}

Future<void> _shootPage(WidgetTester tester, String prefix) async {
  final position = tester.state<ScrollableState>(_page()).position;
  final max = position.maxScrollExtent;
  var i = 0;
  for (double y = 0; ; y += 640) {
    await _scrollTo(tester, y);
    await captureDesignShot(tester, '$prefix-${i.toString().padLeft(2, '0')}');
    i++;
    if (y >= max) break;
  }
}

const _actions = <String>[
  'profile-close',
  'profile-open-settings',
  'profile-goalplan-edit',
  'profile-log-weight',
  'profile-edit-goals',
  'profile-health-refresh',
];

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('profile-00..: the lived-in account, top to bottom', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final overflows = await collectOverflows(() async {
        await _pump(tester, _screen());
        expect(find.text('Moritz Schneider'), findsOneWidget);
        // Streak, lifetime and the daily rows from the scenario.
        expect(find.text('12'), findsWidgets);
        expect(find.text('412'), findsOneWidget);
        expect(find.text('1221/2050'), findsOneWidget);
        expect(find.text('6430/8000'), findsOneWidget);
        expect(find.text('Goal 76 kg'), findsOneWidget);
        for (final key in _actions) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        await _shootPage(tester, 'profile');
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('profile-de: the dense middle of the page in German', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final overflows = await collectOverflows(() async {
        await _pump(tester, _screen(), locale: const Locale('de'));
        expect(find.text('Ziel 76 kg'), findsOneWidget);
        await captureDesignShot(tester, 'profile-de-00');
        await _scrollTo(tester, 640);
        await captureDesignShot(tester, 'profile-de-01');
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
    });
  });

  testWidgets('profile-new-00: a fresh account', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final overflows = await collectOverflows(() async {
        await _pump(
          tester,
          _screen(
            profile: const UserProfile(
              weightKg: 68,
              targetWeightKg: 68,
              heightCm: 170,
              sex: BiologicalSex.female,
            ),
            log: WeightLog(
              entries: <WeightLogEntry>[
                WeightLogEntry(timestamp: _now, weightKg: 68),
              ],
            ),
            stats: LifetimeStats(sessionStart: _now),
            health: HealthAuthState.unknown,
            steps: null,
            kcal: 0,
          ),
        );
        expect(find.byKey(const ValueKey('profile-health-connect')),
            findsOneWidget);
        await _shootPage(tester, 'profile-new');
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
    });
  });

  testWidgets('profile sheets: log weight and the BMI explanation', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pump(tester, _screen());
      final logWeight = find.byKey(const ValueKey('profile-log-weight'));
      await tester.ensureVisible(logWeight);
      await tester.pumpAndSettle();
      await tester.tap(logWeight);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-weight-input')),
          findsOneWidget);
      await captureDesignShot(tester, 'profile-weight-sheet');
      Navigator.of(
        tester.element(find.byKey(const ValueKey('profile-weight-input'))),
      ).pop();
      await tester.pumpAndSettle();

      final info = find.byTooltip('About BMI');
      await tester.ensureVisible(info);
      await tester.pumpAndSettle();
      await tester.tap(info);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'profile-bmi-sheet');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('profile-xl: the page at 2.0 text scale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final overflows = await collectOverflows(() async {
        await _pump(tester, _screen(), textScale: 2.0);
        await captureDesignShot(tester, 'profile-xl-00');
        await _scrollTo(tester, 900);
        await captureDesignShot(tester, 'profile-xl-01');
        final position = tester.state<ScrollableState>(_page()).position;
        await _scrollTo(tester, position.maxScrollExtent);
        expect(find.byKey(const ValueKey('profile-health-refresh')),
            findsOneWidget);
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
    });
  });
}
