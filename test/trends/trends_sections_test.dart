// The trends page's store sections (2026-10-18): steps, weight and training,
// the protein goal days, the six-month range with weekly bars, the step
// backfill per range, live rebuilds from the store, the sections surviving a
// failed server window, and Today's trends card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/today/today_trends.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/trend_service.dart';

import '../support/harness.dart';
import '../support/pinned_clock.dart';

final DateTime _now = DateTime(2026, 10, 18, 12);

DateTime _day(int back) => DateTime(2026, 10, 18 - back);

List<TrendDayTotals> _days() => [
  for (var d = 0; d < 10; d++)
    TrendDayTotals(
      day: _day(d),
      kcal: 2000,
      proteinG: d.isEven ? 140 : 100,
      carbsG: 200,
      fatG: 60,
    ),
];

TrendLocalData _local({
  bool steps = true,
  List<WeightLogEntry>? weighIns,
  int workouts = 4,
}) => TrendLocalData(
  stepsByDay: steps
      ? {
          localDayKey(_day(1)): 12000,
          localDayKey(_day(2)): 6000,
          localDayKey(_day(3)): 9000,
        }
      : const {},
  stepsToday: steps ? 3000 : null,
  hasStepSource: steps,
  weighIns:
      weighIns ??
      [
        WeightLogEntry(
          timestamp: _day(20).add(const Duration(hours: 7)),
          weightKg: 81,
        ),
        WeightLogEntry(
          timestamp: _day(10).add(const Duration(hours: 7)),
          weightKg: 80.2,
        ),
        WeightLogEntry(
          timestamp: _day(5).add(const Duration(hours: 7)),
          weightKg: 79.8,
        ),
        WeightLogEntry(
          timestamp: _day(1).add(const Duration(hours: 7)),
          weightKg: 79.6,
        ),
      ],
  workoutsFinishedAt: [
    for (var i = 0; i < workouts; i++)
      _day(1 + i * 5).add(const Duration(hours: 18)),
  ],
  proteinGoalG: 130,
  stepsGoal: 8000,
);

