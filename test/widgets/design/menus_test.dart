import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'design_harness.dart';

// X-03 / T1: every overflow menu speaks one row language, and a destructive
// entry is no red line of text: only its glyph carries `danger`.
void main() {
  // One palette: MenuRow has no brightness branch (repo_rules_test).
  testWidgets('MenuRow: Label immer ink, nur die Glyphe traegt danger', (
    tester,
  ) async {
    const t = AppTokens.light;
    await tester.pumpWidget(
      designHarness(
        const Column(
          children: [
            MenuRow(icon: Icons.edit_outlined, label: 'Bearbeiten'),
            MenuRow(
              icon: Icons.delete_outline_rounded,
              label: 'Loeschen',
              destructive: true,
            ),
          ],
        ),
      ),
    );
    for (final label in ['Bearbeiten', 'Loeschen']) {
      final style = tester.widget<Text>(find.text(label)).style!;
      expect(style.color, t.ink, reason: label);
      expect(style.fontSize, 15);
      expect(style.fontWeight, FontWeight.w600);
    }
    expect(
      tester.widget<Icon>(find.byIcon(Icons.delete_outline_rounded)).color,
      t.danger,
    );
    expect(tester.widget<Icon>(find.byIcon(Icons.edit_outlined)).color, t.ink2);
  });

  // The theme is where a brightness branch may live, so both palettes.
  for (final brightness in Brightness.values) {
    // Depth and light: the menu floats like the decision card, lit and on
    // a wide shadow, without an edge line.
    test('Menue schwebt ohne Kante wie die Entscheidungskarte '
        '(${brightness.name})', () {
      final menu = buildEatovaTheme(brightness).popupMenuTheme;
      final shape = menu.shape! as RoundedRectangleBorder;
      expect(shape.side, BorderSide.none);
      expect(shape.borderRadius, BorderRadius.circular(rCard));
      expect(menu.elevation, greaterThan(0), reason: 'depth from a shadow');
    });
  }

  testWidgets('eatovaMenuItem oeffnet unter dem Anker und meldet den Wert', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    String? picked;
    await tester.pumpWidget(
      designHarness(
        Align(
          alignment: Alignment.topRight,
          child: PopupMenuButton<String>(
            key: const ValueKey('menu'),
            onSelected: (value) => picked = value,
            itemBuilder: (_) => [
              eatovaMenuItem(
                key: const ValueKey('menu-delete'),
                value: 'delete',
                icon: Icons.delete_outline_rounded,
                label: 'Loeschen',
                destructive: true,
              ),
            ],
          ),
        ),
      ),
    );
    final anchor = tester.getRect(find.byKey(const ValueKey('menu')));
    await tester.tap(find.byKey(const ValueKey('menu')));
    await tester.pumpAndSettle();
    final item = tester.getRect(find.byKey(const ValueKey('menu-delete')));
    // The theme's PopupMenuPosition.under: the menu opens below the glyph
    // (Material tucks it into the button's own padding), not over it.
    expect(item.top, greaterThan(anchor.center.dy));
    expect(find.byType(MenuRow), findsOneWidget);
    await tester.tap(find.text('Loeschen'));
    await tester.pumpAndSettle();
    expect(picked, 'delete');
  });

  testWidgets('MenuRow ohne Glyphe haelt die Labelspalte', (tester) async {
    await tester.pumpWidget(
      designHarness(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MenuRow(icon: Icons.check_rounded, label: 'Gewaehlt'),
            MenuRow(label: 'Anderes'),
          ],
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('Gewaehlt')).dx,
      tester.getTopLeft(find.text('Anderes')).dx,
    );
  });
}
