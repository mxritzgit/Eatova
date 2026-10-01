import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';

// The Today tab resolves the streak with `clock.now()`, the profile used
// `DateTime.now()`. Under an injected clock the two disagreed: Today showed a
// live 7-day chain while the profile reported it as broken. Both now read the
// same clock.

final _day = DateTime(2026, 9, 13, 18);

ProfileScreen _profile(LifetimeStats stats) => ProfileScreen(
  name: 'Alex',
  profile: const UserProfile(),
  weightLog: const WeightLog(),
  stats: stats,
  dailyConsumedKcal: 0,
  dailySteps: null,
  healthAuthState: HealthAuthState.unknown,
  healthLastFetch: null,
  onLogWeight: (_) {},
  onEditProfile: () {},
  onOpenSettings: () {},
  onConnectHealth: () {},
  onRefreshHealth: () {},
);

// Reads the number the streak tile actually draws (the counted figure), and
// pins that the tile sits in the identity hero.
Future<void> _expectStreakShows(
  WidgetTester tester,
  AppLocalizations l10n,
  String number,
) async {
  await tester.pumpAndSettle();
  final tile = find.descendant(
    of: find.byKey(const ValueKey('profile-studio-identity')),
    matching: find.byWidgetPredicate(
      (w) => w is ProfileStatTile && w.label == l10n.profileLabelStreak,
    ),
  );
  expect(tile, findsOneWidget);
  expect(
    find.descendant(of: tile, matching: find.text(number)),
    findsOneWidget,
    reason: 'The streak tile must draw $number.',
  );
}

void main() {
  testWidgets('Profil-Serie folgt der injizierten Uhr wie der Heute-Tab', (
    tester,
  ) async {
    await withClock(Clock.fixed(_day), () async {
      final stats = LifetimeStats(
        currentStreak: 7,
        longestStreak: 9,
        lastTrackedDate: _day,
        sessionStart: _day,
      );
      final c = await pumpLocalizedContext(
        tester,
        _profile(stats),
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
      );
      expect(stats.effectiveStreakOn(_day), 7);
      await _expectStreakShows(tester, c.l10n, '7');
    });
  });

  testWidgets('eine gerissene Kette bleibt auch im Profil gerissen', (
    tester,
  ) async {
    await withClock(Clock.fixed(_day), () async {
      final c = await pumpLocalizedContext(
        tester,
        _profile(
          LifetimeStats(
            currentStreak: 7,
            lastTrackedDate: _day.subtract(const Duration(days: 3)),
            sessionStart: _day,
          ),
        ),
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
      );
      await _expectStreakShows(tester, c.l10n, '0');
    });
  });
}
