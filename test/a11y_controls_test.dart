import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

// ---------------------------------------------------------------------------
// A11y-Zusicherungen der gemeinsamen Bedienelemente (Verifikation 2026-08-09,
// Bereich „Bedienbarkeit, Textskalierung, Bewegung").
//
// Warum eigene Datei: test/widgets/design/controls_test.dart prueft, was die
// Bausteine ZEICHNEN. Hier steht, was sie einem Screenreader SAGEN — und das
// faellt bei einem Umbau lautlos weg, weil kein Pixel sich aendert. Genau so
// ist es beim Design-Refactor passiert: aus `FilledButton`/`IconButton`
// wurden blanke `InkWell`s und `GestureDetector`s, die weder `isButton` noch
// einen Enabled- oder Auswahl-Zustand tragen.
//
// Der Coach-Composer steht bewusst mit drin: seine drei Icon-Knoepfe
// (Anhang, Mikrofon, Senden) hatten GAR KEINE Semantik — „Senden" war fuer
// TalkBack/VoiceOver nicht einmal als Schaltflaeche erkennbar.
// ---------------------------------------------------------------------------

Widget _harness(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    // PageHeader liest jetzt context.l10n (Review-Fixwelle Finding 2) — ohne
    // Lokalisierung wirft AppLocalizations.of() beim Bau des Zurueck-Knopfs
    // (docs/I18N_PAKETE.md, "Bekannte Fallen"). Generierte Listen statt
    // eigenem Block, wie dort empfohlen.
    locale: const Locale('de'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: SafeArea(child: Padding(
      padding: const EdgeInsets.all(20),
      child: child,
    ))),
  );
}

void main() {
  group('PrimaryActionButton', () {
    // Vorher lag diese Huelle DOPPELT im Produktivcode (onboarding_screen.dart
    // und settings_screen.dart), beide mit dem Kommentar „gehoert in die
    // Bibliothek". Jetzt liegt sie in der Bibliothek — dieser Test haelt sie
    // dort fest.
    testWidgets('ist eine Schaltflaeche und sagt seinen Enabled-Zustand',
        (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _harness(PrimaryActionButton(label: 'Essen loggen', onTap: () {})),
      );
      expect(
        tester.getSemantics(find.byType(PrimaryActionButton)),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
      );

      // `onTap == null` ist app-weit die Sperr-Konvention (settings-save,
      // SheetScaffold): ohne `hasEnabledState` klaenge der gesperrte Knopf
      // wie ein normaler, der nichts tut.
      await tester.pumpWidget(
        _harness(const PrimaryActionButton(label: 'Speichern')),
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

      await tester.pumpWidget(
        _harness(
          Row(
            children: <Widget>[
              FilterChipPill(label: 'Alle', selected: true, onTap: () {}),
              const SizedBox(width: 8),
              FilterChipPill(label: 'Eigene', selected: false, onTap: () {}),
            ],
          ),
        ),
      );

      // Die Auswahl steckt sonst allein in der Fuellfarbe — in der
      // Rezepte-Filterleiste waere fuer einen Screenreader-Nutzer nicht
      // feststellbar, welcher Filter aktiv ist.
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

      await tester.pumpWidget(
        _harness(
          SegmentedPill(
            options: const <String>['Metrisch', 'Imperial'],
            selected: 'Metrisch',
            onChanged: (_) {},
          ),
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
      // Ein Semantics-Label ist GESPROCHENER Text: die ASCII-Umschrift
      // „Zurueck" liest TalkBack als „zurookk" vor.
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_harness(const PageHeader(title: 'Mein Profil')));

      expect(
        tester.getSemantics(find.byType(SquareIconButton)),
        isSemantics(isButton: true, label: 'Zurück'),
      );
      handle.dispose();
    });
  });

  group('MacroBar', () {
    // Die Beschriftungsspalte der Vorlage ist fuer „Carbs" gerechnet (52 px).
    // Auf Deutsch heisst das Makro „Kohlenhydrate" — es brach damit SCHON BEI
    // SYSTEMSCHRIFT 1.0 zweizeilig um, waehrend „Protein" und „Fett" einzeilig
    // blieben; die drei Balken standen sichtbar versetzt.
    //
    // Der Test laedt die gebuendelte Archivo: das Ersatzfont des Testbindings
    // rendert JEDES Zeichen quadratisch in Schriftgroesse und ist damit rund
    // doppelt so breit wie die echte Schrift — eine Breitenmessung darauf
    // waere ohne Aussage ueber das Geraet.
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

      await tester.pumpWidget(
        _harness(
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
