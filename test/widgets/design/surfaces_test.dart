import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/surfaces.dart';

import 'design_harness.dart';

void main() {
  group('AppCard', () {
    testWidgets('traegt Kind, Standard-Radius rCard und die Kartenflaeche',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const AppCard(child: Text('Inhalt'))),
      );

      expect(find.text('Inhalt'), findsOneWidget);
      final deco = decorationOf(tester, find.byType(AppCard));
      expect(deco.color, AppTokens.light.surf);
      expect(deco.borderRadius, BorderRadius.circular(rCard));
      expect(deco.border, Border.all(color: AppTokens.light.line));
    });

    testWidgets('clip:true schneidet zu und nimmt die Innenpolsterung weg',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const AppCard(clip: true, child: Text('Rand'))),
      );

      final container = tester.widget<Container>(
        find
            .descendant(of: find.byType(AppCard), matching: find.byType(Container))
            .first,
      );
      expect(container.clipBehavior, Clip.antiAlias);
      expect(container.padding, EdgeInsets.zero);
    });

    testWidgets('color uebersteuert die Kartenflaeche', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const AppCard(color: Color(0xFF123456), child: Text('x')),
        ),
      );

      expect(
        decorationOf(tester, find.byType(AppCard)).color,
        const Color(0xFF123456),
      );
    });
  });

  group('ScreenTitle', () {
    testWidgets('zeigt Titel, optionalen Untertitel und trailing',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const ScreenTitle(
            title: 'Ernaehrung',
            subtitle: 'Sonntag, 9. August',
            trailing: Icon(Icons.person_outline),
          ),
        ),
      );

      expect(find.text('Ernaehrung'), findsOneWidget);
      expect(find.text('Sonntag, 9. August'), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('ohne Untertitel bleibt nur der Titel', (tester) async {
      await tester.pumpWidget(
        designHarness(const ScreenTitle(title: 'Nur Titel')),
      );

      expect(find.byType(Text), findsOneWidget);
    });
  });

  group('SectionHeading', () {
    testWidgets('setzt den Titel links und den gedaempften Text rechts',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SectionHeading(title: 'Makros', trailing: 'Tagesziele'),
        ),
      );

      expect(find.text('Makros'), findsOneWidget);
      expect(find.text('Tagesziele'), findsOneWidget);

      final title = tester.widget<Text>(find.text('Makros'));
      expect(title.style?.fontSize, 17);
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(title.style?.color, AppTokens.light.ink);

      final trailing = tester.widget<Text>(find.text('Tagesziele'));
      expect(trailing.style?.color, AppTokens.light.ink2);
    });

    testWidgets('ohne trailing bleibt eine einzige Zeile', (tester) async {
      await tester.pumpWidget(
        designHarness(const SectionHeading(title: 'Mahlzeiten')),
      );

      expect(find.byType(Text), findsOneWidget);
    });
  });

  group('ImagePlaceholder', () {
    testWidgets('zeigt das Standard-Label BILD und malt die Streifen',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const SizedBox(height: 120, child: ImagePlaceholder())),
      );

      expect(find.text('BILD'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ImagePlaceholder),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });

    testWidgets('eigenes Label ersetzt den Standard', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SizedBox(height: 120, child: ImagePlaceholder(label: 'FOTO')),
        ),
      );

      expect(find.text('FOTO'), findsOneWidget);
      expect(find.text('BILD'), findsNothing);
    });
  });

  group('DottedAddSlot', () {
    testWidgets('Tap ruft onTap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        designHarness(
          DottedAddSlot(label: 'Lebensmittel hinzufuegen', onTap: () => taps++),
        ),
      );

      await tester.tap(find.byType(DottedAddSlot));
      expect(taps, 1);
      expect(find.text('Lebensmittel hinzufuegen'), findsOneWidget);
    });

    testWidgets('ohne onTap bleibt der Slot tippbar ohne zu werfen',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const DottedAddSlot(label: 'Leer')),
      );

      await tester.tap(find.byType(DottedAddSlot), warnIfMissed: false);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('alle Flaechen rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => const Column(
        children: [
          AppCard(child: Text('Karte')),
          ScreenTitle(title: 'Titel', subtitle: 'Untertitel'),
          SectionHeading(title: 'Abschnitt', trailing: 'rechts'),
          SizedBox(height: 90, child: ImagePlaceholder()),
          DottedAddSlot(label: 'Hinzufuegen'),
        ],
      ),
      scrollable: true,
    );
  });

  testWidgets('alle Flaechen ueberstehen textScaler 2.0', (tester) async {
    pinPhoneViewport(tester);
    await expectSurvivesTextScale(
      tester,
      const Column(
        children: [
          AppCard(child: Text('Karteninhalt mit laengerem Text')),
          ScreenTitle(title: 'Ernaehrung', subtitle: 'Sonntag, 9. August'),
          SectionHeading(title: 'Makros', trailing: 'Tagesziele'),
          SizedBox(height: 90, child: ImagePlaceholder()),
          DottedAddSlot(label: 'Lebensmittel hinzufuegen'),
        ],
      ),
    );
  });
}
