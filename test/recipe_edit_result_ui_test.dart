import 'dart:async';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_save_result.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recipe_edit_feature_test.dart' show original, field;
import 'support/harness.dart';

Future<void> edit(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('recipe-detail-edit'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester, String title) async {
  await tester.enterText(field('name'), title);
  await tester.tap(field('save'));
  await tester.pumpAndSettle();
}

Future<void> showDetail(
  WidgetTester tester,
  Future<RecipeSaveResult> Function(FitnessRecipe) onEdit, {
  Future<bool> Function(String)? onHistory,
  ValueChanged<String>? onDelete,
}) => pumpLocalized(
  tester,
  RecipeDetailScreen(
    recipe: original,
    onAddMeal: (_, _) {},
    onEdit: onEdit,
    onOpenHistory: onHistory,
    onDelete: onDelete,
  ),
  locale: const Locale('en'),
  safeArea: false,
);

void main() {
  testWidgets(
    'second edit receives canonical copy identity and current revision',
    (tester) async {
      pinPhoneViewport(tester);
      final inputs = <FitnessRecipe>[];
      final handles = <RecipeSaveHandle>[];
      final histories = <String>[];
      await showDetail(
        tester,
        (recipe) async {
          inputs.add(recipe);
          final canonical = recipe.copyWith(
            slug: 'user_conflict_copy',
            serverRevision: 8 + inputs.length,
            conflictOf: original.slug,
          );
          final handle = RecipeSaveHandle(
            operationId: 'edit-${inputs.length}',
            initial: RecipeSaveState(
              recipe: canonical,
              pending: false,
              conflictSaved: true,
            ),
          );
          handles.add(handle);
          return RecipeSaveResult(
            delivery: SyncDelivery.delivered,
            handle: handle,
          );
        },
        onHistory: (slug) async {
          histories.add(slug);
          return false;
        },
      );
      await edit(tester);
      await save(tester, 'First');
      await edit(tester);
      await save(tester, 'Second');
      expect(inputs, hasLength(2));
      expect(inputs.last.slug, 'user_conflict_copy');
      expect(inputs.last.serverRevision, 9);
      expect(inputs.last.conflictOf, original.slug);
      expect(handles.first.isDisposed, isTrue);
      final history = find.byKey(const ValueKey('recipe-detail-history'));
      await tester.ensureVisible(history);
      await tester.tap(history);
      await tester.pumpAndSettle();
      expect(histories.single, 'user_conflict_copy');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(handles.last.isDisposed, isTrue);
    },
  );

  testWidgets(
    'ACK while a new editor is open does not raise its observed base',
    (tester) async {
      pinPhoneViewport(tester);
      final inputs = <FitnessRecipe>[];
      RecipeSaveHandle? pending;
      await showDetail(tester, (recipe) async {
        inputs.add(recipe);
        final result = RecipeSaveResult.detached(
          recipe,
          SyncDelivery.queuedOffline,
        );
        pending ??= result.handle;
        return result;
      });
      await edit(tester);
      await save(tester, 'Offline first');
      await edit(tester);
      pending!.publish(
        RecipeSaveState(
          recipe: original.copyWith(title: 'Server first', serverRevision: 8),
          pending: false,
        ),
      );
      await tester.pump();
      await save(tester, 'Already editing');
      expect(inputs.last.serverRevision, 7);
      expect(inputs.last.title, 'Already editing');
      expect(pending!.isDisposed, isTrue);
    },
  );

  testWidgets(
    'late resolution blocks stale actions and enables exact-copy actions',
    (tester) async {
      pinPhoneViewport(tester);
      late RecipeSaveHandle handle;
      var edits = 0;
      final histories = <String>[];
      await showDetail(
        tester,
        (recipe) async {
          edits++;
          final result = RecipeSaveResult.detached(
            recipe,
            SyncDelivery.queuedOffline,
          );
          handle = result.handle;
          return result;
        },
        onHistory: (slug) async {
          histories.add(slug);
          return false;
        },
      );
      await edit(tester);
      await save(tester, 'Waiting draft');
      handle.publish(
        RecipeSaveState(
          recipe: handle.value.recipe,
          pending: true,
          resolving: true,
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('recipe-detail-edit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('recipe-edit-refresh-result')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('recipe-detail-history')),
            )
            .onPressed,
        isNull,
      );
      handle.publish(
        const RecipeSaveState(
          recipe: null,
          targetSlug: 'user_deleted_copy',
          pending: false,
        ),
      );
      await tester.pump();
      expect(find.textContaining('no longer available'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('recipe-detail-edit')),
            )
            .onPressed,
        isNull,
      );
      final deletedHistory = find.byKey(
        const ValueKey('recipe-detail-history'),
      );
      await tester.ensureVisible(deletedHistory);
      await tester.tap(deletedHistory);
      await tester.pumpAndSettle();
      expect(histories.single, 'user_deleted_copy');
      handle.publish(
        RecipeSaveState(
          recipe: original.copyWith(
            slug: 'user_restored_copy',
            title: 'Resolved copy',
            serverRevision: 12,
          ),
          pending: false,
          conflictSaved: true,
        ),
      );
      await tester.pump();
      expect(find.text('Resolved copy'), findsOneWidget);
      final history = find.byKey(const ValueKey('recipe-detail-history'));
      await tester.ensureVisible(history);
      await tester.tap(history);
      await tester.pumpAndSettle();
      expect(histories.last, 'user_restored_copy');
      expect(edits, 1);
    },
  );

  testWidgets('late save result after route disposal releases its handle', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    final gate = Completer<RecipeSaveResult>();
    FitnessRecipe? submitted;
    await showDetail(tester, (recipe) {
      submitted = recipe;
      return gate.future;
    });
    await edit(tester);
    await tester.enterText(field('name'), 'Committing');
    await tester.tap(field('save'));
    await tester.pump();
    expect(submitted, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final result = RecipeSaveResult.detached(
      submitted!,
      SyncDelivery.delivered,
    );
    gate.complete(result);
    await tester.pump();
    expect(result.handle.isDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
