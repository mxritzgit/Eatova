import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Widget-Tests fuer die Trend-Ansicht: Empty State, Kennzahlen-Rendering,
// Zeitraum-Umschalter und Fehler-/Retry-Zustand — alles mit injizierten
// Fake-Loadern, ohne Supabase.

DateTime _daysAgo(int n) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - n);
}

TrendDayTotals _day(
  int daysAgo, {
  required int kcal,
  double p = 0,
  double c = 0,
  double f = 0,
}) => TrendDayTotals(
  day: _daysAgo(daysAgo),
  kcal: kcal,
  proteinG: p,
  carbsG: c,
  fatG: f,
);

Future<void> _pumpTrends(
  WidgetTester tester, {
  required TrendTotalsLoader loader,
  int kcalGoal = 2200,
  Brightness brightness = Brightness.dark,
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      home: textScaler == null
          ? TrendsScreen(kcalGoal: kcalGoal, loadTotals: loader)
          : MediaQuery(
              data: MediaQueryData(textScaler: textScaler),
              child: TrendsScreen(kcalGoal: kcalGoal, loadTotals: loader),
            ),
    ),
  );
}

/// iPhone-14-Viewport, damit die Karten eine realistische Breite bekommen.
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Sammelt Overflow-Fehler waehrend [body] und meldet sie gesammelt.
/// FlutterError.onError wird VOR dem expect() zurueckgesetzt — sonst asserted
/// das Test-Binding beim ersten TestFailure.
Future<void> _expectNoOverflow(Future<void> Function() body) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(overflows, isEmpty, reason: overflows.join('\n'));
}

