import '../support/recipe_navigation.dart';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart';

FitnessRecipe _recipe() => const FitnessRecipe(
  slug: 'user_coach_confirmed-again',
  title: 'Coach Bowl',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: 300,
  categories: ['Eigene'],
  userCreated: true,
);

void main() {
  for (final rebuildBeforeTimer in [true, false]) {
    testWidgets('confirmed re-add survives the old recipe delete timer '
        '(rebuild first: $rebuildBeforeTimer)', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 8, 12)), () async {
        pinPhoneViewport(tester);
        final server = FixlaufServer()
          ..profileRow = serverProfileRow(completedProfile);
        final store = await pumpSignedIn(tester, server);
        final recipe = _recipe();
        await store.createUserRecipe(recipe);
        await settleFrames(tester);
        await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
        await settleFrames(tester);
        await selectRecipeSection(tester, 'own');
        final tile = find.byKey(ValueKey('recipe-tile-${recipe.slug}'));
        await tester.scrollUntilVisible(
          tile,
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('screen-recipes')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(tile);
        await settleFrames(tester);
        await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
        await settleFrames(tester);
        expect(store.pendingRecipeDeletes, contains(recipe.slug));

        // Use the real shell's Coach callback: it is invoked only after the
        // actual Coach confirmation flow (covered in coach_recipe_flow_test).
        // The tab switch is programmatic because the Undo toast covers nav.
        store.setTab(4);
        await settleFrames(tester);
        final coach = tester.widget<CoachChatScreen>(
          find.byType(CoachChatScreen),
        );
        expect(coach.userRecipeSlugs, isNot(contains(recipe.slug)));
        await coach.onCreateRecipe!(recipe);
        if (rebuildBeforeTimer) await settleFrames(tester);
        await tester.pump(kRecipeUndoWindow + const Duration(seconds: 1));
        await settleFrames(tester);

        expect(store.userRecipes.map((r) => r.slug), contains(recipe.slug));
        expect(store.pendingRecipeDeletes, isEmpty);
        expect(server.recipeRows, contains(recipe.slug));
        expect(
          server.requestsTo('/user_recipes', method: 'DELETE'),
          isEmpty,
          reason: 'the superseded deletion must never reach persistence',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await settleFrames(tester);
      });
    });
  }
}
