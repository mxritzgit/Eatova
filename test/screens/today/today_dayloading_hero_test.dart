// Full review 2026-08-19: the today tab's loading state only covered the meals
// card. The calorie hero and macro card had no `dayLoading` guard, so paging
// into an archive day outside the boot window showed the full day balance of
// an EMPTY day while loading, then jumped to the real values.
//
// The harness mirrors test/screens/today/today_screen_test.dart (Eatova theme,
// phone viewport, the padding from eatova_home_page.dart).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../../support/harness.dart';

/// 2026-08-09, 10:00 — far from any day boundary.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

/// A day well outside the 35-day boot window: only there does
/// `HomeStore.isLoadingFoodDay` ever set `dayLoading`.
final DateTime _archivtag = DateTime(2026, 6, 12);

const UserProfile _profil = UserProfile(
  dailyKcalGoal: 2000,
  proteinGoalG: 130,
  carbsGoalG: 240,
  fatGoalG: 70,
);

Future<void> _pumpToday(
  WidgetTester tester, {
  required bool dayLoading,
  int consumedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
}) async {
  pinPhoneViewport(tester);

  await pumpLocalized(
    tester,
    TodayScreen(
      userName: 'Moritz',
      profile: _profil,
      consumedKcal: consumedKcal,
      burnedKcal: 0,
      macroProgress: macroProgress,
      meals: const [],
      selectedDate: _archivtag,
      streak: 4,
      dayLoading: dayLoading,
    ),
    brightness: Brightness.light,
    // Motion as before the migration.
    reducedMotion: false,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );

  // No pumpAndSettle: the loading card spins a CircularProgressIndicator
  // forever, so nothing ever settles.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _key(String key) =>
    find.byKey(ValueKey<String>(key), skipOffstage: false);

void main() {
  group('dayLoading deckt den ganzen Tagesblock', () {
    testWidgets('waehrend des Ladens behauptet der Hero keine Tagesbilanz',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-kcal-hero'), findsNothing);
      // The actual lie: a remaining-kcal figure for a day whose numbers have
      // not arrived yet.
      expect(_key('today-kcal-remaining'), findsNothing);
      expect(find.text('kcal übrig', skipOffstage: false), findsNothing);
      expect(_key('today-kcal-goal'), findsNothing);
    });

    testWidgets('waehrend des Ladens behaupten die Makro-Balken keine Nullen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-macros-card'), findsNothing);
      expect(find.byType(MacroBar, skipOffstage: false), findsNothing);
    });

    testWidgets('die Ladekarte bleibt die EINZIGE Lade-Aussage',
        (tester) async {
      // The state belongs on screen once, not three times: hero and macros
      // step aside, the card under the heading carries it.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-day-loading'), findsOneWidget);
      expect(find.text('Tag wird geladen…', skipOffstage: false),
          findsOneWidget);
      // The heading stays, without the "today" prefix on an archive day.
      expect(find.text('Mahlzeiten', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ohne dayLoading stehen Hero und Makros unveraendert da',
        (tester) async {
      // Counter-check: the guard must not touch the loaded view.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          dayLoading: false,
          consumedKcal: 700,
          macroProgress: const MacroProgress(
            proteinG: 42,
            carbsG: 80,
            fatG: 20,
            kcal: 700,
          ),
        );
      });

      expect(_key('today-kcal-hero'), findsOneWidget);
      // 2000 goal + 0 burned - 700 eaten.
      expect(tester.widget<Text>(_key('today-kcal-remaining')).data, '1.300');
      expect(_key('today-day-loading'), findsNothing);

      // Scrolled into view rather than guessed: the ListView builds its lower
      // children lazily, and the macro card's position depends on text scale.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('today-macros-card')),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(_key('today-macros-card'), findsOneWidget);
      expect(find.byType(MacroBar, skipOffstage: false), findsNWidgets(3));
    });
  });
}
