import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';

// Coach-Rezept-Generator (Spec 2026-08-12): das Proposal ist die
// Client-Sicht auf das Server-Wire-Format (snake_case) des Recipe-Mode.
// Der Server klemmt bereits; hier gibt es nur die billige Defensiv-Klemme
// gegen aeltere/kaputte Function-Antworten (estimated_g 0 wuerde sonst in
// FitnessRecipe.kcalPer100G durch 0 teilen).

Map<String, dynamic> _validJson() => <String, dynamic>{
      'title': 'Huehnchenauflauf',
      'description': 'Cremig und proteinreich.',
      'portion': '1 grosse Portion',
      'ingredients': '- 250 g Haehnchenbrust\n- 150 g Brokkoli',
      'preparation': '1. Ofen vorheizen.\n2. Backen.',
      'calories_kcal': 520,
      'protein_g': 48,
      'carbs_g': 32,
      'fat_g': 18,
      'estimated_g': 450,
    };

void main() {
  test('fromJson uebernimmt alle Felder samt Bild-Bytes', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final proposal =
        CoachRecipeProposal.fromJson(_validJson(), imageBytes: bytes);

    expect(proposal, isNotNull);
    expect(proposal!.title, 'Huehnchenauflauf');
    expect(proposal.caloriesKcal, 520);
    expect(proposal.proteinG, 48);
    expect(proposal.estimatedGrams, 450);
    expect(proposal.ingredients, contains('Haehnchenbrust'));
    expect(proposal.imageBytes, same(bytes));
  });

  test('ohne Titel oder ohne kcal -> null (unbrauchbarer Vorschlag)', () {
    expect(
      CoachRecipeProposal.fromJson(_validJson()..remove('title')),
      isNull,
    );
    expect(
      CoachRecipeProposal.fromJson(_validJson()..remove('calories_kcal')),
      isNull,
    );
  });

  test('Defensiv-Klemme: estimated_g 0 wird nie uebernommen (Division!)', () {
    final proposal =
        CoachRecipeProposal.fromJson(_validJson()..['estimated_g'] = 0);
    expect(proposal, isNotNull);
    expect(proposal!.estimatedGrams, greaterThanOrEqualTo(1));
  });

  test('ChatMessage.fromRow baut das Proposal aus chat_messages.recipe '
      '(Reload-Karte, Nachtrag 2026-08-13)', () {
    final message = ChatMessage.fromRow(<String, dynamic>{
      'id': 'srv-1',
      'role': 'assistant',
      'content': 'Rezeptvorschlag: Huehnchenauflauf.',
      'refusal': false,
      'created_at': '2026-08-12T18:00:00Z',
      'recipe': _validJson(),
    });
    expect(message.recipeProposal, isNotNull);
    expect(message.recipeProposal!.title, 'Huehnchenauflauf');
    expect(message.recipeProposal!.imageBytes, isNull,
        reason: 'Bytes kommen nie aus der DB — nur aus dem lokalen Store');

    final ohne = ChatMessage.fromRow(<String, dynamic>{
      'role': 'assistant',
      'content': 'normale Antwort',
      'created_at': '2026-08-12T18:00:00Z',
    });
    expect(ohne.recipeProposal, isNull);
  });

  test('toFitnessRecipe baut ein Eigen-Rezept nach den Haus-Regeln', () {
    final recipe = CoachRecipeProposal.fromJson(_validJson())!
        .toFitnessRecipe(imageAsset: 'local:img_abc.jpg');

    expect(recipe.slug, startsWith('user_'));
    expect(recipe.userCreated, isTrue);
    expect(recipe.categories, const <String>['Eigene']);
    expect(recipe.title, 'Huehnchenauflauf');
    expect(recipe.description, 'Cremig und proteinreich.');
    expect(recipe.preparation, startsWith('1.'));
    expect(recipe.professionalHint, isEmpty,
        reason: 'user_recipes hat keine professional_hint-Spalte');
    expect(recipe.imageAsset, 'local:img_abc.jpg');
    expect(recipe.caloriesKcal, 520);
    expect(recipe.estimatedGrams, 450);
  });
}
