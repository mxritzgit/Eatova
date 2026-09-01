import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/controls.dart';

import 'design_harness.dart';

const List<AppNavItem> _navItems = <AppNavItem>[
  AppNavItem(
    icon: Icons.restaurant_outlined,
    activeIcon: Icons.restaurant_rounded,
    label: 'Food',
  ),
  AppNavItem(
    icon: Icons.menu_book_outlined,
    activeIcon: Icons.menu_book_rounded,
    label: 'Rezepte',
  ),
  AppNavItem(
    icon: Icons.auto_awesome_outlined,
    activeIcon: Icons.auto_awesome_rounded,
    label: 'Coach',
  ),
];

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

  group('SegmentedPill', () {
    testWidgets('Tap meldet die getippte Option', (tester) async {
      String? picked;
      await tester.pumpWidget(
        designHarness(
          SegmentedPill(
            options: const <String>['kg', 'lb'],
            selected: 'kg',
            onChanged: (v) => picked = v,
          ),
        ),
      );

      await tester.tap(find.text('lb'));
      expect(picked, 'lb');
    });

    testWidgets('die aktive Option traegt die Akzentflaeche, die andere nicht',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          SegmentedPill(
            options: const <String>['kg', 'lb'],
            selected: 'kg',
            onChanged: (_) {},
          ),
        ),
      );

      BoxDecoration decoFor(String option) {
        final box = tester.widget<AnimatedContainer>(
          find
              .ancestor(
                of: find.text(option),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
        return box.decoration! as BoxDecoration;
      }

      // Selection language since P9-02: `ink`, not `forest` — the latter is
      // itself a dark surface and vanishes in dark mode
      // (review0829_selection_contrast_test).
      expect(decoFor('kg').color, AppTokens.light.ink);
      expect(decoFor('lb').color, Colors.transparent);
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

    testWidgets('ausgewaehlt wechselt die Flaeche auf ink', (tester) async {
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
      expect(materialOf().color, AppTokens.light.ink);
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
      expect(materialOf().color, AppTokens.light.ink);

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

      expect(find.byIcon(Icons.restaurant_rounded), findsOneWidget);
      expect(find.byIcon(Icons.restaurant_outlined), findsNothing);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
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
                icon: Icons.restaurant_outlined,
                activeIcon: Icons.restaurant_rounded,
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

    testWidgets('bleibt flach, aber jedes Item bleibt ein 44-px-Tap-Ziel',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        designHarness(
          AppNavBar(index: 0, onChanged: (_) {}, items: _navItems),
        ),
      );

      // The bar was shortened from ~76 to ~58 px because it sits on every
      // screen; growing it again should break this test deliberately.
      expect(
        tester.getSize(find.byType(AppNavBar)).height,
        lessThanOrEqualTo(62),
      );

      // The floor of that shortening: 44 px hit area per item. The guideline
      // check runs over the semantics nodes, i.e. what a finger hits.
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
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
          SegmentedPill(
            options: const <String>['kg', 'lb'],
            selected: 'kg',
            onChanged: (_) {},
          ),
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
          SegmentedPill(
            options: const <String>['Metrisch', 'Imperial'],
            selected: 'Metrisch',
            onChanged: (_) {},
          ),
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
