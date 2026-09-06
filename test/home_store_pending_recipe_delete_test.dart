// Bug 2026-09-02: delete a recipe in the recipes tab, switch to the coach at
// once — the card still said "Hinzugefügt" until the undo toast was gone. The
// recipes tab keeps the row inside its undo window (so undo needs no upsert),
// but every OTHER reader has to treat it as gone. The store now carries the
// pending set; the coach reads `visibleUserRecipes`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

FitnessRecipe _rezept(String slug) => FitnessRecipe(
      slug: slug,
      title: 'Bowl $slug',
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

HomeStore _store() => HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _noopSnack,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('schwebende Löschung: userRecipes behält die Zeile, visibleUserRecipes '
      'nicht', () async {
    final s = _store();
    addTearDown(s.dispose);
    await s.createUserRecipe(_rezept('user_coach_a'));
    await s.createUserRecipe(_rezept('user_coach_b'));

    var notifications = 0;
    s.addListener(() => notifications++);

    s.setRecipeDeletePending('user_coach_a', pending: true);

    expect(notifications, 1);
    expect(s.pendingRecipeDeletes, {'user_coach_a'});
    expect(s.userRecipes.map((r) => r.slug), ['user_coach_b', 'user_coach_a'],
        reason: 'die Zeile bleibt bis zum Commit im Store');
    expect(s.visibleUserRecipes.map((r) => r.slug), ['user_coach_b'],
        reason: 'aus Nutzersicht ist das Rezept schon weg');
  });

  test('idempotent: dieselbe Meldung zweimal löst keinen zweiten Notify aus',
      () async {
    final s = _store();
    addTearDown(s.dispose);
    await s.createUserRecipe(_rezept('user_coach_a'));
    var notifications = 0;
    s.addListener(() => notifications++);

    s.setRecipeDeletePending('user_coach_a', pending: true);
    s.setRecipeDeletePending('user_coach_a', pending: true);
    expect(notifications, 1);

    s.setRecipeDeletePending('user_coach_a', pending: false);
    s.setRecipeDeletePending('user_coach_a', pending: false);
    expect(notifications, 2);
    expect(s.pendingRecipeDeletes, isEmpty);
    expect(s.visibleUserRecipes.map((r) => r.slug), ['user_coach_a'],
        reason: 'Undo: das Rezept ist wieder sichtbar');
  });

  test('jede Änderung liefert eine NEUE Set-Instanz — die Tab-Selektoren '
      'vergleichen mit !=', () async {
    final s = _store();
    addTearDown(s.dispose);
    await s.createUserRecipe(_rezept('user_coach_a'));

    final vorher = s.pendingRecipeDeletes;
    s.setRecipeDeletePending('user_coach_a', pending: true);
    final dazwischen = s.pendingRecipeDeletes;
    s.setRecipeDeletePending('user_coach_a', pending: false);
    final nachher = s.pendingRecipeDeletes;

    expect(identical(vorher, dazwischen), isFalse);
    expect(identical(dazwischen, nachher), isFalse);
    expect(vorher, isEmpty, reason: 'das alte Set wurde nicht mutiert');
  });

  test('der echte Delete räumt die Markierung mit der Zeile ab', () async {
    final s = _store();
    addTearDown(s.dispose);
    await s.createUserRecipe(_rezept('user_coach_a'));
    s.setRecipeDeletePending('user_coach_a', pending: true);

    await s.deleteUserRecipe('user_coach_a');

    expect(s.userRecipes, isEmpty);
    expect(s.pendingRecipeDeletes, isEmpty,
        reason: 'sonst sammelt das Set tote Slugs');
    expect(s.visibleUserRecipes, isEmpty);
  });

  test('ohne schwebende Löschung ist visibleUserRecipes dieselbe Liste',
      () async {
    final s = _store();
    addTearDown(s.dispose);
    await s.createUserRecipe(_rezept('user_coach_a'));
    expect(identical(s.visibleUserRecipes, s.userRecipes), isTrue,
        reason: 'kein Kopieren im Normalfall');
  });
}
