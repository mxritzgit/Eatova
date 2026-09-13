import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

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

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Finder _title(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is Text && widget.data == title && widget.style?.fontSize == 30,
);

void main() {
  setUpAll(_fonts);

  for (final locale in [const Locale('de'), const Locale('en')]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('tab titles share scale and origin ($locale, $scale)', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 760);
        addTearDown(tester.view.reset);
        await pumpLocalized(
          tester,
          EatovaHomePage(),
          locale: locale,
          textScale: scale,
          scaffold: false,
          safeArea: false,
        );
        await _frames(tester);
        final context = tester.element(find.byType(EatovaHomePage));
        final l10n = context.l10n;
        final labels = [
          l10n.navToday,
          l10n.navFood,
          l10n.navRecipes,
          l10n.trainingPageTitle,
          l10n.coachTitle,
        ];
        const nav = ['Heute', 'Food', 'Rezepte', 'Training', 'Coach'];
        final origin = tester.getTopLeft(_title(labels.first));
        for (var index = 0; index < labels.length; index++) {
          await tester.tap(find.byKey(ValueKey('nav-${nav[index]}')));
          await _frames(tester);
          final title = _title(labels[index]);
          expect(title, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(tester.getTopLeft(title), origin, reason: labels[index]);
          expect(find.byKey(const ValueKey('food-options')), findsNothing);
          expect(
            find.byKey(const ValueKey('today-profile')),
            index == 0 ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('today-settings')),
            index == 0 ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('Today opens the correct account routes and keeps tab drafts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await pumpLocalized(
      tester,
      EatovaHomePage(),
      scaffold: false,
      safeArea: false,
    );
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await _frames(tester);
    await tester.enterText(
      find.byKey(const ValueKey('recipes-search-input')),
      'Lachs',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await _frames(tester);
    for (final action in ['profile', 'settings']) {
      await tester.tap(find.byKey(ValueKey('today-$action')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('screen-$action')), findsOneWidget);
      final routeContext = tester.element(
        find.byKey(ValueKey('screen-$action')),
      );
      Navigator.of(routeContext).pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('today-settings')).hitTestable(),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await _frames(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('recipes-search-input')))
          .controller!
          .text,
      'Lachs',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('subpage aliases have identical readable titles at double text', (
    tester,
  ) async {
    for (final large in [false, true]) {
      await pumpLocalized(
        tester,
        PageHeader(
          title: large ? null : 'Einstellungen',
          large: large ? 'Einstellungen' : null,
          trailing: SquareIconButton(
            icon: Icons.settings_outlined,
            onTap: () {},
          ),
        ),
        surfaceSize: const Size(320, 568),
        textScale: 2,
      );
      final title = find.text('Einstellungen');
      expect(tester.widget<Text>(title).style?.fontSize, 24);
      final paragraph = tester.renderObject<RenderParagraph>(title);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 13),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
