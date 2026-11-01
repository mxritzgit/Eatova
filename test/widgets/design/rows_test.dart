import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_icons.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/rows.dart';

import 'design_harness.dart';

void main() {
  group('PageHeader', () {
    testWidgets('back can stay disabled while its owner saves', (tester) async {
      var backs = 0;
      await tester.pumpWidget(designHarness(
        PageHeader(title: 'Profil', backEnabled: false, onBack: () => backs++),
      ));
      await tester.tap(find.byIcon(AppIcons.chevronLeft));
      expect(backs, 0);
    });
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

      await tester.tap(find.byIcon(AppIcons.chevronLeft));
      await tester.pumpAndSettle();
      expect(find.text('Profil'), findsNothing);
    });

    // Pages with drafts pass onBack for a discard prompt: the button must
    // call it INSTEAD of popping, or the page closes past the prompt.
    testWidgets('onBack am backKey ersetzt das Poppen', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: PageHeader(
                      title: 'Profil',
                      backKey: const ValueKey<String>('profile-close'),
                      onBack: () => backs++,
                    ),
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

      await tester.tap(find.byKey(const ValueKey<String>('profile-close')));
      await tester.pumpAndSettle();
      expect(backs, 1);
      expect(find.text('Profil'), findsOneWidget, reason: 'nicht gepoppt');
    });

    testWidgets('large uses the shared subpage title scale', (tester) async {
      await tester.pumpWidget(
        designHarness(const PageHeader(large: 'Einstellungen')),
      );

      final title = tester.widget<Text>(find.text('Einstellungen'));
      expect(title.style?.fontSize, 24);
      expect(title.style?.color, AppTokens.light.ink);
    });

    testWidgets('trailing landet rechts', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const PageHeader(title: 'Profil', trailing: Icon(Icons.more_horiz)),
        ),
      );

      expect(
        tester.getCenter(find.byIcon(Icons.more_horiz)).dx,
        greaterThan(tester.getRect(find.text('Profil')).right),
      );
    });
  });

  group('SettingsGroup', () {
    testWidgets('zeigt Label und alle Kinder mit Trennern dazwischen',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SettingsGroup(
            label: 'Konto',
            children: <Widget>[
              SettingsRow(title: 'E-Mail'),
              SettingsRow(title: 'Passwort'),
              SettingsRow(title: 'Abmelden'),
            ],
          ),
        ),
      );

      // The section heading since 2026-11-01, no longer an all-caps caption.
      expect(find.text('Konto'), findsOneWidget);
      expect(find.text('E-Mail'), findsOneWidget);
      expect(find.text('Abmelden'), findsOneWidget);
      // Dividers only BETWEEN rows.
      expect(find.byType(Divider), findsNWidgets(2));
    });
  });

  group('ListRow', () {
    testWidgets('ist ein Knoten; die Trenner beginnen an der Textspalte, auch '
        'bei 320 px und 2,0x Text', (tester) async {
      final handle = tester.ensureSemantics();
      addTearDown(tester.view.reset);
      Widget section() => ListSection(
        title: 'Konto',
        children: <Widget>[
          ListRow(
            key: const ValueKey('row-profile'),
            icon: AppIcons.person,
            title: 'Profil',
            subtitle: 'Ziele und Koerperdaten',
            value: '72 kg',
            trailing: ListTrailing.chevron,
            onTap: () {},
          ),
          const ListRow(
            icon: AppIcons.translate,
            title: 'Sprache',
            value: 'Deutsch',
            trailing: ListTrailing.value,
          ),
          ListRow(
            key: const ValueKey('row-pick'),
            title: 'Englisch',
            trailing: ListTrailing.check,
            selected: true,
            onTap: () {},
          ),
        ],
      );
      for (final (width, scale) in <(double, double)>[(393, 1), (320, 2)]) {
        final row = '$width px, ${scale}x';
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = Size(width * 3, 2556);
        await tester.pumpWidget(
          designHarness(
            section(),
            textScaler: TextScaler.linear(scale),
            scrollable: true,
          ),
        );
        expect(tester.takeException(), isNull, reason: row);

        final divider = find.byType(Divider).first;
        final lineStart =
            tester.getRect(divider).left + tester.widget<Divider>(divider).indent!;
        expect(
          lineStart,
          moreOrLessEquals(tester.getRect(find.text('Sprache')).left),
          reason: '$row: der Trenner beginnt an der Textspalte',
        );

        final node = tester.getSemantics(
          find.byKey(const ValueKey('row-profile')),
        );
        expect(
          node,
          isSemantics(isButton: true, hasTapAction: true),
          reason: row,
        );
        expect(
          node.label,
          allOf(contains('Profil'), contains('Ziele'), contains('72 kg')),
          reason: '$row: Titel, Untertitel und Wert in einem Knoten',
        );
        expect(
          tester.getSemantics(find.byKey(const ValueKey('row-pick'))),
          isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true),
          reason: '$row: eine Haken-Zeile ist eine Wahl in einer Gruppe',
        );
      }
      handle.dispose();
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
      expect(find.byIcon(AppIcons.chevronRight), findsOneWidget);

      // chevron: false drops the arrow.
      await tester.pumpWidget(
        designHarness(const SettingsRow(title: 'Nur Text', chevron: false)),
      );
      expect(find.byIcon(AppIcons.chevronRight), findsNothing);
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
