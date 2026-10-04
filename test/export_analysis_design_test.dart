import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/widgets/design/design.dart' show PrimaryActionButton;
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/shared/data_export_sheet.dart';

import 'support/harness.dart';

const _meal = MealAnalysisResult(
  mealName: 'Lachs-Bowl mit Avocado',
  caloriesKcal: 584,
  estimatedGrams: 420,
  kcalPer100G: 139,
  protein: '34 g',
  carbs: '62 g',
  fat: '22 g',
  confidence: 'medium',
  portionNotes: 'Eine Schale mit Reis und Gemüse.',
  sourceLabel: 'photoAi',
  items: [
    MealComponent(name: 'Lachs', grams: 120, caloriesKcal: 240),
    MealComponent(name: 'Reis', grams: 160, caloriesKcal: 208),
    MealComponent(name: 'Avocado & Gemüse', grams: 140, caloriesKcal: 136),
  ],
);

String _export() => jsonEncode({
  'format': DataExportService.formatKennung,
  'exportedAt': '2026-09-26T12:00:00Z',
  'userId': 'demo-account',
  for (final table in DataExportService.alleExportTabellen) table: <dynamic>[],
  'profiles': [
    {'display_name': 'Alex', 'daily_kcal_goal': 2200},
  ],
  'logged_meals': List.generate(
    7,
    (i) => {
      'id': 'meal-$i',
      'logged_at': '2026-09-${10 + i}T12:00:00Z',
      'payload': {'mealName': 'Bowl $i', 'kcal': 500 + i},
    },
  ),
});

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

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_UI')) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/export-analysis/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  void viewport(WidgetTester tester, double width) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
    addTearDown(tester.view.reset);
  }

  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      for (final scale in [1.0, 2.0]) {
        final name = '${brightness.name}-${locale.languageCode}-$scale';
        testWidgets(
          'analysis real fonts, photo, actions and large text: $name',
          (tester) async {
            viewport(tester, scale == 1 ? 390 : 320);
            var added = 0;
            var favorites = 0;
            await tester.pumpWidget(
              RepaintBoundary(
                key: const ValueKey('capture'),
                child: localizedApp(
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showMealAnalysisSheet(
                        context,
                        slot: MealSlot.lunch,
                        resultFuture: Future.value(_meal),
                        previewImage: File(
                          'assets/recipes/lachs_poke_bowl.jpg',
                        ).readAsBytesSync(),
                        onAdd: (result, slot) {
                          added++;
                          return 'meal-id';
                        },
                        onUpdateMeal: (_, _) {},
                        failureMessage: 'Unavailable',
                        onToggleFavorite: (_) => favorites++,
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                  brightness: brightness,
                  locale: locale,
                  textScale: scale,
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            final photo = find.descendant(
              of: find.byType(MealAnalysisSheet),
              matching: find.byType(Image),
            );
            await tester.runAsync(
              () => precacheImage(
                tester.widget<Image>(photo).image,
                tester.element(photo),
              ),
            );
            await tester.pumpAndSettle();
            await capture(tester, 'analysis-$name');
            expect(tester.takeException(), isNull);
            final add = find.byKey(const ValueKey('analyse-add-daily-button'));
            if (scale == 1) expect(add.hitTestable(), findsOneWidget);
            await tester.ensureVisible(add);
            await tester.pumpAndSettle();
            await tester.tap(add);
            await tester.pumpAndSettle();
            expect(added, 1);
            expect(tester.widget<PrimaryActionButton>(add).onTap, isNull);
            final favorite = find.byKey(
              const ValueKey('analyse-favorite-button'),
            );
            await tester.ensureVisible(favorite);
            await tester.pumpAndSettle();
            await tester.tap(favorite);
            await tester.pumpAndSettle();
            expect(favorites, 1);
            await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets('export real fonts and extractable sections: $name', (
          tester,
        ) async {
          viewport(tester, scale == 1 ? 390 : 320);
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = call.arguments['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('capture'),
              child: localizedApp(
                DataExportSheet(
                  snapshot: Future.value(_export()),
                ),
                brightness: brightness,
                locale: locale,
                textScale: scale,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await capture(tester, 'export-$name');
          final copy = find.byKey(const ValueKey('profile-export-copy'));
          await tester.scrollUntilVisible(copy, 200);
          await tester.pumpAndSettle();
          await tester.tap(copy);
          await tester.pumpAndSettle();
          expect(copied, contains('Bowl 0'));
          expect(copied, contains('Bowl 6'));
          expect(copied, isNot(startsWith('{')));
          final section = find.byKey(
            const ValueKey('export-expand-logged_meals'),
          );
          await tester.scrollUntilVisible(section, 200);
          // Clear of the copy snack at the sheet's foot.
          await Scrollable.ensureVisible(
            tester.element(section),
            alignment: 0.3,
          );
          await tester.pumpAndSettle();
          await tester.tap(section);
          await tester.pumpAndSettle();
          final csv = find.byKey(const ValueKey('export-csv-logged_meals'));
          await tester.ensureVisible(csv);
          await tester.pumpAndSettle();
          await tester.tap(csv);
          await tester.pumpAndSettle();
          expect(copied, contains('"/payload/mealName"'));
          expect(copied, contains('Bowl 0'));
          expect(copied, contains('Bowl 6'));
          expect(
            copied!.indexOf('Bowl 6'),
            lessThan(copied!.indexOf('Bowl 0')),
          );
          expect(find.text('Bowl 6'), findsOneWidget);
          expect(find.text('Bowl 0'), findsNothing);
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
          await capture(tester, 'export-section-$name');
          final next = find.byKey(const ValueKey('export-next-logged_meals'));
          await tester.ensureVisible(next);
          await tester.pumpAndSettle();
          await tester.tap(next);
          await tester.pumpAndSettle();
          expect(find.text('Bowl 3'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets(
    'loading disables copying; unknown format never claims completeness',
    (tester) async {
      final pending = Completer<String>();
      await pumpLocalized(
        tester,
        DataExportSheet(
          snapshot: pending.future,
        ),
      );
      final copy = find.descendant(
        of: find.byKey(const ValueKey('profile-export-copy')),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(copy).onTap, isNull);
      pending.complete('{"legacy": []}');
      await tester.pumpAndSettle();
      expect(find.text(deL10n.exportUnverified), findsOneWidget);
      expect(find.text(deL10n.exportSheetFullSubtitle), findsNothing);
    },
  );
}
