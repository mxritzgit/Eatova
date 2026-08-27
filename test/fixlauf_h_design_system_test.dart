import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

// pumpLocalized/renderMatrix plus the re-exported design helpers
// (pinPhoneViewport, decorationOf).
import 'support/harness.dart';

// ---------------------------------------------------------------------------
// Fix-Lauf 2026-08-27, Paket H (design system): F8-02/03/04/06/07/08/09/10/11.
//
// Contrast is measured, not asserted by token name: WCAG relative luminance,
// translucent layers composited first.
//
// Every claim that used to be spelled out once per palette now runs through
// `renderMatrix`, which declares one test per brightness and appends the
// combination to the test name. `c.t` is the palette of that case, so the
// assertions read the same in both modes.
// ---------------------------------------------------------------------------

/// The 20 px the screens (and `designHarness`, this suite's predecessor) pad
/// every subject with. `pumpLocalized` defaults to `EdgeInsets.zero`, so every
/// mount here passes it explicitly — without it the overflow probes get 40 px
/// MORE width than before the harness migration and prove less.
const EdgeInsets _rand = EdgeInsets.all(20);

double _kontrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color _ueber(Color vorn, Color hinten) => Color.alphaBlend(vorn, hinten);

BoxDecoration _fieldDecoration(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byType(SheetField),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return box.decoration! as BoxDecoration;
}

