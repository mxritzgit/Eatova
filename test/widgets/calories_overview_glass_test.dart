// Die Tages-Zusammenfassung des Food-Tabs rastert nichts Teures.
//
// UMGESCHRIEBEN im Design-Refactor 2026-08 (vorher: „Die Glass-Kalorienkarte
// rastert keinen Backdrop-Filter mehr"). Der alte Test hielt die Glas-Optik
// fest — forgeGlassFill, forgeGlassBorder, ein ImageFiltered-Glow und die
// Abwesenheit eines BackdropFilters. Genau diese Flaeche loest der neue
// Entwurf ab: die Karte traegt jetzt die ruhige AppCard-Sprache
// (Token-Fuellung + 1-px-Rand), der Kalorien-Hero zieht in den Heute-Tab.
//
// Der PRUEFGEGENSTAND wandert 1:1 mit: die Karte traegt bewusst Fuellung und
// Haarlinie, und sie rastert nichts, was pro Frame Zeit kostet — jetzt also
// weder BackdropFilter NOCH ImageFiltered (der teure Glow gehoerte zur
// abgeloesten Sprache). Dazu die Zahlenformate, die der Vertrag zeichengenau
// festnagelt.
//
// Das Projekt fuehrt KEINE Golden-Tests (weder matchesGoldenFile noch ein
// test/goldens-Verzeichnis existieren), deshalb weiterhin die
// Widget-Baum-Variante.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/daily_summary_card.dart';