Future<List<int>> _pump(
  WidgetTester tester, {
  TrendLocalData Function()? read,
  Listenable? changes,
  TrendTotalsLoader? loader,
  VoidCallback? onAskCoach,
}) async {
  final backfills = <int>[];
  await pumpLocalized(
    tester,
    TrendsScreen(
      kcalGoal: 2000,
      loadTotals: loader ?? () async => _days(),
      local: TrendLocalSource(
        changes: changes ?? ChangeNotifier(),
        read: read ?? _local,
      ),
      onBackfillSteps: (days) async => backfills.add(days),
      onAskCoachAboutWeight: onAskCoach,
    ),
    locale: const Locale('de'),
    scaffold: false,
    safeArea: false,
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return backfills;
}

Future<void> _scrollTo(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    300,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('screen-trends')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

String _textIn(String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '')
    .join(' | ');

void main() {
  testWidgets(
    '30 Tage: Schritte, Gewicht, Training und Proteinziel-Tage',
    (tester) => withClockAt(_now, () async {
      await _pump(tester);

      expect(
        find.text('Proteinziel an 4 von 9 Tagen erreicht'),
        findsOneWidget,
        reason: 'days 1..9 completed; 2, 4, 6 and 8 reach 130 g',
      );

      await _scrollTo(tester, 'trends-steps');
      final steps = _textIn('trends-steps');
      expect(steps, contains('9.000'), reason: 'average of 12,000/6,000/9,000');
      expect(steps, contains('pro Tag, Werte für 3 von 29 Tagen'));
      expect(steps, contains('Bester Tag: 12.000 Schritte am 17.10.'));
      expect(steps, contains('Schrittziel an 2 von 3 Tagen erreicht'));
      expect(find.byKey(const ValueKey('trends-steps-chart')), findsOneWidget);

      await _scrollTo(tester, 'trends-weight');
      final weight = _textIn('trends-weight');
      expect(weight, contains('−1,4 kg'));
      expect(weight, contains('81,0 → 79,6 kg, 4 Wiegungen'));
      expect(
        weight,
        contains('Gemessenes Tempo: −0,55 kg/Woche'),
        reason: 'the regression of the four days, −0.527 kg/week',
      );

      await _scrollTo(tester, 'trends-training');
      final training = _textIn('trends-training');
      expect(training, contains('4 Trainings'));
      expect(training, contains('Ø 0,9 pro Woche'));
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'nur ein stagnierendes Gewicht bietet die Frage an den Coach an '
    '(2026-10-22)',
    (tester) => withClockAt(_now, () async {
      WeightLogEntry at(int back, double kg) => WeightLogEntry(
        timestamp: _day(back).add(const Duration(hours: 7)),
        weightKg: kg,
      );
      for (final (name, weighIns, offered) in <(String, List<WeightLogEntry>?, bool)>[
        ('falling 0.52 kg a week', null, false),
        ('flat', [at(20, 80), at(10, 80.2), at(1, 80.1)], true),
      ]) {
        var asked = 0;
        await _pump(
          tester,
          read: () => _local(weighIns: weighIns),
          onAskCoach: () => asked++,
        );
        await _scrollTo(tester, 'trends-weight');
        final pill = find.byKey(const ValueKey('trends-ask-coach-weight'));
        expect(pill, offered ? findsOneWidget : findsNothing, reason: name);
        if (!offered) continue;
        await tester.ensureVisible(pill);
        await tester.tap(pill);
        await tester.pumpAndSettle();
        expect(asked, 1, reason: name);
      }
    }),
  );

  testWidgets(
    'ohne Schrittquelle erklaert der Abschnitt, woher Schritte kommen',
    (tester) => withClockAt(_now, () async {
      await _pump(
        tester,
        read: () => _local(steps: false, weighIns: const [], workouts: 0),
      );
      await _scrollTo(tester, 'trends-training');
      expect(find.byKey(const ValueKey('trends-steps-chart')), findsNothing);
      expect(
        _textIn('trends-steps'),
        contains('Schritte kommen aus Apple Health oder Health Connect'),
      );
      expect(
        _textIn('trends-weight'),
        contains('Keine Wiegung in diesem Zeitraum.'),
      );
      expect(_textIn('trends-training'), contains('Kein Training'));
    }),
  );

  testWidgets(
    'sechs Monate: Wochenbalken mit Hinweis, Nachladen je Zeitraum',
    (tester) => withClockAt(_now, () async {
      final backfills = await _pump(tester);
      expect(backfills, [30]);
      expect(find.byKey(const ValueKey('trends-weekly-note')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('trends-range-182')));
      await tester.pumpAndSettle();
      expect(find.text('Wochenschnitt'), findsOneWidget);
      await _scrollTo(tester, 'trends-weekly-note');
      expect(backfills, [30, 182]);

      // Shorter ranges are covered by the six months already read.
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('trends-range-7')),
        find.byKey(const ValueKey('screen-trends')),
        const Offset(0, 300),
      );
      await tester.tap(find.byKey(const ValueKey('trends-range-7')));
      await tester.pumpAndSettle();
      expect(backfills, [30, 182]);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'ein Store-Signal baut die Abschnitte mit den neuen Werten neu',
    (tester) => withClockAt(_now, () async {
      final changes = ValueNotifier<int>(0);
      var data = _local(workouts: 1);
      await _pump(tester, changes: changes, read: () => data);
      await _scrollTo(tester, 'trends-training');
      expect(_textIn('trends-training'), contains('1 Training'));

      data = _local(workouts: 3);
      changes.value++;
      await tester.pumpAndSettle();
      expect(_textIn('trends-training'), contains('3 Trainings'));
    }),
  );

  testWidgets(
    'scheitert das Server-Fenster, bleiben die lokalen Abschnitte',
    (tester) => withClockAt(_now, () async {
      await _pump(tester, loader: () async => throw StateError('offline'));
      expect(find.byKey(const ValueKey('trends-error')), findsOneWidget);
      await _scrollTo(tester, 'trends-training');
      expect(find.byKey(const ValueKey('trends-steps')), findsOneWidget);
      expect(find.byKey(const ValueKey('trends-weight')), findsOneWidget);
    }),
  );

  testWidgets(
    'lokale Tage ueberlagern das Server-Fenster (TRN-9)',
    (tester) => withClockAt(_now, () async {
      await _pump(
        tester,
        loader: () async => [
          TrendDayTotals(
            day: _day(1),
            kcal: 1000,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
          ),
        ],
        read: () => TrendLocalData(
          dayTotals: {
            localDayKey(_day(1)): TrendDayTotals(
              day: _day(1),
              kcal: 1600,
              proteinG: 0,
              carbsG: 0,
              fatG: 0,
            ),
          },
        ),
      );
      expect(_textIn('trends-avg-kcal'), contains('1.600 kcal'));
    }),
  );

  group('TodayTrendsCard', () {
    testWidgets('zeigt die Schnitte und oeffnet die Trends', (tester) async {
      var opened = 0;
      await pumpLocalized(
        tester,
        TodayTrendsCard(
          preview: (avgKcal: 2104.4, avgProteinG: 117.6, avgSteps: 8432),
          onOpen: () => opened++,
        ),
        locale: const Locale('de'),
      );
      expect(find.text('2.104 kcal'), findsOneWidget);
      expect(find.text('118 g'), findsOneWidget);
      expect(find.text('8.432'), findsOneWidget);
      expect(find.text('Ø der letzten 7 Tage'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('today-trends')));
      expect(opened, 1);
      final node = tester.getSemantics(
        find.byKey(const ValueKey('today-trends')),
      );
      expect(node.hint, contains('Schritte'));
    });

    testWidgets(
      'ohne Schrittquelle faellt die Spalte weg, ohne Daten ein Satz',
      (tester) async {
        await pumpLocalized(
          tester,
          Column(
            children: [
              TodayTrendsCard(
                preview: (avgKcal: 1900, avgProteinG: null, avgSteps: null),
                onOpen: () {},
              ),
              TodayTrendsCard(
                preview: (avgKcal: null, avgProteinG: null, avgSteps: null),
                onOpen: () {},
              ),
            ],
          ),
          locale: const Locale('de'),
        );
        expect(find.text('Schritte'), findsNothing);
        expect(find.text('1.900 kcal'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('today-trends-empty')),
          findsOneWidget,
        );
      },
    );
  });
}
