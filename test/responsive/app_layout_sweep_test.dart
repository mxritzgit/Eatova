// Layout sweep over the signed-in shell (preview store, no sync).
//
// Walks every tab and the sheets/pages reachable from them in one journey per
// window configuration and fails on ANY FlutterError: RenderFlex overflow,
// unbounded constraints, ParentData misuse and everything else the framework
// reports. Each step also asserts that its surface really opened, so a renamed
// key cannot turn a step into a silent no-op.
//
// Existing suites cover single screens (text_scale_stress_test.dart walks the
// app at 393 px, German, 2.0x) and single components at 320 px. This file adds
// the combinations they leave out: 320 x 568 and 390 x 844, 1.0x and 2.0x,
// German and English, light and dark — plus tablet and landscape windows,
// where pages must stay in a readable column (see ReadableWidth).
//
// Export and camera/barcode flows need sync or hardware and are covered by
// their own suites (export_analysis_design_test.dart, meal_camera_sheet_test
// .dart, barcode_* tests).

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/widgets/design/readable_width.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import '../support/harness.dart';

// A Wednesday; recommendations rotate by date, so the clock is frozen.
final _now = DateTime(2026, 9, 16, 12);

MealAnalysisResult _meal(String name, int kcal) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 350,
  kcalPer100G: kcal / 3.5,
  protein: '32 g',
  carbs: '41 g',
  fat: '12 g',
  confidence: 'Mittel',
  portionNotes: '',
  sourceLabel: 'Manuell',
);

TrainingPlan _plan() => TrainingPlan(
  id: 'sweep-plan',
  proposal: CoachTrainingProposal(
    title: 'Ganzkörper-Kraft für Zuhause mit Kurzhanteln',
    workouts: [
      TrainingWorkout(
        title: 'Einheit A: Beine, Rücken und Rumpfstabilität',
        exercises: [
          TrainingExercise(
            name: 'Bulgarische Split-Kniebeuge mit Kurzhanteln',
            sets: 3,
            reps: 10,
            restSeconds: 60,
          ),
        ],
      ),
    ],
  ),
);

/// One surface of the journey: switch to [tab], tap [taps] in order, expect
/// [opened], scroll it, then pop [pops] routes.
typedef _Step = ({
  String name,
  String tab,
  List<String> taps,
  Finder opened,
  int pops,
  Finder? column,
});

