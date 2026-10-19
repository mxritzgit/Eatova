import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';
import '../support/pinned_clock.dart';

// Widget tests for the trend view, with injected fake loaders, no Supabase.

/// Tests with day-relative data pin the clock here; the days count back
/// from it, so "today" in the data and on screen is the same day.
final DateTime _jetzt = DateTime(2026, 9, 25, 12);

DateTime _daysAgo(int n) =>
    DateTime(_jetzt.year, _jetzt.month, _jetzt.day - n);

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
  testWidgets('zeigt Lade-Zustand bis der Loader antwortet', (tester) => withClockAt(_jetzt, () async {
    final completer = Completer<List<TrendDayTotals>>();
    await _pumpTrends(tester, loader: () => completer.future);

    expect(find.byKey(const ValueKey('trends-loading')), findsOneWidget);

    completer.complete([_day(0, kcal: 2000), _day(1, kcal: 2100)]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-loading')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
  }));

  testWidgets('Empty State ohne getrackte Tage', (tester) async {
    await _pumpTrends(
      tester,
      loader: () => Future.value(const <TrendDayTotals>[]),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trends-empty')), findsOneWidget);
    expect(find.text('Noch zu wenig Daten'), findsOneWidget);
    // No metrics and no chart in the empty state.
    expect(find.byKey(const ValueKey('trends-avg-kcal')), findsNothing);
    expect(find.byKey(const ValueKey('trends-chart')), findsNothing);
  });

  testWidgets('ein einzelner getrackter Tag bleibt im Chart sichtbar', (
    tester,
  ) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 25, 12)), () async {
      await _pumpTrends(
        tester,
        loader: () => Future.value([
          TrendDayTotals(
            day: DateTime(2026, 9, 25),
            kcal: 350,
            proteinG: 12,
            carbsG: 40,
            fatG: 8,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('trends-empty')), findsNothing);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-avg-kcal')), findsOneWidget);
      expect(find.text('noch kein abgeschlossener Tag'), findsNWidgets(2));
    });
  });

  testWidgets('rendert Kennzahlen (Ø kcal, Treffer-Quote, Ø Makros)', (
    tester,
  ) => withClockAt(_jetzt, () async {
    // Today 2200, yesterday 2000 (hit), 10 days ago 1200 (miss, but above
    // half the goal: complete). Gaps must NOT pull the average to 0; today
    // is excluded (B6) but stays charted.
    final totals = [
      _day(0, kcal: 2200, p: 120, c: 200, f: 60),
      _day(1, kcal: 2000, p: 100, c: 180, f: 80),
      _day(10, kcal: 1200, p: 80, c: 100, f: 40),
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // Default range 30 days, without today: average (2000+1200)/2 = 1600.
    expect(find.text('1.600 kcal'), findsOneWidget);
    expect(find.text('aus 2 vollständigen Tagen'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('1 von 2 Tagen (±10 %)'), findsOneWidget);
    // Avg macros without today: P (100+80)/2, C (180+100)/2, F (80+40)/2.
    expect(find.text('90 g'), findsOneWidget);
    expect(find.text('140 g'), findsOneWidget);
    expect(find.text('60 g'), findsOneWidget);
    expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
  }));

  testWidgets('Zeitraum-Umschalter filtert die Kennzahlen', (tester) => withClockAt(_jetzt, () async {
    final totals = [
      _day(0, kcal: 2200),
      _day(1, kcal: 2000),
      _day(10, kcal: 1200), // outside the 7-day window
    ];
    await _pumpTrends(tester, loader: () => Future.value(totals));
    await tester.pump();
    await tester.pumpAndSettle();

    // 30 days without today: (2000+1200)/2 = 1600.
    expect(find.text('1.600 kcal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trends-range-7')));
    await tester.pumpAndSettle();

    // 7 days: the old value drops out and today does not count.
    expect(find.text('2.000 kcal'), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(find.text('1 von 1 Tag (±10 %)'), findsOneWidget);
  }));

  testWidgets('B6: der laufende Teiltag verwaessert die Kennzahlen nicht', (
    tester,
  ) => withClockAt(_jetzt, () async {
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
  }));

  // 2026-10-19: one rule for a complete day. Half-logged days (below half
  // the goal) leave the averages and the tile says how many were left out.
  testWidgets(
    'unvollstaendige Tage fallen aus den Kennzahlen und werden genannt',
    (tester) => withClockAt(_jetzt, () async {
      final totals = [
        _day(0, kcal: 350),
        for (var d = 1; d <= 4; d++) _day(d, kcal: 2200, p: 120, c: 200, f: 60),
        _day(5, kcal: 600, p: 20, c: 60, f: 20),
        _day(6, kcal: 1099, p: 40, c: 100, f: 30),
      ];
      await _pumpTrends(tester, loader: () => Future.value(totals));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();

      // Over every logged day it was (4 x 2200 + 600 + 1099) / 6 = 1750.
      expect(find.text('2.200 kcal'), findsOneWidget);
      expect(
        find.text('aus 4 vollständigen Tagen · 2 unvollständige ausgelassen'),
        findsOneWidget,
      );
      expect(find.text('4 von 4 Tagen (±10 %)'), findsOneWidget);
      expect(find.text('120 g'), findsOneWidget);
      // The chart keeps every day (TrendReport marks the two to fade).
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    }),
  );

  testWidgets(
    'nur unvollstaendige Tage: die Kacheln sagen das statt "kein Tag"',
    (tester) => withClockAt(_jetzt, () async {
      final totals = [_day(1, kcal: 400), _day(2, kcal: 900)];
      await _pumpTrends(tester, loader: () => Future.value(totals));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('noch kein vollständiger Tag'), findsNWidgets(2));
      expect(find.text('noch kein abgeschlossener Tag'), findsNothing);
      expect(find.textContaining('NaN'), findsNothing);
    }),
  );

  testWidgets(
    'B6: nur heute im Fenster -> Kennzahlen leer statt NaN, Chart bleibt',
    (tester) => withClockAt(_jetzt, () async {
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
    }),
  );

  testWidgets('Fehler-Zustand mit funktionierendem Retry', (tester) => withClockAt(_jetzt, () async {
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
  }));

  // Design contract §7.2: both modes must render, and the painter's five
  // colours are parameters, so a drop shows up here. The old trio (both
  // brightnesses / textScaler 2.0 / EN smoke) is one matrix now, which pairs
  // `en` with 2.0 for the first time.
  renderMatrix(
    'Die Trend-Ansicht rendert overflow-frei',
    (tester, c) => withClockAt(_jetzt, () async {
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
    }),
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

  testWidgets('unter en steht die englische Kennzahl-Beschriftung im Baum', (
    tester,
  ) => withClockAt(_jetzt, () async {
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
  }));

  // Light pass (2026-10-04): a month of full iris bars weighed on the white
  // card; the bars take `progressAccent`, which IS the accent in dark.
  for (final (helligkeit, t) in const <(Brightness, AppTokens)>[
    (Brightness.dark, AppTokens.dark),
    (Brightness.light, AppTokens.light),
  ]) {
    testWidgets('${helligkeit.name}: die Balken tragen progressAccent', (
      tester,
    ) => withClockAt(_jetzt, () async {
      await _pumpTrends(
        tester,
        brightness: helligkeit,
        loader: () async => _sechsTage(),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('trends-chart')),
        paints..rrect(color: t.progressAccent.withValues(alpha: 0.92)),
      );
    }));
  }
  // The goal label sat on the bars ("Goal 2,200" half covered when a day
  // went over), later on a card-coloured pill that still hid the latest
  // bars. It is a legend in the card header now, where the repeated range
  // ("30 Tage", already the selected pill) used to float mid-row.
  for (final (helligkeit, t) in const <(Brightness, AppTokens)>[
    (Brightness.dark, AppTokens.dark),
    (Brightness.light, AppTokens.light),
  ]) {
    testWidgets('${helligkeit.name}: das Ziel steht als Legende im Kopf', (
      tester,
    ) => withClockAt(_jetzt, () async {
      await _pumpTrends(
        tester,
        brightness: helligkeit,
        loader: () async => _sechsTage(),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      final legende = find.byKey(const ValueKey('trends-goal-legend'));
      expect(
        find.descendant(of: legende, matching: find.text('Ziel 2.200')),
        findsOneWidget,
      );
      expect(find.text('30 Tage'), findsOneWidget, reason: 'only the pill');
      // Flush with the card's right edge, level with the title.
      final titel = tester.getRect(find.text('Kalorien pro Tag'));
      final karte = tester.getRect(
        find
            .ancestor(of: legende, matching: find.byType(AppCard))
            .first,
      );
      expect(
        karte.right - tester.getRect(legende).right,
        // The card's 18 px padding inside its 1 px border.
        moreOrLessEquals(19, epsilon: 0.5),
      );
      expect(
        tester.getCenter(legende).dy,
        moreOrLessEquals(titel.center.dy, epsilon: 1),
      );
      // Nothing card-coloured is painted over the plot any more (compared
      // as ARGB: the theme arrives through a lerp).
      expect(
        find.byKey(const ValueKey('trends-chart')),
        isNot(
          paints..something(
            (method, arguments) =>
                method == #drawRRect &&
                (arguments[1] as Paint).color.toARGB32() ==
                    t.surf.toARGB32(),
          ),
        ),
      );
    }));
  }

  testWidgets('die Zeitraum-Pillen zentrieren ihre Beschriftung', (
    tester,
  ) => withClockAt(_jetzt, () async {
    await _pumpTrends(tester, loader: () async => _sechsTage());
    await tester.pump();
    await tester.pumpAndSettle();
    for (final range in const [7, 30, 90]) {
      final pille = tester.getRect(find.byKey(ValueKey('trends-range-$range')));
      final text = tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey('trends-range-$range')),
          matching: find.text('$range Tage'),
        ),
      );
      expect(
        text.center.dx,
        moreOrLessEquals(pille.center.dx, epsilon: 1),
        reason: '$range Tage',
      );
    }
  }));
  test('dunkel bleiben die Balken der Akzent', () {
    expect(AppTokens.dark.progressAccent, AppTokens.dark.accent);
  });
}
