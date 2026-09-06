// 2026-09-02: the recipes tab's undo window has to reach the coach card
// through the REAL shell (eatova_home_page.dart), not only through the store
// or a test shell. Pins the two wires: RecipesScreen.onDeletePendingChanged is
// connected, and CoachChatScreen.userRecipeSlugs follows
// HomeStore.visibleUserRecipes while a delete is pending.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

FitnessRecipe _rezept(String slug) => FitnessRecipe(
      slug: slug,
      title: 'Coach-Bowl',
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: 500,
      proteinG: 40,
      carbsG: 50,
      fatG: 12,
      estimatedGrams: 350,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

void main() {
  testWidgets(
      'Undo-Fenster des Rezepte-Tabs erreicht die Coach-Karte über die echte '
      'Shell', (tester) async {
    // A finished profile, or the shell opens the onboarding instead of the
    // tab bar (same seed as offline_sync_flow_test).
    final server = FixlaufServer()
      ..profileRow = serverProfileRow(completedProfile);
    final store = await pumpSignedIn(tester, server);
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget,
        reason: 'ein fertiges Profil darf nicht ins Onboarding führen');
    final recipe = _rezept(FitnessRecipe.coachProposalSlug('msg-1'));
    await store.createUserRecipe(recipe);
    await settleFrames(tester);

    // Both tabs have to exist once (the IndexedStack builds them lazily).
    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await settleFrames(tester);
    await tester.tap(find.byKey(const ValueKey('nav-Coach')));
    await settleFrames(tester);

    final recipesScreen = tester.widget<RecipesScreen>(
      find.byType(RecipesScreen, skipOffstage: false),
    );
    expect(recipesScreen.onDeletePendingChanged, isNotNull,
        reason: 'die Shell verdrahtet den Undo-Hook — immer, auch ohne Sync');

    CoachChatScreen coach() => tester.widget<CoachChatScreen>(
          find.byType(CoachChatScreen, skipOffstage: false),
        );
    expect(coach().userRecipeSlugs, contains(recipe.slug));

    // The tab reports the window; the shell must route it to the store and
    // the coach must see the recipe disappear while the store keeps the row.
    recipesScreen.onDeletePendingChanged!(recipe.slug, pending: true);
    await settleFrames(tester);
    expect(store.pendingRecipeDeletes, {recipe.slug});
    expect(store.userRecipes.map((r) => r.slug), contains(recipe.slug),
        reason: 'die Zeile bleibt bis zum Commit im Store');
    expect(coach().userRecipeSlugs, isNot(contains(recipe.slug)),
        reason: 'die Karte liest visibleUserRecipes, nicht userRecipes');

    recipesScreen.onDeletePendingChanged!(recipe.slug, pending: false);
    await settleFrames(tester);
    expect(store.pendingRecipeDeletes, isEmpty);
    expect(coach().userRecipeSlugs, contains(recipe.slug),
        reason: 'Undo: das Rezept ist wieder da');
  });
}
