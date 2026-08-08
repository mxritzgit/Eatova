// G10: Blur ueber einer einfarbigen Flaeche.
//
// Das Glass-Panel der Kalorienkarte legte einen BackdropFilter(sigma 20) unter
// den transluzenten forgeGlassFill. Hinter dem Panel liegt aber nichts ausser
// Scaffold(backgroundColor: bg) — Header, Datumsleiste, Add-Block und Verlauf
// sind nicht ueberlappende Geschwister derselben Column
// (meal_analysis_screen.dart:253-286). Ein Blur ueber einheitlichem #0B0D11
// gibt #0B0D11 zurueck, der Fill komponiert also identisch.
//
// Backdrop-Filter-Layer sind nicht raster-cachebar: der Pass lief in JEDEM
// Frame, in dem der Food-Tab rastert (LivelyEntrance 320 ms pro Tab-Wechsel,
// jeder Scroll-Frame des Tagebuchs, die 160-ms-Datumschip-Animation). Das
// RepaintBoundary half nicht — es cacht den Inhalt, nicht den Backdrop-Pass.
//
// Das Projekt fuehrt KEINE Golden-Tests (weder matchesGoldenFile noch ein
// test/goldens-Verzeichnis existieren), deshalb hier die Widget-Baum-Variante:
// der Filter ist weg UND die Fuellung/der Rand sind unveraendert.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/theme/app_colors.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/calories_overview_card.dart';

Future<void> _pumpCard(WidgetTester tester) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(),
      home: const Scaffold(
        backgroundColor: bg,
        body: Padding(
          padding: EdgeInsets.all(20),
          child: CaloriesOverviewCard(
            dailyConsumedKcal: 1200,
            kcalGoal: 2200,
            burnedKcal: 180,
            macroProgress: MacroProgress.empty,
            profile: UserProfile(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Die Glass-Kalorienkarte rastert keinen Backdrop-Filter mehr',
      (tester) async {
    await _pumpCard(tester);

    expect(find.byType(CaloriesOverviewCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CaloriesOverviewCard),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
      reason: 'Der Blur laeuft ueber einer einfarbigen Flaeche und kostet in '
          'jedem Frame Zeit, ohne etwas zu zeigen',
    );
  });

  testWidgets('Fuellung und Hairline des Glass-Panels bleiben unveraendert',
      (tester) async {
    await _pumpCard(tester);

    final panels = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(CaloriesOverviewCard),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.color == forgeGlassFill)
        .toList();

    expect(panels, hasLength(1),
        reason: 'Genau eine Flaeche traegt weiterhin forgeGlassFill');
    expect(panels.single.border, Border.all(color: forgeGlassBorder),
        reason: 'Der Hairline-Rand bleibt derselbe');
    expect(panels.single.borderRadius, BorderRadius.circular(rCard),
        reason: 'Die Panel-Rundung bleibt dieselbe');
  });

  testWidgets('Der dekorative forgeLime-Glow bleibt erhalten', (tester) async {
    await _pumpCard(tester);

    // Der Glow ist ein ImageFiltered-Kreis oben rechts — er ist Absicht und
    // darf beim Entfernen des Backdrop-Passes nicht mit verschwinden.
    expect(
      find.descendant(
        of: find.byType(CaloriesOverviewCard),
        matching: find.byType(ImageFiltered),
      ),
      findsOneWidget,
    );
  });
}
