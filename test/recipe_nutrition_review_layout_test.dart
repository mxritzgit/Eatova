import 'dart:io';
import 'dart:ui' as ui;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(() async {
    for (final family in ['Figtree', 'BricolageGrotesque']) {
      final loader = FontLoader(family);
      for (final file in Directory(
        'assets/fonts',
      ).listSync().whereType<File>()) {
        if (file.uri.pathSegments.last.startsWith('$family-')) {
          loader.addFont(file.readAsBytes().then(ByteData.sublistView));
        }
      }
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final locale in ['de', 'en']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final name = '$locale-${brightness.name}-$scale';
        testWidgets('nutrition review stays reachable with real fonts: $name', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 568);
          tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
          addTearDown(tester.view.reset);
          late BuildContext context;
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('capture'),
              child: localizedApp(
                const SizedBox.expand(),
                locale: Locale(locale),
                brightness: brightness,
                textScale: scale,
                onContext: (value) => context = value,
              ),
            ),
          );
          await tester.pumpAndSettle();
          const candidate = RecipeImportCandidate(
            id: 'caption',
            title: 'Kaiserschmarrn',
            ingredients: '160 g Mehl',
            preparation: 'In der Pfanne backen.',
            servings: 2,
            caloriesKcal: 650,
            fatG: 20,
            nutritionBasisUnclear: true,
            nutritionConflicts: ['protein_g'],
          );
          final result = showRecipeNutritionDraftEditor(
            context: context,
            recipe: candidate.toRecipe(
              slug: candidate.stableSlug(),
              sourceLabel: 'Source',
            ),
            isSessionCurrent: () => true,
          );
          await tester.pumpAndSettle();
          final l10n = context.l10n;
          expect(
            find.textContaining(
              l10n.recipeNutritionConflictFields(l10n.todayMacroProtein),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('recipe-create-name')),
            findsNothing,
          );
          final save = find.byKey(const ValueKey('recipe-create-save'));
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          if (scale == 1 &&
              const bool.fromEnvironment('CAPTURE_NUTRITION_REVIEW')) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('build/nutrition-review/$name.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          for (final entry in {'protein': '47', 'carbs': '68'}.entries) {
            final input = find.byKey(ValueKey('recipe-create-${entry.key}'));
            await tester.ensureVisible(input);
            await tester.enterText(input, entry.value);
            await tester.pumpAndSettle();
          }
          final checkbox = find.descendant(
            of: find.byKey(
              const ValueKey('recipe-edit-confirm-nutrition-basis'),
            ),
            matching: find.byType(Checkbox),
          );
          await tester.ensureVisible(checkbox);
          await tester.pumpAndSettle();
          await tester.tap(checkbox);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('recipe-create-sheet')),
            findsNothing,
          );
          expect((await result)?.hasPendingNutrition, isFalse);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
