// The "today" tab.
//
// The harness reproduces the SHELL the screen later hangs in (theme, phone
// viewport, SafeArea + 20/12/20/12 padding from eatova_home_page.dart), which
// is what makes it testable that the screen adds NO second side margin.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../../support/harness.dart';

/// Sunday, 9 August 2026, 10:00 — far from any day boundary.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

LoggedMeal _meal(String name, MealSlot slot, int kcal) => LoggedMeal(
      id: '$name-${slot.name}',
      loggedAt: DateTime(2026, 8, 9, 12),
      forcedSlot: slot,
      result: MealAnalysisResult(
        mealName: name,
        caloriesKcal: kcal,
        estimatedGrams: 300,
        kcalPer100G: 120,
        protein: '30 g',
        carbs: '40 g',
        fat: '12 g',
        confidence: 'Mittel',
        portionNotes: 'Test.',
      ),
    );

/// The shell pads every tab with `EdgeInsets.fromLTRB(20, 12, 20, 12)` — that
/// is what makes it testable that the screen adds NO second side margin.
const EdgeInsets _schalenrand = EdgeInsets.fromLTRB(20, 12, 20, 12);

TodayScreen _today({
  UserProfile profile = const UserProfile(),
  String userName = 'Moritz',
  String? profileInitial,
  int consumedKcal = 0,
  int burnedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
  List<LoggedMeal> meals = const <LoggedMeal>[],
  DateTime? selectedDate,
  int streak = 0,
  bool dayLoading = false,
  ValueChanged<DateTime>? onDateSelected,
  VoidCallback? onOpenCoach,
  VoidCallback? onOpenProfile,
  ValueChanged<MealSlot>? onOpenMealSlot,
}) =>
    TodayScreen(
      userName: userName,
      profile: profile,
      consumedKcal: consumedKcal,
      burnedKcal: burnedKcal,
      macroProgress: macroProgress,
      meals: meals,
      selectedDate: selectedDate ?? startOfDay(clock.now()),
      streak: streak,
      profileInitial: profileInitial,
      dayLoading: dayLoading,
      onDateSelected: onDateSelected,
      onOpenCoach: onOpenCoach,
      onOpenProfile: onOpenProfile,
      onOpenMealSlot: onOpenMealSlot,
    );

