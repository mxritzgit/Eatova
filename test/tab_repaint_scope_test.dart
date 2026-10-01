// Paint scope of the tab pages (perf-ui, polish run 2026-10-01).
//
// Two findings, both measured with `debugOnProfilePaint` (every RenderObject
// painted per frame, debug builds only):
//
//  * Scrolling Today, Food and Training re-recorded the whole page on every
//    scroll frame: a SingleChildScrollView's viewport is the nearest repaint
//    boundary, so its whole child is painted again whenever the offset moves.
//    Measured per scroll frame before the fix: Today ~330, Food ~320,
//    Training ~140 render objects (Recipes, a ListView with per-item
//    boundaries: ~20). The page content now has its own layer.
//  * On the coach start state the orb breathes forever. Its ScaleTransitions
//    rebuild under the conversation area's LayoutBuilder, whose build scope
//    then relayouts it every frame, and a relayout repaints up to the nearest
//    boundary: the whole tab, header and composer included (~75 render
//    objects per idle frame). The area now has its own boundary.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'flows/flow_test_helpers.dart' show storeOf;
import 'support/harness.dart';

MealAnalysisResult _meal(String name) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 420,
  estimatedGrams: 300,
  kcalPer100G: 140,
  protein: '30 g',
  carbs: '40 g',
  fat: '12 g',
  confidence: 'Mittel',
  portionNotes: 'Test.',
  sourceLabel: 'Foto-KI',
);

Future<void> _frames(WidgetTester tester, int count, Duration step) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(step);
  }
}

/// The home shell on [tab], with enough meals that Today and Food scroll.
Future<void> _pumpTab(WidgetTester tester, int tab) async {
  pinPhoneViewport(tester);
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
  await pumpLocalized(
    tester,
    EatovaHomePage(),
    // Real motion: the coach orb must breathe for the idle-frame check.
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await _frames(tester, 20, const Duration(milliseconds: 50));
  final store = storeOf(tester);
  for (var i = 0; i < 6; i++) {
    store.addResultToDailyTotal(_meal('Mahlzeit $i'));
  }
  store.setTab(tab);
  // Entrances and the debounced stats save run out.
  await _frames(tester, 40, const Duration(milliseconds: 50));
}

/// Every RenderObject painted while [body] runs.
Future<List<RenderObject>> _paintedDuring(Future<void> Function() body) async {
  final painted = <RenderObject>[];
  debugOnProfilePaint = painted.add;
  try {
    await body();
  } finally {
    debugOnProfilePaint = null;
  }
  return painted;
}

bool _isWithin(RenderObject node, RenderObject ancestor) {
  for (
    RenderObject? current = node;
    current != null;
    current = current.parent
  ) {
    if (identical(current, ancestor)) return true;
  }
  return false;
}

Finder _inTab(int tab, Finder finder) => find.descendant(
  of: find.byKey(ValueKey('tab-fixed-$tab')),
  matching: finder,
);

Future<void> _settleAway(WidgetTester tester) async {
  await _frames(tester, 40, const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  for (final (tab, name) in const [
    (0, 'Heute'),
    (1, 'Food'),
    (3, 'Training'),
  ]) {
    testWidgets('Scrollen im $name-Tab zeichnet die Seite nicht neu', (
      tester,
    ) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 28, 13)), () async {
        await _pumpTab(tester, tab);
        final header = tester.renderObject(
          _inTab(tab, find.byKey(TabChrome.headerKey)),
        );
        final position = tester
            .state<ScrollableState>(_inTab(tab, find.byType(Scrollable)).first)
            .position;
        const frames = 10;

        final painted = await _paintedDuring(() async {
          final gesture = await tester.startGesture(const Offset(200, 500));
          for (var i = 0; i < frames; i++) {
            await gesture.moveBy(const Offset(0, -8));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await gesture.up();
        });

        expect(
          position.pixels,
          greaterThan(0),
          reason: 'the page must really scroll, or the check proves nothing',
        );
        expect(
          painted.where((node) => _isWithin(node, header)),
          isEmpty,
          reason:
              'a scroll frame only moves the recorded page layer; the '
              'header scrolls along without being painted again',
        );
        expect(
          painted.length,
          lessThan(frames * 30),
          reason:
              'measured before: ~330 (Today), ~320 (Food), ~140 '
              '(Training) render objects per scroll frame',
        );
        await _settleAway(tester);
      });
    });
  }

  testWidgets('die Orb-Atmung zeichnet Kopfzeile und Eingabe nicht neu', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 13)), () async {
      await _pumpTab(tester, 4);
      expect(
        find.byType(CoachOrb),
        findsOneWidget,
        reason: 'the start state with the breathing orb is shown',
      );
      final tab = tester.renderObject(
        find.byKey(const ValueKey('tab-fixed-4')),
      );
      final header = tester.renderObject(
        _inTab(4, find.byKey(TabChrome.headerKey)),
      );
      const frames = 10;

      final painted = await _paintedDuring(
        () => _frames(tester, frames, const Duration(milliseconds: 16)),
      );

      final inTab = painted.where((node) => _isWithin(node, tab)).toList();
      expect(inTab, isNotEmpty, reason: 'the orb does animate');
      expect(
        inTab.where((node) => _isWithin(node, header)),
        isEmpty,
        reason: 'the header sits outside the animated area',
      );
      expect(
        inTab.whereType<RenderEditable>(),
        isEmpty,
        reason: 'neither does the composer',
      );
      expect(
        inTab.length,
        lessThan(frames * 30),
        reason: 'measured before: ~75 render objects per idle frame',
      );
      await _settleAway(tester);
    });
  });
}
