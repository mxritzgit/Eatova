import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/design_previews.dart';

import '../../support/harness.dart';

// The widget previews are never imported by the app. This suite builds each
// one through the wrappers its annotation declares, so a design change that
// breaks a preview fails here instead of silently in the IDE previewer.

final Map<String, Widget Function()> _previews = <String, Widget Function()>{
  'Primäre Aktion': primaryActionPreview,
  'Icon-Buttons und Stepper': iconButtonsPreview,
  'Liste': listSectionPreview,
  'Aufzaehlungen': enumerationsPreview,
  'Status, Badges, Leerzustand': statesPreview,
  'Navigation': navBarPreview,
  'Lesbare Spalte (Tablet)': readableWidthPreview,
};

void main() {
  test('jede Vorschau traegt eine helle und eine dunkle Variante', () {
    for (final name in _previews.keys) {
      final previews = EatovaPreview(name: name).previews;
      expect(previews.map((p) => p.brightness), [
        Brightness.light,
        Brightness.dark,
      ]);
      expect(previews.map((p) => p.wrapper), [
        eatovaLightPreviewWrapper,
        eatovaDarkPreviewWrapper,
      ]);
      expect(previews.every((p) => p.group == 'Eatova design'), isTrue);
    }
  });

  // One table over every preview and both palettes.
  testWidgets('jede Vorschau baut ohne Fehler', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 400);
    addTearDown(tester.view.reset);
    for (final entry in _previews.entries) {
      for (final preview in EatovaPreview(name: entry.key).previews) {
        final overflows = await collectOverflows(() async {
          await tester.pumpWidget(
            MaterialApp(home: preview.wrapper!(entry.value())),
          );
          await tester.pump();
        });
        expect(
          overflows,
          isEmpty,
          reason: '${preview.name}: ${describeOverflows(overflows)}',
        );
        expect(tester.takeException(), isNull, reason: preview.name);
        expect(find.byType(Material), findsWidgets, reason: preview.name);
      }
    }
  });
}
