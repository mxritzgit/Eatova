import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/sheets.dart';

import 'design_harness.dart';

void main() {
  group('SheetScaffold', () {
    testWidgets('zeigt Titel, Untertitel, Kinder und Aktionslabel',
        (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SheetScaffold(
            title: 'E-Mail aendern',
            subtitle: 'Wir schicken einen Bestaetigungslink.',
            actionLabel: 'Link senden',
            children: <Widget>[Text('Feldplatzhalter')],
          ),
        ),
      );

      expect(find.text('E-Mail aendern'), findsOneWidget);
      expect(find.text('Wir schicken einen Bestaetigungslink.'), findsOneWidget);
      expect(find.text('Feldplatzhalter'), findsOneWidget);
      expect(find.text('Link senden'), findsOneWidget);
    });

    testWidgets('Tap auf die Aktion ruft onAction', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        designHarness(
          SheetScaffold(
            title: 'Titel',
            subtitle: 'Untertitel',
            actionLabel: 'Speichern',
            onAction: () => calls++,
            children: const <Widget>[],
          ),
        ),
      );

      await tester.tap(find.text('Speichern'));
      expect(calls, 1);
    });

    testWidgets('actionEnabled:false schluckt den Tap und daempft',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        designHarness(
          SheetScaffold(
            title: 'Konto loeschen',
            subtitle: 'Unwiderruflich.',
            actionLabel: 'Loeschen',
            destructive: true,
            actionEnabled: false,
            onAction: () => calls++,
            children: const <Widget>[],
          ),
        ),
      );

      await tester.tap(find.text('Loeschen'), warnIfMissed: false);
      expect(calls, 0);

      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(SheetScaffold),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1.0));
    });

    testWidgets('destructive faerbt die Aktionsflaeche auf danger',
        (tester) async {
      Material actionMaterial() => tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(SheetScaffold),
                  matching: find.byType(Material),
                )
                .first,
          );

      await tester.pumpWidget(
        designHarness(
          const SheetScaffold(
            title: 'Titel',
            subtitle: 'Untertitel',
            actionLabel: 'Weiter',
            children: <Widget>[],
          ),
        ),
      );
      expect(actionMaterial().color, AppTokens.light.forest);

      await tester.pumpWidget(
        designHarness(
          const SheetScaffold(
            title: 'Titel',
            subtitle: 'Untertitel',
            actionLabel: 'Loeschen',
            destructive: true,
            children: <Widget>[],
          ),
        ),
      );
      expect(actionMaterial().color, AppTokens.light.danger);
    });

    testWidgets('ohne onAction poppt die Aktion das Sheet', (tester) async {
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showEatovaSheet<void>(
                context,
                const SheetScaffold(
                  title: 'Titel',
                  subtitle: 'Untertitel',
                  actionLabel: 'Fertig',
                  children: <Widget>[],
                ),
              ),
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      expect(find.text('Fertig'), findsOneWidget);

      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();
      expect(find.text('Fertig'), findsNothing);
    });
  });

  group('SheetField', () {
    testWidgets('Eingabe landet im Controller', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        designHarness(
          SheetField(
            label: 'Neue E-Mail',
            hint: 'du@example.com',
            controller: controller,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'neu@eatova.de');
      expect(controller.text, 'neu@eatova.de');
    });

    testWidgets('onChanged meldet jede Eingabe', (tester) async {
      String? seen;
      await tester.pumpWidget(
        designHarness(
          SheetField(
            label: 'Name',
            hint: 'Vorname',
            onChanged: (v) => seen = v,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Mo');
      expect(seen, 'Mo');
    });

    testWidgets('obscure verdeckt die Eingabe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SheetField(
            label: 'Passwort',
            hint: 'mindestens 10 Zeichen',
            obscure: true,
          ),
        ),
      );

      expect(tester.widget<TextField>(find.byType(TextField)).obscureText,
          isTrue);
    });

    testWidgets('errorText erscheint in der Warnfarbe', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SheetField(
            label: 'E-Mail',
            hint: 'du@example.com',
            errorText: 'Bitte eine gueltige Adresse eingeben',
          ),
        ),
      );

      final error = tester.widget<Text>(
        find.text('Bitte eine gueltige Adresse eingeben'),
      );
      expect(error.style?.color, AppTokens.light.danger);
    });

    testWidgets('ohne errorText bleibt die Fehlerzeile weg und der Rand ruhig',
        (tester) async {
      await tester.pumpWidget(
        designHarness(const SheetField(label: 'E-Mail', hint: 'hint')),
      );

      expect(find.text('E-MAIL'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SheetField),
          matching: find.byWidgetPredicate(
            (w) => w is Text && w.style?.color == AppTokens.light.danger,
          ),
        ),
        findsNothing,
      );
      expect(
        decorationOf(tester, find.byType(SheetField)).border,
        Border.all(color: AppTokens.light.line),
      );
    });

    testWidgets('enabled:false sperrt das Feld', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SheetField(label: 'E-Mail', hint: 'hint', enabled: false),
        ),
      );

      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });

    testWidgets('suffix haengt rechts im Feld', (tester) async {
      await tester.pumpWidget(
        designHarness(
          const SheetField(
            label: 'Passwort',
            hint: 'hint',
            suffix: Icon(Icons.visibility_outlined),
          ),
        ),
      );

      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });
  });

  group('showEatovaSheet', () {
    testWidgets('oeffnet modal, liefert das Ergebnis und traegt t.bg',
        (tester) async {
      String? result;
      await tester.pumpWidget(
        designHarness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showEatovaSheet<String>(
                  context,
                  Builder(
                    builder: (sheetContext) => TextButton(
                      onPressed: () =>
                          Navigator.of(sheetContext).pop('bestaetigt'),
                      child: const Text('bestaetigen'),
                    ),
                  ),
                );
              },
              child: const Text('oeffnen'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      expect(find.text('bestaetigen'), findsOneWidget);

      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.backgroundColor, AppTokens.light.bg);
      expect(sheet.showDragHandle, isTrue);

      await tester.tap(find.text('bestaetigen'));
      await tester.pumpAndSettle();
      expect(result, 'bestaetigt');
    });
  });

  testWidgets('Sheets rendern in hell und dunkel', (tester) async {
    pinPhoneViewport(tester);
    await expectRendersInBothBrightnesses(
      tester,
      () => const SheetScaffold(
        title: 'E-Mail aendern',
        subtitle: 'Wir schicken einen Bestaetigungslink an die neue Adresse.',
        actionLabel: 'Bestaetigung senden',
        children: <Widget>[
          SheetField(label: 'Neue E-Mail', hint: 'du@example.com'),
          SheetField(
            label: 'Aktuelles Passwort',
            hint: 'Passwort',
            obscure: true,
            errorText: 'Falsches Passwort',
          ),
        ],
      ),
      scrollable: true,
    );
  });

  testWidgets('Sheets ueberstehen textScaler 2.0', (tester) async {
    pinPhoneViewport(tester);
    await expectSurvivesTextScale(
      tester,
      const SheetScaffold(
        title: 'E-Mail aendern',
        subtitle: 'Wir schicken einen Bestaetigungslink an die neue Adresse.',
        actionLabel: 'Bestaetigung senden',
        children: <Widget>[
          SheetField(label: 'Neue E-Mail', hint: 'du@example.com'),
          SheetField(
            label: 'Aktuelles Passwort',
            hint: 'Passwort',
            obscure: true,
            errorText: 'Falsches Passwort, bitte erneut versuchen',
          ),
        ],
      ),
    );
  });
}
