import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/controls.dart';
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

      // The dimming is the PrimaryActionButton's own disabled fill (alpha
      // < 1), not an Opacity wrapper — one disabled look app-wide.
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(PrimaryActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color!.a, lessThan(1.0));
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
      // ONE primary semantics (F8-10): the sheet action is the same accent
      // pill as PrimaryActionButton, not a forest block.
      expect(actionMaterial().color, AppTokens.light.accentFill);

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
      // Repo rule: inputs are borderless soft capsules — no hairline in any
      // state, the capsule is an AnimatedContainer (focus lightens the fill).
      final kapsel = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(SheetField),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final deco = kapsel.decoration! as BoxDecoration;
      expect(deco.border, isNull);
      expect(deco.color, AppTokens.light.field);
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

  // Design review 2026-10-11: one close control and one title for every
  // sheet header. The old `surf2` disc measured 1.05:1 on the light sheet
  // ground and read as a bare glyph.
  group('SheetCloseButton', () {
    for (final brightness in Brightness.values) {
      testWidgets('surf disc with lineStrong ring, 44 in 48 ($brightness)', (
        tester,
      ) async {
        await tester.pumpWidget(
          designHarness(
            Align(
              alignment: Alignment.topLeft,
              child: SheetCloseButton(
                buttonKey: const ValueKey('close'),
                onTap: () {},
              ),
            ),
            brightness: brightness,
          ),
        );
        final t = brightness == Brightness.light
            ? AppTokens.light
            : AppTokens.dark;
        final button = find.byKey(const ValueKey('close'));
        expect(tester.widget(button), isA<IconButton>());
        expect(tester.getSize(button), const Size(48, 48));
        final style = tester.widget<IconButton>(button).style!;
        expect(style.backgroundColor!.resolve(<WidgetState>{}), t.surf);
        expect(style.foregroundColor!.resolve(<WidgetState>{}), t.inkMuted);
        expect(style.fixedSize!.resolve(<WidgetState>{}), const Size(44, 44));
        final shape = style.shape!.resolve(<WidgetState>{})! as CircleBorder;
        expect(shape.side.color, t.lineStrong);
        // The disc itself must differ from the sheet ground (bg).
        expect(t.surf, isNot(t.bg));
      });
    }

    testWidgets('null onTap is disabled; the default tooltip is Close', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        designHarness(
          const SheetCloseButton(buttonKey: ValueKey('close'), onTap: null),
          locale: const Locale('en'),
        ),
      );
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('close')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'Close');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('close'))),
        isSemantics(
          tooltip: 'Close',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      semantics.dispose();
    });
  });

  group('SheetHeader', () {
    testWidgets('title is a level-1 heading at 24 (compact 20)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      for (final compact in <bool>[false, true]) {
        await tester.pumpWidget(
          designHarness(
            SheetHeader(
              title: 'Tag waehlen',
              subtitle: 'Fuer das Ernaehrungstagebuch',
              titleKey: const ValueKey('title'),
              compact: compact,
              onClose: () {},
            ),
          ),
        );
        final title = tester.widget<Text>(find.byKey(const ValueKey('title')));
        expect(title.style!.fontSize, compact ? 20 : 24);
        final node = tester.getSemantics(find.byKey(const ValueKey('title')));
        expect(node, isSemantics(label: 'Tag waehlen', isHeader: true));
        expect(node.headingLevel, 1);
      }
      semantics.dispose();
    });

    testWidgets('close: tap, disabled while busy, hidden without onClose', (
      tester,
    ) async {
      var closed = 0;
      Future<void> pump({bool enabled = true, bool withClose = true}) =>
          tester.pumpWidget(
            designHarness(
              SheetHeader(
                title: 'Titel',
                closeKey: const ValueKey('close'),
                closeEnabled: enabled,
                onClose: withClose ? () => closed++ : null,
              ),
            ),
          );
      await pump();
      await tester.tap(find.byKey(const ValueKey('close')));
      expect(closed, 1);

      await pump(enabled: false);
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('close'))).onPressed,
        isNull,
      );
      expect(find.byType(SheetCloseButton), findsOneWidget);

      await pump(withClose: false);
      expect(find.byType(SheetCloseButton), findsNothing);
    });

    testWidgets('a wrapping title keeps the close button at the top', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 3, 700 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        designHarness(
          SheetHeader(
            title: 'Mahlzeit mit einem sehr langen Namen bearbeiten',
            subtitle: 'Haehnchen mit Reis und Brokkoli',
            leading: const SizedBox.square(dimension: 40),
            closeKey: const ValueKey('close'),
            onClose: () {},
            padding: EdgeInsets.zero,
          ),
          textScaler: const TextScaler.linear(2),
          scrollable: true,
        ),
      );
      expect(tester.takeException(), isNull);
      final header = tester.getRect(find.byType(SheetHeader));
      final close = tester.getRect(find.byKey(const ValueKey('close')));
      expect(close.top, header.top);
      expect(header.height, greaterThan(close.height * 2));
    });
  });
}
