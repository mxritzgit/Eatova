// Fix dispatch F1-01: `AnimatedSize` must not be handed `Duration.zero`.
//
// `motionDuration` collapses to zero under `MediaQuery.disableAnimations`, and
// RenderAnimatedSize answers a zero duration by resizing INSIDE its own
// `performLayout` — the framework then asserts "A RenderAnimatedSize was
// mutated in its own performLayout implementation". Every device with "reduce
// motion" on hit that: a crash in debug, a silent layout risk in release.
//
// `maybeAnimatedSize` drops the widget instead of shortening it. The tests
// below pump two of the four former sites, change the child's size and prove
// nothing throws — plus the counter-checks that the animation is still there
// with motion on and that the end state is identical either way.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import 'support/harness.dart';

const MealAnalysisResult _haferbrei = MealAnalysisResult(
  mealName: 'Haferbrei',
  caloriesKcal: 320,
  estimatedGrams: 250,
  kcalPer100G: 128,
  protein: '12 g',
  carbs: '48 g',
  fat: '6 g',
  confidence: 'Hoch',
  portionNotes: 'Standardportion.',
  sourceLabel: 'Foto-KI',
);

/// The item with its own expand state, so a tap really changes the child's
/// height — the trigger the assertion needs.
class _Aufklappbar extends StatefulWidget {
  const _Aufklappbar();

  @override
  State<_Aufklappbar> createState() => _AufklappbarState();
}

class _AufklappbarState extends State<_Aufklappbar> {
  bool _offen = false;

  @override
  Widget build(BuildContext context) => MealSuggestionItem(
        result: _haferbrei,
        expanded: _offen,
        onTap: () => setState(() => _offen = !_offen),
        onAdd: (_) {},
      );
}

Finder get _animierteGroessen => find.descendant(
      of: find.byType(MealSuggestionItem),
      matching: find.byType(AnimatedSize),
    );

/// The expanded body: the gram slider only exists when the item is open.
Finder get _aufgeklappterKoerper => find.descendant(
      of: find.byType(MealSuggestionItem),
      matching: find.byType(Slider),
    );

void main() {
  group('MealSuggestionItem unter reduzierter Bewegung', () {
    testWidgets('Aufklappen wirft keine RenderAnimatedSize-Assertion',
        (tester) async {
      await pumpLocalized(
        tester,
        const _Aufklappbar(),
        reducedMotion: true,
        scrollable: true,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(MealSuggestionItem));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'AnimatedSize mit Duration.zero mutiert sich im eigenen '
            'performLayout — der Baum darf es gar nicht erst enthalten',
      );
      expect(_aufgeklappterKoerper, findsOneWidget);
    });

    testWidgets('der Baum enthaelt gar kein AnimatedSize mehr', (tester) async {
      await pumpLocalized(
        tester,
        const _Aufklappbar(),
        reducedMotion: true,
        scrollable: true,
      );

      expect(_animierteGroessen, findsNothing);
    });

    // Counter-check: nobody may "clean up" the animation itself. With motion
    // on the widget must still be in the tree.
    testWidgets('mit normaler Bewegung animiert die Karte weiterhin',
        (tester) async {
      await pumpLocalized(
        tester,
        const _Aufklappbar(),
        reducedMotion: false,
        scrollable: true,
      );

      expect(_animierteGroessen, findsOneWidget);
      expect(
        tester.widget<AnimatedSize>(_animierteGroessen).duration,
        const Duration(milliseconds: 180),
      );
    });

    // No behaviour break: the END state is the same in both modes, only the
    // transition is gone.
    testWidgets('der Endzustand ist in beiden Modi derselbe', (tester) async {
      await pumpLocalized(
        tester,
        const _Aufklappbar(),
        reducedMotion: false,
        scrollable: true,
      );
      await tester.tap(find.byType(MealSuggestionItem));
      await tester.pumpAndSettle();
      final mitBewegung = tester.getSize(find.byType(MealSuggestionItem));

      await pumpLocalized(
        tester,
        const _Aufklappbar(),
        reducedMotion: true,
        scrollable: true,
      );
      await tester.tap(find.byType(MealSuggestionItem));
      await tester.pump();
      expect(tester.getSize(find.byType(MealSuggestionItem)), mitBewegung);
    });
  });

  group('AuthScreen unter reduzierter Bewegung', () {
    testWidgets('Wechsel zu Registrieren wirft keine Assertion',
        (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        AuthScreen(authRepository: InMemoryAuthRepository()),
        reducedMotion: true,
        scaffold: false,
        safeArea: false,
      );
      expect(tester.takeException(), isNull);

      // Opens the name field inside the former AnimatedSize -> the child grows.
      final umschalter = find.byKey(const ValueKey('auth-toggle-register'));
      await tester.ensureVisible(umschalter);
      await tester.pump();
      await tester.tap(umschalter);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('auth-name-field')), findsOneWidget);
    });
  });
}
