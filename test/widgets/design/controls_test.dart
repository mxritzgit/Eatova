import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/controls.dart';
import 'package:eatova/src/widgets/design/app_icon.dart';

import 'design_harness.dart';

const List<AppNavItem> _navItems = <AppNavItem>[
  AppNavItem(
    icon: AppSymbol.food,
    label: 'Food',
  ),
  AppNavItem(
    icon: AppSymbol.recipes,
    label: 'Rezepte',
  ),
  AppNavItem(
    icon: AppSymbol.coach,
    label: 'Coach',
  ),
];

/// The nav bar where the shell mounts it: a floating bottom bar over an
/// extended body, in the dark app theme.
Widget _navShell(Widget nav, {Widget? body}) => MaterialApp(
  theme: buildEatovaTheme(Brightness.dark),
  home: Scaffold(
    extendBody: true,
    body: KeyedSubtree(
      key: const ValueKey('nav-body'),
      child: body ?? const SizedBox.expand(),
    ),
    bottomNavigationBar: nav,
  ),
);

void main() {
  group('SquareIconButton', () {
    testWidgets('Tap ruft onTap und die Semantik traegt das Label',
        (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        designHarness(
          SquareIconButton(
            icon: Icons.chevron_left_rounded,
            onTap: () => taps++,
            semanticLabel: 'Zurueck',
          ),
        ),
      );

      await tester.tap(find.byType(SquareIconButton));
      expect(taps, 1);
      expect(
        tester.getSemantics(find.byType(SquareIconButton)),
        isSemantics(label: 'Zurueck', isButton: true),
      );
      // The visible chip is 34 px, the hit area 44. Shrinking the SizedBox to
      // the drawn size passed every test in this file — back, close and menu
      // buttons sit on almost every screen, so the floor belongs here and not
      // only on the nav bar.
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
    });
  });

  group('IconTile', () {
    testWidgets('ohne Farbe faellt die Kachel auf t.tile zurueck',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const IconTile(icon: Icons.bolt_rounded)),
      );

      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
      expect(
        decorationOf(tester, find.byType(IconTile)).color,
        AppTokens.light.tile,
      );
    });

    testWidgets('mit Farbe wird die Kachel getoent', (tester) async {
      await tester.pumpWidget(
        designHarness(
          IconTile(icon: Icons.bolt_rounded, color: AppTokens.light.protein),
        ),
      );

      expect(
        decorationOf(tester, find.byType(IconTile)).color,
        AppTokens.light.protein.withValues(alpha: 0.15),
      );
    });
  });

  group('AppToggle', () {
    testWidgets('Tap meldet den invertierten Wert', (tester) async {
      bool? received;
      await tester.pumpWidget(
        designHarness(
          AppToggle(value: false, onChanged: (v) => received = v),
        ),
      );

      await tester.tap(find.byType(AppToggle));
      expect(received, isTrue);

      await tester.pumpWidget(
        designHarness(AppToggle(value: true, onChanged: (v) => received = v)),
      );
      await tester.tap(find.byType(AppToggle));
      expect(received, isFalse);
    });

    testWidgets('enabled:false schluckt den Tap und daempft die Deckkraft',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        designHarness(
          AppToggle(value: true, enabled: false, onChanged: (_) => calls++),
        ),
      );

      await tester.tap(find.byType(AppToggle), warnIfMissed: false);
      expect(calls, 0);

      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(AppToggle),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1.0));
    });

    testWidgets('Semantik meldet den Schaltzustand', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        designHarness(AppToggle(value: true, onChanged: (_) {})),
      );
      expect(
        tester.getSemantics(find.byType(AppToggle)),
        isSemantics(isToggled: true),
      );

      await tester.pumpWidget(
        designHarness(AppToggle(value: false, onChanged: (_) {})),
      );
      expect(
        tester.getSemantics(find.byType(AppToggle)),
        isSemantics(isToggled: false),
      );
      handle.dispose();
    });
  });

  group('FilterChipPill', () {
    testWidgets('Tap ruft onTap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        designHarness(
          Align(
            child: FilterChipPill(
              label: 'Fruehstueck',
              selected: false,
              onTap: () => taps++,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(FilterChipPill));
      expect(taps, 1);
    });

    testWidgets('ausgewaehlt wechselt die Flaeche auf die Akzentfuellung',
        (tester) async {
      Material materialOf() => tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(FilterChipPill),
                  matching: find.byType(Material),
                )
                .first,
          );

      await tester.pumpWidget(
        designHarness(
          const Align(
            child: FilterChipPill(label: 'Alle', selected: false),
          ),
        ),
      );
      expect(materialOf().color, AppTokens.light.surf);

      await tester.pumpWidget(
        designHarness(
          const Align(
            child: FilterChipPill(label: 'Alle', selected: true),
          ),
        ),
      );
      expect(materialOf().color, AppTokens.light.accentFill);
    });

    testWidgets('folgt dem Design: 44 px Pille, 14/700, Akzent vs. Karte',
        (tester) async {
      const t = AppTokens.dark;
      Future<void> pump({required bool selected}) => tester.pumpWidget(
            designHarness(
              Align(child: FilterChipPill(label: 'Alle', selected: selected)),
              brightness: Brightness.dark,
            ),
          );
      BoxDecoration ring() => tester
          .widget<Container>(
            find
                .descendant(
                  of: find.byType(FilterChipPill),
                  matching: find.byType(Container),
                )
                .first,
          )
          .decoration! as BoxDecoration;
      Color fill() => tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(FilterChipPill),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color!;
      TextStyle label() => tester.widget<Text>(find.text('Alle')).style!;

      await pump(selected: false);
      // 44 px since 2026-10-03: the pill is its own tap target.
      expect(tester.getSize(find.byType(FilterChipPill)).height, 44);
      expect(fill(), t.surf);
      expect(ring().border, Border.all(color: t.lineStrong));
      expect(ring().borderRadius, BorderRadius.circular(rPill));
      expect(label().color, t.inkMuted);
      expect(label().fontSize, 14);
      expect(label().fontWeight, FontWeight.w700);

      await pump(selected: true);
      expect(fill(), t.accentFill);
      expect(ring().border, Border.all(color: t.accentFill));
      expect(label().color, t.onAccentFill);
      expect(label().fontWeight, FontWeight.w700);
    });
  });

  group('HeaderIconButton', () {
    Material materialOf(WidgetTester tester) => tester.widget<Material>(
          find
              .descendant(
                of: find.byType(HeaderIconButton),
                matching: find.byType(Material),
              )
              .first,
        );

    testWidgets('neutral: 44-px-Kreis, Karte mit Umriss, inkMuted-Glyphe',
        (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        designHarness(
          Align(
            child: HeaderIconButton(
              icon: Icons.calendar_today_rounded,
              semanticLabel: 'Kalender',
              onTap: () => taps++,
            ),
          ),
          brightness: Brightness.dark,
        ),
      );
      const t = AppTokens.dark;

      expect(tester.getSize(find.byType(HeaderIconButton)), const Size(44, 44));
      final material = materialOf(tester);
      expect(material.color, t.surf);
      expect(material.shape, CircleBorder(side: BorderSide(color: t.lineStrong)));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.calendar_today_rounded)).color ??
            IconTheme.of(
              tester.element(find.byIcon(Icons.calendar_today_rounded)),
            ).color,
        t.inkMuted,
      );
      expect(
        tester.getSemantics(find.byType(HeaderIconButton)),
        isSemantics(isButton: true, label: 'Kalender', hasTapAction: true),
      );
      await tester.tap(find.byType(HeaderIconButton));
      expect(taps, 1);
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('primary: Akzentfuellung, on-accent-Glyphe, kein Umriss',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          Align(
            child: HeaderIconButton(
              icon: Icons.add_rounded,
              semanticLabel: 'Neu',
              tone: HeaderIconTone.primary,
              onTap: () {},
            ),
          ),
          brightness: Brightness.dark,
        ),
      );
      const t = AppTokens.dark;

      final material = materialOf(tester);
      expect(material.color, t.accentFill);
      expect(material.shape, const CircleBorder());
      expect(
        IconTheme.of(tester.element(find.byIcon(Icons.add_rounded))).color,
        t.onAccentFill,
      );
    });
  });

  group('PrimaryActionButton', () {
    testWidgets('zeigt Label und Icon und meldet den Tap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        designHarness(
          PrimaryActionButton(
            label: 'Essen eintragen',
            icon: Icons.add_rounded,
            onTap: () => taps++,
          ),
        ),
      );

      expect(find.text('Essen eintragen'), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      await tester.tap(find.byType(PrimaryActionButton));
      expect(taps, 1);
    });

    testWidgets('destructive faerbt die Flaeche auf danger', (tester) async {
      Material materialOf() => tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(PrimaryActionButton),
                  matching: find.byType(Material),
                )
                .first,
          );

      // With a handler: without one the button draws its disabled fill
      // (alpha 0.38), and this test is about the fill hue.
      await tester.pumpWidget(
        designHarness(PrimaryActionButton(label: 'Speichern', onTap: () {})),
      );
      // Dark redesign: the primary action is the accent pill, label 800.
      expect(materialOf().color, AppTokens.light.accentFill);
      final label = tester.widget<Text>(find.text('Speichern')).style!;
      expect(label.color, AppTokens.light.onAccentFill);
      expect(label.fontWeight, FontWeight.w800);
      expect(materialOf().borderRadius, BorderRadius.circular(rButton));

      await tester.pumpWidget(
        designHarness(
          PrimaryActionButton(
            label: 'Loeschen',
            destructive: true,
            onTap: () {},
          ),
        ),
      );
      expect(materialOf().color, AppTokens.light.danger);
    });
  });

  group('AppNavBar', () {
    testWidgets('jedes Item traegt seinen nav-Key und meldet seinen Index',
        (tester) async {
      var picked = -1;
      await tester.pumpWidget(
        designHarness(
          AppNavBar(
            index: 0,
            onChanged: (i) => picked = i,
            items: _navItems,
          ),
        ),
      );

      expect(find.byKey(const ValueKey<String>('nav-Food')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-Rezepte')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-Coach')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('nav-Coach')));
      expect(picked, 2);

      await tester.tap(find.byKey(const ValueKey<String>('nav-Rezepte')));
      expect(picked, 1);
    });

    testWidgets('das aktive Item ist als selected ausgezeichnet',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        designHarness(
          AppNavBar(index: 1, onChanged: (_) {}, items: _navItems),
        ),
      );

      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('nav-Rezepte'))),
        isSemantics(isSelected: true, label: 'Rezepte'),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey<String>('nav-Food'))),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('das aktive Item zeigt das gefuellte Icon', (tester) async {
      await tester.pumpWidget(
        designHarness(
          AppNavBar(index: 0, onChanged: (_) {}, items: _navItems),
        ),
      );

      final icons = tester.widgetList<AppIcon>(find.byType(AppIcon));
      expect(icons.singleWhere((icon) => icon.symbol == AppSymbol.food).selected,
          isTrue);
      expect(icons.singleWhere((icon) => icon.symbol == AppSymbol.recipes).selected,
          isFalse);
    });

    testWidgets('englische Labels, aber die Keys bleiben deutsch',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          AppNavBar(
            index: 0,
            onChanged: (_) {},
            items: const <AppNavItem>[
              AppNavItem(
                icon: AppSymbol.food,
                label: 'Recipes',
                keyId: 'Rezepte',
              ),
            ],
          ),
          locale: const Locale('en'),
        ),
      );

      // DESIGN_REFACTOR §6: the key is API and stays German even when the
      // visible label is translated.
      expect(find.byKey(const ValueKey<String>('nav-Rezepte')), findsOneWidget);
      expect(find.text('Recipes'), findsOneWidget);
    });

    testWidgets('iPhone: 68-px-Glasleiste 14 px vom Rand und 22 px ueber '
        'der Bildschirmkante, der Home-Indikator liegt darunter',
        (tester) async {
      pinIphone14Pro(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _navShell(AppNavBar(index: 0, onChanged: (_) {}, items: _navItems)),
      );

      final glass = tester.getRect(find.byKey(const ValueKey('nav-glass')));
      expect(glass.left, 14);
      expect(glass.right, 390 - 14);
      expect(glass.height, 68);
      // 22 px from the SCREEN edge: the 34 px home-indicator inset is only a
      // gesture strip, the design lets the bar reach into it.
      expect(glass.bottom, 844 - 22);
      expect(AppNavBar.bottomOffsetFor(34), 22);
      // The body runs under the bar and receives the band (offset, bar,
      // 12 px clearance) as padding: scroll ends and docks sit on top of it.
      expect(AppNavBar.reservedHeightFor(34), 22 + 68 + 12);
      expect(tester.getSize(find.byType(AppNavBar)).height, 22 + 68 + 12);
      final body = tester.element(find.byKey(const ValueKey('nav-body')));
      expect(MediaQuery.paddingOf(body).bottom, 22 + 68 + 12);
      expect(tester.getRect(find.byKey(const ValueKey('nav-body'))).bottom,
          844, reason: 'content scrolls under the bar, down to the edge');

      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
    });

    // Final review B-M1: the design's fade is 112 px from the screen edge,
    // 10 px more than the band; over a docked tab it ends at the dock line.
    testWidgets('der Verlauf ist 112 px hoch wie im Design, ueber einem Dock '
        'endet er an dessen Linie', (tester) async {
      pinIphone14Pro(tester);
      for (final (docked, top) in [(false, 844 - 112.0), (true, 844 - 102.0)]) {
        await tester.pumpWidget(
          _navShell(
            AppNavBar(
              index: 0,
              onChanged: (_) {},
              items: _navItems,
              docked: docked,
            ),
          ),
        );
        final fade = tester.getRect(find.byKey(const ValueKey('nav-fade')));
        expect(fade.top, top, reason: 'docked: $docked');
        expect(fade.bottom, 844);
        expect(
          tester.getSize(find.byType(AppNavBar)).height,
          22 + 68 + 12,
          reason: 'the claimed band stays the same',
        );
      }
    });

    testWidgets('Android-Gestenleiste (24 px): ebenfalls 22 px ueber der Kante',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _navShell(AppNavBar(index: 0, onChanged: (_) {}, items: _navItems)),
      );

      final glass = tester.getRect(find.byKey(const ValueKey('nav-glass')));
      expect(glass.bottom, 915 - 22);
      final body = tester.element(find.byKey(const ValueKey('nav-body')));
      expect(MediaQuery.paddingOf(body).bottom, 22 + 68 + 12);
    });

    testWidgets('Android-3-Tasten-Leiste (48 px): Leiste 8 px ueber der '
        'Systemleiste, Band waechst mit', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _navShell(AppNavBar(index: 0, onChanged: (_) {}, items: _navItems)),
      );

      final glass = tester.getRect(find.byKey(const ValueKey('nav-glass')));
      expect(AppNavBar.bottomOffsetFor(48), 48 + 8);
      expect(glass.bottom, 915 - 48 - 8,
          reason: 'the bar must stay clear of the system buttons');
      final body = tester.element(find.byKey(const ValueKey('nav-body')));
      expect(MediaQuery.paddingOf(body).bottom, 48 + 8 + 68 + 12);
      expect(tester.getSize(find.byType(AppNavBar)).height, 48 + 8 + 68 + 12);
    });

    testWidgets('Glas, Umriss, Unschaerfe und Schatten kommen aus den Tokens',
        (tester) async {
      pinIphone14Pro(tester);
      await tester.pumpWidget(
        _navShell(AppNavBar(index: 0, onChanged: (_) {}, items: _navItems)),
      );
      const t = AppTokens.dark;

      final glass = tester
          .widget<DecoratedBox>(find.byKey(const ValueKey('nav-glass')))
          .decoration as BoxDecoration;
      expect(glass.color, t.navGlass);
      expect(glass.border, Border.all(color: t.lineStrong));
      expect(glass.borderRadius, BorderRadius.circular(rNav));

      final blur = tester.widget<BackdropFilter>(
        find.descendant(
          of: find.byType(AppNavBar),
          matching: find.byType(BackdropFilter),
        ),
      );
      expect(
        blur.filter,
        ImageFilter.blur(
          sigmaX: AppNavBar.blurSigma,
          sigmaY: AppNavBar.blurSigma,
        ),
      );

      final shadowed = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(AppNavBar),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.boxShadow != null);
      expect(shadowed.single.boxShadow, floatingShadow(t));
    });

    testWidgets('aktiv = Akzent-Kapsel und Akzent-Label in 800, '
        'inaktiv = ink3 in 600', (tester) async {
      pinIphone14Pro(tester);
      await tester.pumpWidget(
        _navShell(AppNavBar(index: 1, onChanged: (_) {}, items: _navItems)),
      );
      const t = AppTokens.dark;

      TextStyle label(String text) =>
          tester.widget<Text>(find.text(text)).style!;
      expect(label('Rezepte').color, t.accentText);
      expect(label('Rezepte').fontWeight, FontWeight.w800);
      expect(label('Rezepte').fontSize, 11);
      expect(label('Rezepte').fontFamily, AppType.uiFamily);
      for (final idle in <String>['Food', 'Coach']) {
        expect(label(idle).color, t.ink3);
        expect(label(idle).fontWeight, FontWeight.w600);
      }

      // One pill for the whole bar (it slides between items): it covers the
      // active item's 48x28 capsule slot, centred on its icon, and it is the
      // only accent capsule painted.
      final track = tester.renderObject(find.byKey(const ValueKey('nav-pill')));
      final pill = AppNavBar.debugPillRect(track)!;
      expect(pill.size, const Size(48, 28));
      expect(
        pill.center,
        offsetMoreOrLessEquals(
          tester.getCenter(
            find.byWidgetPredicate(
              (w) => w is AppIcon && w.symbol == AppSymbol.recipes,
            ),
          ),
        ),
      );
      expect(track, paints..rrect(color: t.accentTintStrong));
      expect(
        track,
        isNot(
          paints
            ..rrect(color: t.accentTintStrong)
            ..rrect(color: t.accentTintStrong),
        ),
      );

      final icons = tester.widgetList<AppIcon>(find.byType(AppIcon)).toList();
      expect(icons.map((icon) => icon.color), <Color>[
        t.ink3,
        t.accentText,
        t.ink3,
      ]);
      expect(icons.every((icon) => icon.size == 22), isTrue);
    });

    testWidgets('Fade und Luecken um die Leiste fangen keine Taps ab',
        (tester) async {
      pinIphone14Pro(tester);
      var bodyTaps = 0;
      var navTaps = 0;
      await tester.pumpWidget(
        _navShell(
          AppNavBar(index: 0, onChanged: (_) => navTaps++, items: _navItems),
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => bodyTaps++,
          ),
        ),
      );
      final glass = tester.getRect(find.byKey(const ValueKey('nav-glass')));

      // In the fade above the bar, in the side gap and below the bar.
      for (final point in <Offset>[
        Offset(glass.center.dx, glass.top - 10),
        Offset(glass.left / 2, glass.center.dy),
        Offset(glass.center.dx, glass.bottom + 10),
      ]) {
        await tester.tapAt(point);
      }
      expect(bodyTaps, 3);
      expect(navTaps, 0);

      await tester.tapAt(glass.center);
      expect(navTaps, 1);
    });
  });

  testWidgets('alle Bedienelemente rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => Column(
        children: <Widget>[
          SquareIconButton(icon: Icons.chevron_left_rounded, onTap: () {}),
          const IconTile(icon: Icons.bolt_rounded),
          AppToggle(value: true, onChanged: (_) {}),
          const FilterChipPill(label: 'Alle', selected: true),
          const PrimaryActionButton(label: 'Essen eintragen'),
          AppNavBar(index: 0, onChanged: (_) {}, items: _navItems),
        ],
      ),
      scrollable: true,
    );
  });

  testWidgets('alle Bedienelemente ueberstehen textScaler 2.0',
      (tester) async {
    pinPhoneViewport(tester);
    await expectSurvivesTextScale(
      tester,
      Column(
        children: <Widget>[
          SquareIconButton(icon: Icons.chevron_left_rounded, onTap: () {}),
          const IconTile(icon: Icons.bolt_rounded),
          AppToggle(value: true, onChanged: (_) {}),
          const FilterChipPill(label: 'Fruehstueck', selected: true),
          const PrimaryActionButton(
            label: 'Essen eintragen',
            icon: Icons.add_rounded,
          ),
          AppNavBar(index: 0, onChanged: (_) {}, items: _navItems),
        ],
      ),
    );
  });
}
