import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

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

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Finder _title(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == title &&
      widget.style?.fontSize == AppType.pageTitle(const Color(0xFF000000)).fontSize,
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
          // Visible "Coach"; "AI Coach" is its semantics label.
          l10n.navCoach,
        ];
        const nav = ['Heute', 'Food', 'Rezepte', 'Training', 'Coach'];
        final origin = tester.getTopLeft(_title(labels.first));
        double? recipesTop;
        for (var index = 0; index < labels.length; index++) {
          await tester.tap(find.byKey(ValueKey('nav-${nav[index]}')));
          await _frames(tester);
          final title = _title(labels[index]);
          expect(title, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          // Dark redesign (2026-09-28): a redesigned tab sets its title in
          // the design's header row. All tabs share the 20 px gutter; Today
          // and Training carry a line above their title, so only tabs still
          // on the old header also share the top with each other.
          expect(tester.getTopLeft(title).dx, origin.dx, reason: labels[index]);
          if (nav[index] == 'Food') {
            final button = tester.getRect(
              find.byKey(const ValueKey('food-date-calendar')),
            );
            final rect = tester.getRect(title);
            expect(
              rect.top < button.top ? rect.top : button.top,
              15,
              reason: labels[index],
            );
            expect(rect.center.dy, closeTo(button.center.dy, 1));
          } else if (nav[index] == 'Rezepte') {
            recipesTop = tester.getTopLeft(title).dy;
          } else if (nav[index] == 'Coach') {
            // Recipes and Coach still share the old header's title top.
            expect(
              tester.getTopLeft(title).dy,
              recipesTop,
              reason: labels[index],
            );
          }
          expect(find.byKey(const ValueKey('food-options')), findsNothing);
          expect(
            find.byKey(const ValueKey('today-profile')),
            index == 0 ? findsOneWidget : findsNothing,
          );
          // Settings moved behind the avatar (profile page) in the redesign.
          expect(find.byKey(const ValueKey('today-settings')), findsNothing);
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
    // The avatar opens the profile; its gear opens the settings the old
    // header linked directly.
    await tester.tap(find.byKey(const ValueKey('today-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    for (final route in ['settings', 'profile']) {
      final routeContext = tester.element(
        find.byKey(ValueKey('screen-$route')),
      );
      Navigator.of(routeContext).pop();
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('today-profile')).hitTestable(),
      findsOneWidget,
    );
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
