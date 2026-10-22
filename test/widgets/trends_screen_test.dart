import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../support/harness.dart';
import '../support/pinned_clock.dart';

// Widget tests for the trend view, with injected fake loaders, no Supabase.

/// Tests with day-relative data pin the clock here; the days count back
/// from it, so "today" in the data and on screen is the same day.
final DateTime _jetzt = DateTime(2026, 9, 25, 12);

DateTime _daysAgo(int n) =>
    DateTime(_jetzt.year, _jetzt.month, _jetzt.day - n);

/// The label tests count their days back from here.
final DateTime _letzterAugust = DateTime(2026, 8, 31, 12);

TrendDayTotals _tag(DateTime day, {int kcal = 2000}) =>
    TrendDayTotals(day: day, kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0);

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
    // The outline of the chart and stat cards, no default spinner.
    expect(find.byType(CircularProgressIndicator), findsNothing);

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

  testWidgets(
    'B6: nur heute erfasst -> kein Empty State, Kennzahlen leer statt NaN',
    (tester) => withClockAt(_jetzt, () async {
      await _pumpTrends(
        tester,
        loader: () => Future.value([_day(0, kcal: 1800, p: 12, c: 40, f: 8)]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('trends-empty')), findsNothing);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
      // Both metric tiles show the dash, no 0 and no NaN from a 0/0 division.
      expect(find.text('–'), findsNWidgets(5)); // 2 tiles + 3 macros
      expect(find.text('noch kein abgeschlossener Tag'), findsNWidgets(2));
      expect(find.textContaining('NaN'), findsNothing);
      expect(find.text('0 von 0 Tagen (±10 %)'), findsNothing);
    }),
  );

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
    // B6: the footnote says today does not count.
    expect(find.byKey(const ValueKey('trends-metrics-note')), findsOneWidget);
  }));

  // Entries without a macro add 0 g: an average over such a day is a lower
  // bound (review 2026-10-22). Today is not averaged, so its gap is not
  // either.
  testWidgets(
    'unbekannte Makros machen den Schnitt zur Untergrenze',
    (tester) => withClockAt(_jetzt, () async {
      final totals = [
        TrendDayTotals(
          day: _daysAgo(0),
          kcal: 2200,
          proteinG: 120,
          carbsG: 200,
          fatG: 60,
          fatMissing: 1,
        ),
        _day(1, kcal: 2000, p: 100, c: 180, f: 80),
        TrendDayTotals(
          day: _daysAgo(2),
          kcal: 2100,
          proteinG: 80,
          carbsG: 100,
          fatG: 40,
          carbsMissing: 1,
        ),
      ];
      await _pumpTrends(tester, loader: () => Future.value(totals));
      await tester.pumpAndSettle();

      expect(find.text('90 g'), findsOneWidget);
      expect(find.text('≥140 g'), findsOneWidget);
      expect(find.text('60 g'), findsOneWidget);
    }),
  );

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
  // `en` with 2.0 for the first time. On the narrowest phone (320 px), where
  // the chart's date captions once overflowed at 2.0.
  renderMatrix(
    'Die Trend-Ansicht rendert overflow-frei',
    (tester, c) => withClockAt(_jetzt, () async {
      tester.view.physicalSize = const Size(960, 1704);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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

  // The goal label sat on the bars ("Goal 2,200" half covered when a day
  // went over), later on a card-coloured pill that still hid the latest
  // bars. It is a legend in the card header now, where the repeated range
  // ("30 Tage", already the selected pill) used to float mid-row.
  testWidgets('das Ziel steht als Legende im Kopf, nicht auf dem Plot', (
    tester,
  ) => withClockAt(_jetzt, () async {
    await _pumpTrends(
      tester,
      brightness: Brightness.light,
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
    // Nothing card-coloured is painted over the plot any more (compared as
    // ARGB: the theme arrives through a lerp).
    expect(
      find.byKey(const ValueKey('trends-chart')),
      isNot(
        paints..something(
          (method, arguments) =>
              method == #drawRRect &&
              (arguments[1] as Paint).color.toARGB32() ==
                  AppTokens.light.surf.toARGB32(),
        ),
      ),
    );
  }));

  // Perf package B6: the painter rebuilt every DateFormat and TextPainter
  // inside paint(), so the 550 ms build-up paid for them on each of its ~33
  // frames. They are laid out once in [TrendChartLabels] now.
  group('TrendChartLabels', () {
    test(
      'gleiche Eingaben liefern dieselbe Instanz, ein Sprachwechsel nicht',
      () {
        final window = <TrendDayTotals?>[
          for (var i = 0; i < 7; i++) _tag(DateTime(2026, 8, 25 + i)),
        ];
        final goals = List<int>.filled(7, 2200);
        TrendChartLabels bauen(
          TrendChartLabels? vorher,
          AppLocalizations l10n,
        ) => TrendChartLabels.resolve(
          vorher,
          values: [for (final day in window) day?.kcal],
          goals: goals,
          firstDay: DateTime(2026, 8, 25),
          axisTextColor: const Color(0xFF888888),
          l10n: l10n,
        );

        final erst = bauen(null, deL10n);
        expect(identical(bauen(erst, deL10n), erst), isTrue);
        // 7-day view: weekday row present, one label per slot.
        expect(erst.weekdayLabels, hasLength(7));
        expect(erst.gridLabels, hasLength(4));
        // The goal line's label is a legend in the card header now.

        final englisch = bauen(erst, enL10n);
        expect(identical(englisch, erst), isFalse);
        expect(
          englisch.weekdayLabels.first.text!.toPlainText(),
          isNot(erst.weekdayLabels.first.text!.toPlainText()),
        );
      },
    );

    test(
      'ein anderer Farbtoken (Theme-Wechsel) baut die Beschriftungen neu',
      () {
        final window = <TrendDayTotals?>[_tag(DateTime(2026, 8, 30))];
        TrendChartLabels bauen(TrendChartLabels? vorher, Color farbe) =>
            TrendChartLabels.resolve(
              vorher,
              values: [for (final day in window) day?.kcal],
              goals: const [2200],
              firstDay: DateTime(2026, 8, 30),
              axisTextColor: farbe,
              l10n: deL10n,
            );

        final erst = bauen(null, const Color(0xFF888888));
        expect(identical(bauen(erst, const Color(0xFF222222)), erst), isFalse);
        // Not the 7-day view: no weekday row at all.
        expect(erst.weekdayLabels, isEmpty);
      },
    );
  });

  group('TrendsScreen Aufbau-Animation', () {
    testWidgets('legt ueber die Frames hinweg keine Beschriftung neu an', (
      tester,
    ) => withClockAt(_letzterAugust, () async {
      final totals = <TrendDayTotals>[
        for (var i = 0; i < 7; i++)
          _tag(DateTime(2026, 8, 25 + i), kcal: 1800 + i * 50),
      ];
      await pumpLocalized(
        tester,
        TrendsScreen(kcalGoal: 2200, loadTotals: () async => totals),
        // The build-up must really run; the harness kills motion by default.
        reducedMotion: false,
        // TrendsScreen brings its own Scaffold and SafeArea.
        scaffold: false,
        safeArea: false,
      );
      await tester.pump();
      // 7-day range: the weekday row is the most expensive label set.
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pump();

      // The first frame of the build-up lays the labels out.
      final nachErstemFrame = TrendChartLabels.debugLayoutCount;
      expect(nachErstemFrame, greaterThan(0));

      // ~20 further frames of the 550 ms build-up.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(
        TrendChartLabels.debugLayoutCount,
        nachErstemFrame,
        reason: 'paint() darf keine TextPainter mehr bauen',
      );

      await tester.pumpAndSettle();
      expect(TrendChartLabels.debugLayoutCount, nachErstemFrame);
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    }));
  });
}
