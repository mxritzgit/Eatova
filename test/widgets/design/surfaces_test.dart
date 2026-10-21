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
      expect(
        tester.getRect(find.text('Tagesziele')).left,
        greaterThan(tester.getRect(find.text('Makros')).right),
      );
    });

    testWidgets('ohne trailing bleibt eine einzige Zeile', (tester) async {
      await tester.pumpWidget(
        designHarness(const SectionHeading(title: 'Mahlzeiten')),
      );

      expect(find.byType(Text), findsOneWidget);
    });
  });

  testWidgets('alle Flaechen rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => const Column(
        children: [
          AppCard(child: Text('Karte')),
          SectionHeading(title: 'Abschnitt', trailing: 'rechts'),
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
          SectionHeading(title: 'Makros', trailing: 'Tagesziele'),
        ],
      ),
    );
  });
}
