// The "today" tab (dark redesign, 2026-09-28).
//
// The harness reproduces the SHELL the screen later hangs in (theme, phone
// viewport, SafeArea + 20/12/20/12 padding from eatova_home_page.dart), which
// is what makes it testable that the screen adds NO second side margin.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_macros.dart';
import 'package:eatova/src/screens/today/today_progress.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../../support/harness.dart';
import '../../support/today_summary.dart';

/// Sunday, 9 August 2026, 10:00 — far from any day boundary.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

LoggedMeal _meal(String name, MealSlot slot, int kcal, {DateTime? at}) =>
    LoggedMeal(
      id: '$name-${slot.name}',
      loggedAt: at ?? DateTime(2026, 8, 9, 12),
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

const FitnessRecipe _recipe = FitnessRecipe(
  slug: 'user_lachs_reis',
  title: 'Lachs mit Reis',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 610,
  proteinG: 58,
  carbsG: 60,
  fatG: 14,
  estimatedGrams: 450,
  categories: <String>['Eigene'],
  userCreated: true,
);

RecipePick _pick({
  int? kcal = 610,
  int remaining = 902,
  RecipePickSource source = RecipePickSource.suggested,
  PlannedMeal? planned,
}) => RecipePick(
  recipe: _recipe,
  slot: MealSlot.dinner,
  source: source,
  servings: 1,
  kcal: kcal,
  proteinG: kcal == null ? null : 58,
  remainingKcalBefore: remaining,
  plannedMeal: planned,
);

/// Five exercises of 4 x 10 with 160 s rest: the app's estimate is 50 min.
TrainingNextWorkout _workout({bool completedToday = false}) =>
    TrainingNextWorkout(
      plan: TrainingPlan(
        id: 'push-plan',
        proposal: CoachTrainingProposal(
          title: 'Kraftplan',
          workouts: <TrainingWorkout>[
            TrainingWorkout(
              title: 'Oberkörper Drücken',
              exercises: <TrainingExercise>[
                for (var i = 0; i < 5; i++)
                  TrainingExercise(
                    id: 'ex$i',
                    name: 'Übung $i',
                    sets: 4,
                    reps: 10,
                    restSeconds: 160,
                  ),
              ],
            ),
          ],
        ),
      ),
      workoutIndex: 0,
      completedToday: completedToday,
      exercises: const <TrainingExercisePreview>[],
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
  int? steps,
  bool dayLoading = false,
  RecipePick? pick,
  TrainingNextWorkout? nextWorkout,
  MealSlot? accentSlot,
  ValueChanged<DateTime>? onDateSelected,
  VoidCallback? onOpenProfile,
  ValueChanged<MealSlot>? onOpenMealSlot,
  ValueChanged<RecipePick>? onOpenPick,
  VoidCallback? onOpenFoodLog,
  VoidCallback? onOpenTraining,
}) => TodayScreen(
  userName: userName,
  profile: profile,
  summary: todaySummary(
    profile: profile,
    consumedKcal: consumedKcal,
    burnedKcal: burnedKcal,
    macroProgress: macroProgress,
  ),
  meals: meals,
  selectedDate: selectedDate ?? startOfDay(clock.now()),
  streak: streak,
  steps: steps,
  profileInitial: profileInitial,
  dayLoading: dayLoading,
  pick: pick,
  nextWorkout: nextWorkout,
  accentSlot: accentSlot,
  onDateSelected: onDateSelected,
  onOpenProfile: onOpenProfile,
  onOpenMealSlot: onOpenMealSlot,
  onOpenPick: onOpenPick,
  onOpenFoodLog: onOpenFoodLog,
  onOpenTraining: onOpenTraining,
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

Future<void> _pump(
  WidgetTester tester,
  TodayScreen screen, {
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  Locale locale = const Locale('de'),
  bool settle = true,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    screen,
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    // The arc and bars animate; the tests read their settled values.
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
  await tester.scrollUntilVisible(
    ziel,
    220,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Fill of the 34 px circle inside a slot's add button.
Color _addFill(WidgetTester tester, MealSlot slot) {
  final circle = find.descendant(
    of: find.byKey(ValueKey<String>('today-meal-add-${slot.name}')),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle,
    ),
  );
  return ((tester.widget<Container>(circle).decoration!) as BoxDecoration)
      .color!;
}

void main() {
  group('Kalorien-Karte', () {
    testWidgets('das Ziel bleibt roh, das Verbrannte steckt im Rest', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            profile: const UserProfile(dailyKcalGoal: 2000),
            consumedKcal: 500,
            burnedKcal: 300,
          ),
        );
      });

      // The goal is the raw settings value; the activity credit is its own
      // stat and only the remainder counts against goal + credit.
      expect(_textOf(tester, 'today-kcal-goal'), '2.000');
      expect(_textOf(tester, 'today-kcal-remaining'), '1.800');
      expect(_textOf(tester, 'today-kcal-budget'), 'kcal von 2.300');
      expect(find.text('HEUTE ÜBRIG'), findsOneWidget);
      expect(_textOf(tester, 'today-stat-eaten'), '500');
      expect(_textOf(tester, 'today-stat-burned'), '+300');
    });

    testWidgets(
      'eine Ueberschreitung zeigt den Betrag und wechselt die Aussage',
      (tester) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(
            tester,
            _today(
              profile: const UserProfile(dailyKcalGoal: 2000),
              consumedKcal: 2600,
            ),
          );
        });

        expect(_textOf(tester, 'today-kcal-remaining'), '600');
        expect(find.text('HEUTE DRÜBER'), findsOneWidget);
        expect(find.text('HEUTE ÜBRIG'), findsNothing);
        expect(_textOf(tester, 'today-kcal-budget'), 'kcal über 2.000');
        // The share and the arc stop at 100 %.
        expect(_textOf(tester, 'today-kcal-percent'), '100 % gegessen');
        expect(
          tester.widget<TodayCalorieArc>(find.byType(TodayCalorieArc)).progress,
          1.0,
        );
      },
    );

    testWidgets('ohne Aktivitaetsgutschrift bleibt die Aktivitaet weg', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(consumedKcal: 800));
      });

      expect(find.byKey(const ValueKey('today-stat-burned')), findsNothing);
      expect(find.text('Aktivität'), findsNothing);
      expect(_textOf(tester, 'today-stat-eaten'), '800');
    });

    testWidgets('der Bogen und der Anteil nutzen das Budget inkl. Aktivitaet', (
      tester,
    ) async {
      // 1,210 eaten of 2,100 + 320: exactly half.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            profile: const UserProfile(dailyKcalGoal: 2100),
            consumedKcal: 1210,
            burnedKcal: 320,
          ),
        );
      });

      expect(
        tester.widget<TodayCalorieArc>(find.byType(TodayCalorieArc)).progress,
        0.5,
      );
      expect(_textOf(tester, 'today-kcal-percent'), '50 % gegessen');
      expect(_textOf(tester, 'today-kcal-remaining'), '1.210');
    });

    testWidgets('ein Tagesziel von 0 stuerzt nicht ab', (tester) async {
      // Broken profiles arrive from the network; `goal <= 0 -> 1` keeps
      // the share from dividing by zero.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            profile: const UserProfile(dailyKcalGoal: 0),
            consumedKcal: 400,
          ),
        );
      });

      expect(tester.takeException(), isNull);
      expect(_textOf(tester, 'today-kcal-goal'), '1');
      expect(_textOf(tester, 'today-kcal-remaining'), '399');
      expect(find.text('HEUTE DRÜBER'), findsOneWidget);
    });

    // The arc is a CustomPaint and semantically empty, so without this
    // annotation the daily progress would not exist for a screen reader.
    testWidgets('der Screenreader hoert den Fortschritt als Prozentwert', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            profile: const UserProfile(dailyKcalGoal: 2200),
            consumedKcal: 1100,
          ),
        );
      });

      final gauge = find.bySemanticsLabel(RegExp('Kalorienfortschritt'));
      expect(gauge, findsOneWidget);
      expect(
        tester.getSemantics(gauge).value,
        contains('50 Prozent des Tagesziels gegessen'),
      );
      handle.dispose();
    });
  });

  group('Kopfzeile', () {
    testWidgets('der Streak kommt fertig herein und wird nur angezeigt', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(streak: 12, onOpenProfile: () {}));
      });

      expect(_textOf(tester, 'today-streak-count'), '12');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-streak'))),
        isSemantics(label: 'Serie: 12 Tage in Folge', isButton: true),
      );
      handle.dispose();
    });

    testWidgets('ein gerissener Streak (0) zeigt keine Pille', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(streak: 0, onOpenProfile: () {}));
      });
      expect(find.byKey(const ValueKey('today-streak')), findsNothing);
      expect(find.byKey(const ValueKey('today-profile')), findsOneWidget);
    });

    testWidgets('die Datumszeile nennt den gezeigten Tag', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today());
      });
      expect(_textOf(tester, 'today-date-selected-label'), 'Sonntag, 9. Aug.');
    });

    testWidgets('das Profil-Badge traegt die durchgereichte Initiale', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(userName: 'Moritz', profileInitial: 'Q'));
      });
      expect(_in('today-profile', 'Q'), findsOneWidget);
    });

    testWidgets('ohne durchgereichte Initiale zaehlt der Name', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(userName: 'ada lovelace'));
      });
      expect(_in('today-profile', 'A'), findsOneWidget);
    });
  });

  group('Makros', () {
    testWidgets('drei Kacheln gegen die Ziele des Profils', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            profile: const UserProfile(
              proteinGoalG: 130,
              carbsGoalG: 240,
              fatGoalG: 70,
            ),
            macroProgress: const MacroProgress(
              proteinG: 42.4,
              carbsG: 80,
              fatG: 80,
              kcal: 700,
            ),
          ),
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-macros-card')));
      final kacheln = tester
          .widgetList<TodayMacroTile>(find.byType(TodayMacroTile))
          .toList(growable: false);
      expect(kacheln.length, 3);
      expect(kacheln[0].label, 'Protein');
      expect(kacheln[0].value, 42);
      expect(kacheln[0].goal, 130);
      // Visible compact name, full name for screen readers.
      expect(kacheln[1].label, 'Kohlenhydrate');
      expect(kacheln[1].shortLabel, 'Carbs');
      expect(kacheln[1].goal, 240);
      expect(kacheln[2].label, 'Fett');
      expect(kacheln[2].goal, 70);
      expect(find.text('88 g übrig'), findsOneWidget);
      expect(find.text('160 g übrig'), findsOneWidget);
      // Over the goal says so instead of "0 g left".
      expect(find.text('10 g drüber'), findsOneWidget);
    });
  });

  group('Mahlzeiten', () {
    testWidgets('vier Slots mit Titeln, Namen in Log-Reihenfolge und kcal', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            meals: <LoggedMeal>[
              _meal(
                'Haferbrei',
                MealSlot.breakfast,
                320,
                at: DateTime(2026, 8, 9, 8),
              ),
              _meal(
                'Kaffee',
                MealSlot.breakfast,
                20,
                at: DateTime(2026, 8, 9, 8, 5),
              ),
              _meal('Lachsbowl', MealSlot.dinner, 610),
            ],
          ),
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-meals-card')));

      expect(_in('today-meal-row-breakfast', 'Frühstück'), findsOneWidget);
      expect(_textOf(tester, 'today-meal-sub-breakfast'), 'Haferbrei, Kaffee');
      expect(_textOf(tester, 'today-meal-kcal-breakfast'), '340 kcal');

      expect(_in('today-meal-row-lunch', 'Mittagessen'), findsOneWidget);
      // Default profile: 2,200 kcal budget, lunch 25–33 %.
      expect(_textOf(tester, 'today-meal-sub-lunch'), 'Empfohlen 550–750 kcal');
      expect(find.byKey(const ValueKey('today-meal-kcal-lunch')), findsNothing);

      expect(_in('today-meal-row-dinner', 'Abendessen'), findsOneWidget);
      expect(_textOf(tester, 'today-meal-kcal-dinner'), '610 kcal');

      expect(_in('today-meal-row-snack', 'Snacks'), findsOneWidget);
    });

    testWidgets('auf einem Archivtag schlaegt ein leerer Slot nichts vor', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(selectedDate: DateTime(2026, 8, 4)));
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-meals-card')));
      expect(_textOf(tester, 'today-meal-sub-lunch'), 'Nichts geloggt');
    });

    testWidgets('dayLoading ersetzt die Karte durch die Ladekarte', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(dayLoading: true, pick: _pick()),
          settle: false,
        );
      });

      expect(find.byKey(const ValueKey('today-day-loading')), findsOneWidget);
      expect(find.text('Tag wird geladen…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-meals-card'), skipOffstage: false),
        findsNothing,
      );
      // The heading stays, otherwise the screen jumps while loading.
      expect(find.text('Mahlzeiten'), findsOneWidget);
      // Neither a pick nor suggested bands claim anything about the day.
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
      expect(find.textContaining('Empfohlen'), findsNothing);
    });

    testWidgets('der uebergebene naechste Hauptslot hat den Akzent-Plus', (
      tester,
    ) async {
      // The shell passes `HomeStore.nextOpenMainSlot()`; the rule itself is
      // pinned in today_wiring_flow_test.dart and recipe_pick_test.dart.
      const t = AppTokens.dark;
      for (final accent in [MealSlot.breakfast, MealSlot.lunch]) {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(
            tester,
            _today(onOpenMealSlot: (_) {}, accentSlot: accent),
          );
        });
        await _scrollTo(
          tester,
          find.byKey(const ValueKey('today-meal-add-snack')),
        );
        for (final slot in MealSlot.values) {
          expect(
            _addFill(tester, slot),
            slot == accent ? t.accentFill : t.accentTint,
            reason: '$accent: ${slot.name}',
          );
        }
      }
    });

    testWidgets('ohne naechsten Hauptslot und auf Archivtagen kein Akzent', (
      tester,
    ) async {
      const t = AppTokens.dark;
      for (final (accent, day) in <(MealSlot?, DateTime?)>[
        (null, null),
        // A stale slot must not light up a past day.
        (MealSlot.dinner, DateTime(2026, 8, 8)),
      ]) {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(
            tester,
            _today(
              onOpenMealSlot: (_) {},
              accentSlot: accent,
              selectedDate: day,
            ),
          );
        });
        await _scrollTo(
          tester,
          find.byKey(const ValueKey('today-meal-add-snack')),
        );
        for (final slot in MealSlot.values) {
          expect(_addFill(tester, slot), t.accentTint, reason: '$day $slot');
        }
      }
    });
  });

  group('Tagesleiste', () {
    testWidgets('sieben Tage bis heute, heute gewaehlt, keine Zukunft', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(onDateSelected: (_) {}));
      });

      for (var day = 3; day <= 9; day++) {
        final key = 'today-day-2026-08-0$day';
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('today-day-2026-08-02')), findsNothing);
      expect(find.byKey(const ValueKey('today-day-2026-08-10')), findsNothing);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-day-2026-08-09'))),
        isSemantics(
          label: 'Heute, Sonntag, 9. August',
          isButton: true,
          isSelected: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-day-2026-08-08'))),
        isSemantics(
          label: 'Gestern, Samstag, 8. August',
          isButton: true,
          isSelected: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('ein Tipp auf gestern meldet genau diesen Tag', (tester) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(onDateSelected: (d) => gewaehlt = d));
        await _tap(tester, 'today-day-2026-08-08');
      });
      expect(gewaehlt, DateTime(2026, 8, 8));
    });

    testWidgets('die Leiste ueberlebt die Zeitumstellung', (tester) async {
      // B5 anchor: `subtract(Duration(days: 1))` landed 2026-03-30 on the 28th
      // at 23:00, dropping Sunday and giving meals the wrong local_day.
      DateTime? gewaehlt;
      await withClock(Clock.fixed(DateTime(2026, 3, 30, 9)), () async {
        await _pump(tester, _today(onDateSelected: (d) => gewaehlt = d));
        for (var day = 24; day <= 30; day++) {
          expect(
            find.byKey(ValueKey('today-day-2026-03-$day')),
            findsOneWidget,
            reason: 'gapless across the DST switch: $day',
          );
        }
        await _tap(tester, 'today-day-2026-03-29');
      });
      expect(gewaehlt, DateTime(2026, 3, 29));
    });

    testWidgets('Wischen blaettert eine Woche zurueck und wieder vor', (
      tester,
    ) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(onDateSelected: (d) => gewaehlt = d));
        final strip = find.byKey(const ValueKey('today-date-strip'));

        await tester.fling(strip, const Offset(300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('today-day-2026-08-02')), findsOne);
        expect(find.byKey(const ValueKey('today-day-2026-07-27')), findsOne);
        expect(
          find.byKey(const ValueKey('today-day-2026-08-09')),
          findsNothing,
        );

        await _tap(tester, 'today-day-2026-07-30');
        expect(gewaehlt, DateTime(2026, 7, 30));

        await tester.fling(strip, const Offset(-300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('today-day-2026-08-09')), findsOne);
        // No page after today.
        await tester.fling(strip, const Offset(-300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('today-day-2026-08-09')), findsOne);
      });
    });

    testWidgets('Screenreader blaettern ueber benannte Aktionen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(onDateSelected: (_) {}));
      });
      final strip = find.bySemanticsLabel('Tag wählen');
      final node = tester.getSemantics(strip);
      final actions = node.getSemanticsData().customSemanticsActionIds!;
      final labels = [
        for (final id in actions) CustomSemanticsAction.getAction(id)!.label,
      ];
      // On the first page only "earlier" exists.
      expect(labels, ['Frühere Tage']);
      tester
          .renderObject(find.byKey(const ValueKey('today-date-strip')))
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.customAction, actions.single);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-day-2026-08-02')), findsOne);
      final later = tester.getSemantics(find.bySemanticsLabel('Tag wählen'));
      expect([
        for (final id in later.getSemanticsData().customSemanticsActionIds!)
          CustomSemanticsAction.getAction(id)!.label,
      ], containsAll(<String>['Frühere Tage', 'Spätere Tage']));
      handle.dispose();
    });

    testWidgets('ein aelterer gewaehlter Tag bringt seine Woche mit', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        // Picked in the Food tab's calendar, 20 days back.
        await _pump(
          tester,
          _today(selectedDate: DateTime(2026, 7, 20), onDateSelected: (_) {}),
        );
      });
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-day-2026-07-20'))),
        isSemantics(isSelected: true, isButton: true),
      );
      handle.dispose();
    });

    testWidgets('ein Archivtag heisst nicht „heute"', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            selectedDate: DateTime(2026, 8, 4),
            consumedKcal: 1200,
            pick: _pick(),
            nextWorkout: _workout(),
          ),
        );
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Dienstag, 4. Aug.');
      expect(find.text('AN DEM TAG ÜBRIG'), findsOneWidget);
      expect(find.text('HEUTE ÜBRIG'), findsNothing);
      expect(find.text('Mahlzeiten'), findsOneWidget);
      // Pick and next workout are about today, not the 4th of August.
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
      expect(
        find.byKey(const ValueKey('today-workout-row'), skipOffstage: false),
        findsNothing,
      );
    });
  });

  group('Aktionen', () {
    testWidgets('jede Aktion meldet sich mit ihrem Ziel zurueck', (
      tester,
    ) async {
      var profil = 0;
      var tagebuch = 0;
      var training = 0;
      final slots = <MealSlot>[];
      final rezepte = <RecipePick>[];
      final pick = _pick();

      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            streak: 4,
            steps: 3000,
            pick: pick,
            nextWorkout: _workout(),
            onOpenProfile: () => profil++,
            onOpenMealSlot: slots.add,
            onOpenPick: rezepte.add,
            onOpenFoodLog: () => tagebuch++,
            onOpenTraining: () => training++,
          ),
        );

        await _tap(tester, 'today-profile');
        await _tap(tester, 'today-streak');
        expect(profil, 2, reason: 'avatar and streak open the profile');

        await _tap(tester, 'today-pick');
        expect(rezepte, [same(pick)]);

        await _tap(tester, 'today-open-food-log');
        expect(tagebuch, 1);

        // Each add button reports ITS slot, not the current one.
        for (final slot in MealSlot.values) {
          await _tap(tester, 'today-meal-add-${slot.name}');
        }
        expect(slots, MealSlot.values);

        await _tap(tester, 'today-workout-row');
        expect(training, 1);
      });
    });

    testWidgets('jedes Tippziel ist mindestens 44 px gross', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            streak: 4,
            steps: 3000,
            pick: _pick(),
            nextWorkout: _workout(),
            onDateSelected: (_) {},
            onOpenProfile: () {},
            onOpenMealSlot: (_) {},
            onOpenPick: (_) {},
            onOpenFoodLog: () {},
            onOpenTraining: () {},
          ),
        );
      });
      for (final key in <String>[
        'today-profile',
        'today-streak',
        'today-day-2026-08-09',
        'today-day-2026-08-03',
        'today-pick',
        'today-open-food-log',
        for (final slot in MealSlot.values) 'today-meal-add-${slot.name}',
        'today-workout-row',
      ]) {
        final size = tester.getSize(
          find.byKey(ValueKey<String>(key), skipOffstage: false),
        );
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
        expect(size.width, greaterThanOrEqualTo(44), reason: key);
      }
    });

    testWidgets('ohne Callbacks gibt es keine toten Knoepfe', (tester) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            streak: 4,
            steps: 3000,
            pick: _pick(),
            nextWorkout: _workout(),
          ),
        );
      });
      expect(find.byKey(const ValueKey('today-open-food-log')), findsNothing);
      for (final slot in MealSlot.values) {
        expect(
          find.byKey(
            ValueKey('today-meal-add-${slot.name}'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      }
      // Shown, but neither a ripple nor a button for a screen reader.
      for (final key in <String>[
        'today-profile',
        'today-streak',
        'today-pick',
        'today-workout-row',
        'today-day-2026-08-09',
      ]) {
        final target = find.byKey(ValueKey<String>(key), skipOffstage: false);
        expect(target, findsOneWidget, reason: key);
        expect(
          find.descendant(of: target, matching: find.byType(InkWell)),
          findsNothing,
          reason: key,
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(target),
          isSemantics(isButton: false, hasTapAction: false),
          reason: key,
        );
      }
      handle.dispose();
    });
  });

  group('Tipp fuer heute Abend', () {
    testWidgets('zeigt Rezept, Zahlen und was vom Tag bleibt', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(pick: _pick()));
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-pick')));
      expect(find.text('TIPP FÜR HEUTE ABEND'), findsOneWidget);
      expect(_textOf(tester, 'today-pick-title'), 'Lachs mit Reis');
      expect(find.text('610 kcal · 58 g Protein'), findsOneWidget);
      expect(
        _textOf(tester, 'today-pick-leaves'),
        'Danach bleiben 292 kcal für heute',
      );
    });

    testWidgets('ohne Tipp gibt es keine Zeile', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today());
      });
      expect(
        find.byKey(const ValueKey('today-pick'), skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('ein geplantes Gericht, das nicht passt, sagt es', (
      tester,
    ) async {
      const t = AppTokens.dark;
      final planned = PlannedMeal.create(
        recipe: _recipe,
        day: _jetzt,
        slot: MealSlot.dinner,
      );
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            pick: _pick(
              remaining: 500,
              source: RecipePickSource.planned,
              planned: planned,
            ),
          ),
        );
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-pick')));
      expect(find.text('GEPLANT FÜR HEUTE ABEND'), findsOneWidget);
      final leaves = tester.widget<Text>(
        find.byKey(const ValueKey('today-pick-leaves')),
      );
      expect(leaves.data, '110 kcal über deinem Tagesbudget');
      expect(leaves.style!.color, t.warning);
    });

    testWidgets('die Zeile reicht genau ihren Tipp weiter, geplant oder '
        'vorgeschlagen', (tester) async {
      // Where a pick leads is the shared `openRecipePick`'s job (planned ->
      // meal plan / eatPlannedMeal, suggested -> recipe detail); the shell
      // calls it, see today_wiring_flow_test.dart. The row must hand over
      // the pick it shows, including a planned one without kcal.
      final planned = PlannedMeal.create(
        recipe: _recipe,
        day: _jetzt,
        slot: MealSlot.dinner,
        servings: 2,
      );
      for (final pick in <RecipePick>[
        _pick(kcal: 1220, source: RecipePickSource.planned, planned: planned),
        _pick(kcal: null, source: RecipePickSource.planned, planned: planned),
        _pick(),
      ]) {
        final gemeldet = <RecipePick>[];
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(tester, _today(pick: pick, onOpenPick: gemeldet.add));
          await _tap(tester, 'today-pick');
        });
        expect(gemeldet, [same(pick)]);
      }
    });

    testWidgets('unbekannte kcal behaupten keine Zahlen', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today(pick: _pick(kcal: null)));
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-pick')));
      expect(find.textContaining('g Protein'), findsNothing);
      expect(find.byKey(const ValueKey('today-pick-leaves')), findsNothing);
    });
  });

  group('Aktivitaet', () {
    testWidgets('das naechste Training steht unter den Schritten', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(steps: 3000, nextWorkout: _workout(), onOpenTraining: () {}),
        );
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-workout-row')));
      expect(_textOf(tester, 'today-workout-title'), 'Oberkörper Drücken');
      expect(
        _textOf(tester, 'today-workout-sub'),
        'Nächstes Training · ≈ 50 Min.',
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('today-workout-row'))).top,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('today-steps-card'))).bottom,
        ),
      );
    });

    testWidgets('ein heute erledigtes Training heisst so', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(nextWorkout: _workout(completedToday: true)),
        );
      });
      await _scrollTo(tester, find.byKey(const ValueKey('today-workout-row')));
      expect(
        _textOf(tester, 'today-workout-sub'),
        'Heute erledigt · ≈ 50 Min.',
      );
    });

    testWidgets('ohne Schritte, Hinweis und Training keine Karte', (
      tester,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today());
      });
      expect(
        find.byKey(const ValueKey('today-activity-card'), skipOffstage: false),
        findsNothing,
      );
    });
  });

  group('Robustheit', () {
    // Every combination lays out, including at the bottom of the page.
    renderMatrix('jede Kombination bleibt layoutbar', (tester, c) async {
      for (final mitMahlzeiten in <bool>[false, true]) {
        final fall = '${c.label} / Mahlzeiten=$mitMahlzeiten';
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(
            tester,
            _today(
              consumedKcal: mitMahlzeiten ? 610 : 0,
              burnedKcal: 120,
              streak: 3,
              steps: 4200,
              pick: _pick(),
              nextWorkout: _workout(),
              onOpenMealSlot: (_) {},
              onOpenFoodLog: () {},
              onOpenTraining: () {},
              meals: mitMahlzeiten
                  ? <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)]
                  : const <LoggedMeal>[],
            ),
            brightness: c.brightness,
            textScale: c.textScale,
          );
        });
        expect(tester.takeException(), isNull, reason: fall);

        await _scrollTo(
          tester,
          find.byKey(const ValueKey('today-workout-row')),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'nach unten gescrollt: $fall',
        );
      }
    }, textScales: const <double>[1.0, 2.0]);

    renderMatrix('auch waehrend dayLoading bleibt die Seite heil', (
      tester,
      c,
    ) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(dayLoading: true),
          brightness: c.brightness,
          textScale: c.textScale,
          settle: false,
        );
      });
      expect(tester.takeException(), isNull, reason: c.label);
    }, textScales: const <double>[2.0]);

    // Both languages: English strings are sometimes longer and catch
    // overflows a `de`-only run would never show.
    renderMatrix('der Heute-Tab rendert overflow-frei', (tester, c) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            consumedKcal: 1400,
            burnedKcal: 220,
            streak: 5,
            steps: 6000,
            pick: _pick(),
            nextWorkout: _workout(),
            onOpenMealSlot: (_) {},
            onOpenFoodLog: () {},
            meals: <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)],
          ),
          brightness: c.brightness,
          locale: c.locale,
        );
      });
      expect(
        tester.takeException(),
        isNull,
        reason: 'Rendering unter ${c.label} ist fehlgeschlagen',
      );

      // Visible without scrolling, and translated.
      expect(find.text(c.l10n.todayArcLeftToday.toUpperCase()), findsOneWidget);
      await _scrollTo(tester, find.byKey(const ValueKey('today-workout-row')));
      expect(tester.takeException(), isNull);
      expect(find.text(c.l10n.todayOpenFoodLog), findsOneWidget);
    }, locales: const <Locale>[Locale('de'), Locale('en')]);

    // Requirement of the redesign: 1.3x on 390 px and 1.0x on 320 px lay out
    // without a single overflow, with every section on screen.
    for (final (width, scale) in <(double, double)>[(390, 1.3), (320, 1.0)]) {
      for (final locale in const <Locale>[Locale('de'), Locale('en')]) {
        testWidgets('kein Ueberlauf bei $width px / ${scale}x / $locale', (
          tester,
        ) async {
          final overflows = await collectOverflows(() async {
            await withClock(Clock.fixed(_jetzt), () async {
              pinPhoneViewport(tester);
              await pumpLocalized(
                tester,
                _today(
                  consumedKcal: 1221,
                  burnedKcal: 73,
                  streak: 12,
                  steps: 1392,
                  pick: _pick(),
                  nextWorkout: _workout(),
                  onDateSelected: (_) {},
                  onOpenProfile: () {},
                  onOpenMealSlot: (_) {},
                  onOpenPick: (_) {},
                  onOpenFoodLog: () {},
                  onOpenTraining: () {},
                  meals: <LoggedMeal>[
                    _meal('Skyr mit Haferflocken', MealSlot.breakfast, 401),
                    _meal('Hähnchen mit Reis', MealSlot.lunch, 597),
                    _meal('Banane', MealSlot.snack, 105),
                  ],
                ),
                surfaceSize: Size(width, 844),
                locale: locale,
                textScale: scale,
                padding: _schalenrand,
                settle: true,
              );
              await _scrollTo(
                tester,
                find.byKey(const ValueKey('today-workout-row')),
              );
            });
          });
          expect(overflows, isEmpty, reason: describeOverflows(overflows));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('die Kennzahlen stapeln sich bei 2.0, statt zu schrumpfen', (
      tester,
    ) async {
      // A third of the card is narrower than a 2x value. Shrinking the text
      // would undo the user's setting (review F8-09); the stats stack and
      // keep their real size. An overflow does not THROW, so the geometry is
      // asserted directly.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(consumedKcal: 12345, burnedKcal: 1234, streak: 365),
          textScale: 2.0,
        );
      });
      expect(tester.takeException(), isNull);
      await _scrollTo(tester, find.byKey(const ValueKey('today-stat-burned')));

      final eaten = find.byKey(const ValueKey('today-stat-eaten'));
      final goal = find.byKey(const ValueKey('today-kcal-goal'));
      final activity = find.byKey(const ValueKey('today-stat-burned'));
      expect(
        tester.getRect(goal).top,
        greaterThanOrEqualTo(tester.getRect(eaten).bottom),
      );
      expect(
        tester.getRect(activity).top,
        greaterThanOrEqualTo(tester.getRect(goal).bottom),
      );
      for (final key in ['today-stat-eaten', 'today-stat-burned']) {
        final text = find.byKey(ValueKey(key));
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
        );
        final style = tester.widget<Text>(text).style!;
        expect(
          MediaQuery.textScalerOf(tester.element(text)).scale(style.fontSize!),
          style.fontSize! * 2,
        );
      }
    });

    // The remaining number is the app's largest type (58 px base). The
    // FITTEDBOX is measured, not the text: the text keeps its unshrunk size
    // and the scaling sits in the transform above it.
    renderMatrix(
      'die Restzahl schrumpft bei Systemschrift 2.0, statt die Karte zu '
      'sprengen',
      (tester, c) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pump(
            tester,
            _today(
              profile: const UserProfile(dailyKcalGoal: 99999),
              consumedKcal: 12345,
              burnedKcal: 1234,
            ),
            brightness: c.brightness,
            textScale: c.textScale,
          );
        });

        expect(tester.takeException(), isNull);
        final karte = find.byKey(const ValueKey('today-kcal-hero'));
        final zahl = find.byKey(const ValueKey('today-kcal-remaining'));
        expect(zahl, findsOneWidget);
        final kasten = find
            .ancestor(of: zahl, matching: find.byType(FittedBox))
            .first;
        expect(tester.widget<FittedBox>(kasten).fit, BoxFit.scaleDown);
        expect(
          tester.getSize(kasten).width,
          lessThanOrEqualTo(tester.getSize(karte).width),
        );
      },
      textScales: const <double>[2.0],
    );

    testWidgets('die Vorlese-Beschriftungen tragen echte Umlaute', (
      tester,
    ) async {
      // A semantics label is spoken text, so ASCII transliterations would be
      // read out as written.
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(
          tester,
          _today(
            selectedDate: DateTime(2026, 8, 8),
            onDateSelected: (_) {},
            onOpenProfile: () {},
          ),
        );
      });

      expect(
        find.bySemanticsLabel(RegExp('Profil und Einstellungen')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Tag wählen'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Kalorienfortschritt')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('setzt keinen zweiten Seitenrand', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today());
      });

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('today-kcal-hero'))).dx,
        20,
        reason: 'die Schale liefert die 20 px bereits — 40 waere doppelt',
      );
    });

    testWidgets('die Wurzel traegt weiterhin screen-today', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pump(tester, _today());
      });
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    });
  });

  testWidgets('unter en stehen die englischen Beschriftungen im Baum', (
    tester,
  ) async {
    // Counter-check to the `en` column of the render matrix above: the labels
    // must really CHANGE with the language, not just resolve to some ARB hit.
    await withClock(Clock.fixed(_jetzt), () async {
      await _pump(
        tester,
        _today(
          consumedKcal: 1400,
          burnedKcal: 220,
          streak: 5,
          onOpenFoodLog: () {},
          meals: <LoggedMeal>[_meal('Salmon bowl', MealSlot.dinner, 610)],
        ),
        locale: const Locale('en'),
      );
    });

    expect(find.text('LEFT TODAY'), findsOneWidget);
    expect(find.text('HEUTE ÜBRIG'), findsNothing);
    expect(_textOf(tester, 'today-date-selected-label'), 'Sunday, Aug 9');
    await _scrollTo(tester, find.byKey(const ValueKey('today-open-food-log')));
    expect(find.text('Open food log'), findsOneWidget);
  });
}
