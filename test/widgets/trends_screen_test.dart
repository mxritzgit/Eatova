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
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(),
      home: TrendsScreen(kcalGoal: kcalGoal, loadTotals: loader),
    ),
  );
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
    // Drei getrackte Tage: heute 2200 (Hit), gestern 2000 (Hit, Korridor
    // 1980-2420), vor 10 Tagen 1000 (Miss). Luecken dazwischen duerfen den
    // Schnitt NICHT auf 0 ziehen.
    final totals = [
      _day(0, kcal: 2200, p: 120, c: 200, f: 60),
      _day(1, kcal: 2000, p: 100, c: 180, f: 80),
      _day(10, kcal: 1000, p: 80, c: 100, f: 40),
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // Default-Zeitraum 30 Tage: Schnitt (2200+2000+1000)/3 = 1733.
    expect(find.text('1.733 kcal'), findsOneWidget);
    expect(find.text('67 %'), findsOneWidget);
    expect(find.text('2 von 3 Tagen (±10 %)'), findsOneWidget);
    // Ø Makros: P (120+100+80)/3, C (200+180+100)/3, F (60+80+40)/3.
    expect(find.text('100 g'), findsOneWidget);
    expect(find.text('160 g'), findsOneWidget);
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

    expect(find.text('1.733 kcal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trends-range-7')));
    await tester.pumpAndSettle();

    // Nur noch heute + gestern: Schnitt 2100, beide im Korridor.
    expect(find.text('2.100 kcal'), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(find.text('2 von 2 Tagen (±10 %)'), findsOneWidget);
  });

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
