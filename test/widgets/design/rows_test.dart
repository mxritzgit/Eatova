import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/rows.dart';

import 'design_harness.dart';

void main() {
  group('PageHeader', () {
    testWidgets('der Zurueck-Knopf poppt die Route', (tester) async {
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: PageHeader(title: 'Profil'),
                  ),
                ),
              ),
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      expect(find.text('Profil'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Profil'), findsNothing);
    });

    testWidgets('onBack ersetzt das Poppen', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        designHarness(PageHeader(title: 'Profil', onBack: () => backs++)),
      );

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      expect(backs, 1);
    });

    testWidgets('backKey liegt am Zurueck-Knopf', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        designHarness(
          PageHeader(
            title: 'Profil',
            backKey: const ValueKey<String>('profile-close'),
            onBack: () => backs++,
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('profile-close')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('profile-close')));
      expect(backs, 1);
    });

    testWidgets('large setzt den Titel gross nach links', (tester) async {
      await tester.pumpWidget(
        designHarness(const PageHeader(large: 'Einstellungen')),
      );

      final title = tester.widget<Text>(find.text('Einstellungen'));
      expect(title.style?.fontSize, 28);
      expect(title.style?.color, AppTokens.light.ink);
    });

    testWidgets('trailing landet rechts', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const PageHeader(title: 'Profil', trailing: Icon(Icons.more_horiz)),
        ),
      );

      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    });
  });

  group('SettingsGroup', () {
    testWidgets('zeigt Label und alle Kinder mit Trennern dazwischen',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SettingsGroup(
            label: 'KONTO',
            children: <Widget>[
              SettingsRow(title: 'E-Mail'),
              SettingsRow(title: 'Passwort'),
              SettingsRow(title: 'Abmelden'),
            ],
          ),
        ),
      );

      expect(find.text('KONTO'), findsOneWidget);
      expect(find.text('E-Mail'), findsOneWidget);
      expect(find.text('Abmelden'), findsOneWidget);
      expect(find.byType(Divider), findsNWidgets(2));
    });

    testWidgets('labelColor und borderColor schlagen durch', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SettingsGroup(
            label: 'GEFAHRENZONE',
            labelColor: Color(0xFFB23A28),
            borderColor: Color(0xFFB23A28),
            children: <Widget>[SettingsRow(title: 'Konto loeschen')],
          ),
        ),
      );

      expect(
        tester.widget<Text>(find.text('GEFAHRENZONE')).style?.color,
        const Color(0xFFB23A28),
      );
      expect(
        decorationOf(tester, find.byType(SettingsGroup)).border,
        Border.all(color: const Color(0xFFB23A28)),
      );
    });
  });

  group('SettingsRow', () {
    testWidgets('onTap feuert', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        designHarness(SettingsRow(title: 'Sprache', onTap: () => taps++)),
      );

      await tester.tap(find.byType(SettingsRow));
      expect(taps, 1);
    });

    testWidgets('value, subtitle, leading und trailing erscheinen',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SettingsRow(
            title: 'Einheiten',
            subtitle: 'Gewicht und Groesse',
            value: 'Metrisch',
            leading: Icon(Icons.straighten),
            trailing: Icon(Icons.info_outline),
          ),
        ),
      );

      expect(find.text('Einheiten'), findsOneWidget);
      expect(find.text('Gewicht und Groesse'), findsOneWidget);
      expect(find.text('Metrisch'), findsOneWidget);
      expect(find.byIcon(Icons.straighten), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    });

    testWidgets('chevron:false laesst den Pfeil weg', (tester) async {
      await tester.pumpWidget(
        designHarness(const SettingsRow(title: 'Nur Text', chevron: false)),
      );

      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });

    testWidgets('titleColor uebersteuert die Tintenfarbe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          SettingsRow(
            title: 'Konto loeschen',
            titleColor: AppTokens.light.danger,
          ),
        ),
      );

      expect(
        tester.widget<Text>(find.text('Konto loeschen')).style?.color,
        AppTokens.light.danger,
      );
    });
  });

  testWidgets('alle Zeilen rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => const Column(
        children: <Widget>[
          PageHeader(title: 'Profil'),
          PageHeader(large: 'Einstellungen'),
          SettingsGroup(
            label: 'KONTO',
            children: <Widget>[
              SettingsRow(title: 'E-Mail', value: 'du@example.com'),
              SettingsRow(
                title: 'Einheiten',
                subtitle: 'Gewicht und Groesse',
                chevron: false,
              ),
            ],
          ),
        ],
      ),
      scrollable: true,
    );
  });

  testWidgets('alle Zeilen ueberstehen textScaler 2.0', (tester) async {
    pinPhoneViewport(tester);
    await expectSurvivesTextScale(
      tester,
      const Column(
        children: <Widget>[
          PageHeader(title: 'Mein Profil'),
          PageHeader(large: 'Einstellungen'),
          SettingsGroup(
            label: 'KONTO UND SICHERHEIT',
            children: <Widget>[
              SettingsRow(
                title: 'E-Mail-Adresse aendern',
                subtitle: 'Bestaetigung noetig',
                value: 'du@example.com',
                leading: Icon(Icons.mail_outline),
              ),
            ],
          ),
        ],
      ),
    );
  });
}