void main() {
  // =========================================================================
  // F8-02 — Material buttons are themed
  // =========================================================================
  group('F8-02 Button-Themes', () {
    renderMatrix('TextButton-Label (leises ink) auf surf >= 4.5:1',
        (tester, c) async {
      final t = c.t;
      final theme = buildEatovaTheme(c.brightness);
      final style = theme.textButtonTheme.style!;
      final fg = style.foregroundColor!.resolve(<WidgetState>{});
      // Quiet by default; a screen opts into `accent` for an affirmative
      // action itself.
      expect(fg, t.ink);
      expect(_kontrast(fg!, t.surf), greaterThanOrEqualTo(4.5));
      expect(_kontrast(fg, t.bg), greaterThanOrEqualTo(4.5));
      final text = style.textStyle!.resolve(<WidgetState>{})!;
      expect(text.fontWeight, FontWeight.w700);
      expect(text.fontFamily, AppType.uiFamily);
    });

    renderMatrix('FilledButton-Flaeche (ink) auf surf >= 3:1, Text bg',
        (tester, c) async {
      final t = c.t;
      final theme = buildEatovaTheme(c.brightness);
      final style = theme.filledButtonTheme.style!;
      final bgColor = style.backgroundColor!.resolve(<WidgetState>{})!;
      final fg = style.foregroundColor!.resolve(<WidgetState>{})!;
      expect(bgColor, t.ink);
      expect(fg, t.bg);
      expect(_kontrast(bgColor, t.surf), greaterThanOrEqualTo(3.0));
      expect(_kontrast(fg, bgColor), greaterThanOrEqualTo(4.5));
      final shape = style.shape!.resolve(<WidgetState>{})!;
      expect(shape, isA<RoundedRectangleBorder>());
      expect((shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(rButton));
      // Touch floor only — the 54 px primary height stays with
      // PrimaryActionButton and the sheet action.
      expect(style.minimumSize!.resolve(<WidgetState>{})!.height,
          kButtonMinHeight);
    });

    renderMatrix('OutlinedButton traegt line-Rand, ink-Text, 48 px',
        (tester, c) async {
      final t = c.t;
      final style = buildEatovaTheme(c.brightness).outlinedButtonTheme.style!;
      expect(style.side!.resolve(<WidgetState>{})!.color, t.line);
      expect(style.foregroundColor!.resolve(<WidgetState>{}), t.ink);
      expect(style.minimumSize!.resolve(<WidgetState>{})!.height,
          kButtonMinHeight);
    });

    testWidgets('ein nackter TextButton ist im Dark Mode lesbar',
        (tester) async {
      await pumpLocalized(
        tester,
        TextButton(onPressed: () {}, child: const Text('Weiter bearbeiten')),
        padding: _rand,
      );
      final text = tester.widget<Text>(find.text('Weiter bearbeiten'));
      final farbe = DefaultTextStyle.of(
        tester.element(find.text('Weiter bearbeiten')),
      ).style.color;
      expect(text.style?.color ?? farbe, AppTokens.dark.ink);
    });

    renderMatrix('ein FilledButton im Dialog bleibt 48, nicht 54',
        (tester, c) async {
      await c.pump(
        tester,
        Row(
          children: <Widget>[
            TextButton(onPressed: () {}, child: const Text('Abbrechen')),
            FilledButton(onPressed: () {}, child: const Text('Speichern')),
          ],
        ),
        padding: _rand,
      );
      expect(tester.getSize(find.byType(FilledButton)).height, 48);
    });
  });

  // =========================================================================
  // F8-03 — borderless input theme + SheetField
  // =========================================================================
  group('F8-03 inputDecorationTheme', () {
    renderMatrix('keine sichtbare Linie in irgendeinem Zustand',
        (tester, c) async {
      final deco = buildEatovaTheme(c.brightness).inputDecorationTheme;
      expect(deco.filled, isTrue);
      for (final border in <InputBorder?>[
        deco.border,
        deco.enabledBorder,
        deco.focusedBorder,
        deco.errorBorder,
        deco.focusedErrorBorder,
        deco.disabledBorder,
      ]) {
        expect(border, isNotNull);
        expect(border!.borderSide, BorderSide.none,
            reason: 'Rahmen-Regel: keine Hairline an Eingabefeldern');
      }
    });

    renderMatrix('Fokus hellt die Flaeche auf, Fehler toent danger',
        (tester, c) async {
      final t = c.t;
      final deco = buildEatovaTheme(c.brightness).inputDecorationTheme;
      final fill = deco.fillColor! as WidgetStateColor;
      final ruhe = fill.resolve(<WidgetState>{});
      final fokus = fill.resolve(<WidgetState>{WidgetState.focused});
      final fehler = fill.resolve(<WidgetState>{WidgetState.error});
      expect(ruhe, t.field);
      expect(fokus, t.fieldFocus);
      expect(fokus.computeLuminance(), greaterThan(ruhe.computeLuminance()),
          reason: 'Fokus = Aufhellung, in BEIDEN Modi');
      expect(fehler, t.fieldError);
      expect(fehler, isNot(ruhe));
      // The error tint carries hint AND value text.
      expect(_kontrast(t.ink, fehler), greaterThanOrEqualTo(4.5));
      expect(_kontrast(t.ink2, fehler), greaterThanOrEqualTo(4.5));
    });

    renderMatrix('Hint- und Wert-Text bleiben auf allen drei Flaechen AA',
        (tester, c) async {
      final t = c.t;
      for (final f in <Color>[t.field, t.fieldFocus, t.fieldError]) {
        expect(_kontrast(t.ink2, f), greaterThanOrEqualTo(4.5));
        expect(_kontrast(t.ink, f), greaterThanOrEqualTo(4.5));
      }
    });

    // The capsule lives on cards (surf) AND on sheets (bg). A fill equal
    // to either ground vanished there (fix round 1). ≥ 1.2:1 against both
    // at once is unreachable in light mode — bg and surf are only 1.13:1
    // apart and ink2 caps how dark the fill may go — so the rest fill
    // pins 1.2 to surf / 1.1 to bg, the focus fill "not the ground" plus
    // a real lightening step; the softShadow carries the remaining edge.
    renderMatrix('Kapsel-Fuellungen sind weder surf noch surf2 noch bg',
        (tester, c) async {
      final t = c.t;
      for (final f in <Color>[t.field, t.fieldFocus, t.fieldError]) {
        expect(f, isNot(t.surf));
        expect(f, isNot(t.surf2));
        expect(f, isNot(t.bg));
      }
    });

    renderMatrix('Ruhe-Kapsel hebt sich von Karte und Sheet ab',
        (tester, c) async {
      final t = c.t;
      expect(_kontrast(t.field, t.surf), greaterThanOrEqualTo(1.2),
          reason: 'field gegen surf');
      expect(_kontrast(t.field, t.bg), greaterThanOrEqualTo(1.1),
          reason: 'field gegen bg');
    });

    renderMatrix('Fokus-Kapsel bleibt auf Karte und Sheet sichtbar',
        (tester, c) async {
      final t = c.t;
      expect(_kontrast(t.fieldFocus, t.surf), greaterThanOrEqualTo(1.04),
          reason: 'fieldFocus gegen surf');
      expect(_kontrast(t.fieldFocus, t.bg), greaterThanOrEqualTo(1.04),
          reason: 'fieldFocus gegen bg');
      expect(_kontrast(t.fieldFocus, t.field), greaterThanOrEqualTo(1.05),
          reason: 'der Fokus-Schritt muss wahrnehmbar sein');
    });
  });

  group('F8-03 FieldCapsule', () {
    BoxDecoration deco(WidgetTester tester) => tester
        .widget<AnimatedContainer>(
          find
              .descendant(
                of: find.byType(FieldCapsule),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        )
        .decoration! as BoxDecoration;

    renderMatrix('folgt dem FocusNode: field -> fieldFocus, ohne Rand',
        (tester, c) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await c.pump(
        tester,
        FieldCapsule(
          focusNode: node,
          child: TextField(focusNode: node),
        ),
        padding: _rand,
      );
      final t = c.t;
      expect(deco(tester).color, t.field);
      expect(deco(tester).border, isNull);
      expect(deco(tester).boxShadow, isNotEmpty);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(deco(tester).color, t.fieldFocus);

      node.unfocus();
      await tester.pumpAndSettle();
      expect(deco(tester).color, t.field);
    });

    renderMatrix('focused/error/shape/shadow steuern die Kapsel direkt',
        (tester, c) async {
      await c.pump(
        tester,
        const FieldCapsule(
          focused: true,
          shape: SheetFieldShape.pill,
          shadow: false,
          child: Text('x'),
        ),
        padding: _rand,
      );
      final t = c.t;
      expect(deco(tester).color, t.fieldFocus);
      expect(deco(tester).borderRadius, BorderRadius.circular(rPill));
      expect(deco(tester).boxShadow, isNull);

      await c.pump(
        tester,
        const FieldCapsule(focused: true, error: true, child: Text('x')),
        padding: _rand,
      );
      expect(deco(tester).color, t.fieldError, reason: 'Fehler schlaegt Fokus');
    });
  });

  group('F8-03 SheetField', () {
    renderMatrix('ist rahmenlos, weich schattiert und rControl-rund',
        (tester, c) async {
      await c.pump(tester, const SheetField(label: 'E-Mail', hint: 'hint'),
          padding: _rand);
      final deco = _fieldDecoration(tester);
      expect(deco.border, isNull);
      expect(deco.boxShadow, isNotEmpty);
      expect(deco.borderRadius, BorderRadius.circular(rControl));
      expect(deco.color, c.t.field);
    });

    renderMatrix('Fokus hellt die Kapsel auf statt einen Ring zu zeichnen',
        (tester, c) async {
      await c.pump(tester, const SheetField(label: 'Name', hint: 'hint'),
          padding: _rand);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final deco = _fieldDecoration(tester);
      expect(deco.color, c.t.fieldFocus);
      expect(deco.border, isNull);
    });

    renderMatrix('Fehler toent die Flaeche, kein roter Rand', (tester, c) async {
      await c.pump(
        tester,
        const SheetField(label: 'E-Mail', hint: 'hint', errorText: 'Nein'),
        padding: _rand,
      );
      final deco = _fieldDecoration(tester);
      expect(deco.border, isNull);
      expect(deco.color, c.t.fieldError);
      expect(find.text('Nein'), findsOneWidget);
    });

    testWidgets('shape.pill rundet voll', (tester) async {
      await pumpLocalized(
        tester,
        const SheetField(
          label: 'Suche',
          hint: 'hint',
          shape: SheetFieldShape.pill,
        ),
        padding: _rand,
      );
      expect(
          _fieldDecoration(tester).borderRadius, BorderRadius.circular(rPill));
    });

    testWidgets('label ist optional (Suchfelder)', (tester) async {
      await pumpLocalized(tester, const SheetField(hint: 'Suchen'),
          padding: _rand);
      expect(find.byType(TextField), findsOneWidget);
      // The hint is the only Text: no all-caps eyebrow row.
      expect(find.text('SUCHEN'), findsNothing,
          reason: 'ohne label keine Eyebrow-Zeile');
      expect(find.text('Suchen'), findsOneWidget);
    });

    testWidgets('prefix, suffix, autofocus, focusNode, maxLines, formatter',
        (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await pumpLocalized(
        tester,
        SheetField(
          label: 'Gramm',
          hint: '0',
          controller: controller,
          focusNode: node,
          autofocus: true,
          prefix: const Icon(Icons.search_rounded),
          suffix: const Icon(Icons.close_rounded),
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          maxLines: 3,
          maxLength: 4,
        ),
        padding: _rand,
      );
      await tester.pump();

      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(node.hasFocus, isTrue, reason: 'autofocus + eigener FocusNode');

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 3);
      expect(field.maxLength, 4);
      expect(field.keyboardType, TextInputType.number);

      await tester.enterText(find.byType(TextField), '12a3');
      expect(controller.text, '123', reason: 'inputFormatters greifen');
    });

    testWidgets('semanticLabel und fieldKey landen am Textfeld',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        const SheetField(
          hint: 'Suchen',
          semanticLabel: 'Favoriten durchsuchen',
          fieldKey: ValueKey('fav-search'),
        ),
        padding: _rand,
      );
      expect(find.byKey(const ValueKey('fav-search')), findsOneWidget);
      // The text field node keeps its own hint line ("label\nhint"); the
      // spoken name must come first.
      final node = tester.getSemantics(find.byType(TextField));
      expect(node, isSemantics(isTextField: true));
      expect(node.label, startsWith('Favoriten durchsuchen'));
      handle.dispose();
    });

    testWidgets('onSubmitted feuert bei Enter', (tester) async {
      String? gesendet;
      await pumpLocalized(
        tester,
        SheetField(
          hint: 'hint',
          onSubmitted: (v) => gesendet = v,
          textInputAction: TextInputAction.search,
        ),
        padding: _rand,
      );
      await tester.enterText(find.byType(TextField), 'Apfel');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(gesendet, 'Apfel');
    });

    // Replaces `expectRendersInBothBrightnesses`: renderMatrix pumps both
    // palettes and fails the case on any overflow.
    renderMatrix('rendert mit allen Zustaenden', (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(
        tester,
        const Column(
          children: <Widget>[
            SheetField(label: 'A', hint: 'a'),
            SheetField(label: 'B', hint: 'b', errorText: 'Fehler'),
            SheetField(hint: 'c', shape: SheetFieldShape.pill),
            SheetField(label: 'D', hint: 'd', enabled: false),
          ],
        ),
        padding: _rand,
        scrollable: true,
        settle: true,
      );
    });
  });

  // =========================================================================
  // F8-10 — one primary semantics
  // =========================================================================
  group('F8-10 SheetScaffold-Aktion', () {
    renderMatrix('ist ein PrimaryActionButton mit ink-Flaeche',
        (tester, c) async {
      await c.pump(
        tester,
        SheetScaffold(
          title: 'T',
          subtitle: 'U',
          actionLabel: 'Speichern',
          onAction: () {},
          children: const <Widget>[],
        ),
        padding: _rand,
      );
      final button = find.byType(PrimaryActionButton);
      expect(button, findsOneWidget);
      final material = tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first,
      );
      expect(material.color, c.t.ink);
      expect(material.borderRadius, BorderRadius.circular(rButton));
    });

    testWidgets('actionEnabled:false sperrt den PrimaryActionButton',
        (tester) async {
      var calls = 0;
      await pumpLocalized(
        tester,
        SheetScaffold(
          title: 'T',
          subtitle: 'U',
          actionLabel: 'Speichern',
          actionEnabled: false,
          onAction: () => calls++,
          children: const <Widget>[],
        ),
        padding: _rand,
      );
      expect(
        tester
            .widget<PrimaryActionButton>(find.byType(PrimaryActionButton))
            .onTap,
        isNull,
      );
      await tester.tap(find.text('Speichern'), warnIfMissed: false);
      expect(calls, 0);
    });

    test('rButton ist die eine Radius-Quelle fuer Primaer-Flaechen', () {
      expect(rButton, 18);
      expect(kPrimaryButtonHeight, 54);
    });

    renderMatrix(
        'deaktivierter PrimaryActionButton sieht anders aus und bleibt als '
        'Flaeche erkennbar', (tester, c) async {
      Color fillOf() => tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(PrimaryActionButton),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color!;

      await c.pump(tester, PrimaryActionButton(label: 'Weiter', onTap: () {}),
          padding: _rand);
      final t = c.t;
      final aktiv = _ueber(fillOf(), t.surf);
      expect(aktiv, t.ink);

      await c.pump(tester, const PrimaryActionButton(label: 'Weiter'),
          padding: _rand);
      final gesperrt = _ueber(fillOf(), t.surf);
      expect(_kontrast(aktiv, gesperrt), greaterThanOrEqualTo(1.5),
          reason: 'gesperrt muss sich von aktiv unterscheiden');
      expect(_kontrast(gesperrt, t.surf), greaterThanOrEqualTo(1.5),
          reason: 'gesperrt bleibt als Flaeche auf der Karte erkennbar');
      // No ripple: the InkWell has no handler.
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
      final label = tester.widget<Text>(find.text('Weiter'));
      expect(label.style!.color!.a, lessThan(1.0), reason: 'Label gedimmt');
    });
  });

  // =========================================================================
  // F8-04 — AppToggle OFF
  // =========================================================================
  group('F8-04 AppToggle AUS', () {
    renderMatrix('Knopf und Spur sind gegen surf >= 3:1 erkennbar',
        (tester, c) async {
      await c.pump(tester, AppToggle(value: false, onChanged: (_) {}),
          padding: _rand);
      final t = c.t;
      final spurBox = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(AppToggle),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final spur = _ueber(
        (spurBox.decoration! as BoxDecoration).color!,
        t.surf,
      );
      final knopfBox = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AppToggle),
              matching: find.byType(Container),
            )
            .last,
      );
      final knopfDeco = knopfBox.decoration! as BoxDecoration;
      final knopf = _ueber(knopfDeco.color!, spur);
      final rand = _ueber(knopfDeco.border!.top.color, spur);

      // WCAG 1.4.11: the component BOUNDARY against every adjacent color.
      // The knob's edge is its `ink2` ring — it must read against the
      // card, the knob fill and the track (before: 1.10–1.34:1).
      expect(_kontrast(rand, t.surf), greaterThanOrEqualTo(3.0),
          reason: 'Knopf-Rand gegen die Karte');
      expect(_kontrast(rand, knopf), greaterThanOrEqualTo(3.0),
          reason: 'Knopf-Rand gegen den Knopf');
      expect(_kontrast(rand, spur), greaterThanOrEqualTo(3.0),
          reason: 'Knopf-Rand gegen die Spur');
      // The track itself is a state carrier (forest = on): it must be
      // more than a whisper against the card.
      expect(_kontrast(spur, t.surf), greaterThanOrEqualTo(1.5),
          reason: 'Spur gegen die Karte');
    });
  });

  // =========================================================================
  // F8-08 — macro colors as 9 px bars
  // =========================================================================
  group('F8-08 Makro-Farben', () {
    renderMatrix('jede Makro-Farbe erreicht 3:1 auf surf', (tester, c) async {
      final t = c.t;
      for (final paar in <(String, Color)>[
        ('protein', t.protein),
        ('carbs', t.carbs),
        ('fat', t.fat),
        ('snack', t.snack),
      ]) {
        expect(_kontrast(paar.$2, t.surf), greaterThanOrEqualTo(3.0),
            reason: '${c.label}: ${paar.$1}-Balken auf der Karte');
      }
    });

    renderMatrix('readableOnTint(carbs) bleibt AA auf seiner Tint',
        (tester, c) async {
      final t = c.t;
      final tint = _ueber(t.carbs.withValues(alpha: 0.16), t.surf);
      expect(_kontrast(t.readableOnTint(t.carbs), tint),
          greaterThanOrEqualTo(4.5));
    });
  });

  // =========================================================================
  // F8-09 — text scaling as a layout feature
  // =========================================================================
  group('F8-09 Textskalierung', () {
    testWidgets('MealAvatar nutzt keine FittedBox mehr und waechst mit',
        (tester) async {
      await pumpLocalized(
        tester,
        MealAvatar(letter: 'F', color: AppTokens.light.carbs),
        brightness: Brightness.light,
        padding: _rand,
      );
      expect(
        find.descendant(
          of: find.byType(MealAvatar),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      expect(tester.getSize(find.byType(MealAvatar)), const Size(40, 40));
      final klein = tester.getSize(find.text('F'));

      await pumpLocalized(
        tester,
        MealAvatar(letter: 'F', color: AppTokens.light.carbs),
        brightness: Brightness.light,
        padding: _rand,
        textScale: 2.0,
      );
      expect(tester.takeException(), isNull);
      final kachel = tester.getSize(find.byType(MealAvatar));
      expect(kachel.width, greaterThan(40));
      expect(kachel.width, lessThanOrEqualTo(60));
      expect(tester.getSize(find.text('F')).height, greaterThan(klein.height),
          reason: 'die Ziffer skaliert mit dem Systemfont');
    });

    testWidgets('scaledWidth reserviert Breite, gedeckelt', (tester) async {
      late double normal;
      late double gross;
      await pumpLocalized(
        tester,
        Builder(builder: (context) {
          normal = scaledWidth(context, 84);
          return const SizedBox();
        }),
        padding: _rand,
      );
      await pumpLocalized(
        tester,
        Builder(builder: (context) {
          gross = scaledWidth(context, 84, max: 124);
          return const SizedBox();
        }),
        padding: _rand,
        textScale: 2.0,
      );
      expect(normal, 84);
      expect(gross, 124);
    });

    testWidgets('ScaledWidth ist die Widget-Form davon', (tester) async {
      await pumpLocalized(
        tester,
        const Row(
          children: <Widget>[
            ScaledWidth(base: 60, child: Text('Fett')),
          ],
        ),
        padding: _rand,
        textScale: 1.5,
      );
      expect(tester.getSize(find.byType(ScaledWidth)).width, 90);
    });
  });

  // =========================================================================
  // F8-06 — sheet family
  // =========================================================================
  group('F8-06 showEatovaSheet', () {
    Future<void> pumpOpener(
      WidgetTester tester,
      void Function(BuildContext) open,
    ) {
      return pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('oeffnen'),
          ),
        ),
        brightness: Brightness.light,
        padding: _rand,
      );
    }

    testWidgets('Standard: Handle an, Scrim = t.scrim, Handle 40x4',
        (tester) async {
      await pumpOpener(tester, (c) => showEatovaSheet<void>(c, const Text('Inhalt')));
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();

      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.showDragHandle, isTrue);
      final route =
          ModalRoute.of(tester.element(find.text('Inhalt'))) as ModalRoute;
      expect(route.barrierColor, AppTokens.light.scrim);
      final theme = buildEatovaTheme(Brightness.light).bottomSheetTheme;
      expect(theme.dragHandleSize, const Size(40, 4));
      expect(theme.dragHandleColor, AppTokens.light.line);
    });

    testWidgets('dragHandle:false zeichnet keinen Material-Griff',
        (tester) async {
      await pumpOpener(
        tester,
        (c) => showEatovaSheet<void>(
          c,
          const Text('Inhalt'),
          dragHandle: false,
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.showDragHandle, isFalse);
    });

    testWidgets('transparentShell laesst das Sheet selbst zeichnen',
        (tester) async {
      await pumpOpener(
        tester,
        (c) => showEatovaSheet<void>(
          c,
          const Text('Inhalt'),
          transparentShell: true,
          dragHandle: false,
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.backgroundColor, Colors.transparent);
    });

    testWidgets('barrierColor ueberschreibt den Scrim', (tester) async {
      await pumpOpener(
        tester,
        (c) => showEatovaSheet<void>(
          c,
          const Text('Inhalt'),
          barrierColor: const Color(0x80FF0000),
        ),
      );
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();
      final route =
          ModalRoute.of(tester.element(find.text('Inhalt'))) as ModalRoute;
      expect(route.barrierColor, const Color(0x80FF0000));
    });

    renderMatrix('SheetHandle: 40x4, line, ohne Semantik', (tester, c) async {
      final handle = tester.ensureSemantics();
      await c.pump(tester, const SheetHandle(), padding: _rand);
      final bar = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SheetHandle),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(tester.getSize(find.byWidget(bar)), const Size(40, 4));
      expect((bar.decoration! as BoxDecoration).color, c.t.line);
      expect(
        find.descendant(
          of: find.byType(SheetHandle),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    renderMatrix('scrim ist ein Token und halbtransparent', (tester, c) async {
      expect(c.t.scrim.a, inExclusiveRange(0.3, 0.8),
          reason: '${c.label}: Scrim muss den Hintergrund noch zeigen');
    });
  });

  // =========================================================================
  // F8-07 — chip family
  // =========================================================================
  group('F8-07 FilterChipPill', () {
    Material materialOf(WidgetTester tester) => tester.widget<Material>(
          find
              .descendant(
                of: find.byType(FilterChipPill),
                matching: find.byType(Material),
              )
              .first,
        );

    testWidgets('icon steht vor dem Label', (tester) async {
      await pumpLocalized(
        tester,
        const Align(
          child: FilterChipPill(
            label: 'Eigene',
            selected: false,
            icon: Icons.person_outline_rounded,
          ),
        ),
        padding: _rand,
      );
      expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
      final icon = tester.getTopLeft(find.byIcon(Icons.person_outline_rounded));
      final text = tester.getTopLeft(find.text('Eigene'));
      expect(icon.dx, lessThan(text.dx));
    });

    testWidgets('size.sm ist kleiner als md', (tester) async {
      await pumpLocalized(
        tester,
        const Align(
          child: FilterChipPill(
            label: 'Alle',
            selected: false,
            size: FilterChipSize.md,
          ),
        ),
        padding: _rand,
      );
      final md = tester.getSize(find.byType(FilterChipPill));
      await pumpLocalized(
        tester,
        const Align(
          child: FilterChipPill(
            label: 'Alle',
            selected: false,
            size: FilterChipSize.sm,
          ),
        ),
        padding: _rand,
      );
      final sm = tester.getSize(find.byType(FilterChipPill));
      expect(sm.height, lessThan(md.height));
      expect(sm.width, lessThan(md.width));
    });

    testWidgets('tone.slot zeigt einen Farbpunkt', (tester) async {
      await pumpLocalized(
        tester,
        Align(
          child: FilterChipPill(
            label: 'Fruehstueck',
            selected: false,
            tone: FilterChipTone.slot,
            dotColor: AppTokens.dark.carbs,
          ),
        ),
        padding: _rand,
      );
      expect(find.byKey(const ValueKey('filter-chip-dot')), findsOneWidget);
    });

    renderMatrix('Selektion ist immer forest + onForest, Radius rChip',
        (tester, c) async {
      final t = c.t;
      for (final tone in FilterChipTone.values) {
        await c.pump(
          tester,
          Align(
            child: FilterChipPill(
              label: 'Alle',
              selected: true,
              tone: tone,
              dotColor: t.snack,
              icon: Icons.star_rounded,
            ),
          ),
          padding: _rand,
        );
        final material = materialOf(tester);
        expect(material.color, t.forest, reason: '$tone');
        expect(material.borderRadius, BorderRadius.circular(rChip));
        final text = tester.widget<Text>(find.text('Alle'));
        expect(text.style?.color, t.onForest);
        final icon = tester.widget<Icon>(find.byIcon(Icons.star_rounded));
        expect(icon.color, t.onForest);
      }
    });

    testWidgets('semanticLabel ersetzt das sichtbare Label, ohne Doppel',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        const Align(
          child: FilterChipPill(
            label: 'Alle',
            selected: true,
            semanticLabel: 'Alle Rezepte',
          ),
        ),
        padding: _rand,
      );
      expect(
        tester.getSemantics(find.byType(FilterChipPill)),
        isSemantics(label: 'Alle Rezepte', isButton: true, isSelected: true),
      );
      // Without a spoken name the visible label still reaches the reader.
      await pumpLocalized(
        tester,
        const Align(child: FilterChipPill(label: 'Alle', selected: false)),
        padding: _rand,
      );
      expect(
        tester.getSemantics(find.byType(FilterChipPill)),
        isSemantics(label: 'Alle', isButton: true),
      );
      handle.dispose();
    });

    // Replaces `expectRendersInBothBrightnesses` + `expectSurvivesTextScale`:
    // hell/dunkel x 1.0/2.0 = four cases, each overflow-checked.
    renderMatrix('alle Varianten ueberstehen jede Kombination',
        (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(
        tester,
        Wrap(
          spacing: 8,
          children: <Widget>[
            const FilterChipPill(label: 'Alle', selected: true),
            const FilterChipPill(
              label: 'Eigene',
              selected: false,
              icon: Icons.person_outline_rounded,
              size: FilterChipSize.sm,
            ),
            FilterChipPill(
              label: 'Fruehstueck',
              selected: false,
              tone: FilterChipTone.slot,
              dotColor: c.t.carbs,
            ),
          ],
        ),
        padding: _rand,
        scrollable: true,
        settle: true,
      );
    }, textScales: const <double>[1.0, 2.0]);
  });

  // =========================================================================
  // F8-11 — radii from the scale
  // =========================================================================
  group('F8-11 Radius-Skala', () {
    testWidgets('AppCard rundet mit rCard', (tester) async {
      await pumpLocalized(tester, const AppCard(child: Text('K')),
          padding: _rand);
      expect(
        decorationOf(tester, find.byType(AppCard)).borderRadius,
        BorderRadius.circular(rCard),
      );
    });

    testWidgets('PrimaryActionButton rundet mit rButton', (tester) async {
      await pumpLocalized(tester, const PrimaryActionButton(label: 'Weiter'),
          padding: _rand);
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(PrimaryActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.borderRadius, BorderRadius.circular(rButton));
    });

    testWidgets('SquareIconButton und IconTile runden mit rChip',
        (tester) async {
      await pumpLocalized(
        tester,
        Row(
          children: <Widget>[
            SquareIconButton(icon: Icons.close_rounded, onTap: () {}),
            const IconTile(icon: Icons.bolt_rounded),
          ],
        ),
        padding: _rand,
      );
      expect(
        decorationOf(tester, find.byType(SquareIconButton)).borderRadius,
        BorderRadius.circular(rChip),
      );
      expect(
        decorationOf(tester, find.byType(IconTile)).borderRadius,
        BorderRadius.circular(rChip),
      );
    });
  });
}
