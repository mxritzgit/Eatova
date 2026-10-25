import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

// pumpLocalized/renderMatrix.
import '../../support/harness.dart';

// ---------------------------------------------------------------------------
// Design-system contracts (fix run 2026-08-27, package H): themed buttons,
// the borderless input language (theme, FieldCapsule, SheetField), the
// disabled primary, AppToggle states, text scaling, the sheet family and the
// chip selection. Token-only contrast that app_tokens_test.dart already
// measures, and pure radius/size pins, are not repeated here.
//
// Contrast is measured, not asserted by token name: WCAG relative luminance,
// translucent layers composited first.
//
// Every claim that used to be spelled out once per palette now runs through
// `renderMatrix` with `bothBrightnesses`, one test per brightness with the
// combination appended to the test name. `c.t` is the palette of that case, so the
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
    }, brightnesses: bothBrightnesses);

    // Dark redesign 2026-09-28: the primary action is the accent pill.
    renderMatrix('FilledButton-Flaeche (Akzent) auf surf >= 3:1, Text on-accent',
        (tester, c) async {
      final t = c.t;
      final theme = buildEatovaTheme(c.brightness);
      final style = theme.filledButtonTheme.style!;
      final bgColor = style.backgroundColor!.resolve(<WidgetState>{})!;
      final fg = style.foregroundColor!.resolve(<WidgetState>{})!;
      expect(bgColor, t.accentFill);
      expect(fg, t.onAccentFill);
      expect(
        style.textStyle!.resolve(<WidgetState>{})!.fontWeight,
        FontWeight.w800,
      );
      expect(_kontrast(bgColor, t.surf), greaterThanOrEqualTo(3.0));
      expect(_kontrast(fg, bgColor), greaterThanOrEqualTo(4.5));
      final fokus = style.overlayColor!.resolve(<WidgetState>{
        WidgetState.focused,
      })!;
      expect(Color.alphaBlend(fokus, bgColor).computeLuminance(),
          greaterThan(bgColor.computeLuminance()),
          reason: 'Fokus = Aufhellung, in BEIDEN Modi');
      final shape = style.shape!.resolve(<WidgetState>{})!;
      expect(shape, isA<RoundedRectangleBorder>());
      expect((shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(rButton));
      // Touch floor only — the 54 px primary height stays with
      // PrimaryActionButton and the sheet action.
      expect(style.minimumSize!.resolve(<WidgetState>{})!.height,
          kButtonMinHeight);
    }, brightnesses: bothBrightnesses);

    // The secondary action: a tonal `softFill` pill with an `ink` label, 700
    // (`softFill` holds on the light page ground, where `surf2` vanished).
    renderMatrix('OutlinedButton ist die tonale Sekundaer-Pille, 48 px',
        (tester, c) async {
      final t = c.t;
      final style = buildEatovaTheme(c.brightness).outlinedButtonTheme.style!;
      final fill = style.backgroundColor!.resolve(<WidgetState>{})!;
      final fg = style.foregroundColor!.resolve(<WidgetState>{})!;
      expect(fill, t.softFill);
      expect(style.side!.resolve(<WidgetState>{}), BorderSide.none);
      expect(fg, t.ink);
      expect(_kontrast(fg, fill), greaterThanOrEqualTo(4.5));
      expect(
        style.textStyle!.resolve(<WidgetState>{})!.fontWeight,
        FontWeight.w700,
      );
      final shape =
          style.shape!.resolve(<WidgetState>{})! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(rButton));
      expect(style.minimumSize!.resolve(<WidgetState>{})!.height,
          kButtonMinHeight);
    }, brightnesses: bothBrightnesses);
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
    }, brightnesses: bothBrightnesses);

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
      // Hint and value text on all three fills: app_tokens_test.dart ('Hint
      // und Wert tragen auf allen Feld-Fuellungen').
    }, brightnesses: bothBrightnesses);

    // The capsule lives on cards (surf) AND on sheets (bg). A fill equal
    // to either ground vanished there (fix round 1). ≥ 1.2:1 against both
    // at once is unreachable in light mode — bg and surf are only 1.13:1
    // apart and ink2 caps how dark the fill may go — so the rest fill
    // pins 1.2 to surf / 1.1 to bg, the focus fill "not the ground" plus
    // a real lightening step; the softShadow carries the remaining edge.
    renderMatrix('Ruhe- und Fokus-Kapsel bleiben auf Karte und Sheet sichtbar',
        (tester, c) async {
      final t = c.t;
      expect(_kontrast(t.field, t.surf), greaterThanOrEqualTo(1.2),
          reason: 'field gegen surf');
      expect(_kontrast(t.field, t.bg), greaterThanOrEqualTo(1.1),
          reason: 'field gegen bg');
      expect(_kontrast(t.fieldFocus, t.surf), greaterThanOrEqualTo(1.04),
          reason: 'fieldFocus gegen surf');
      expect(_kontrast(t.fieldFocus, t.bg), greaterThanOrEqualTo(1.04),
          reason: 'fieldFocus gegen bg');
      expect(_kontrast(t.fieldFocus, t.field), greaterThanOrEqualTo(1.05),
          reason: 'der Fokus-Schritt muss wahrnehmbar sein');
      // No fill may BE one of the grounds it sits on.
      for (final f in <Color>[t.field, t.fieldFocus, t.fieldError]) {
        expect(f, isNot(t.surf));
        expect(f, isNot(t.surf2));
        expect(f, isNot(t.bg));
      }
    }, brightnesses: bothBrightnesses);
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
    }, brightnesses: bothBrightnesses);

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
    }, brightnesses: bothBrightnesses);
  });

  group('F8-03 SheetField', () {
    renderMatrix('ist rahmenlos und weich schattiert; Fokus hellt die Kapsel '
        'auf statt einen Ring zu zeichnen', (tester, c) async {
      await c.pump(tester, const SheetField(label: 'E-Mail', hint: 'hint'),
          padding: _rand);
      var deco = _fieldDecoration(tester);
      expect(deco.border, isNull);
      expect(deco.boxShadow, isNotEmpty);
      expect(deco.color, c.t.field);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      deco = _fieldDecoration(tester);
      expect(deco.color, c.t.fieldFocus);
      expect(deco.border, isNull);
    }, brightnesses: bothBrightnesses);

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
    }, brightnesses: bothBrightnesses);

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

    // Rendering in both palettes and at 2.0: sheets_test.dart ('Sheets
    // rendern in hell und dunkel', 'Sheets ueberstehen textScaler 2.0').
  });

  // =========================================================================
  // F8-10 — one primary semantics. The sheet action IS the accent
  // PrimaryActionButton and actionEnabled:false locks it: sheets_test.dart
  // ('destructive faerbt die Aktionsflaeche auf danger', 'actionEnabled:false
  // schluckt den Tap und daempft'); the radius scale: app_tokens_test.dart
  // ('Form-Skala folgt dem Design').
  // =========================================================================
  group('F8-10 PrimaryActionButton', () {
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
      expect(aktiv, t.accentFill);

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
    }, brightnesses: bothBrightnesses);
  });

  // =========================================================================
  // F8-04 — AppToggle OFF and ON
  // =========================================================================
  group('F8-04 AppToggle', () {
    /// The painted track and knob of the pumped toggle, both composited
    /// onto the card (`surf`) they sit on in the goals screen.
    ({Color spur, Color knopf, BoxDecoration knopfDeco}) farben(
      WidgetTester tester,
      AppTokens t,
    ) {
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
      final knopfDeco = tester
          .widget<Container>(
            find
                .descendant(
                  of: find.byType(AppToggle),
                  matching: find.byType(Container),
                )
                .last,
          )
          .decoration! as BoxDecoration;
      return (
        spur: spur,
        knopf: _ueber(knopfDeco.color!, spur),
        knopfDeco: knopfDeco,
      );
    }

    renderMatrix('AUS: der volle Knopf ist gegen Karte und Spur >= 3:1',
        (tester, c) async {
      await c.pump(tester, AppToggle(value: false, onChanged: (_) {}),
          padding: _rand);
      final t = c.t;
      final (:spur, :knopf, :knopfDeco) = farben(tester, t);

      // WCAG 1.4.11: the component BOUNDARY against every adjacent color.
      // Since 2026-10-03 that is the solid knob itself (before the ring of
      // a hollow knob, and before that 1.10–1.34:1).
      expect(knopfDeco.border, isNull, reason: 'voller Knopf, kein Ring');
      expect(_kontrast(knopf, t.surf), greaterThanOrEqualTo(3.0),
          reason: 'Knopf gegen die Karte');
      expect(_kontrast(knopf, spur), greaterThanOrEqualTo(3.0),
          reason: 'Knopf gegen die Spur');
      // The track itself is a state carrier: it must be more than a
      // whisper against the card.
      expect(_kontrast(spur, t.surf), greaterThanOrEqualTo(1.5),
          reason: 'Spur gegen die Karte');
    }, brightnesses: bothBrightnesses);

    renderMatrix('AN: Akzent-Spur und Knopf sind >= 3:1 erkennbar',
        (tester, c) async {
      await c.pump(tester, AppToggle(value: true, onChanged: (_) {}),
          padding: _rand);
      final t = c.t;
      final (:spur, :knopf, knopfDeco: _) = farben(tester, t);

      // The app's selection language ([SelectionTone]): a solid fill, like
      // the chosen settings segment. A tint (the old `forest`) read as off.
      expect(spur, t.selectedFill, reason: 'volle Auswahl-Spur');
      expect(_kontrast(spur, t.surf), greaterThanOrEqualTo(3.0),
          reason: 'Spur gegen die Karte');
      expect(_kontrast(knopf, spur), greaterThanOrEqualTo(3.0),
          reason: 'Knopf gegen die Spur');
    }, brightnesses: bothBrightnesses);
  });

  // F8-08 (macro colours carry 3:1 on the card and on the track):
  // app_tokens_test.dart ('Grafik-Toene tragen 3:1 auf Karte und Spur').

  // =========================================================================
  // F8-09 — text scaling as a layout feature
  // =========================================================================
  group('F8-09 Textskalierung', () {
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

    testWidgets('Standard: Handle an, Scrim = t.scrim', (tester) async {
      await pumpOpener(tester, (c) => showEatovaSheet<void>(c, const Text('Inhalt')));
      await tester.tap(find.text('oeffnen'));
      await tester.pumpAndSettle();

      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.showDragHandle, isTrue);
      final route =
          ModalRoute.of(tester.element(find.text('Inhalt'))) as ModalRoute;
      expect(route.barrierColor, AppTokens.light.scrim);
      // Not `line`: the 6 % hairline was invisible on the sheet ground.
      expect(buildEatovaTheme(Brightness.light).bottomSheetTheme.dragHandleColor,
          AppTokens.light.inkDisabled);
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

    renderMatrix('SheetHandle: inkDisabled, ohne Semantik', (tester, c) async {
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
      // Not `line`: the 6 % hairline was invisible on the sheet ground.
      expect((bar.decoration! as BoxDecoration).color, c.t.inkDisabled);
      // Decoration: the sheet's close path speaks for it (see
      // auth/account_change_sheet_dismiss_test.dart).
      expect(
        find.descendant(
          of: find.byType(SheetHandle),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    }, brightnesses: bothBrightnesses);
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

    // Since P9-02 the language is SelectionTone instead of `forest` +
    // `onForest` (forest is itself a dark surface and carried the selected
    // state at 1.33:1 in dark mode); since the dark redesign (2026-09-28)
    // SelectionTone is the accent pair. The numbers live in
    // review0829_selection_contrast_test.
    renderMatrix('Selektion ist immer Akzent + on-accent, voll rund',
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
        expect(material.color, t.accentFill, reason: '$tone');
        expect(material.borderRadius, BorderRadius.circular(rPill));
        final text = tester.widget<Text>(find.text('Alle'));
        expect(text.style?.color, t.onAccentFill);
        final icon = tester.widget<Icon>(find.byIcon(Icons.star_rounded));
        expect(icon.color, t.onAccentFill);
      }
    }, brightnesses: bothBrightnesses);

    testWidgets('semanticLabel ersetzt das sichtbare Label, ohne Doppel',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        Align(
          child: FilterChipPill(
            label: 'Alle',
            selected: true,
            semanticLabel: 'Alle Rezepte',
            onTap: () {},
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
        Align(
          child: FilterChipPill(label: 'Alle', selected: false, onTap: () {}),
        ),
        padding: _rand,
      );
      expect(
        tester.getSemantics(find.byType(FilterChipPill)),
        isSemantics(label: 'Alle', isButton: true),
      );
      handle.dispose();
    });

    // Rendering in both palettes and at 2.0: controls_test.dart ('alle
    // Bedienelemente rendern in hell und dunkel', '... ueberstehen
    // textScaler 2.0').
  });
}