Future<void> _pumpCard(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  int burnedKcal = 180,
  int dailyConsumedKcal = 1200,
  int kcalGoal = 2200,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DailySummaryCard(
                  dailyConsumedKcal: dailyConsumedKcal,
                  kcalGoal: kcalGoal,
                  burnedKcal: burnedKcal,
                  macroProgress: MacroProgress.empty,
                  profile: const UserProfile(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

/// Die Tokens des gepumpten Themes — dieselbe Quelle, aus der die Karte liest.
AppTokens _tokens(WidgetTester tester) => AppTokens.of(
      tester.element(find.byType(DailySummaryCard)),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Die Zusammenfassung traegt in $brightness Flaeche und '
        'Haarlinie aus den Tokens', (tester) async {
      await _pumpCard(tester, brightness: brightness);

      final t = _tokens(tester);
      final karte = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
          matching: find.byType(Container),
          matchRoot: true,
        ).first,
      );
      final deko = karte.decoration! as BoxDecoration;

      expect(deko.color, t.surf);
      expect(deko.border, Border.all(color: t.line));
      expect(deko.borderRadius, BorderRadius.circular(rCard));
    });

    testWidgets('Die Zusammenfassung rastert in $brightness nichts Teures',
        (tester) async {
      await _pumpCard(tester, brightness: brightness);

      final karte = find.byKey(const ValueKey('analyse-daily-kcal-card'));
      expect(
        find.descendant(of: karte, matching: find.byType(BackdropFilter)),
        findsNothing,
        reason: 'Ein Blur ueber einer einfarbigen Flaeche kostet in jedem '
            'Frame Zeit, ohne etwas zu zeigen',
      );
      expect(
        find.descendant(of: karte, matching: find.byType(ImageFiltered)),
        findsNothing,
        reason: 'Der weiche Glow gehoerte zur abgeloesten Glas-Sprache',
      );
    });
  }

  testWidgets('Kalorien tragen den Tausenderpunkt', (tester) async {
    await _pumpCard(tester);

    expect(find.text('2.200 kcal'), findsOneWidget);
    expect(find.text('1.200 kcal'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.byKey(const ValueKey('analyse-daily-kcal-total')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Ohne Schrittdaten steht in VERBRANNT ein Gedankenstrich',
      (tester) async {
    await _pumpCard(tester, burnedKcal: 0);

    expect(find.text('—'), findsOneWidget);
    // Ein zweites „0 kcal" im Baum machte die Zaehlungen der Flow-Tests
    // mehrdeutig — deshalb ist das hier keine Kosmetik.
    expect(find.text('0 kcal'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Die verbleibenden Kalorien (Verifikation 2026-08-09).
  //
  // Die abgeloeste CaloriesOverviewCard zeigte sie als grosse Zahl mit
  // Fortschrittsring („VERBLEIBENDE KCAL", calories_overview_card.dart:78).
  // Mit der neuen Karte waren sie aus dem Food-Tab verschwunden — genau die
  // Zahl, die man beim Loggen braucht („passt das noch rein?").
  // -------------------------------------------------------------------------
  group('Verbleibende Kalorien', () {
    testWidgets('stehen als fuehrende Groesse in der Karte', (tester) async {
      await _pumpCard(tester); // 2200 Ziel + 180 verbrannt - 1200 gegessen

      expect(_textOf(tester, 'analyse-daily-kcal-remaining'), '1.180');
      expect(find.text('kcal übrig'), findsOneWidget);
      expect(find.text('kcal drüber'), findsNothing);
      // Sie sitzen IN der Karte, nicht daneben.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
          matching: find.byKey(const ValueKey('analyse-daily-kcal-remaining')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('zeigen beim Ueberziehen den Betrag und wechseln die Einheit',
        (tester) async {
      await _pumpCard(tester, dailyConsumedKcal: 2600, burnedKcal: 0);

      // Kein Minuszeichen an der Zahl — das Vorzeichen traegt die Einheit.
      expect(_textOf(tester, 'analyse-daily-kcal-remaining'), '400');
      expect(find.text('kcal drüber'), findsOneWidget);
      expect(find.text('kcal übrig'), findsNothing);
    });

    testWidgets('stimmen auch an einem Nicht-Heute-Tag (burned hart 0)',
        (tester) async {
      // Dokumentierter Sonderfall (DESIGN_REFACTOR §5): an einem Archivtag
      // reicht die Schale 0 durch. Die VERBRANNT-Kachel zeigt dann „—", die
      // Restzahl muss trotzdem gegen das reine Tagesziel stimmen.
      await _pumpCard(tester, burnedKcal: 0, dailyConsumedKcal: 1200);

      expect(find.text('—'), findsOneWidget);
      expect(_textOf(tester, 'analyse-daily-kcal-remaining'), '1.000');
      expect(_textOf(tester, 'analyse-daily-kcal-goal'), '2.200 kcal');
    });

    testWidgets('die ZIEL-Kachel bleibt roh — ohne das Verbrannte',
        (tester) async {
      await _pumpCard(tester, burnedKcal: 180);

      // 2.380 waere „Ziel + verbrannt" und widerspraeche dem Heute-Tab.
      expect(_textOf(tester, 'analyse-daily-kcal-goal'), '2.200 kcal');
      expect(find.text('2.380 kcal'), findsNothing);
    });

    testWidgets('der Fortschritt ist fuer einen Screenreader vorhanden',
        (tester) async {
      // Das war in der alten Karte die EINZIGE Stelle, an der ein Screenreader
      // den Tagesfortschritt erfuhr (calories_overview_card.dart:140). Der
      // TickGauge ist ein CustomPaint — ohne Annotation ist er stumm.
      final handle = tester.ensureSemantics();
      await _pumpCard(tester, dailyConsumedKcal: 1100, kcalGoal: 2200,
          burnedKcal: 0);

      expect(find.bySemanticsLabel('Kalorienfortschritt'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Kalorienfortschritt'))
            .value,
        '50 Prozent des Tagesziels gegessen',
      );
      handle.dispose();
    });

    testWidgets('ein Tagesziel von 0 stuerzt nicht ab', (tester) async {
      // Kaputte Profile kommen aus dem Netz; `goal <= 0 -> 1` verhindert die
      // Division durch 0 in `progress`.
      await _pumpCard(tester, kcalGoal: 0, dailyConsumedKcal: 400,
          burnedKcal: 0);

      expect(tester.takeException(), isNull);
      expect(_textOf(tester, 'analyse-daily-kcal-remaining'), '399');
      expect(find.text('kcal drüber'), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('ueberleben in $brightness die Systemschrift 2.0',
          (tester) async {
        await _pumpCard(
          tester,
          brightness: brightness,
          textScaler: const TextScaler.linear(2.0),
          dailyConsumedKcal: 12345,
          kcalGoal: 99999,
          burnedKcal: 1234,
        );

        expect(tester.takeException(), isNull);
        // Die Zahl schrumpft, statt die Karte zu sprengen. Gemessen wird die
        // FITTEDBOX: der Text darin behaelt seine ungeschrumpfte Groesse, die
        // Verkleinerung steckt in der Transformation darueber.
        final karte = find.byKey(const ValueKey('analyse-daily-kcal-card'));
        final zahl =
            find.byKey(const ValueKey('analyse-daily-kcal-remaining'));
        expect(zahl, findsOneWidget);
        final kasten =
            find.ancestor(of: zahl, matching: find.byType(FittedBox)).first;
        expect(tester.widget<FittedBox>(kasten).fit, BoxFit.scaleDown);
        expect(
          tester.getSize(kasten).width,
          lessThanOrEqualTo(tester.getSize(karte).width),
        );
      });
    }
  });

  testWidgets('Der Makro-Balken bleibt beim Format ohne Leerzeichen',
      (tester) async {
    await _pumpCard(tester);

    expect(find.text('0/130g'), findsOneWidget);
    expect(find.textContaining('0 / 130'), findsNothing);
  });
}