void main() {
  testWidgets('zeigt Lade-Zustand bis der Loader antwortet', (tester) async {
    final completer = Completer<List<TrendDayTotals>>();
    await _pumpTrends(tester, loader: () => completer.future);

    expect(find.byKey(const ValueKey('trends-loading')), findsOneWidget);

    completer.complete([_day(0, kcal: 2000), _day(1, kcal: 2100)]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-loading')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
  });

  testWidgets('Empty State bei weniger als zwei getrackten Tagen', (
    tester,
  ) async {
    await _pumpTrends(
      tester,
      loader: () => Future.value([_day(0, kcal: 1800)]),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-empty')), findsOneWidget);
    expect(find.text('Noch zu wenig Daten'), findsOneWidget);
    // Keine Kennzahlen/kein Chart im Empty State.
    expect(find.byKey(const ValueKey('trends-avg-kcal')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsNothing);
  });

  testWidgets('rendert Kennzahlen (Ø kcal, Treffer-Quote, Ø Makros)', (
    tester,
  ) async {
    // Drei getrackte Tage: heute 2200, gestern 2000 (Hit, Korridor
    // 1980-2420), vor 10 Tagen 1000 (Miss). Luecken dazwischen duerfen den
    // Schnitt NICHT auf 0 ziehen — und heute zaehlt als Teiltag gar nicht
    // erst mit (B6), bleibt aber im Chart.
    final totals = [
      _day(0, kcal: 2200, p: 120, c: 200, f: 60),
      _day(1, kcal: 2000, p: 100, c: 180, f: 80),
      _day(10, kcal: 1000, p: 80, c: 100, f: 40),
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // Default-Zeitraum 30 Tage, ohne heute: Schnitt (2000+1000)/2 = 1500.
    expect(find.text('1.500 kcal'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('1 von 2 Tagen (±10 %)'), findsOneWidget);
    // Ø Makros ohne heute: P (100+80)/2, C (180+100)/2, F (80+40)/2.
    expect(find.text('90 g'), findsOneWidget);
    expect(find.text('140 g'), findsOneWidget);
    expect(find.text('60 g'), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
  });

  testWidgets('Zeitraum-Umschalter filtert die Kennzahlen', (tester) async {
    final totals = [
      _day(0, kcal: 2200),
      _day(1, kcal: 2000),
      _day(10, kcal: 1000), // liegt ausserhalb des 7-Tage-Fensters
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // 30 Tage ohne heute: (2000+1000)/2 = 1500.
    expect(find.text('1.500 kcal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trends-range-7')));
    await tester.pumpAndSettle();

    // 7 Tage: der 10-Tage-alte Wert faellt raus, heute zaehlt nicht mit ->
    // bleibt gestern allein, im Korridor.
    expect(find.text('2.000 kcal'), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(find.text('1 von 1 Tag (±10 %)'), findsOneWidget);
  });

  testWidgets('B6: der laufende Teiltag verwaessert die Kennzahlen nicht', (
    tester,
  ) async {
    // Review-Szenario: sechs abgeschlossene Tage mit exakt dem Ziel, dann
    // heute Morgen ein 350-kcal-Fruehstueck. Vorher zeigte die Ansicht
    // 1.936 kcal / 86 % / „6 von 7 Tagen".
    final totals = [
      _day(0, kcal: 350, p: 10, c: 40, f: 8),
      for (var d = 1; d <= 6; d++) _day(d, kcal: 2200, p: 120, c: 200, f: 60),
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('trends-range-7')));
    await tester.pumpAndSettle();

    expect(find.text('2.200 kcal'), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(find.text('6 von 6 Tagen (±10 %)'), findsOneWidget);
    // Ø Makros ebenfalls unverduennt.
    expect(find.text('120 g'), findsOneWidget);
    expect(find.text('200 g'), findsOneWidget);
    expect(find.text('60 g'), findsOneWidget);
    // Das Chart behaelt den laufenden Tag.
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    // Und die Beschriftung sagt, dass heute nicht mitzaehlt.
    expect(find.byKey(const ValueKey('trends-metrics-note')), findsOneWidget);
  });

  testWidgets(
    'B6: nur heute im Fenster -> Kennzahlen leer statt NaN, Chart bleibt',
    (tester) async {
      // Zwei Tagessummen (der Empty-State greift also nicht), aber im
      // 7-Tage-Fenster liegt nur der laufende Tag.
      final totals = [_day(0, kcal: 1800), _day(40, kcal: 2000)];
      await _pumpTrends(tester, loader: () => Future.value(totals));
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      // Beide Kennzahlen-Kacheln zeigen den Gedankenstrich, keine 0 und
      // kein NaN aus einer 0/0-Division.
      expect(find.text('–'), findsNWidgets(5)); // 2 Kacheln + 3 Makros
      expect(find.text('noch kein abgeschlossener Tag'), findsNWidgets(2));
      expect(find.textContaining('NaN'), findsNothing);
      expect(find.text('0 von 0 Tagen (±10 %)'), findsNothing);
    },
  );

  testWidgets('Fehler-Zustand mit funktionierendem Retry', (tester) async {
    var calls = 0;
    Future<List<TrendDayTotals>> loader() {
      calls++;
      if (calls == 1) {
        return Future<List<TrendDayTotals>>.error(StateError('offline'));
      }
      return Future.value([_day(0, kcal: 2000), _day(1, kcal: 2100)]);
    }

    await _pumpTrends(tester, loader: loader);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
    expect(find.text('Trends konnten nicht geladen werden'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trends-retry')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-error')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    expect(calls, 2);
  });

  // Design-Vertrag §7.2: jeder Screen muss in BEIDEN Anzeige-Modi rendern.
  // Der Trend-Painter bekommt seine fuenf Farben seit dem Refactor als
  // Parameter — faellt eine davon aus dem Vertrag, faellt es hier auf.
  for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
    testWidgets('rendert in ${brightness.name} ohne Exception', (tester) async {
      _pinViewport(tester);
      await _pumpTrends(
        tester,
        brightness: brightness,
        loader: () => Future.value([
          for (var d = 0; d < 6; d++) _day(d, kcal: 1800 + d * 90, p: 110, c: 190, f: 65),
        ]),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      expect(find.text('Trends'), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-close')), findsOneWidget);
    });
  }

  testWidgets('rendert bei textScaler 2.0 ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow(() async {
      await _pumpTrends(
        tester,
        textScaler: const TextScaler.linear(2.0),
        loader: () => Future.value([
          for (var d = 0; d < 6; d++) _day(d, kcal: 2200, p: 120, c: 200, f: 60),
        ]),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // Auch die 7-Tage-Ansicht (Wochentags-Achse) einmal zeichnen.
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });
  });

  testWidgets('auch ein synchron werfender Loader endet im Retry-Zustand', (
    tester,
  ) async {
    // Produktionsfall: Supabase.instance nicht initialisiert -> der Default-
    // Loader wirft SYNCHRON. Das darf kein Crash sein, sondern der normale
    // Fehler-Zustand.
    await _pumpTrends(
      tester,
      loader: () => throw StateError('Supabase nicht initialisiert'),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-retry')), findsOneWidget);
  });
}
