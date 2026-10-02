import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';
import 'support/harness.dart';
import 'support/meal_slot_picker.dart';

Future<void> _fonts() async {
  for (final family in ['Figtree', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final weight
        in family == 'Figtree'
            ? ['Regular', 'Medium', 'SemiBold', 'Bold']
            : ['Bold', 'ExtraBold']) {
      loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
    }
    await loader.load();
  }
}

Finder _slot(MealSlot slot) => find.byKey(ValueKey('slot-select-${slot.name}'));

void main() {
  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'all four slots stay reachable inline with real fonts: '
          '$brightness $locale x$scale',
          (tester) async {
            await _fonts();
            tester.view.physicalSize = const Size(320, 852);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            var selected = MealSlot.lunch;
            final choices = <MealSlot>[];
            final semantics = tester.ensureSemantics();
            await pumpLocalized(
              tester,
              Padding(
                padding: const EdgeInsets.all(16),
                child: StatefulBuilder(
                  builder: (context, setState) => MealSlotPicker(
                    selected: selected,
                    onSelected: (slot) => setState(() {
                      selected = slot;
                      choices.add(slot);
                    }),
                  ),
                ),
              ),
              brightness: brightness,
              locale: locale,
              textScale: scale,
            );
            final group = find.byKey(const ValueKey('slot-select-group'));
            final bounds = tester.getRect(group);
            for (final slot in MealSlot.values) {
              final segment = _slot(slot);
              expect(segment.hitTestable(), findsOneWidget);
              final rect = tester.getRect(segment);
              expect(rect.height, greaterThanOrEqualTo(48));
              expect(rect.width, greaterThanOrEqualTo(48));
              // Inside the track's padding, never under its edge.
              expect(bounds.deflate(4).contains(rect.topLeft), isTrue);
              expect(
                bounds.deflate(4).contains(
                  rect.bottomRight - const Offset(0.01, 0.01),
                ),
                isTrue,
              );
              final title =
                  find.descendant(of: segment, matching: find.byType(Text));
              final paragraph = tester.renderObject<RenderParagraph>(title);
              final label = tester.widget<Text>(title).data!;
              expect(
                paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: label.length),
                ),
                hasLength(1),
                reason: 'A meal name should not split mid-word.',
              );
              // One line without wrapping: the full text width must fit.
              expect(
                paragraph.getMaxIntrinsicWidth(double.infinity),
                lessThanOrEqualTo(paragraph.size.width + 0.5),
                reason: '$label must fit its segment',
              );
              expect(
                tester.getSemantics(segment),
                isSemantics(
                  isButton: true,
                  isSelected: slot == selected,
                  isInMutuallyExclusiveGroup: true,
                  hasTapAction: true,
                ),
              );
            }
            // Tapping the current slot is no choice.
            await tester.tap(_slot(MealSlot.lunch));
            await tester.pump();
            expect(choices, isEmpty);
            await chooseMealSlot(tester, 'slot-select-snack');
            expect(choices, [MealSlot.snack]);
            expect(
              tester.getSemantics(_slot(MealSlot.snack)),
              isSemantics(isSelected: true),
            );
            expect(
              tester.getSemantics(_slot(MealSlot.lunch)),
              isSemantics(isSelected: false),
            );
            expect(tester.takeException(), isNull);
            semantics.dispose();
          },
        );
      }
    }
  }

  testWidgets('the slot names are spoken in full inside a named group', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLocalized(
      tester,
      MealSlotPicker(selected: MealSlot.dinner, onSelected: (_) {}),
      surfaceSize: const Size(390, 400),
    );
    // On a phone, German short labels ("Mittag") stay visual; the full name is read.
    expect(find.text('Mittag'), findsOneWidget);
    expect(find.bySemanticsLabel('Mittagessen'), findsOneWidget);
    expect(find.bySemanticsLabel('Mahlzeit wählen'), findsOneWidget);
    semantics.dispose();
  });

  for (final reduced in [true, false]) {
    testWidgets('the selection pill slides, or jumps under reduced motion: '
        '$reduced', (tester) async {
      var selected = MealSlot.breakfast;
      await pumpLocalized(
        tester,
        Padding(
          padding: const EdgeInsets.all(16),
          child: StatefulBuilder(
            builder: (context, setState) => MealSlotPicker(
              selected: selected,
              onSelected: (slot) => setState(() => selected = slot),
            ),
          ),
        ),
        reducedMotion: reduced,
        surfaceSize: const Size(390, 400),
      );
      final pill = find.byKey(const ValueKey('slot-select-indicator'));
      double pillCenter() => tester.getCenter(pill).dx;
      expect(pillCenter(), tester.getCenter(_slot(MealSlot.breakfast)).dx);
      await tester.tap(_slot(MealSlot.snack));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final target = tester.getCenter(_slot(MealSlot.snack)).dx;
      if (reduced) {
        expect(pillCenter(), target);
      } else {
        expect(pillCenter(), lessThan(target));
        expect(
          pillCenter(),
          greaterThan(tester.getCenter(_slot(MealSlot.breakfast)).dx),
        );
      }
      await tester.pumpAndSettle();
      expect(pillCenter(), target);
    });
  }
}
