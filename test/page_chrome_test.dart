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

/// The design phone's status bar height (iPhone, 390x844).
const double _statusBar = 47;

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
        // The design phone's status bar: the shell passes it on, and every
        // tab starts its header 15 px below it (62 px from the top).
        tester.view.padding = const FakeViewPadding(top: _statusBar);
        tester.view.viewPadding = const FakeViewPadding(top: _statusBar);
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
        for (var index = 0; index < labels.length; index++) {
          await tester.tap(find.byKey(ValueKey('nav-${nav[index]}')));
          await _frames(tester);
          final title = _title(labels[index]);
          expect(title, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          // Dark redesign: one title origin for every tab — the header row
          // starts at the 20 px gutter, 62 px from the top on the design's
          // phone (Today and Training carry a line above their title, so
          // the row, not the title text, shares the top).
          final header = find.byKey(TabChrome.headerKey);
          expect(header, findsOneWidget, reason: labels[index]);
          expect(
            tester.getTopLeft(header),
            const Offset(20, _statusBar + TabChrome.headerGap),
            reason: labels[index],
          );
          expect(tester.getTopLeft(title).dx, 20, reason: labels[index]);
          if (nav[index] == 'Food') {
            final button = tester.getRect(
              find.byKey(const ValueKey('food-date-calendar')),
            );
            expect(
              tester.getRect(title).center.dy,
              closeTo(button.center.dy, 1),
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

  testWidgets('tabs scroll under the status bar behind one scrim', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: _statusBar);
    tester.view.viewPadding = const FakeViewPadding(top: _statusBar);
    addTearDown(tester.view.reset);
    await pumpLocalized(
      tester,
      EatovaHomePage(),
      scaffold: false,
      safeArea: false,
    );
    await _frames(tester);
    // The scrim covers the status bar and fades out over the header gap, so
    // at rest it lies over empty page only; it never takes a tap.
    final scrim = find.byKey(const ValueKey('status-bar-scrim'));
    expect(
      tester.getRect(scrim),
      const Rect.fromLTWH(0, 0, 390, _statusBar + TabChrome.headerGap),
    );
    expect(
      find.ancestor(of: scrim, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
    const scrollables = <String, Key>{
      'Heute': ValueKey('screen-today'),
      'Food': ValueKey('food-diary-scroll'),
      'Rezepte': ValueKey('screen-recipes'),
      'Training': PageStorageKey('training-scroll'),
    };
    for (final MapEntry(key: nav, value: scrollKey) in scrollables.entries) {
      await tester.tap(find.byKey(ValueKey('nav-$nav')));
      await _frames(tester);
      // The viewport starts at the screen top (no top SafeArea in the
      // shell), so scrolled content passes under the status bar.
      expect(tester.getRect(find.byKey(scrollKey)).top, 0, reason: nav);
      final scrim = tester.getRect(
        find.byKey(const ValueKey('status-bar-scrim')),
      );
      final header = tester.getRect(find.byKey(TabChrome.headerKey));
      expect(header.top, greaterThanOrEqualTo(scrim.bottom), reason: nav);
    }
    expect(tester.takeException(), isNull);
  });

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