_Step _step(
  String name,
  String tab,
  List<String> taps,
  Finder opened, {
  int? pops,
  Finder? column,
}) => (
  name: name,
  tab: tab,
  taps: taps,
  opened: opened,
  // A bare tab has nothing to close.
  pops: pops ?? (taps.isEmpty ? 0 : 1),
  column: column,
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

final List<_Step> _journey = <_Step>[
  _step('Heute', 'Heute', const [], _key('today-kcal-hero')),
  _step('Food', 'Food', const [], _key('food-entry-dock')),
  _step('Rezepte', 'Rezepte', const [], _key('screen-recipes')),
  _step('Training', 'Training', const [], _key('training-open-plans')),
  _step('Coach', 'Coach', const [], _key('screen-coach')),
  _step(
    'Profil',
    'Heute',
    const ['today-profile'],
    _key('screen-profile'),
    column: _key('screen-profile'),
  ),
  // Settings sit behind the avatar's profile page (dark redesign).
  _step(
    'Einstellungen',
    'Heute',
    const ['today-profile', 'profile-open-settings'],
    _key('screen-settings'),
    column: _key('screen-settings'),
    pops: 2,
  ),
  _step(
    'Ziele',
    'Heute',
    const ['today-profile', 'profile-open-settings', 'settings-open-goals'],
    _key('settings-save'),
    pops: 3,
  ),
  _step('Mahlzeit hinzufuegen', 'Food', const [
    'food-slot-add-dinner',
  ], _key('add-meal-sheet')),
  _step(
    'Favoriten',
    'Food',
    const ['food-slot-add-dinner', 'add-meal-favorites-all'],
    _key('favorites-sheet'),
    pops: 2,
  ),
  // Manual entry from the dock: long-press on the search capsule (the add
  // sheet's "Add manually" row is pinned in the Food wiring tests).
  _step('Manuell', 'Food', const [
    'long:food-search',
  ], _key('manual-meal-sheet')),
  // Entries are always listed; no expand tap before editing.
  _step('Mahlzeit bearbeiten', 'Food', const [
    'food-history-entry-',
  ], _key('edit-meal-sheet')),
  _step('Kalender', 'Food', const [
    'food-date-calendar',
  ], find.byType(FoodDatePicker)),
  _step(
    'Trends',
    'Food',
    const ['topbar-trends'],
    _key('screen-trends'),
    column: _key('screen-trends'),
  ),
  _step('Rezept erstellen', 'Rezepte', const [
    'recipe-create-button',
  ], _key('recipe-create-sheet')),
  _step('Rezept importieren', 'Rezepte', const [
    'recipe-import-button',
  ], _key('recipe-import-sheet')),
  _step(
    'Rezeptdetail',
    'Rezepte',
    const ['recipes-tab-all', 'recipe-tile-hahnchen_mit_reis_and_brokkoli'],
    _key('recipe-detail-scroll'),
    column: _key('recipe-detail-scroll'),
  ),
  _step(
    'Rezept einplanen',
    'Rezepte',
    const [
      'recipes-tab-all',
      'recipe-tile-hahnchen_mit_reis_and_brokkoli',
      'recipe-add-button',
    ],
    _key('recipe-meal-picker-sheet'),
    pops: 2,
  ),
  _step(
    'Wochenplan',
    'Rezepte',
    const ['recipe-meal-plan-button'],
    _key('meal-plan-week-range'),
    column: find.byKey(const PageStorageKey<String>('meal-plan-scroll')),
  ),
  _step(
    'Einkaufsliste',
    'Rezepte',
    const ['recipe-meal-plan-button', 'meal-plan-tab-shopping'],
    _key('shopping-summary'),
  ),
  _step(
    'Plan-Editor',
    'Rezepte',
    const ['recipe-meal-plan-button', 'meal-plan-add-'],
    _key('meal-plan-editor-scroll'),
    pops: 2,
  ),
  _step('Trainingsplaene', 'Training', const [
    'training-open-plans',
  ], _key('training-plan-library-scroll')),
  _step('Trainingseditor', 'Training', const [
    'training-create',
  ], _key('training-editor-scroll')),
  _step('Trainingsverlauf', 'Training', const [
    'training-open-history',
  ], _key('training-history-back')),
  _step('Coach-Info', 'Coach', const ['coach-info'], _key('coach-info-sheet')),
  _step('Coach-Verlauf', 'Coach', const [
    'coach-sessions-open',
  ], _key('coach-sessions-new')),
];

/// Bounded settle: the Coach orb and progress indicators may never settle.
/// The first 300 ms always elapse, so short timers behind a tap (route pushes
/// after an async store read) complete before the step is checked.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (i >= 5 && !tester.binding.hasScheduledFrame) return;
  }
}

/// Taps [key] (or the first widget whose key starts with it, for keys ending
/// in '-'; a `long:` prefix long-presses), scrolling the visible list to it
/// first when it is not built yet.
Future<void> _tap(WidgetTester tester, String key, String step) async {
  final longPress = key.startsWith('long:');
  if (longPress) key = key.substring('long:'.length);
  final target = key.endsWith('-') ? _keyPrefix(key) : _key(key);
  final list = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .hitTestable();
  for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
    if (list.evaluate().isEmpty) break;
    await tester.drag(list.first, const Offset(0, -200), warnIfMissed: false);
    await _settle(tester);
  }
  expect(target, findsWidgets, reason: '$step: $key fehlt');
  await tester.ensureVisible(target.first);
  await _settle(tester);
  if (longPress) {
    await tester.longPress(target.first);
  } else {
    await tester.tap(target.first);
  }
  await _settle(tester);
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).hitTestable();
  if (scrollable.evaluate().isEmpty) return;
  for (var i = 0; i < 4; i++) {
    await tester.drag(
      scrollable.first,
      const Offset(0, -300),
      warnIfMissed: false,
    );
    await _settle(tester);
  }
}

