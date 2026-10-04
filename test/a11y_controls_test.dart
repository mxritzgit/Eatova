import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// A11y guarantees of the shared controls (verification 2026-08-09).
// controls_test.dart checks what the building blocks DRAW; this checks what
// they SAY to a screen reader, which a refactor drops silently.
// ---------------------------------------------------------------------------

/// PageHeader reads context.l10n, which throws without localizations.
Future<void> _harness(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) =>
    pumpLocalized(
      tester,
      child,
      reducedMotion: false,
      brightness: brightness,
      padding: const EdgeInsets.all(20),
    );

void main() {
  group('PrimaryActionButton', () {
    testWidgets('ist eine Schaltflaeche und sagt seinen Enabled-Zustand',
        (tester) async {
      final handle = tester.ensureSemantics();

      await _harness(
        tester,
        PrimaryActionButton(label: 'Essen loggen', onTap: () {}),
      );
      expect(
        tester.getSemantics(find.byType(PrimaryActionButton)),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
      );

      // `onTap == null` is the disabled convention; without `hasEnabledState`
      // a locked button sounds like a normal one.
      await _harness(
        tester,
        const PrimaryActionButton(label: 'Speichern'),
      );
      expect(
        tester.getSemantics(find.byType(PrimaryActionButton)),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      handle.dispose();
    });
  });

  group('Auswahl-Zustaende', () {
    testWidgets('FilterChipPill meldet, ob der Filter gerade greift',
        (tester) async {
      final handle = tester.ensureSemantics();

      await _harness(
        tester,
        Row(
          children: <Widget>[
            FilterChipPill(label: 'Alle', selected: true, onTap: () {}),
            const SizedBox(width: 8),
            FilterChipPill(label: 'Eigene', selected: false, onTap: () {}),
          ],
        ),
      );

      // Otherwise selection lives only in the fill colour.
      expect(
        tester.getSemantics(find.widgetWithText(FilterChipPill, 'Alle')),
        isSemantics(isButton: true, isSelected: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(FilterChipPill, 'Eigene')),
        isSemantics(isButton: true, isSelected: false),
      );
      handle.dispose();
    });
  });
}
