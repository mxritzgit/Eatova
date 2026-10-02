// SheetHandle and the sheets without a close button (2026-10-03).
//
// The two profile sheets (log weight, BMI guide) draw the shared SheetHandle
// instead of a route handle. Neither has a close button, and on Android the
// barrier offers no dismiss semantics, so the handle must carry the "dismiss"
// action, or a screen-reader user cannot leave. The weight-adjust sheet's
// handle is covered with its discard guard in meal_adjust_discard_test.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';

final DateTime _now = DateTime(2026, 10, 3, 9, 30);

/// Material's dismiss label in English, the locale of these cases.
final _dismiss = find.semantics.byLabel('Dismiss');

/// The painted bar of the one [SheetHandle] on screen.
BoxDecoration _bar(WidgetTester tester) => tester
    .widget<Container>(
      find.descendant(
        of: find.byType(SheetHandle),
        matching: find.byType(Container),
      ),
    )
    .decoration! as BoxDecoration;

Widget _profile() => ProfileScreen(
  name: 'Moritz',
  profile: const UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    dailyKcalGoal: 2050,
  ),
  weightLog: WeightLog(
    entries: <WeightLogEntry>[
      WeightLogEntry(timestamp: DateTime(2026, 10, 1, 7), weightKg: 84),
    ],
  ),
  stats: LifetimeStats(
    mealsLogged: 10,
    weightLogs: 1,
    currentStreak: 1,
    longestStreak: 1,
    lastTrackedDate: DateTime(2026, 10, 3),
    sessionStart: DateTime(2026, 9, 1),
  ),
  dailyConsumedKcal: 900,
  dailySteps: null,
  healthAuthState: HealthAuthState.unknown,
  healthLastFetch: null,
  onLogWeight: (_) {},
  onEditProfile: () {},
  onOpenSettings: () {},
  onConnectHealth: () {},
  onRefreshHealth: () {},
);

Future<void> _tapInto(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  group('SheetHandle', () {
    testWidgets('without onDismiss it is decoration only', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpLocalized(tester, const SheetHandle(), locale: const Locale('en'));

      expect(_dismiss, findsNothing);
      semantics.dispose();
    });

    testWidgets('with onDismiss it is a dismiss button for screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var dismissed = 0;
      await pumpLocalized(
        tester,
        SheetHandle(onDismiss: () => dismissed++),
        locale: const Locale('en'),
      );

      expect(_dismiss, findsOne);
      expect(
        tester.getSemantics(find.byType(SheetHandle)),
        isSemantics(
          label: 'Dismiss',
          isButton: true,
          hasTapAction: true,
        ),
      );
      tester.semantics.performAction(_dismiss, SemanticsAction.tap);
      expect(dismissed, 1);
      semantics.dispose();
    });

    testWidgets('one bar app-wide: 40 x 4 in inkDisabled', (tester) async {
      await pumpLocalized(
        tester,
        SheetHandle(onDismiss: () {}),
        brightness: Brightness.dark,
      );
      final bar = find.descendant(
        of: find.byType(SheetHandle),
        matching: find.byType(Container),
      );
      expect(tester.getSize(bar), const Size(40, 4));
      expect(_bar(tester).color, AppTokens.dark.inkDisabled);
    });
  });

  group('profile sheets offer a dismiss action on their handle', () {
    for (final (name, open) in <(String, Finder)>[
      ('log weight', find.byKey(const ValueKey('profile-log-weight'))),
      ('BMI guide', find.byTooltip('About BMI')),
    ]) {
      testWidgets(name, (tester) async {
        await withClock(Clock.fixed(_now), () async {
          final semantics = tester.ensureSemantics();
          await pumpLocalized(
            tester,
            _profile(),
            locale: const Locale('en'),
            scaffold: false,
            surfaceSize: const Size(390, 844),
          );
          await _tapInto(tester, open);
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.byType(SheetHandle), findsOneWidget);

          expect(
            _dismiss,
            findsOne,
            reason: 'The sheet has no close button; without this node a '
                'screen-reader user cannot leave it.',
          );
          tester.semantics.performAction(_dismiss, SemanticsAction.tap);
          await tester.pumpAndSettle();

          expect(find.byType(BottomSheet), findsNothing);
          semantics.dispose();
        });
      });
    }
  });
}
