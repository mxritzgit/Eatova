import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';
import 'support/harness.dart';
import 'support/meal_slot_picker.dart';

Future<void> _fonts() async {
  for (final family in ['Archivo', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final weight
        in family == 'Archivo'
            ? ['Regular', 'Medium', 'SemiBold', 'Bold']
            : ['Bold', 'ExtraBold']) {
      loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
    }
    await loader.load();
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      testWidgets(
        'choices remain reachable with real fonts, keyboard and 2x text: $brightness $locale',
        (tester) async {
          await _fonts();
          tester.view.physicalSize = const Size(320, 852);
          tester.view.devicePixelRatio = 1;
          tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(tester.view.reset);
          var selected = MealSlot.lunch;
          final choices = <MealSlot>[];
          final semantics = tester.ensureSemantics();
          await pumpLocalized(
            tester,
            StatefulBuilder(
              builder: (context, setState) => MealSlotPicker(
                selected: selected,
                onSelected: (slot) => setState(() {
                  selected = slot;
                  choices.add(slot);
                }),
              ),
            ),
            brightness: brightness,
            locale: locale,
            textScale: 2,
          );
          final trigger = find.byKey(const ValueKey('slot-select-open'));
          expect(tester.getSize(trigger).height, greaterThanOrEqualTo(48));
          expect(find.byKey(const ValueKey('slot-select-lunch')), findsNothing);
          final node = tester.getSemantics(trigger);
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          tester.semantics.performAction(
            find.semantics.byLabel(node.getSemanticsData().label),
            SemanticsAction.tap,
          );
          await tester.pumpAndSettle();
          final sheet = find.byKey(const ValueKey('slot-select-sheet'));
          expect(tester.getRect(sheet).top, greaterThanOrEqualTo(44));
          expect(tester.getRect(sheet).bottom, lessThanOrEqualTo(552));
          for (final slot in MealSlot.values) {
            final row = find.byKey(ValueKey('slot-select-${slot.name}'));
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            expect(row.hitTestable(), findsOneWidget);
            expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
            final title = find
                .descendant(of: row, matching: find.byType(Text))
                .first;
            final paragraph = tester.renderObject<RenderParagraph>(title);
            final label = tester.widget<Text>(title).data!;
            expect(
              paragraph.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: label.length),
              ),
              hasLength(1),
              reason: 'A meal name should not split mid-word.',
            );
            final selectedSemantics = tester.widget<Semantics>(
              find.ancestor(of: row, matching: find.byType(Semantics)).first,
            );
            expect(selectedSemantics.properties.selected, slot == selected);
            for (final label
                in find
                    .descendant(of: row, matching: find.byType(Text))
                    .evaluate()) {
              final bounds = tester.getRect(find.byWidget(label.widget));
              expect(
                bounds.right,
                lessThanOrEqualTo(tester.getRect(row).right),
              );
              expect(
                bounds.bottom,
                lessThanOrEqualTo(tester.getRect(row).bottom),
              );
            }
          }
          await tester.tap(find.byKey(const ValueKey('slot-select-close')));
          await tester.pumpAndSettle();
          expect(choices, isEmpty);
          expect(
            tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
            MealSlot.lunch,
          );
          await chooseMealSlot(tester, 'slot-select-snack');
          expect(choices, [MealSlot.snack]);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('barrier dismissal preserves the slot and an input draft', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Skyr Natur');
    addTearDown(controller.dispose);
    var calls = 0;
    await pumpLocalized(
      tester,
      Column(
        children: [
          TextField(controller: controller),
          MealSlotPicker(selected: MealSlot.dinner, onSelected: (_) => calls++),
        ],
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('slot-select-open')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slot-select-sheet')), findsNothing);
    expect(controller.text, 'Skyr Natur');
    expect(calls, 0);
    expect(
      tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
      MealSlot.dinner,
    );
  });

  testWidgets('a removed owner cannot receive a late choice', (tester) async {
    var show = true;
    var calls = 0;
    late StateSetter update;
    await pumpLocalized(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return show
              ? MealSlotPicker(
                  selected: MealSlot.lunch,
                  onSelected: (_) => calls++,
                )
              : const SizedBox.shrink();
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('slot-select-open')));
    await tester.pumpAndSettle();
    update(() => show = false);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('slot-select-snack')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
