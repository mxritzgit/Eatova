import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
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

    testWidgets('SegmentedPill meldet die gewaehlte Option', (tester) async {
      final handle = tester.ensureSemantics();

      await _harness(
        tester,
        SegmentedPill(
          options: const <String>['Metrisch', 'Imperial'],
          selected: 'Metrisch',
          onChanged: (_) {},
        ),
      );

      expect(
        tester.getSemantics(find.text('Metrisch')),
        isSemantics(isButton: true, isSelected: true),
      );
      expect(
        tester.getSemantics(find.text('Imperial')),
        isSemantics(isButton: true, isSelected: false),
      );
      handle.dispose();
    });
  });

  group('PageHeader', () {
    testWidgets('der Zurueck-Knopf traegt einen echten Umlaut',
        (tester) async {
      // A semantics label is SPOKEN text; an ASCII transliteration is read
      // out literally.
      final handle = tester.ensureSemantics();

      await _harness(tester, const PageHeader(title: 'Mein Profil'));

      expect(
        tester.getSemantics(find.byType(SquareIconButton)),
        isSemantics(isButton: true, label: 'Zurück'),
      );
      handle.dispose();
    });
  });

  group('MacroBar', () {
    // The label column is sized for "Carbs" (52 px) and the German label
    // wrapped even at scale 1.0. Loads the bundled Archivo, since the test
    // binding's fallback font is twice as wide and proves nothing.
    setUpAll(() async {
      final loader = FontLoader('Archivo');
      for (final datei in const <String>[
        'assets/fonts/Archivo-Medium.ttf',
        'assets/fonts/Archivo-SemiBold.ttf',
      ]) {
        loader.addFont(
          File(datei).readAsBytes().then(
                (bytes) => ByteData.sublistView(bytes),
              ),
        );
      }
      await loader.load();
    });

    testWidgets('die drei Makro-Zeilen stehen bei Normalschrift auf gleicher '
        'Hoehe', (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _harness(
        tester,
        AppCard(
          child: Column(
            children: <Widget>[
              MacroBar(
                label: 'Protein',
                value: 90,
                goal: 130,
                unit: 'g',
                color: AppTokens.light.protein,
              ),
              MacroBar(
                label: 'Kohlenhydrate',
                value: 180,
                goal: 250,
                unit: 'g',
                color: AppTokens.light.carbs,
              ),
              MacroBar(
                label: 'Fett',
                value: 50,
                goal: 70,
                unit: 'g',
                color: AppTokens.light.fat,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hoehen = <String, double>{
        for (final l in const <String>['Protein', 'Kohlenhydrate', 'Fett'])
          l: tester.getSize(find.text(l)).height,
      };
      expect(
        hoehen.values.toSet(),
        hasLength(1),
        reason: 'Eine Beschriftung bricht um und versetzt ihren Balken '
            'gegen die anderen: $hoehen',
      );
    });
  });
}
