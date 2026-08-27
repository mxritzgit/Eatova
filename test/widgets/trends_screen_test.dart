import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';

import '../support/harness.dart';

// Widget tests for the trend view, with injected fake loaders, no Supabase.

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
  double textScale = 1.0,
  Locale locale = const Locale('de'),
}) async {
  await pumpLocalized(
    tester,
    TrendsScreen(kcalGoal: kcalGoal, loadTotals: loader),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    // TrendsScreen brings its own Scaffold and SafeArea.
    scaffold: false,
    safeArea: false,
  );
}

/// Six days of realistic totals — the fixture every render smoke uses.
List<TrendDayTotals> _sechsTage() => <TrendDayTotals>[
      for (var d = 0; d < 6; d++)
        _day(d, kcal: 1800 + d * 90, p: 110, c: 190, f: 65),
    ];

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
    // No metrics and no chart in the empty state.
    expect(find.byKey(const ValueKey('trends-avg-kcal')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsNothing);
  });

  testWidgets('rendert Kennzahlen (Ø kcal, Treffer-Quote, Ø Makros)', (
    tester,
  ) async {
    // Today 2200, yesterday 2000 (hit), 10 days ago 1000 (miss). Gaps must
    // NOT pull the average to 0; today is excluded (B6) but stays charted.
    final totals = [
      _day(0, kcal: 2200, p: 120, c: 200, f: 60),
      _day(1, kcal: 2000, p: 100, c: 180, f: 80),
      _day(10, kcal: 1000, p: 80, c: 100, f: 40),
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // Default range 30 days, without today: average (2000+1000)/2 = 1500.
    expect(find.text('1.500 kcal'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('1 von 2 Tagen (±10 %)'), findsOneWidget);
    // Avg macros without today: P (100+80)/2, C (180+100)/2, F (80+40)/2.
    expect(find.text('90 g'), findsOneWidget);
    expect(find.text('140 g'), findsOneWidget);
    expect(find.text('60 g'), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
  });

  testWidgets('Zeitraum-Umschalter filtert die Kennzahlen', (tester) async {
    final totals = [
      _day(0, kcal: 2200),
      _day(1, kcal: 2000),
      _day(10, kcal: 1000), // outside the 7-day window
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // 30 days without today: (2000+1000)/2 = 1500.
    expect(find.text('1.500 kcal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trends-range-7')));
    await tester.pumpAndSettle();

    // 7 days: the old value drops out and today does not count.
    expect(find.text('2.000 kcal'), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(find.text('1 von 1 Tag (±10 %)'), findsOneWidget);
  });

  testWidgets('B6: der laufende Teiltag verwaessert die Kennzahlen nicht', (
    tester,
  ) async {
    // Six days on target, then a 350 kcal breakfast this morning, which used
    // to dilute the view to 1,936 kcal / 86 %.
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
    // Avg macros likewise undiluted.
    expect(find.text('120 g'), findsOneWidget);
    expect(find.text('200 g'), findsOneWidget);
    expect(find.text('60 g'), findsOneWidget);
    // The chart keeps the current day.
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    // And the label says today does not count.
    expect(find.byKey(const ValueKey('trends-metrics-note')), findsOneWidget);
  });

  testWidgets(
    'B6: nur heute im Fenster -> Kennzahlen leer statt NaN, Chart bleibt',
    (tester) async {
      // Two totals, so not the empty state, but only today is in the window.
      final totals = [_day(0, kcal: 1800), _day(40, kcal: 2000)];
      await _pumpTrends(tester, loader: () => Future.value(totals));
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      // Both metric tiles show the dash, no 0 and no NaN from a 0/0 division.
      expect(find.text('–'), findsNWidgets(5)); // 2 tiles + 3 macros
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

  // Design contract §7.2: both modes must render, and the painter's five
  // colours are parameters, so a drop shows up here. The old trio (both
  // brightnesses / textScaler 2.0 / EN smoke) is one matrix now, which pairs
  // `en` with 2.0 for the first time.
  renderMatrix(
    'Die Trend-Ansicht rendert overflow-frei',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(
        tester,
        TrendsScreen(kcalGoal: 2200, loadTotals: () async => _sechsTage()),
        scaffold: false,
        safeArea: false,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      expect(find.text(c.l10n.trendsTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-close')), findsOneWidget);
      // Not just chrome: the avg-calories label is a real translation.
      expect(find.text(c.l10n.trendsStatAvgKcalLabel), findsOneWidget);

      // Draw the 7-day view (weekday axis) once as well — its own layout with
      // a weekday axis instead of the 30-day date axis.
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
    textScales: const <double>[1.0, 2.0],
  );

  testWidgets('auch ein synchron werfender Loader endet im Retry-Zustand', (
    tester,
  ) async {
    // Uninitialized, the default loader throws SYNCHRONOUSLY, which must be
    // the error state, not a crash.
    await _pumpTrends(
      tester,
      loader: () => throw StateError('Supabase nicht initialisiert'),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-retry')), findsOneWidget);
  });

  testWidgets('unter en steht die englische Kennzahl-Beschriftung im Baum',
      (tester) async {
    // Counter-check to the matrix above: the label must really CHANGE with
    // the language, not just resolve to whatever the ARB lookup returns.
    pinPhoneViewport(tester);
    await _pumpTrends(
      tester,
      locale: const Locale('en'),
      loader: () async => _sechsTage(),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('AVG CALORIES'), findsOneWidget);
    expect(find.text('Ø KALORIEN'), findsNothing);
  });
}