/// Walks [_journey] and returns every FlutterError, labelled by step.
Future<List<String>> _walk(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  required Brightness brightness,
  required double textScale,
  void Function(_Step step)? onOpened,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final errors = <String>[];
  var current = 'Start';
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString().split('\n').first;
    errors.add('$current: $message');
  };
  // Restored in `finally`, not in a tear-down: the binding checks the handler
  // right after the body, and a failed expect must not leave it installed.
  try {
    await withClock(Clock.fixed(_now), () async {
      await tester.pumpWidget(
        localizedApp(
          EatovaHomePage(),
          locale: locale,
          brightness: brightness,
          textScale: textScale,
          safeArea: false,
          scaffold: false,
        ),
      );
      await _settle(tester);
      await _seed(tester);
      expect(errors, isEmpty, reason: errors.join('\n'));
      for (final step in _journey) {
        current = step.name;
        await _visit(tester, step, onOpened);
        // Fail at the step that produced the error, not at the end.
        expect(errors, isEmpty, reason: errors.join('\n'));
      }

      // The player needs the signed-in store's local cache to start from the
      // shell, so it is mounted directly with the same plan.
      current = 'Trainingsplayer';
      await tester.pumpWidget(
        localizedApp(
          TrainingPlayerScreen(
            plan: _plan(),
            onPersist: (_) async => true,
            onComplete: (_) async {},
          ),
          locale: locale,
          brightness: brightness,
          textScale: textScale,
          safeArea: false,
          scaffold: false,
        ),
      );
      await _settle(tester);
      final player = _step(
        'Trainingsplayer',
        'Training',
        const [],
        _key('training-player-list'),
        column: find
            .descendant(
              of: find.byType(TrainingPlayerScreen),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      expect(player.opened, findsOneWidget, reason: 'Trainingsplayer fehlt');
      onOpened?.call(player);
      await _scrollThrough(tester);
      expect(errors, isEmpty, reason: errors.join('\n'));
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    });
  } finally {
    FlutterError.onError = prior;
  }
  return errors;
}

/// Long names, several entries per slot, pinned favorites (so the library
/// opens) and a selected training plan.
Future<void> _seed(WidgetTester tester) async {
  final store = storeOf(tester);
  final meals = <(MealAnalysisResult, MealSlot)>[
    (
      _meal('Haferflocken mit Blaubeeren, Walnüssen und griechischem Joghurt', 540),
      MealSlot.breakfast,
    ),
    (_meal('Linsen-Curry mit Basmatireis', 720), MealSlot.lunch),
    (_meal('Apfel', 80), MealSlot.lunch),
    (_meal('Magerquark mit Leinöl', 210), MealSlot.lunch),
  ];
  for (final (result, slot) in meals) {
    await store.addResultToDailyTotal(result, slot: slot);
    await store.toggleFavorite(result);
  }
  // The save serializes through timers; pump fake time instead of awaiting.
  var saved = false;
  unawaited(store.saveTrainingPlan(_plan()).whenComplete(() => saved = true));
  for (var i = 0; i < 200 && !saved; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(store.trainingPlans, isNotEmpty, reason: 'Trainingsplan fehlt');
  await _settle(tester);
}

Future<void> _visit(
  WidgetTester tester,
  _Step step,
  void Function(_Step step)? onOpened,
) async {
  await tester.tap(find.byKey(ValueKey<String>('nav-${step.tab}')));
  await _settle(tester);
  // Each step starts at the top of its tab, whatever the previous one scrolled.
  for (final element in find.byType(Scrollable).hitTestable().evaluate()) {
    final position = (element as StatefulElement).state as ScrollableState;
    if (position.position.axis == Axis.vertical) position.position.jumpTo(0);
  }
  await _settle(tester);
  for (final key in step.taps) {
    await _tap(tester, key, step.name);
  }
  expect(step.opened, findsWidgets, reason: '${step.name} nicht offen');
  onOpened?.call(step);
  await _scrollThrough(tester);
  for (var i = 0; i < step.pops; i++) {
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await _settle(tester);
  }
  if (step.pops > 0) {
    // Closed = the home route is on top again. A hit test at the tab stack's
    // centre used to stand in for this; since the tabs run under the floating
    // bar, that centre can land on empty space of an open tab.
    final home = find.byKey(const ValueKey<String>('home-tab-stack'));
    expect(home, findsOneWidget, reason: '${step.name} nicht geschlossen');
    expect(
      ModalRoute.of(tester.element(home))!.isCurrent,
      isTrue,
      reason: '${step.name} nicht geschlossen',
    );
  }
}

String _label(Size size, double scale, Locale locale, Brightness brightness) =>
    '${size.width.toInt()}x${size.height.toInt()} ${scale}x '
    '${locale.languageCode} ${brightness.name}';

void main() {
  group('Telefone', () {
    for (final size in const [Size(320, 568), Size(390, 844)]) {
      for (final scale in const [1.0, 2.0]) {
        for (final locale in const [Locale('de'), Locale('en')]) {
          for (final brightness in Brightness.values) {
            testWidgets(
              'alle Tabs und Sheets ohne Layoutfehler '
              '[${_label(size, scale, locale, brightness)}]',
              (tester) async {
                final errors = await _walk(
                  tester,
                  size: size,
                  locale: locale,
                  brightness: brightness,
                  textScale: scale,
                  onOpened: (step) {
                    // Phones never get a side inset: pages span the window.
                    final column = step.column;
                    if (column == null) return;
                    expect(
                      tester.getRect(column).width,
                      size.width,
                      reason: '${step.name} ist auf dem Telefon eingerueckt',
                    );
                  },
                );
                expect(errors, isEmpty, reason: errors.join('\n'));
              },
            );
          }
        }
      }
    }
  });

  group('Grosse Fenster', () {
    for (final size in const [
      Size(1024, 768),
      Size(1366, 1024),
      // Phone in landscape: wide but short.
      Size(844, 390),
    ]) {
      for (final scale in const [1.0, 2.0]) {
        for (final locale in const [Locale('de'), Locale('en')]) {
          testWidgets(
            'lesbare Spalte ohne Layoutfehler '
            '[${_label(size, scale, locale, Brightness.light)}]',
            (tester) async {
              void expectColumn(Rect rect, String what) {
                expect(
                  rect.width,
                  lessThanOrEqualTo(kReadableContentWidth),
                  reason: '$what ist ${rect.width} px breit',
                );
                expect(
                  rect.center.dx,
                  moreOrLessEquals(size.width / 2, epsilon: 0.5),
                  reason: '$what ist nicht zentriert',
                );
              }

              final errors = await _walk(
                tester,
                size: size,
                locale: locale,
                brightness: Brightness.light,
                textScale: scale,
                onOpened: (step) {
                  final tabs = find.byKey(
                    const ValueKey<String>('home-tab-stack'),
                  );
                  if (step.taps.isEmpty && tabs.evaluate().isNotEmpty) {
                    expectColumn(
                      tester.getRect(tabs),
                      '${step.name}-Tab',
                    );
                    expectColumn(
                      tester
                          .getRect(find.byKey(const ValueKey('nav-Heute')))
                          .expandToInclude(
                            tester.getRect(
                              find.byKey(const ValueKey('nav-Coach')),
                            ),
                          ),
                      'Navigation',
                    );
                  }
                  final column = step.column;
                  if (column != null) {
                    expectColumn(tester.getRect(column), step.name);
                  }
                },
              );
              expect(errors, isEmpty, reason: errors.join('\n'));
            },
          );
        }
      }
    }
  });
}