/// The loading card spins forever, so `pumpAndSettle` would never settle;
/// [settle] switches to a bounded number of frames.
Future<void> _finish(WidgetTester tester, {required bool settle}) async {
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

Future<void> _pumpToday(
  WidgetTester tester, {
  UserProfile profile = const UserProfile(),
  String userName = 'Moritz',
  String? profileInitial,
  int consumedKcal = 0,
  int burnedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
  List<LoggedMeal> meals = const <LoggedMeal>[],
  DateTime? selectedDate,
  int streak = 0,
  bool dayLoading = false,
  ValueChanged<DateTime>? onDateSelected,
  VoidCallback? onOpenCoach,
  VoidCallback? onOpenProfile,
  ValueChanged<MealSlot>? onOpenMealSlot,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  Locale locale = const Locale('de'),
  bool settle = true,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    _today(
      profile: profile,
      userName: userName,
      profileInitial: profileInitial,
      consumedKcal: consumedKcal,
      burnedKcal: burnedKcal,
      macroProgress: macroProgress,
      meals: meals,
      selectedDate: selectedDate,
      streak: streak,
      dayLoading: dayLoading,
      onDateSelected: onDateSelected,
      onOpenCoach: onOpenCoach,
      onOpenProfile: onOpenProfile,
      onOpenMealSlot: onOpenMealSlot,
    ),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    // The gauge and the entry animations are part of what is measured here.
    reducedMotion: false,
    padding: _schalenrand,
  );
  await _finish(tester, settle: settle);
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

Finder _in(String key, String text) => find.descendant(
      of: find.byKey(ValueKey<String>(key)),
      matching: find.text(text),
    );

/// Scrolls [ziel] into view — the screen is taller than a phone.
Future<void> _scrollTo(WidgetTester tester, Finder ziel) async {
  await tester.scrollUntilVisible(ziel, 220,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

/// Same without `pumpAndSettle`, for the endlessly spinning loading card.
/// Stops once [ziel] is built; the ListView builds its lower children only
/// while scrolling.
Future<void> _scrollToUnsettled(WidgetTester tester, Finder ziel) async {
  for (var i = 0; i < 14 && ziel.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(ziel, findsOneWidget, reason: 'Ziel liess sich nicht heranscrollen');
}

void main() {
  group('Kalorien-Hero', () {
    testWidgets('das Ziel bleibt roh, das Verbrannte steckt im Rest',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2000),
          consumedKcal: 500,
          burnedKcal: 300,
        );
      });

      // The goal is the raw settings value; folding the burned credit into it
      // showed two different numbers for the same word across tabs.
      expect(_textOf(tester, 'today-kcal-goal'), 'Ziel 2.000 kcal');
      // The remainder still counts against goal + burned: 2000+300-500.
      expect(_textOf(tester, 'today-kcal-remaining'), '1.800');
      expect(find.text('kcal übrig'), findsOneWidget);
      // Burned keeps its own tile, so the arithmetic stays traceable.
      expect(_in('today-stat-burned', '300'), findsOneWidget);
    });

    testWidgets('eine Ueberschreitung zeigt den Betrag und wechselt die Einheit',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2000),
          consumedKcal: 2600,
        );
      });

      expect(_textOf(tester, 'today-kcal-remaining'), '600');
      expect(find.text('kcal drüber'), findsOneWidget);
      expect(find.text('kcal übrig'), findsNothing);
    });

    testWidgets('ohne Verbranntes steht der Gedankenstrich', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, consumedKcal: 800);
      });

      expect(_in('today-stat-burned', '—'), findsOneWidget);
      expect(_in('today-stat-eaten', '800'), findsOneWidget);
    });

    testWidgets('der Streak kommt fertig herein und wird nur angezeigt',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, streak: 12);
      });

      expect(_in('today-stat-streak', '12'), findsOneWidget);
    });

    testWidgets('ein Tagesziel von 0 stuerzt nicht ab', (tester) async {
      // Broken profiles arrive from the network; `goal <= 0 -> 1` keeps
      // `eaten / adjustedGoal` from dividing by zero.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 0),
          consumedKcal: 400,
        );
      });

      expect(tester.takeException(), isNull);
      expect(_textOf(tester, 'today-kcal-goal'), 'Ziel 1 kcal');
      expect(_textOf(tester, 'today-kcal-remaining'), '399');
      expect(find.text('kcal drüber'), findsOneWidget);
    });

    // TickGauge is a CustomPaint and semantically empty, so without this
    // annotation the daily progress would not exist for a screen reader at
    // all — hence asserting the VALUE, not just the label.
    testWidgets('der Screenreader hoert den Fortschritt als Prozentwert',
        (tester) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2200),
          consumedKcal: 1100,
        );
      });

      // RegExp instead of equality: the hero merges the gauge node with the
      // surrounding texts, so the label is not alone in the node.
      final gauge = find.bySemanticsLabel(RegExp('Kalorienfortschritt'));
      expect(gauge, findsOneWidget);
      expect(
        tester.getSemantics(gauge).value,
        contains('50 Prozent des Tagesziels gegessen'),
      );
      handle.dispose();
    });
  });

  group('Makros', () {
    testWidgets('drei Balken gegen die Ziele des Profils', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(
            proteinGoalG: 130,
            carbsGoalG: 240,
            fatGoalG: 70,
          ),
          macroProgress:
              const MacroProgress(proteinG: 42.4, carbsG: 80, fatG: 20, kcal: 700),
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-macros-card')));
      final balken = tester
          .widgetList<MacroBar>(find.byType(MacroBar))
          .toList(growable: false);
      expect(balken.length, 3);
      expect(balken[0].label, 'Protein');
      expect(balken[0].value, 42);
      expect(balken[0].goal, 130);
      expect(balken[1].label, 'Kohlenhydrate');
      expect(balken[1].goal, 240);
      expect(balken[2].label, 'Fett');
      expect(balken[2].goal, 70);
    });
  });

  group('Mahlzeiten', () {
    testWidgets('vier Slots mit wortgleichen Titeln, Namen und kcal-Summen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          meals: <LoggedMeal>[
            _meal('Haferbrei', MealSlot.breakfast, 320),
            _meal('Kaffee', MealSlot.breakfast, 20),
            _meal('Lachsbowl', MealSlot.dinner, 610),
          ],
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-meals-card')));

      expect(_in('today-meal-row-breakfast', 'Frühstück'), findsOneWidget);
      expect(_in('today-meal-row-breakfast', 'Haferbrei · Kaffee'),
          findsOneWidget);
      expect(_in('today-meal-row-breakfast', '340'), findsOneWidget);

      expect(_in('today-meal-row-lunch', 'Mittagessen'), findsOneWidget);
      expect(_in('today-meal-row-lunch', 'Noch nichts geloggt'), findsOneWidget);

      expect(_in('today-meal-row-dinner', 'Abendessen'), findsOneWidget);
      expect(_in('today-meal-row-dinner', '610'), findsOneWidget);

      expect(_in('today-meal-row-snack', 'Snacks'), findsOneWidget);
    });

    testWidgets('dayLoading ersetzt die Karte durch die Ladekarte',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true, settle: false);
      });

      expect(find.byKey(const ValueKey('today-day-loading')), findsOneWidget);
      expect(find.text('Tag wird geladen…'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-meals-card'), skipOffstage: false),
          findsNothing);
      // The heading stays, otherwise the screen jumps while loading.
      expect(find.text('Heutige Mahlzeiten'), findsOneWidget);
    });

    testWidgets('waehrend des Ladens behauptet der Coach keinen leeren Tag',
        (tester) async {
      // `meals` is empty while loading WITHOUT the day being empty, so the
      // empty teaser would claim something about unloaded data.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true, settle: false);
      });

      await _scrollToUnsettled(
          tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsNothing,
      );
    });
  });

  group('Datums-Streifen', () {
    testWidgets('auf heute ist der Vorwaerts-Pfeil taub', (tester) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, onDateSelected: (d) => gewaehlt = d);
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Heute');

      await tester.tap(find.byKey(const ValueKey('today-date-next')));
      await tester.pumpAndSettle();
      expect(gewaehlt, isNull, reason: 'die Zukunft hat keine Daten');

      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 8, 8));
    });

    testWidgets('auf gestern fuehrt der Vorwaerts-Pfeil zurueck auf heute',
        (tester) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          selectedDate: DateTime(2026, 8, 8),
          onDateSelected: (d) => gewaehlt = d,
        );
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Gestern');

      await tester.tap(find.byKey(const ValueKey('today-date-next')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 8, 9));
    });

    testWidgets('der Rueckwaerts-Schritt ueberlebt die Zeitumstellung',
        (tester) async {
      // B5 anchor: `subtract(Duration(days: 1))` landed 2026-03-30 on the 28th
      // at 23:00, dropping Sunday from the strip and giving every meal logged
      // there the wrong local_day.
      DateTime? gewaehlt;
      await withClock(Clock.fixed(DateTime(2026, 3, 30, 9)), () async {
        await _pumpToday(tester, onDateSelected: (d) => gewaehlt = d);
      });

      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 3, 29));
    });

    testWidgets('ein Archivtag heisst nicht mehr „Heutige Mahlzeiten"',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          selectedDate: DateTime(2026, 8, 4),
          consumedKcal: 1200,
        );
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Vor 5 Tagen');
      expect(find.text('Mahlzeiten'), findsOneWidget);
      expect(find.text('Heutige Mahlzeiten'), findsNothing);
      // The eyebrow follows the SELECTED day, not the wall clock, or it would
      // contradict the strip right below it.
      expect(_textOf(tester, 'today-eyebrow'), 'DIENSTAG, 4. AUGUST');
    });

    testWidgets('auf einem Archivtag lockt der Coach nicht ins Nachtragen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, selectedDate: DateTime(2026, 8, 4));
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(find.text('Frag den Coach nach Ideen für deine Ziele.'),
          findsOneWidget);
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsNothing,
        reason: 'der 4. August ist vorbei — dort ist nichts mehr zu bauen',
      );
    });

    testWidgets('heute lockt er weiterhin zum ersten Log', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsOneWidget,
      );
    });
  });

  group('Aktionen', () {
    // The log-food button is gone, so this no longer taps it.
    testWidgets('Profil, Slot und Coach melden sich zurueck', (tester) async {
      var profil = 0;
      var coach = 0;
      MealSlot? slot;

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          onOpenProfile: () => profil++,
          onOpenCoach: () => coach++,
          onOpenMealSlot: (s) => slot = s,
        );
      });

      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(profil, 1);

      await _scrollTo(
          tester, find.byKey(const ValueKey('today-meal-row-dinner')));
      await tester.tap(find.byKey(const ValueKey('today-meal-row-dinner')));
      await tester.pumpAndSettle();
      expect(slot, MealSlot.dinner);

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-cta')));
      await tester.tap(find.byKey(const ValueKey('today-coach-cta')));
      await tester.pumpAndSettle();
      expect(coach, 1);
    });

    testWidgets('das Profil-Badge traegt die durchgereichte Initiale',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, userName: 'Moritz', profileInitial: 'Q');
      });
      expect(_in('today-profile', 'Q'), findsOneWidget);
    });

    testWidgets('ohne durchgereichte Initiale zaehlt der Name', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, userName: 'ada lovelace');
      });
      expect(_in('today-profile', 'A'), findsOneWidget);
    });
  });

  group('Der schwebende „Essen loggen"-Knopf ist fort', () {
    // The button was dropped without replacement; the meal rows lead into the
    // food tab. These tests stay as sentries so it cannot return unnoticed.
    testWidgets('weder Key noch Beschriftung sind noch im Baum',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      expect(
        find.byKey(const ValueKey('today-log-food'), skipOffstage: false),
        findsNothing,
      );
      expect(find.text('Essen loggen', skipOffstage: false), findsNothing);
      expect(
        find.byType(PrimaryActionButton, skipOffstage: false),
        findsNothing,
      );
    });

    renderMatrix(
      'die Wurzel ist eine reine Liste ohne Knopf-Reserve',
      (tester, c) async {
        // The bottom reserve used to grow with the system font to clear the
        // button height. Without the button it is a flat 12 at any text size.
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: c.brightness,
            textScale: c.textScale,
          );
        });

        // The cast is the actual assertion: the root is a ListView again, not
        // a Stack. `findsNothing` on Stack would not work — the coach banner
        // brings its own.
        final liste =
            tester.widget<ListView>(find.byKey(const ValueKey('screen-today')));
        expect(liste.padding, const EdgeInsets.fromLTRB(0, 0, 0, 12),
            reason: 'Reserve bei ${c.label}');
      },
      textScales: const <double>[1.0, 2.0],
    );
  });

  group('Robustheit', () {
    // The root used to be a Stack of list + floating button. This matrix pins
    // that the plain ListView breaks in no combination, including at the
    // bottom where children are built only while scrolling. The empty and the
    // filled day stay an inner loop — they are not a matrix dimension.
    renderMatrix(
      'ohne den Knopf-Stack bleibt jede Kombination layoutbar',
      (tester, c) async {
        for (final mitMahlzeiten in <bool>[false, true]) {
          final fall = '${c.label} / Mahlzeiten=$mitMahlzeiten';
          await withClock(Clock.fixed(_jetzt), () async {
            await _pumpToday(
              tester,
              brightness: c.brightness,
              textScale: c.textScale,
              consumedKcal: mitMahlzeiten ? 610 : 0,
              meals: mitMahlzeiten
                  ? <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)]
                  : const <LoggedMeal>[],
            );
          });
          expect(tester.takeException(), isNull, reason: fall);

          await _scrollTo(
              tester, find.byKey(const ValueKey('today-coach-banner')));
          expect(tester.takeException(), isNull,
              reason: 'nach unten gescrollt: $fall');
        }
      },
      textScales: const <double>[1.0, 2.0],
    );

    renderMatrix(
      'auch waehrend dayLoading bleibt die Liste heil',
      (tester, c) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: c.brightness,
            textScale: c.textScale,
            dayLoading: true,
            settle: false,
          );
        });
        expect(tester.takeException(), isNull, reason: c.label);

        await _scrollToUnsettled(
            tester, find.byKey(const ValueKey('today-coach-banner')));
        expect(tester.takeException(), isNull,
            reason: 'nach unten gescrollt: ${c.label}');
      },
      textScales: const <double>[2.0],
    );

    // Both modes AND both languages: English strings are sometimes longer and
    // catch overflows a `de`-only run would never show. Was two separate
    // blocks (brightness loop + EN-Render-Smoke group) before.
    renderMatrix(
      'der Heute-Tab rendert overflow-frei',
      (tester, c) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: c.brightness,
            locale: c.locale,
            consumedKcal: 1400,
            burnedKcal: 220,
            streak: 5,
            meals: <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)],
          );
        });
        expect(tester.takeException(), isNull,
            reason: 'Rendering unter ${c.label} ist fehlgeschlagen');

        // Visible without scrolling, and translated.
        expect(find.text(c.l10n.todayKcalBudgetEyebrow), findsOneWidget);

        await _scrollTo(
            tester, find.byKey(const ValueKey('today-coach-banner')));
        expect(tester.takeException(), isNull,
            reason: 'nach unten gescrollt: ${c.label}');
        expect(find.text(c.l10n.todayCoachCta), findsOneWidget);
      },
      locales: const <Locale>[Locale('de'), Locale('en')],
    );

    testWidgets('ueberlebt textScaler 2.0 ohne Ueberlauf', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          textScale: 2.0,
          consumedKcal: 12345,
          burnedKcal: 1234,
          streak: 365,
          macroProgress: const MacroProgress(
              proteinG: 120, carbsG: 200, fatG: 60, kcal: 1900),
          meals: <LoggedMeal>[
            _meal('Ofengemüse mit Feta und Kichererbsen', MealSlot.dinner, 610),
          ],
        );
      });
      expect(tester.takeException(), isNull);

      // Nothing may overflow after scrolling down either.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('die Hero-Kennzahlen stapeln sich bei 2.0, statt zu schrumpfen',
        (tester) async {
      // Each tile takes a third of the card (~92 px), narrower than its
      // content at textScaler 2.0. The old FittedBox shrank the text back to
      // its 1.0 size and so undid the user's setting (review F8-09); now the
      // tiles stack and keep their real size. An overflow does not THROW, so
      // the geometry is asserted directly.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          textScale: 2.0,
          consumedKcal: 12345,
          burnedKcal: 1234,
          streak: 365,
        );
      });
      expect(tester.takeException(), isNull);

      const faelle = <List<String>>[
        <String>['today-stat-eaten', '12.345', 'GEGESSEN'],
        <String>['today-stat-burned', '1.234', 'VERBRANNT'],
        <String>['today-stat-streak', '365', 'TAGE-STREAK'],
      ];
      double? vorherigeOberkante;
      for (final fall in faelle) {
        final kachel = find.byKey(ValueKey<String>(fall[0]));
        final hero = find.byKey(const ValueKey('today-kcal-hero'));

        // Stacked: each tile starts below the previous one and spans the card.
        final oberkante = tester.getTopLeft(kachel).dy;
        if (vorherigeOberkante != null) {
          expect(oberkante, greaterThan(vorherigeOberkante));
        }
        vorherigeOberkante = oberkante;
        expect(
          tester.getSize(kachel).width,
          greaterThan(tester.getSize(hero).width / 2),
        );

        for (final text in <String>[fall[1], fall[2]]) {
          final zeile = find.descendant(of: kachel, matching: find.text(text));
          expect(zeile, findsOneWidget);
          // Single line at the REAL size: 20 / 10.5 px base type at 2.0 gives
          // at most ~48 px line height; anything above that is a wrap.
          expect(
            tester.getSize(zeile).height,
            lessThan(80),
            reason: '„$text" ist in ${fall[0]} umgebrochen',
          );
        }

        // No FittedBox left in the tiles: the text is not shrunk.
        expect(
          find.descendant(of: kachel, matching: find.byType(FittedBox)),
          findsNothing,
        );
      }
    });

    // The remaining number is the app's largest type (66 px base). The
    // FITTEDBOX is measured, not the text: the text keeps its unshrunk size
    // and the scaling sits in the transform above it. Both brightness modes,
    // because light mode has different border widths and inner dimensions.
    renderMatrix(
      'die Restzahl schrumpft bei Systemschrift 2.0, statt den Hero zu '
      'sprengen',
      (tester, c) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: c.brightness,
            textScale: c.textScale,
            profile: const UserProfile(dailyKcalGoal: 99999),
            consumedKcal: 12345,
            burnedKcal: 1234,
          );
        });

        expect(tester.takeException(), isNull);
        final hero = find.byKey(const ValueKey('today-kcal-hero'));
        final zahl = find.byKey(const ValueKey('today-kcal-remaining'));
        expect(zahl, findsOneWidget);
        final kasten =
            find.ancestor(of: zahl, matching: find.byType(FittedBox)).first;
        expect(tester.widget<FittedBox>(kasten).fit, BoxFit.scaleDown);
        expect(
          tester.getSize(kasten).width,
          lessThanOrEqualTo(tester.getSize(hero).width),
        );
      },
      textScales: const <double>[2.0],
    );

    testWidgets('die Vorlese-Beschriftungen tragen echte Umlaute',
        (tester) async {
      // A semantics label is spoken text, so ASCII transliterations would be
      // read out as written.
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, selectedDate: DateTime(2026, 8, 8));
      });

      // RegExp instead of equality: the profile badge merges its label with
      // the initial below it.
      expect(find.bySemanticsLabel(RegExp('Profil öffnen')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Tag zurück')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Tag vor')), findsOneWidget);
      // The CustomPaint gauge is only reachable through this annotation.
      expect(find.bySemanticsLabel(RegExp('Kalorienfortschritt')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('setzt keinen zweiten Seitenrand', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('today-kcal-hero'))).dx,
        20,
        reason: 'die Schale liefert die 20 px bereits — 40 waere doppelt',
      );
    });

    testWidgets('die Wurzel traegt weiterhin screen-today', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    });
  });

  testWidgets('unter en stehen die englischen Beschriftungen im Baum',
      (tester) async {
    // Counter-check to the `en` column of the render matrix above: the labels
    // must really CHANGE with the language, not just resolve to some ARB hit.
    await withClock(Clock.fixed(_jetzt), () async {
      await _pumpToday(
        tester,
        locale: const Locale('en'),
        consumedKcal: 1400,
        burnedKcal: 220,
        streak: 5,
        meals: <LoggedMeal>[_meal('Salmon bowl', MealSlot.dinner, 610)],
      );
    });

    expect(find.text('CALORIE BUDGET'), findsOneWidget);
    expect(find.text('KALORIENBUDGET'), findsNothing);

    await _scrollTo(tester, find.byKey(const ValueKey('today-coach-banner')));
    expect(find.text('Go to coach'), findsOneWidget);
  });
}
